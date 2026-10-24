package provider

import (
	"context"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"sort"
	"sync"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// Simulated es un proveedor falso para desarrollo local y demos: genera
// precios verosímiles sin llamar a ninguna API ni necesitar claves.
//
// Cada ruta tiene un precio base estable (derivado de su clave) y en cada
// consulta varía ±15 %. Con probabilidad ErrorFareRate devuelve un precio al
// 30 %, imitando una "tarifa error" para poder probar el detector sniper.
type Simulated struct {
	// Latency simula el tiempo de respuesta de una API real.
	Latency time.Duration
	// ErrorFareRate entre 0 y 1.
	ErrorFareRate float64

	mu  sync.Mutex
	rng *rand.Rand
	now func() time.Time
}

// NewSimulated crea el proveedor con una semilla fija (reproducible en tests).
func NewSimulated(seed uint64, latency time.Duration, errorFareRate float64) *Simulated {
	return &Simulated{
		Latency:       latency,
		ErrorFareRate: errorFareRate,
		rng:           rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)),
		now:           time.Now,
	}
}

// Name implementa FareProvider.
func (s *Simulated) Name() string { return "simulated" }

// Quote implementa FareProvider.
func (s *Simulated) Quote(ctx context.Context, spec domain.WatchSpec) ([]domain.Quote, error) {
	if err := spec.Validate(); err != nil {
		return nil, fmt.Errorf("simulated: %w", err)
	}
	if s.Latency > 0 {
		timer := time.NewTimer(s.Latency)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("simulated: %w", ctx.Err())
		case <-timer.C:
		}
	}

	// Un hash convierte la clave de la ruta en un número siempre igual para la
	// misma ruta: así cada ruta tiene "su" precio base estable.
	h := fnv.New64a()
	_, _ = h.Write([]byte(spec.Key()))      // Write de un hash nunca falla.
	base := int64(4_000 + h.Sum64()%90_000) // entre 40 € y 940 €
	if spec.Cabin == domain.CabinBusiness || spec.Cabin == domain.CabinFirst {
		base *= 4
	}

	s.mu.Lock() // rand.Rand no es seguro para uso concurrente.
	variation := 0.85 + s.rng.Float64()*0.30
	errorFare := s.rng.Float64() < s.ErrorFareRate
	s.mu.Unlock()

	if errorFare {
		variation = 0.30
	}
	amount := max(int64(float64(base)*variation), 1)

	return []domain.Quote{{
		Price:       domain.Money{Currency: "EUR", AmountMinor: amount},
		CarrierIATA: "IB",
		DeepLink:    fmt.Sprintf("https://example.invalid/book?route=%s", spec.Key()),
		ObservedAt:  s.now().UTC(),
	}}, nil
}

// simulatedCarriers son aerolíneas reales para que la demo parezca creíble.
var simulatedCarriers = []string{"IB", "UX", "VY", "AF", "LH", "KL", "TP", "BA", "QR", "EK"}

// Search implementa Searcher con ofertas inventadas pero estables: la misma
// búsqueda da siempre las mismas ofertas (útil en demos y tests).
func (s *Simulated) Search(ctx context.Context, spec domain.SearchSpec, limit int) ([]domain.Offer, error) {
	if err := spec.Trip.Validate(); err != nil {
		return nil, fmt.Errorf("simulated: %w", err)
	}
	if s.Latency > 0 {
		timer := time.NewTimer(s.Latency)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("simulated: %w", ctx.Err())
		case <-timer.C:
		}
	}
	h := fnv.New64a()
	_, _ = h.Write([]byte(spec.Trip.Key()))
	seed := h.Sum64()
	rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	base := int64(4_000 + seed%90_000)
	if spec.Trip.Cabin == domain.CabinBusiness || spec.Trip.Cabin == domain.CabinFirst {
		base *= 4
	}
	n := min(3+int(seed%6), limit)
	offers := make([]domain.Offer, 0, n)
	for i := range n {
		carrier := simulatedCarriers[(int(seed%97)+i*3)%len(simulatedCarriers)]
		transfers := rng.IntN(3)
		hour := 6 + rng.IntN(16)
		minutes := 90 + rng.IntN(600) + transfers*120
		out := domain.Offer{
			PricePerAdult:   domain.Money{Currency: "EUR", AmountMinor: base + base*int64(i)*int64(10+rng.IntN(15))/100},
			CarrierIATA:     carrier,
			DepartureAt:     fmt.Sprintf("%sT%02d:%02d:00Z", spec.Trip.Departure, hour, 5*rng.IntN(12)),
			Transfers:       transfers,
			DurationMinutes: minutes,
			DeepLink:        fmt.Sprintf("https://example.invalid/book?route=%s&adults=%d&n=%d", spec.Trip.Key(), spec.Adults, i),
		}
		if spec.Trip.Return != nil {
			out.ReturnAt = fmt.Sprintf("%sT%02d:%02d:00Z", spec.Trip.Return, 6+rng.IntN(16), 5*rng.IntN(12))
			out.ReturnTransfers = transfers
			out.DurationMinutes *= 2
		}
		offers = append(offers, out)
	}
	sort.SliceStable(offers, func(i, j int) bool {
		return offers[i].PricePerAdult.AmountMinor < offers[j].PricePerAdult.AmountMinor
	})
	return offers, nil
}

// Monthly implementa MonthlySearcher con precios inventados pero estables:
// el verano y diciembre salen más caros, como en la vida real.
func (s *Simulated) Monthly(ctx context.Context, route domain.Route) ([]domain.MonthFare, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("simulated: %w", err)
	}
	h := fnv.New64a()
	_, _ = h.Write([]byte(string(route.Origin) + "-" + string(route.Destination)))
	seed := h.Sum64()
	base := int64(8_000 + seed%80_000)
	// Cuánto sube cada mes (en %): enero barato, agosto caro.
	season := [12]int64{-10, -15, -5, 5, 0, 15, 35, 40, 0, -5, -15, 25}
	now := s.now().UTC()
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	out := make([]domain.MonthFare, 0, domain.MaxMonths)
	for i := range domain.MaxMonths {
		m := first.AddDate(0, i, 0)
		dep := m.AddDate(0, 0, int(seed%20)+3)
		ret := dep.AddDate(0, 0, 7)
		out = append(out, domain.MonthFare{
			Year:          m.Year(),
			Month:         m.Month(),
			PricePerAdult: domain.Money{Currency: "EUR", AmountMinor: base + base*season[m.Month()-1]/100},
			CarrierIATA:   simulatedCarriers[(int(seed%97)+i)%len(simulatedCarriers)],
			DepartureAt:   dep.Format(time.DateOnly),
			ReturnAt:      ret.Format(time.DateOnly),
			Transfers:     int(seed % 2),
			DeepLink:      fmt.Sprintf("https://example.invalid/book?route=%s-%s&month=%s", route.Origin, route.Destination, m.Format("2006-01")),
		})
	}
	return out, nil
}
