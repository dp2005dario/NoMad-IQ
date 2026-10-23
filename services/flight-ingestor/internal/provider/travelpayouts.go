package provider

// Travelpayouts: precios REALES de vuelos y enlaces de reserva con
// comisión de afiliado (el modelo de negocio de NomadIQ).
//
// Qué es: Travelpayouts es la red de afiliados de Aviasales (un buscador
// de vuelos). Su "Data API" es gratuita: devuelve los precios que otros
// viajeros encontraron en las últimas horas para una ruta y fecha. No es el
// precio en vivo de la aerolínea (para eso habría que pagar), pero para
// vigilar bajadas de precio es justo lo que hace falta. Cuando alguien
// reserva desde nuestro enlace (que lleva nuestro "marker" de afiliado),
// Travelpayouts nos paga una comisión.
//
// Tres cuidados para no gastar de más ni que nos bloqueen:
//
//  1. Ritmo: un limitador "cubo de fichas" (rate.Limiter) deja pasar como
//     mucho N peticiones por segundo, aunque haya miles de rutas vigiladas.
//  2. Refresco por ruta: la Data API se actualiza cada pocas horas, así que
//     preguntar por la misma ruta cada minuto es tirar peticiones. Cada ruta
//     se consulta como mucho una vez cada TRAVELPAYOUTS_REFRESH (30 min);
//     entre medias, Quote no devuelve nada (y no se publica nada repetido).
//  3. Secretos: el token viaja en una cabecera, nunca en la URL, para que
//     no aparezca en logs ni en mensajes de error.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// TravelpayoutsConfig agrupa las opciones del adaptador.
type TravelpayoutsConfig struct {
	// BaseURL de la API ("https://api.travelpayouts.com"; en los tests, un servidor falso).
	BaseURL string
	// Token de la API (Travelpayouts → Perfil → Token de la API). SECRETO.
	Token string
	// Marker es tu identificador de afiliado: va en cada enlace de reserva
	// para que la comisión sea tuya.
	Marker string
	// Currency en la que se piden los precios (ISO 4217, "EUR").
	Currency string
	// BookingHost es la web donde el viajero reserva ("https://www.aviasales.com").
	BookingHost string
	// RatePerSecond: peticiones por segundo como máximo (todas las rutas juntas).
	RatePerSecond float64
	// Refresh: tiempo mínimo entre dos consultas de la misma ruta.
	Refresh time.Duration
	// HTTPClient opcional (en los tests).
	HTTPClient *http.Client
}

// Travelpayouts implementa FareProvider con la Data API de Aviasales.
type Travelpayouts struct {
	cfg      TravelpayoutsConfig
	base     *url.URL
	booking  *url.URL
	client   *http.Client
	limiter  *rate.Limiter
	exponent int // decimales de la divisa (EUR 2, JPY 0)

	mu   sync.Mutex
	last map[string]time.Time // última consulta buena de cada ruta
	now  func() time.Time
}

// Divisas admitidas y cuántos decimales tienen. La API da los precios en
// unidades enteras o con decimales; nosotros los guardamos en "unidades
// mínimas" (céntimos) para no perder precisión.
var currencyExponents = map[string]int{
	"EUR": 2, "USD": 2, "GBP": 2, "CHF": 2, "CAD": 2, "AUD": 2, "MXN": 2, "BRL": 2,
	"INR": 2, "CNY": 2, "SAR": 2, "AED": 2, "TRY": 2, "PLN": 2, "SEK": 2, "NOK": 2,
	"DKK": 2, "THB": 2, "RUB": 2, "JPY": 0, "KRW": 0,
}

// NewTravelpayouts valida la configuración y crea el adaptador.
func NewTravelpayouts(cfg TravelpayoutsConfig) (*Travelpayouts, error) {
	var errs []error
	base, err := url.Parse(cfg.BaseURL)
	if err != nil || base.Host == "" || (base.Scheme != "https" && base.Scheme != "http") {
		errs = append(errs, errors.New("travelpayouts: BaseURL inválida"))
	}
	booking, err := url.Parse(cfg.BookingHost)
	if err != nil || booking.Host == "" || booking.Scheme != "https" {
		errs = append(errs, errors.New("travelpayouts: BookingHost debe ser una URL https"))
	}
	if cfg.Token == "" {
		errs = append(errs, errors.New("travelpayouts: falta el token de la API"))
	}
	if cfg.Marker == "" || strings.ContainsAny(cfg.Marker, "&?=#/ ") {
		errs = append(errs, errors.New("travelpayouts: el marker de afiliado falta o tiene caracteres raros"))
	}
	exp, ok := currencyExponents[cfg.Currency]
	if !ok {
		errs = append(errs, fmt.Errorf("travelpayouts: divisa %q no admitida", cfg.Currency))
	}
	if cfg.RatePerSecond <= 0 || cfg.Refresh <= 0 {
		errs = append(errs, errors.New("travelpayouts: RatePerSecond y Refresh deben ser positivos"))
	}
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	return &Travelpayouts{
		cfg:      cfg,
		base:     base,
		booking:  booking,
		client:   client,
		limiter:  rate.NewLimiter(rate.Limit(cfg.RatePerSecond), 1),
		exponent: exp,
		last:     make(map[string]time.Time),
		now:      time.Now,
	}, nil
}

// Name implementa FareProvider.
func (t *Travelpayouts) Name() string { return "travelpayouts" }

// tpResponse es la respuesta de /aviasales/v3/prices_for_dates.
type tpResponse struct {
	Success bool     `json:"success"`
	Data    []tpFare `json:"data"`
	Error   string   `json:"error"`
}

type tpFare struct {
	Price       float64 `json:"price"`
	Airline     string  `json:"airline"`
	DepartureAt string  `json:"departure_at"`
	ReturnAt    string  `json:"return_at"`
	Link        string  `json:"link"`
}

// maxBody: una respuesta normal ocupa unos KB; más de 1 MB es un error.
const maxBody = 1 << 20

// Quote implementa FareProvider. Devuelve el precio más barato para ese día
// (o nada si la ruta se consultó hace poco o nadie ha buscado ese vuelo).
func (t *Travelpayouts) Quote(ctx context.Context, spec domain.WatchSpec) ([]domain.Quote, error) {
	if err := spec.Validate(); err != nil {
		return nil, fmt.Errorf("travelpayouts: %w", err)
	}
	// La Data API solo tiene precios de turista: para business o primera no
	// hay dato (mejor nada que un precio de otra cabina).
	if spec.Cabin != domain.CabinEconomy {
		return nil, nil
	}
	key := spec.Key()
	if !t.due(key) {
		return nil, nil
	}
	if err := t.limiter.Wait(ctx); err != nil {
		// No da tiempo a que nos toque turno antes del QueryTimeout: hay más
		// rutas que ritmo permitido. Se reintenta en el siguiente ciclo.
		return nil, fmt.Errorf("%w (cola del limitador: %v)", ErrRateLimited, err)
	}

	q := url.Values{}
	q.Set("origin", string(spec.Route.Origin))
	q.Set("destination", string(spec.Route.Destination))
	q.Set("departure_at", spec.Departure.String())
	if spec.Return != nil {
		q.Set("return_at", spec.Return.String())
		q.Set("one_way", "false")
	} else {
		q.Set("one_way", "true")
	}
	q.Set("currency", strings.ToLower(t.cfg.Currency))
	q.Set("sorting", "price")
	q.Set("direct", "false")
	q.Set("limit", "10")
	endpoint := t.base.JoinPath("/aviasales/v3/prices_for_dates")
	endpoint.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("travelpayouts: %w", err)
	}
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
	var body tpResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&body); err != nil {
		return nil, fmt.Errorf("travelpayouts: respuesta ilegible: %w", err)
	}
	if !body.Success {
		// El texto del error viene de fuera: se recorta por si es enorme.
		return nil, fmt.Errorf("travelpayouts: la API respondió error: %.120q", body.Error)
	}

	observed := t.now().UTC()
	var quotes []domain.Quote
	for _, f := range body.Data {
		quote, ok := t.toQuote(spec, f, observed)
		if ok {
			quotes = append(quotes, quote)
		}
	}
	t.markDone(key, observed)
	if len(quotes) == 0 {
		return nil, nil // nadie ha buscado ese vuelo últimamente
	}
	// Solo el más barato: es el precio que importa para avisar de bajadas.
	sort.Slice(quotes, func(i, j int) bool { return quotes[i].Price.AmountMinor < quotes[j].Price.AmountMinor })
	return quotes[:1], nil
}

// toQuote convierte un resultado de la API, descartando lo que no encaja.
func (t *Travelpayouts) toQuote(spec domain.WatchSpec, f tpFare, observed time.Time) (domain.Quote, bool) {
	// La fecha pedida tiene que ser la del vuelo ("2026-12-15T10:05:00+01:00").
	if !strings.HasPrefix(f.DepartureAt, spec.Departure.String()) {
		return domain.Quote{}, false
	}
	if spec.Return != nil && !strings.HasPrefix(f.ReturnAt, spec.Return.String()) {
		return domain.Quote{}, false
	}
	if f.Price <= 0 || math.IsNaN(f.Price) || math.IsInf(f.Price, 0) || f.Price > 1_000_000 {
		return domain.Quote{}, false
	}
	link, ok := t.bookingLink(f.Link)
	if !ok {
		return domain.Quote{}, false
	}
	carrier := strings.ToUpper(strings.TrimSpace(f.Airline))
	if len(carrier) != 2 {
		carrier = "" // es opcional: mejor vacío que un código raro
	}
	amount := int64(math.Round(f.Price * math.Pow10(t.exponent)))
	return domain.Quote{
		Price:       domain.Money{Currency: t.cfg.Currency, AmountMinor: amount},
		CarrierIATA: carrier,
		DeepLink:    link,
		ObservedAt:  observed,
	}, true
}

// bookingLink monta el enlace de reserva con nuestro marker. La API da una
// ruta relativa ("/search/MAD1512NRT1?t=..."): solo se aceptan rutas que
// empiezan por "/" (nunca otra web) y siempre sobre BookingHost en https.
func (t *Travelpayouts) bookingLink(path string) (string, bool) {
	if !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") || len(path) > 2048 {
		return "", false
	}
	rel, err := url.Parse(path)
	if err != nil || rel.Scheme != "" || rel.Host != "" {
		return "", false
	}
	full := t.booking.ResolveReference(rel)
	query := full.Query()
	query.Set("marker", t.cfg.Marker)
	full.RawQuery = query.Encode()
	return full.String(), true
}

// due dice si toca consultar esta ruta (o se consultó hace menos de Refresh).
func (t *Travelpayouts) due(key string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	last, ok := t.last[key]
	return !ok || t.now().Sub(last) >= t.cfg.Refresh
}

// markDone apunta la consulta y, de paso, olvida rutas viejas para que el
// mapa no crezca sin fin (rutas que ya nadie vigila).
func (t *Travelpayouts) markDone(key string, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.last[key] = at
	if len(t.last) > 4096 {
		for k, v := range t.last {
			if at.Sub(v) >= t.cfg.Refresh {
				delete(t.last, k)
			}
		}
	}
}
