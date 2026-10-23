package provider

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// fakeAPI imita la Data API de Travelpayouts.
type fakeAPI struct {
	calls  atomic.Int64
	status int
	body   string
	last   *http.Request
}

func (f *fakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.calls.Add(1)
	f.last = r
	if f.status != 0 && f.status != http.StatusOK {
		w.WriteHeader(f.status)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(f.body))
}

const twoFares = `{"success":true,"currency":"eur","data":[
 {"origin":"MAD","destination":"NRT","price":540,"airline":"QR","departure_at":"2026-12-15T10:05:00+01:00","link":"/search/MAD1512NRT1?t=b"},
 {"origin":"MAD","destination":"NRT","price":315.5,"airline":"ib","departure_at":"2026-12-15T22:40:00+01:00","link":"/search/MAD1512NRT1?t=a"},
 {"origin":"MAD","destination":"NRT","price":99,"airline":"XX","departure_at":"2026-12-16T08:00:00+01:00","link":"/search/x"},
 {"origin":"MAD","destination":"NRT","price":50,"airline":"YY","departure_at":"2026-12-15T09:00:00+01:00","link":"https://phishing.example/x"}
]}`

func newTP(t *testing.T, api *fakeAPI) *Travelpayouts {
	t.Helper()
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	tp, err := NewTravelpayouts(TravelpayoutsConfig{
		BaseURL: srv.URL, Token: "tok-secreto", Marker: "123456", Currency: "EUR",
		BookingHost: "https://www.aviasales.com", RatePerSecond: 1000, Refresh: 30 * time.Minute,
		HTTPClient: srv.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return tp
}

func spec(t *testing.T, key string) domain.WatchSpec {
	t.Helper()
	s, err := domain.ParseWatchKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestTravelpayoutsReturnsTheCheapestFareOfThatDayWithOurMarker(t *testing.T) {
	api := &fakeAPI{body: twoFares}
	tp := newTP(t, api)
	quotes, err := tp.Quote(context.Background(), spec(t, "MAD-NRT:2026-12-15:ECONOMY"))
	if err != nil {
		t.Fatal(err)
	}
	if len(quotes) != 1 {
		t.Fatalf("se esperaba solo el más barato del día, hay %d", len(quotes))
	}
	q := quotes[0]
	// El de 99 € es de otro día y el de 50 € enlaza a otra web: descartados.
	if q.Price != (domain.Money{Currency: "EUR", AmountMinor: 31550}) || q.CarrierIATA != "IB" {
		t.Fatalf("precio inesperado: %+v", q)
	}
	if q.DeepLink != "https://www.aviasales.com/search/MAD1512NRT1?marker=123456&t=a" {
		t.Fatalf("enlace sin nuestro marker: %s", q.DeepLink)
	}
	// El token viaja en la cabecera, NUNCA en la URL (acabaría en logs).
	if api.last.Header.Get("X-Access-Token") != "tok-secreto" || strings.Contains(api.last.URL.String(), "tok-secreto") {
		t.Fatal("el token debe ir solo en la cabecera")
	}
	qs := api.last.URL.Query()
	if qs.Get("origin") != "MAD" || qs.Get("departure_at") != "2026-12-15" || qs.Get("one_way") != "true" || qs.Get("currency") != "eur" {
		t.Fatalf("consulta inesperada: %s", api.last.URL.RawQuery)
	}
}

func TestTravelpayoutsAsksEachRouteAtMostOncePerRefresh(t *testing.T) {
	api := &fakeAPI{body: twoFares}
	tp := newTP(t, api)
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	tp.now = func() time.Time { return now }
	s := spec(t, "MAD-NRT:2026-12-15:ECONOMY")
	for range 3 {
		if _, err := tp.Quote(context.Background(), s); err != nil {
			t.Fatal(err)
		}
	}
	if api.calls.Load() != 1 {
		t.Fatalf("en 30 minutos, una sola consulta por ruta: hubo %d", api.calls.Load())
	}
	now = now.Add(31 * time.Minute)
	if quotes, _ := tp.Quote(context.Background(), s); len(quotes) != 1 || api.calls.Load() != 2 {
		t.Fatalf("pasado el refresco se vuelve a preguntar: %d llamadas", api.calls.Load())
	}
}

func TestTravelpayoutsSkipsCabinsItDoesNotKnow(t *testing.T) {
	api := &fakeAPI{body: twoFares}
	tp := newTP(t, api)
	quotes, err := tp.Quote(context.Background(), spec(t, "MAD-NRT:2026-12-15:BUSINESS"))
	if err != nil || quotes != nil || api.calls.Load() != 0 {
		t.Fatalf("business: sin consulta ni precio (%v, %v, %d)", err, quotes, api.calls.Load())
	}
}

func TestTravelpayoutsErrors(t *testing.T) {
	s := spec(t, "MAD-LIS:2026-12-02:ECONOMY")
	api := &fakeAPI{status: http.StatusTooManyRequests}
	if _, err := newTP(t, api).Quote(context.Background(), s); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("429 → ErrRateLimited: %v", err)
	}
	api = &fakeAPI{status: http.StatusUnauthorized}
	if _, err := newTP(t, api).Quote(context.Background(), s); err == nil || strings.Contains(err.Error(), "tok-secreto") {
		t.Fatalf("401 debe fallar sin enseñar el token: %v", err)
	}
	api = &fakeAPI{body: `{"success":false,"error":"invalid token"}`}
	if _, err := newTP(t, api).Quote(context.Background(), s); err == nil {
		t.Fatal("success=false es un error")
	}
	// Sin resultados (nadie buscó ese vuelo): nada, sin error.
	api = &fakeAPI{body: `{"success":true,"data":[]}`}
	if quotes, err := newTP(t, api).Quote(context.Background(), s); err != nil || quotes != nil {
		t.Fatalf("vacío: %v %v", quotes, err)
	}
}

func TestTravelpayoutsRejectsBadConfig(t *testing.T) {
	for name, cfg := range map[string]TravelpayoutsConfig{
		"sin token":        {BaseURL: "https://api.travelpayouts.com", Marker: "1", Currency: "EUR", BookingHost: "https://www.aviasales.com", RatePerSecond: 1, Refresh: time.Minute},
		"marker con &":     {BaseURL: "https://api.travelpayouts.com", Token: "t", Marker: "1&x=2", Currency: "EUR", BookingHost: "https://www.aviasales.com", RatePerSecond: 1, Refresh: time.Minute},
		"reserva por http": {BaseURL: "https://api.travelpayouts.com", Token: "t", Marker: "1", Currency: "EUR", BookingHost: "http://www.aviasales.com", RatePerSecond: 1, Refresh: time.Minute},
		"divisa rara":      {BaseURL: "https://api.travelpayouts.com", Token: "t", Marker: "1", Currency: "XYZ", BookingHost: "https://www.aviasales.com", RatePerSecond: 1, Refresh: time.Minute},
	} {
		if _, err := NewTravelpayouts(cfg); err == nil {
			t.Errorf("%s: debería rechazarse", name)
		}
	}
}
