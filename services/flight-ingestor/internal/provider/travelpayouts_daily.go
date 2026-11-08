package provider

// El calendario de precios del buscador: el billete más barato de cada día
// de un mes para una ruta.
//
// Se usa /aviasales/v3/grouped_prices de la Data API de Travelpayouts
// (gratis) agrupado por día de salida: una sola petición devuelve, para cada
// día del mes, lo más barato que han encontrado otros viajeros. Un día sin
// dato no sale (la app enseña "—", nunca un precio inventado).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// tpDaily es la respuesta de grouped_prices: un mapa "AAAA-MM-DD" → billete.
type tpDaily struct {
	Success bool                  `json:"success"`
	Data    map[string]tpDayEntry `json:"data"`
	Error   string                `json:"error"`
}

type tpDayEntry struct {
	Price       float64 `json:"price"`
	Airline     string  `json:"airline"`
	Transfers   int     `json:"transfers"`
	DepartureAt string  `json:"departure_at"`
	ReturnAt    string  `json:"return_at"`
}

// Daily implementa DailySearcher.
func (t *Travelpayouts) Daily(ctx context.Context, route domain.Route, month time.Time, oneWay bool) ([]domain.DayFare, error) {
	if err := t.limiter.Wait(ctx); err != nil {
		return nil, fmt.Errorf("%w (cola del limitador: %v)", ErrRateLimited, err)
	}
	month = time.Date(month.Year(), month.Month(), 1, 0, 0, 0, 0, time.UTC)
	q := url.Values{}
	q.Set("origin", string(route.Origin))
	q.Set("destination", string(route.Destination))
	q.Set("departure_at", month.Format("2006-01"))
	q.Set("group_by", "departure_at")
	q.Set("one_way", strconv.FormatBool(oneWay))
	q.Set("currency", strings.ToLower(t.cfg.Currency))
	endpoint := t.base.JoinPath("/aviasales/v3/grouped_prices")
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
	var body tpDaily
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&body); err != nil {
		return nil, fmt.Errorf("travelpayouts: respuesta ilegible: %w", err)
	}
	if !body.Success {
		return nil, fmt.Errorf("travelpayouts: la API respondió error: %.120q", body.Error)
	}

	y, m, d := t.now().UTC().Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
	var out []domain.DayFare
	for key, e := range body.Data {
		day, err := time.Parse(time.DateOnly, key)
		// Solo días de ESE mes y de hoy en adelante.
		if err != nil || day.Year() != month.Year() || day.Month() != month.Month() || day.Before(today) {
			continue
		}
		if e.Price <= 0 || math.IsNaN(e.Price) || math.IsInf(e.Price, 0) || e.Price > 1_000_000 {
			continue
		}
		dep, ret := dayOf(e.DepartureAt), dayOf(e.ReturnAt)
		if dep.IsZero() || !dep.Equal(day) {
			continue // el dato no cuadra con su día
		}
		if oneWay {
			ret = time.Time{}
		}
		link, ok := t.bookingLink(searchLink(route, dep, ret))
		if !ok {
			continue
		}
		carrier := strings.ToUpper(strings.TrimSpace(e.Airline))
		if len(carrier) != 2 {
			carrier = ""
		}
		retAt := e.ReturnAt
		if oneWay {
			retAt = ""
		}
		out = append(out, domain.DayFare{
			Date: day,
			PricePerAdult: domain.Money{
				Currency:    t.cfg.Currency,
				AmountMinor: int64(math.Round(e.Price * math.Pow10(t.exponent))),
			},
			CarrierIATA: carrier,
			DepartureAt: e.DepartureAt,
			ReturnAt:    retAt,
			Transfers:   clampCount(e.Transfers),
			DeepLink:    link,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Date.Before(out[j].Date) })
	return out, nil
}
