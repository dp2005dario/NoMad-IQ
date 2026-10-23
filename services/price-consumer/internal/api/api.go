// Package api es la API HTTP de vuelos que usa la app ("Cazador de vuelos").
//
// Seguridad Zero Trust, igual que las APIs del notifier y del ai-orchestrator:
//
//   - Esta API NO valida tokens JWT. La puerta de entrada (Traefik) pregunta
//     al auth-gateway si el token es bueno y nos reenvía la petición con las
//     cabeceras X-User-ID y X-User-Roles ya verificadas.
//   - Nadie de dentro de la red puede inventarse esas cabeceras: en
//     producción el puerto exige mTLS y solo la puerta tiene certificado.
//
// Endpoints (todo en JSON):
//
//	GET    /v1/fares/deals?origin=MAD          chollos de hoy desde un aeropuerto (público)
//	GET    /v1/fares/watches                   las rutas que vigilo, con su último precio
//	PUT    /v1/fares/watches/{route_key}       vigilar una ruta (opcional: precio objetivo)
//	DELETE /v1/fares/watches/{route_key}       dejar de vigilarla
//	GET    /v1/fares/history/{route_key}       precio más bajo de cada día (gráfica, público)
//	GET    /v1/fares/alerts                    mis últimos avisos de precio
//
// route_key tiene el formato ORIGEN-DESTINO:AAAA-MM-DD[:AAAA-MM-DD]:CABINA,
// por ejemplo MAD-NRT:2026-12-01:2026-12-15:ECONOMY.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/store"
)

// Cabeceras que pone la puerta de entrada tras validar el JWT.
const (
	HeaderUserID    = "X-User-ID"
	HeaderUserRoles = "X-User-Roles"
	requiredRole    = "USER"
	maxBodyBytes    = 4 << 10
)

var (
	userIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:@-]{1,128}$`)
	rolePattern   = regexp.MustCompile(`^[A-Z_]{1,32}$`)
)

// Store es lo que la API necesita de la base de datos.
type Store interface {
	Deals(ctx context.Context, origin string, since time.Time, historyWindow time.Duration, scan int) ([]domain.Deal, error)
	Watches(ctx context.Context, userID string) ([]domain.Watch, error)
	UpsertSubscription(ctx context.Context, s domain.Subscription) error
	DeleteSubscription(ctx context.Context, userID, routeKey string) error
	History(ctx context.Context, routeKey string, since time.Time) (string, []domain.PricePoint, error)
	Alerts(ctx context.Context, userID string, limit int) ([]domain.AlertView, error)
}

// Watcher pide al flight-ingestor que empiece a consultar una ruta. Es "mejor
// esfuerzo": si falla, el sincronizador (watchsync) lo reintenta solo.
type Watcher interface {
	Ensure(ctx context.Context, spec domain.RouteSpec) error
}

// Config son los límites de la API.
type Config struct {
	MaxWatchesPerUser int           // rutas que puede vigilar una persona
	MaxDaysAhead      int           // hasta cuántos días en el futuro se puede vigilar
	DealsFreshness    time.Duration // un chollo más viejo que esto ya no se enseña
	HistoryWindow     time.Duration // cuánto historial se usa (mediana y gráfica)
	Now               func() time.Time
}

// New crea el manejador HTTP con todas las rutas.
func New(cfg Config, st Store, watcher Watcher, log *slog.Logger) http.Handler {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	h := &handler{cfg: cfg, store: st, watcher: watcher, log: log}
	mux := http.NewServeMux()
	// Chollos e historial son públicos: también los ve quien entra como
	// invitado (no dependen de quién pregunta). Vigilar rutas y los avisos sí
	// necesitan cuenta, porque se guardan a tu nombre.
	mux.HandleFunc("GET /v1/fares/deals", public(h.deals))
	mux.HandleFunc("GET /v1/fares/watches", h.withUser(h.watches))
	mux.HandleFunc("PUT /v1/fares/watches/{route_key}", h.withUser(h.watch))
	mux.HandleFunc("DELETE /v1/fares/watches/{route_key}", h.withUser(h.unwatch))
	mux.HandleFunc("GET /v1/fares/history/{route_key}", public(h.history))
	mux.HandleFunc("GET /v1/fares/alerts", h.withUser(h.alerts))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		problem(w, http.StatusNotFound, "no encontrado")
	})
	return mux
}

type handler struct {
	cfg     Config
	store   Store
	watcher Watcher
	log     *slog.Logger
}

// ---------------------------------------------------------------------------
// Identidad y errores
// ---------------------------------------------------------------------------

// public sirve una ruta sin pedir identidad. Como la respuesta es la misma
// para todo el mundo, se deja guardar un minuto en caché (en el móvil o en
// una CDN): con millones de usuarios, la mayoría de peticiones ni llegan aquí.
func public(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=60")
		next(w, r, "")
	}
}

// withUser comprueba la identidad que puso la puerta de entrada y se la pasa
// al manejador. Sin ella, 401; sin el rol USER, 403.
func (h *handler) withUser(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get(HeaderUserID)
		if !userIDPattern.MatchString(userID) {
			problem(w, http.StatusUnauthorized, "identidad ausente o inválida")
			return
		}
		hasRole := false
		for _, role := range strings.Split(r.Header.Get(HeaderUserRoles), ",") {
			role = strings.TrimSpace(role)
			if role == "" {
				continue
			}
			if !rolePattern.MatchString(role) {
				problem(w, http.StatusUnauthorized, "roles inválidos")
				return
			}
			hasRole = hasRole || role == requiredRole
		}
		if !hasRole {
			problem(w, http.StatusForbidden, "se necesita el rol USER")
			return
		}
		next(w, r, userID)
	}
}

// problem responde con el formato estándar de errores RFC 9457.
func problem(w http.ResponseWriter, status int, title string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"type": "about:blank", "title": title, "status": status})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	// Normalmente son datos de cada usuario: ninguna caché intermedia debe
	// guardarlos. Las rutas públicas ya pusieron su propia regla antes.
	if w.Header().Get("Cache-Control") == "" {
		w.Header().Set("Cache-Control", "private, no-store")
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// unavailable registra el fallo interno (sin datos del usuario) y responde 503.
func (h *handler) unavailable(w http.ResponseWriter, what string, err error) {
	h.log.Error("fallo en la API de vuelos", slog.String("op", what), slog.Any("error", err))
	problem(w, http.StatusServiceUnavailable, "inténtalo de nuevo más tarde")
}

// routeKey lee y valida la clave de ruta de la dirección.
func routeKey(w http.ResponseWriter, r *http.Request) (domain.RouteSpec, bool) {
	spec, err := domain.ParseRouteKey(r.PathValue("route_key"))
	if err != nil {
		problem(w, http.StatusBadRequest, err.Error())
		return domain.RouteSpec{}, false
	}
	return spec, true
}

// ---------------------------------------------------------------------------
// Manejadores
// ---------------------------------------------------------------------------

func (h *handler) deals(w http.ResponseWriter, r *http.Request, _ string) {
	origin := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("origin")))
	if !iataPattern.MatchString(origin) {
		problem(w, http.StatusBadRequest, "origin: se esperaba un código IATA de 3 letras, como MAD")
		return
	}
	limit, ok := intParam(w, r, "limit", 20, 1, 50)
	if !ok {
		return
	}
	now := h.cfg.Now()
	// Se leen más rutas de las que se enseñan: luego se ordenan por chollo.
	deals, err := h.store.Deals(r.Context(), origin, now.Add(-h.cfg.DealsFreshness), h.cfg.HistoryWindow, 500)
	if err != nil {
		h.unavailable(w, "deals", err)
		return
	}
	for i := range deals {
		deals[i].DropBasisPoints = dropBasisPoints(deals[i].UsualMinor, deals[i].Price.AmountMinor)
	}
	// Primero lo que más ha bajado; a igualdad, lo más barato.
	sort.SliceStable(deals, func(i, j int) bool {
		if deals[i].DropBasisPoints != deals[j].DropBasisPoints {
			return deals[i].DropBasisPoints > deals[j].DropBasisPoints
		}
		return deals[i].Price.AmountMinor < deals[j].Price.AmountMinor
	})
	if len(deals) > limit {
		deals = deals[:limit]
	}
	out := make([]dealJSON, len(deals))
	for i, d := range deals {
		out[i] = dealJSON{fareJSON: toFare(d.Fare), UsualMinor: d.UsualMinor, DropBasisPoints: d.DropBasisPoints}
	}
	writeJSON(w, http.StatusOK, map[string]any{"origin": origin, "deals": out})
}

func (h *handler) watches(w http.ResponseWriter, r *http.Request, userID string) {
	list, err := h.store.Watches(r.Context(), userID)
	if err != nil {
		h.unavailable(w, "watches", err)
		return
	}
	out := make([]watchJSON, len(list))
	for i, wt := range list {
		out[i] = watchJSON{routeJSON: toRoute(wt.Spec), Target: toMoney(wt.Target), CreatedAt: wt.CreatedAt}
		if wt.Latest != nil {
			f := toFare(*wt.Latest)
			out[i].Latest = &f
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"watches": out, "max": h.cfg.MaxWatchesPerUser})
}

type watchBody struct {
	Target *moneyJSON `json:"target"`
}

func (h *handler) watch(w http.ResponseWriter, r *http.Request, userID string) {
	spec, ok := routeKey(w, r)
	if !ok {
		return
	}
	today := dateOf(h.cfg.Now())
	switch {
	case spec.Departure.Time().Before(today.Time()):
		problem(w, http.StatusUnprocessableEntity, "ese vuelo ya ha salido")
		return
	case spec.Departure.Time().After(today.Time().AddDate(0, 0, h.cfg.MaxDaysAhead)):
		problem(w, http.StatusUnprocessableEntity, "solo se pueden vigilar vuelos de los próximos "+strconv.Itoa(h.cfg.MaxDaysAhead)+" días")
		return
	}

	var body watchBody
	if r.ContentLength != 0 {
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			problem(w, http.StatusUnsupportedMediaType, "se esperaba application/json")
			return
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
			problem(w, http.StatusBadRequest, "cuerpo JSON inválido")
			return
		}
	}
	sub := domain.Subscription{UserID: userID, RouteKey: spec.Key()}
	if body.Target != nil {
		sub.Target = &domain.Money{Currency: strings.ToUpper(body.Target.Currency), AmountMinor: body.Target.AmountMinor}
	}
	if err := sub.Validate(); err != nil {
		problem(w, http.StatusUnprocessableEntity, err.Error())
		return
	}

	// Límite por persona (protege al flight-ingestor y la base de datos). Si
	// ya la vigilaba, cambiar el objetivo no cuenta como una ruta más.
	existing, err := h.store.Watches(r.Context(), userID)
	if err != nil {
		h.unavailable(w, "watch.list", err)
		return
	}
	already := false
	for _, wt := range existing {
		already = already || wt.Spec.Key() == sub.RouteKey
	}
	if !already && len(existing) >= h.cfg.MaxWatchesPerUser {
		problem(w, http.StatusConflict, "has llegado al máximo de rutas vigiladas: borra alguna")
		return
	}
	if err := h.store.UpsertSubscription(r.Context(), sub); err != nil {
		if domain.IsValidation(err) {
			problem(w, http.StatusUnprocessableEntity, err.Error())
			return
		}
		h.unavailable(w, "watch.upsert", err)
		return
	}
	// Que el flight-ingestor empiece YA a mirar precios. Si no responde, no
	// pasa nada: el sincronizador lo reintenta en un minuto.
	if h.watcher != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := h.watcher.Ensure(ctx, spec); err != nil {
			h.log.Warn("el flight-ingestor no aceptó la ruta (se reintentará)", slog.Any("error", err))
		}
	}
	status := http.StatusCreated
	if already {
		status = http.StatusOK
	}
	writeJSON(w, status, watchJSON{routeJSON: toRoute(spec), Target: toMoney(sub.Target), CreatedAt: h.cfg.Now().UTC()})
}

func (h *handler) unwatch(w http.ResponseWriter, r *http.Request, userID string) {
	spec, ok := routeKey(w, r)
	if !ok {
		return
	}
	err := h.store.DeleteSubscription(r.Context(), userID, spec.Key())
	switch {
	// Idempotente: borrar lo que no existe también es "hecho".
	case err == nil || errors.Is(err, store.ErrNotFound):
		w.WriteHeader(http.StatusNoContent)
	default:
		h.unavailable(w, "unwatch", err)
	}
}

func (h *handler) history(w http.ResponseWriter, r *http.Request, _ string) {
	spec, ok := routeKey(w, r)
	if !ok {
		return
	}
	currency, points, err := h.store.History(r.Context(), spec.Key(), h.cfg.Now().Add(-h.cfg.HistoryWindow))
	if err != nil {
		h.unavailable(w, "history", err)
		return
	}
	out := make([]pointJSON, len(points))
	for i, p := range points {
		out[i] = pointJSON{Date: p.Day.String(), MinMinor: p.MinMinor}
	}
	writeJSON(w, http.StatusOK, map[string]any{"route": toRoute(spec), "currency": currency, "points": out})
}

func (h *handler) alerts(w http.ResponseWriter, r *http.Request, userID string) {
	limit, ok := intParam(w, r, "limit", 30, 1, 100)
	if !ok {
		return
	}
	list, err := h.store.Alerts(r.Context(), userID, limit)
	if err != nil {
		h.unavailable(w, "alerts", err)
		return
	}
	out := make([]alertJSON, len(list))
	for i, a := range list {
		out[i] = alertJSON{
			AlertID:         a.ID,
			Type:            string(a.Type),
			routeJSON:       toRoute(a.Spec),
			Reference:       *toMoney(&a.Reference),
			Current:         *toMoney(&a.Current),
			DropBasisPoints: a.DropBasisPoints,
			BookingURL:      safeLink(a.DeepLink),
			ObservedAt:      a.ObservedAt,
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"alerts": out})
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

var iataPattern = regexp.MustCompile(`^[A-Z]{3}$`)

func intParam(w http.ResponseWriter, r *http.Request, name string, def, min, max int) (int, bool) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, true
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < min || n > max {
		problem(w, http.StatusBadRequest, name+": se esperaba un número entre "+strconv.Itoa(min)+" y "+strconv.Itoa(max))
		return 0, false
	}
	return n, true
}

// dropBasisPoints: cuánto más barato que lo habitual, en centésimas de %.
// 0 si no hay historial o si no está más barato.
func dropBasisPoints(usual, current int64) int32 {
	if usual <= 0 || current >= usual {
		return 0
	}
	return int32((usual - current) * 10_000 / usual)
}

// safeLink solo deja pasar enlaces https: un "javascript:" o "http:" que se
// colara desde un proveedor nunca llega a abrirse en el móvil.
func safeLink(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return ""
	}
	return u.String()
}

func dateOf(t time.Time) domain.Date {
	t = t.UTC()
	return domain.Date{Year: t.Year(), Month: t.Month(), Day: t.Day()}
}
