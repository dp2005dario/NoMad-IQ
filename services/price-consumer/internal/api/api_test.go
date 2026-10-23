package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/store"
)

// fakeStore guarda en memoria lo mínimo para probar la API sin PostgreSQL.
type fakeStore struct {
	deals   []domain.Deal
	subs    map[string][]domain.Subscription // por usuario
	alerts  []domain.AlertView
	points  []domain.PricePoint
	failAll bool
}

func (f *fakeStore) Deals(context.Context, string, time.Time, time.Duration, int) ([]domain.Deal, error) {
	if f.failAll {
		return nil, errors.New("base de datos caída")
	}
	return append([]domain.Deal(nil), f.deals...), nil
}

func (f *fakeStore) Watches(_ context.Context, user string) ([]domain.Watch, error) {
	var out []domain.Watch
	for _, s := range f.subs[user] {
		spec, _ := domain.ParseRouteKey(s.RouteKey)
		out = append(out, domain.Watch{Spec: spec, Target: s.Target})
	}
	return out, nil
}

func (f *fakeStore) UpsertSubscription(_ context.Context, s domain.Subscription) error {
	list := f.subs[s.UserID]
	for i := range list {
		if list[i].RouteKey == s.RouteKey {
			list[i] = s
			return nil
		}
	}
	f.subs[s.UserID] = append(list, s)
	return nil
}

func (f *fakeStore) DeleteSubscription(_ context.Context, user, key string) error {
	list := f.subs[user]
	for i := range list {
		if list[i].RouteKey == key {
			f.subs[user] = append(list[:i], list[i+1:]...)
			return nil
		}
	}
	return store.ErrNotFound
}

func (f *fakeStore) History(context.Context, string, time.Time) (string, []domain.PricePoint, error) {
	return "EUR", f.points, nil
}

func (f *fakeStore) Alerts(_ context.Context, user string, _ int) ([]domain.AlertView, error) {
	if user != "u1" {
		return nil, nil
	}
	return f.alerts, nil
}

type fakeWatcher struct{ ensured []string }

func (w *fakeWatcher) Ensure(_ context.Context, spec domain.RouteSpec) error {
	w.ensured = append(w.ensured, spec.Key())
	return errors.New("ingestor caído") // un fallo aquí no debe romper la petición
}

var today = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

func newAPI(st *fakeStore, w *fakeWatcher) http.Handler {
	if st.subs == nil {
		st.subs = map[string][]domain.Subscription{}
	}
	return New(Config{
		MaxWatchesPerUser: 2,
		MaxDaysAhead:      330,
		DealsFreshness:    48 * time.Hour,
		HistoryWindow:     30 * 24 * time.Hour,
		Now:               func() time.Time { return today },
	}, st, w, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

// call hace una petición como lo haría la puerta de entrada (con identidad).
func call(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set(HeaderUserID, "u1")
	req.Header.Set(HeaderUserRoles, "USER")
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("respuesta no es JSON: %q", rec.Body.String())
	}
	return out
}

func fare(key string, amount int64, link string) domain.Fare {
	spec, _ := domain.ParseRouteKey(key)
	return domain.Fare{Spec: spec, Price: domain.Money{Currency: "EUR", AmountMinor: amount}, DeepLink: link, ObservedAt: today}
}

func TestIdentityIsRequired(t *testing.T) {
	h := newAPI(&fakeStore{}, &fakeWatcher{})
	req := httptest.NewRequest(http.MethodGet, "/v1/fares/watches", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("sin identidad: %d", rec.Code)
	}
	req.Header.Set(HeaderUserID, "u1")
	req.Header.Set(HeaderUserRoles, "ADMIN")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("sin rol USER: %d", rec.Code)
	}
}

// Chollos e historial se ven sin cuenta (modo invitado) y se pueden guardar
// en caché; lo personal sigue pidiendo identidad y nunca se guarda.
func TestDealsAndHistoryArePublic(t *testing.T) {
	st := &fakeStore{deals: []domain.Deal{
		{Fare: fare("MAD-JFK:2026-11-15:ECONOMY", 40000, "https://book.example/jfk"), UsualMinor: 50000},
	}}
	h := newAPI(st, &fakeWatcher{})
	for _, path := range []string{"/v1/fares/deals?origin=MAD", "/v1/fares/history/MAD-JFK:2026-11-15:ECONOMY"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s sin cuenta: %d", path, rec.Code)
		}
		if got := rec.Header().Get("Cache-Control"); got != "public, max-age=60" {
			t.Errorf("%s Cache-Control = %q", path, got)
		}
	}
	for _, path := range []string{"/v1/fares/watches", "/v1/fares/alerts"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s sin cuenta: %d", path, rec.Code)
		}
	}
	if got := call(h, http.MethodGet, "/v1/fares/watches", "").Header().Get("Cache-Control"); got != "private, no-store" {
		t.Errorf("watches Cache-Control = %q", got)
	}
}

func TestDealsAreSortedByDrop(t *testing.T) {
	st := &fakeStore{deals: []domain.Deal{
		{Fare: fare("MAD-JFK:2026-11-15:ECONOMY", 40000, "https://book.example/jfk"), UsualMinor: 50000},         // -20 %
		{Fare: fare("MAD-NRT:2026-11-15:ECONOMY", 38900, "javascript:alert(1)"), UsualMinor: 105000},             // -62 %
		{Fare: fare("MAD-LIS:2026-11-15:ECONOMY", 4500, "https://book.example/lis"), UsualMinor: 0},              // sin historial
		{Fare: fare("MAD-CDG:2026-11-15:ECONOMY", 9000, "https://user:pass@book.example/cdg"), UsualMinor: 8000}, // más caro
	}}
	rec := call(newAPI(st, &fakeWatcher{}), http.MethodGet, "/v1/fares/deals?origin=mad&limit=3", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("código %d: %s", rec.Code, rec.Body)
	}
	deals := decode(t, rec)["deals"].([]any)
	if len(deals) != 3 {
		t.Fatalf("limit=3 no respetado: %d", len(deals))
	}
	first := deals[0].(map[string]any)
	if first["destination"] != "NRT" || first["drop_bp"].(float64) != 6295 {
		t.Errorf("el mayor chollo debería ir primero: %v", first)
	}
	// Un enlace que no es https nunca llega a la app.
	if _, ok := first["booking_url"]; ok {
		t.Errorf("enlace peligroso no filtrado: %v", first["booking_url"])
	}
	if deals[1].(map[string]any)["destination"] != "JFK" {
		t.Errorf("orden inesperado: %v", deals)
	}
	if rec := call(newAPI(st, &fakeWatcher{}), http.MethodGet, "/v1/fares/deals?origin=MADRID", ""); rec.Code != http.StatusBadRequest {
		t.Errorf("origen inválido: %d", rec.Code)
	}
	st.failAll = true
	if rec := call(newAPI(st, &fakeWatcher{}), http.MethodGet, "/v1/fares/deals?origin=MAD", ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("base de datos caída: %d", rec.Code)
	}
}

func TestWatchLifecycle(t *testing.T) {
	st := &fakeStore{}
	w := &fakeWatcher{}
	h := newAPI(st, w)
	key := "MAD-NRT:2026-12-01:2026-12-15:ECONOMY"

	rec := call(h, http.MethodPut, "/v1/fares/watches/"+key, `{"target":{"amount_minor":45000,"currency":"eur"}}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("crear: %d %s", rec.Code, rec.Body)
	}
	if got := st.subs["u1"][0].Target; got == nil || got.Currency != "EUR" || got.AmountMinor != 45000 {
		t.Errorf("objetivo mal guardado: %+v", got)
	}
	// Aunque el ingestor falle, la ruta queda guardada (el sincronizador reintenta).
	if len(w.ensured) != 1 || w.ensured[0] != key {
		t.Errorf("no se pidió la ruta al ingestor: %v", w.ensured)
	}
	// Repetir (cambiar el objetivo) no cuenta como ruta nueva.
	if rec := call(h, http.MethodPut, "/v1/fares/watches/"+key, ""); rec.Code != http.StatusOK {
		t.Errorf("repetir: %d", rec.Code)
	}

	rec = call(h, http.MethodGet, "/v1/fares/watches", "")
	watches := decode(t, rec)["watches"].([]any)
	if len(watches) != 1 || watches[0].(map[string]any)["route_key"] != key {
		t.Errorf("lista inesperada: %v", watches)
	}

	// Límite por persona (2 en este test).
	call(h, http.MethodPut, "/v1/fares/watches/MAD-JFK:2026-12-01:ECONOMY", "")
	if rec := call(h, http.MethodPut, "/v1/fares/watches/MAD-LIS:2026-12-01:ECONOMY", ""); rec.Code != http.StatusConflict {
		t.Errorf("tercera ruta con límite 2: %d", rec.Code)
	}

	if rec := call(h, http.MethodDelete, "/v1/fares/watches/"+key, ""); rec.Code != http.StatusNoContent {
		t.Errorf("borrar: %d", rec.Code)
	}
	// Borrar otra vez también es "hecho".
	if rec := call(h, http.MethodDelete, "/v1/fares/watches/"+key, ""); rec.Code != http.StatusNoContent {
		t.Errorf("borrar dos veces: %d", rec.Code)
	}
}

func TestWatchRejectsBadRoutes(t *testing.T) {
	h := newAPI(&fakeStore{}, &fakeWatcher{})
	cases := map[string]int{
		"/v1/fares/watches/MAD-NRT:2026-10-01:ECONOMY": http.StatusUnprocessableEntity, // ya salió
		"/v1/fares/watches/MAD-NRT:2028-10-01:ECONOMY": http.StatusUnprocessableEntity, // demasiado lejos
		"/v1/fares/watches/MAD-NRT:mañana:ECONOMY":     http.StatusBadRequest,
		"/v1/fares/watches/MAD-MAD:2026-12-01:ECONOMY": http.StatusBadRequest,
	}
	for path, want := range cases {
		if rec := call(h, http.MethodPut, path, ""); rec.Code != want {
			t.Errorf("%s: %d, se esperaba %d", path, rec.Code, want)
		}
	}
	bad := map[string]string{
		`{"target":{"amount_minor":-5,"currency":"EUR"}}`: "importe negativo",
		`{"objetivo":1}`: "campo desconocido",
		`no es json`:     "JSON roto",
	}
	for body, why := range bad {
		if rec := call(h, http.MethodPut, "/v1/fares/watches/MAD-NRT:2026-12-01:ECONOMY", body); rec.Code < 400 || rec.Code >= 500 {
			t.Errorf("%s: %d", why, rec.Code)
		}
	}
}

func TestHistoryAndAlerts(t *testing.T) {
	st := &fakeStore{
		points: []domain.PricePoint{{Day: domain.Date{Year: 2026, Month: 10, Day: 22}, MinMinor: 41000}},
		alerts: []domain.AlertView{{
			ID: "a1", Spec: fare("MAD-NRT:2026-12-01:ECONOMY", 1, "").Spec, Type: domain.AlertErrorFare,
			Reference: domain.Money{Currency: "EUR", AmountMinor: 105000}, Current: domain.Money{Currency: "EUR", AmountMinor: 38900},
			DropBasisPoints: 6295, DeepLink: "https://book.example/nrt", ObservedAt: today,
		}},
	}
	h := newAPI(st, &fakeWatcher{})
	hist := decode(t, call(h, http.MethodGet, "/v1/fares/history/MAD-NRT:2026-12-01:ECONOMY", ""))
	if hist["currency"] != "EUR" || len(hist["points"].([]any)) != 1 {
		t.Errorf("historial inesperado: %v", hist)
	}
	alerts := decode(t, call(h, http.MethodGet, "/v1/fares/alerts", ""))["alerts"].([]any)
	a := alerts[0].(map[string]any)
	if a["type"] != "ERROR_FARE" || a["booking_url"] != "https://book.example/nrt" || a["origin"] != "MAD" {
		t.Errorf("alerta inesperada: %v", a)
	}
}

type fakeSearcher struct {
	got    domain.RouteSpec
	adults int
	calls  int
	err    error
}

func (f *fakeSearcher) Search(_ context.Context, spec domain.RouteSpec, adults int) (domain.SearchResult, error) {
	f.got, f.adults = spec, adults
	f.calls++
	if f.err != nil {
		return domain.SearchResult{}, f.err
	}
	eur := func(n int64) domain.Money { return domain.Money{Currency: "EUR", AmountMinor: n} }
	return domain.SearchResult{
		Provider:   "travelpayouts",
		ObservedAt: today,
		Offers: []domain.Offer{
			{PricePerAdult: eur(31550), Total: eur(63100), CarrierIATA: "IB", DepartureAt: "2026-12-15T22:40:00+01:00",
				ReturnAt: "2026-12-22T09:00:00+09:00", DurationMinutes: 1500, DeepLink: "https://www.aviasales.com/search/MAD1512NRT22122?marker=1"},
			{PricePerAdult: eur(100), Total: eur(200), DeepLink: "javascript:alert(1)"},
		},
	}, nil
}

func newSearchAPI(s Searcher) http.Handler {
	return New(Config{Searcher: s, MaxWatchesPerUser: 2, MaxDaysAhead: 330, DealsFreshness: time.Hour,
		HistoryWindow: time.Hour, Now: func() time.Time { return today }}, &fakeStore{}, &fakeWatcher{},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestSearchIsPublicAndReturnsBookableOffers(t *testing.T) {
	s := &fakeSearcher{}
	rec := get(newSearchAPI(s), "/v1/fares/search?origin=mad&destination=NRT&departure=2026-12-15&return=2026-12-22&adults=2")
	if rec.Code != http.StatusOK {
		t.Fatalf("código %d: %s", rec.Code, rec.Body)
	}
	if s.got.Key() != "MAD-NRT:2026-12-15:2026-12-22:ECONOMY" || s.adults != 2 {
		t.Errorf("búsqueda: %s x%d", s.got.Key(), s.adults)
	}
	if rec.Header().Get("Cache-Control") != "public, max-age=60" {
		t.Errorf("Cache-Control = %q", rec.Header().Get("Cache-Control"))
	}
	body := decode(t, rec)
	offers := body["offers"].([]any)
	// La del enlace "javascript:" no se enseña.
	if len(offers) != 1 || body["adults"].(float64) != 2 {
		t.Fatalf("respuesta: %v", body)
	}
	o := offers[0].(map[string]any)
	if o["total"].(map[string]any)["amount_minor"].(float64) != 63100 || o["carrier"] != "IB" {
		t.Errorf("oferta: %v", o)
	}
}

func TestSearchValidatesAndDegrades(t *testing.T) {
	s := &fakeSearcher{}
	h := newSearchAPI(s)
	for path, want := range map[string]int{
		"/v1/fares/search?origin=MAD&destination=MAD&departure=2026-12-15":                   400,
		"/v1/fares/search?origin=MADRID&destination=NRT&departure=2026-12-15":                400,
		"/v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15&return=2026-12-01": 400,
		"/v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15&adults=10":         400,
		"/v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15&cabin=CHEAP":       400,
		"/v1/fares/search?origin=MAD&destination=NRT&departure=2020-01-01":                   422,
		"/v1/fares/search?origin=MAD&destination=NRT&departure=2030-01-01":                   422,
	} {
		if rec := get(h, path); rec.Code != want {
			t.Errorf("%s: %d (se esperaba %d)", path, rec.Code, want)
		}
	}
	if s.calls != 0 {
		t.Errorf("con datos malos no se debe preguntar al proveedor (%d)", s.calls)
	}
	busy := get(newSearchAPI(&fakeSearcher{err: domain.ErrSearchBusy}), "/v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15")
	if busy.Code != http.StatusTooManyRequests || busy.Header().Get("Retry-After") == "" {
		t.Errorf("ocupado: %d", busy.Code)
	}
	if busy.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("un error no se guarda en caché: %q", busy.Header().Get("Cache-Control"))
	}
	if rec := get(newSearchAPI(nil), "/v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15"); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("sin buscador: %d", rec.Code)
	}
}
