package provider

import (
	"context"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
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
