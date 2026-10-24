package provider

// Explorar: el billete más barato de cada mes para una ruta.
//
// Se usa /v1/prices/monthly de la Data API de Travelpayouts (gratis): una
// sola petición devuelve, para cada mes, el ida y vuelta más barato que han
// encontrado otros viajeros. Con 1 petición se rellena el año entero.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// tpMonthly es la respuesta de /v1/prices/monthly: un mapa "AAAA-MM" → billete.
type tpMonthly struct {
	Success bool                    `json:"success"`
	Data    map[string]tpMonthEntry `json:"data"`
	Error   string                  `json:"error"`
}

type tpMonthEntry struct {
	Price       float64 `json:"price"`
	Airline     string  `json:"airline"`
	Transfers   int     `json:"transfers"`
	DepartureAt string  `json:"departure_at"`
	ReturnAt    string  `json:"return_at"`
}

// Monthly implementa MonthlySearcher.
func (t *Travelpayouts) Monthly(ctx context.Context, route domain.Route) ([]domain.MonthFare, error) {
	if err := t.limiter.Wait(ctx); err != nil {
		return nil, fmt.Errorf("%w (cola del limitador: %v)", ErrRateLimited, err)
	}
	q := url.Values{}
	q.Set("origin", string(route.Origin))
	q.Set("destination", string(route.Destination))
	q.Set("currency", strings.ToLower(t.cfg.Currency))
	endpoint := t.base.JoinPath("/v1/prices/monthly")
	endpoint.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("travelpayouts: %w", err)
	}
	// El token SIEMPRE en la cabecera (nunca en la URL ni en los logs).
	req.Header.Set("X-Access-Token", t.cfg.Token)
	req.Header.Set("Accept", "application/json")
	resp, err := t.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("travelpayouts: petición: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusTooManyRequests:
		return nil, ErrRateLimited
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return nil, fmt.Errorf("travelpayouts: token rechazado (HTTP %d): revisa TRAVELPAYOUTS_TOKEN", resp.StatusCode)
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("travelpayouts: HTTP %d", resp.StatusCode)
	}
	var body tpMonthly
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&body); err != nil {
		return nil, fmt.Errorf("travelpayouts: respuesta ilegible: %w", err)
	}
	if !body.Success {
		return nil, fmt.Errorf("travelpayouts: la API respondió error: %.120q", body.Error)
	}

	now := t.now().UTC()
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	last := first.AddDate(0, domain.MaxMonths, 0) // el mes 13 ya no
	var out []domain.MonthFare
	for key, e := range body.Data {
		month, err := time.Parse("2006-01", key)
		if err != nil || month.Before(first) || !month.Before(last) {
			continue // mes pasado, demasiado lejano o clave rara
		}
		if e.Price <= 0 || math.IsNaN(e.Price) || math.IsInf(e.Price, 0) || e.Price > 1_000_000 {
			continue
		}
		dep, ret := dayOf(e.DepartureAt), dayOf(e.ReturnAt)
		// La salida tiene que caer en ese mes (si no, el dato no cuadra).
		if dep.IsZero() || dep.Year() != month.Year() || dep.Month() != month.Month() {
			continue
		}
		link, ok := t.bookingLink(searchLink(route, dep, ret))
		if !ok {
			continue
		}
		carrier := strings.ToUpper(strings.TrimSpace(e.Airline))
		if len(carrier) != 2 {
			carrier = ""
		}
		out = append(out, domain.MonthFare{
			Year:  month.Year(),
			Month: month.Month(),
			PricePerAdult: domain.Money{
				Currency:    t.cfg.Currency,
				AmountMinor: int64(math.Round(e.Price * math.Pow10(t.exponent))),
			},
			CarrierIATA: carrier,
			DepartureAt: e.DepartureAt,
			ReturnAt:    e.ReturnAt,
			Transfers:   clampCount(e.Transfers),
			DeepLink:    link,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Year != out[j].Year {
			return out[i].Year < out[j].Year
		}
		return out[i].Month < out[j].Month
	})
	return out, nil
}

// dayOf lee el día de "2027-03-11T10:05:00+01:00" o "2027-03-11"; cero si
// no se entiende.
func dayOf(raw string) time.Time {
	if len(raw) < 10 {
		return time.Time{}
	}
	d, err := time.Parse(time.DateOnly, raw[:10])
	if err != nil {
		return time.Time{}
	}
	return d
}

// searchLink monta el enlace de búsqueda de Aviasales para esas fechas:
// "/search/MAD1103NRT20031" = MAD el 11/03, NRT, vuelta el 20/03, 1 adulto.
func searchLink(route domain.Route, dep, ret time.Time) string {
	path := fmt.Sprintf("/search/%s%s%s", route.Origin, dep.Format("0201"), route.Destination)
	if !ret.IsZero() {
		path += ret.Format("0201")
	}
	return path + "1"
}
