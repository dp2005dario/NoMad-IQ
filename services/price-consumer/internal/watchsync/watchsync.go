// Package watchsync mantiene al flight-ingestor consultando justo las rutas
// que hacen falta.
//
// ¿Por qué hace falta? El flight-ingestor guarda en memoria qué rutas vigila
// (si se reinicia, las olvida). La lista "de verdad" está en PostgreSQL: las
// rutas que vigilan los usuarios más las rutas populares de la portada. Cada
// minuto este sincronizador compara las dos listas y arregla la diferencia:
//
//   - falta una ruta en el ingestor → se la pide (WatchRoute);
//   - el ingestor consulta una ruta que ya nadie quiere → se la quita
//     (UnwatchRoute), para no gastar consultas al proveedor de precios.
//
// Analogía: es el encargado que cada mañana compara la lista de pedidos con
// lo que hay en el almacén y corrige lo que no cuadra. Si algo falla hoy,
// mañana (dentro de un minuto) lo vuelve a intentar.
package watchsync

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// Remote es una ruta que el flight-ingestor ya está consultando.
type Remote struct {
	ID  string
	Key string
}

// Ingestor es lo que se necesita del flight-ingestor (gRPC en producción,
// uno falso en los tests).
type Ingestor interface {
	Watch(ctx context.Context, spec domain.RouteSpec) error
	List(ctx context.Context) ([]Remote, error)
	Unwatch(ctx context.Context, id string) error
}

// Store es lo que se necesita de PostgreSQL.
type Store interface {
	SubscribedRouteKeys(ctx context.Context, today time.Time) ([]string, error)
	DeleteExpiredSubscriptions(ctx context.Context, today time.Time) (int64, error)
}

// Route es un par origen-destino popular (para la portada de chollos).
type Route struct {
	Origin      string
	Destination string
}

// ParseRoutes lee "MAD-JFK,BCN-LIS" (variable POPULAR_ROUTES).
func ParseRoutes(items []string) ([]Route, error) {
	out := make([]Route, 0, len(items))
	for _, item := range items {
		parts := strings.Split(strings.ToUpper(strings.TrimSpace(item)), "-")
		if len(parts) != 2 || len(parts[0]) != 3 || len(parts[1]) != 3 || parts[0] == parts[1] {
			return nil, fmt.Errorf("ruta popular inválida %q (formato ORIGEN-DESTINO, como MAD-JFK)", item)
		}
		// Se reutiliza la validación de las claves de ruta.
		if _, err := domain.ParseRouteKey(parts[0] + "-" + parts[1] + ":2030-01-01:ECONOMY"); err != nil {
			return nil, fmt.Errorf("ruta popular inválida %q: %w", item, err)
		}
		out = append(out, Route{Origin: parts[0], Destination: parts[1]})
	}
	return out, nil
}

// PopularSpecs da las fechas que se vigilan para las rutas populares: solo
// ida en turista, el día 15 del mes que viene y del siguiente. Así las
// fechas no cambian cada día y el historial (para saber "lo habitual") se
// acumula durante semanas.
func PopularSpecs(routes []Route, today time.Time) []domain.RouteSpec {
	first := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, time.UTC)
	var out []domain.RouteSpec
	for _, r := range routes {
		for months := 1; months <= 2; months++ {
			d := first.AddDate(0, months, 14)
			out = append(out, domain.RouteSpec{
				Origin:      r.Origin,
				Destination: r.Destination,
				Departure:   domain.Date{Year: d.Year(), Month: d.Month(), Day: d.Day()},
				Cabin:       domain.CabinEconomy,
			})
		}
	}
	return out
}

// Config del sincronizador.
type Config struct {
	Interval time.Duration
	Popular  []Route
	// Prune: quitar del ingestor las rutas que ya nadie quiere.
	Prune bool
	Now   func() time.Time
}

// Syncer compara y corrige. También implementa api.Watcher (Ensure).
type Syncer struct {
	cfg      Config
	store    Store
	ingestor Ingestor
	log      *slog.Logger
}

// New crea el sincronizador.
func New(cfg Config, st Store, ing Ingestor, log *slog.Logger) (*Syncer, error) {
	if cfg.Interval <= 0 {
		return nil, errors.New("watchsync: el intervalo debe ser positivo")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &Syncer{cfg: cfg, store: st, ingestor: ing, log: log}, nil
}

// Ensure pide al ingestor una ruta ya (cuando un usuario la acaba de añadir).
func (s *Syncer) Ensure(ctx context.Context, spec domain.RouteSpec) error {
	return s.ingestor.Watch(ctx, spec)
}

// Run sincroniza al arrancar y luego cada Interval, hasta que ctx se cancele.
// Los fallos se registran y se reintentan en la siguiente vuelta: nunca
// tumban el servicio (los precios se siguen procesando igual).
func (s *Syncer) Run(ctx context.Context) error {
	ticker := time.NewTicker(s.cfg.Interval)
	defer ticker.Stop()
	for {
		if err := s.SyncOnce(ctx); err != nil && ctx.Err() == nil {
			s.log.Warn("no se pudo sincronizar con el flight-ingestor (se reintentará)", slog.Any("error", err))
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

// Result cuenta lo que hizo una vuelta (para los logs y los tests).
type Result struct {
	Added, Removed int
	Expired        int64
}

// SyncOnce hace una vuelta completa.
func (s *Syncer) SyncOnce(ctx context.Context) error {
	_, err := s.syncOnce(ctx)
	return err
}

func (s *Syncer) syncOnce(ctx context.Context) (Result, error) {
	var res Result
	now := s.cfg.Now().UTC()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	expired, err := s.store.DeleteExpiredSubscriptions(ctx, today)
	if err != nil {
		return res, err
	}
	res.Expired = expired

	keys, err := s.store.SubscribedRouteKeys(ctx, today)
	if err != nil {
		return res, err
	}
	desired := make(map[string]domain.RouteSpec, len(keys)+2*len(s.cfg.Popular))
	for _, k := range keys {
		spec, err := domain.ParseRouteKey(k)
		if err != nil {
			continue // una clave rota no frena al resto
		}
		desired[k] = spec
	}
	for _, spec := range PopularSpecs(s.cfg.Popular, today) {
		desired[spec.Key()] = spec
	}

	remote, err := s.ingestor.List(ctx)
	if err != nil {
		return res, err
	}
	have := make(map[string]bool, len(remote))
	var errs []error
	for _, r := range remote {
		have[r.Key] = true
		if _, ok := desired[r.Key]; ok || !s.cfg.Prune {
			continue
		}
		if err := s.ingestor.Unwatch(ctx, r.ID); err != nil {
			errs = append(errs, err)
			continue
		}
		res.Removed++
	}
	for key, spec := range desired {
		if have[key] {
			continue
		}
		if err := s.ingestor.Watch(ctx, spec); err != nil {
			errs = append(errs, err)
			continue
		}
		res.Added++
	}
	if res.Added > 0 || res.Removed > 0 || res.Expired > 0 {
		s.log.Info("rutas sincronizadas con el flight-ingestor",
			slog.Int("added", res.Added), slog.Int("removed", res.Removed), slog.Int64("expired", res.Expired))
	}
	return res, errors.Join(errs...)
}
