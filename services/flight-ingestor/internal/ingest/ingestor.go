// Package ingest es el corazón del servicio: cada cierto tiempo consulta los
// precios de todas las rutas vigiladas, en paralelo y con un límite de
// concurrencia, y publica cada observación en Kafka.
package ingest

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/provider"
)

// WatchLister da la lista de seguimientos actual (la implementa watchlist.Store).
type WatchLister interface {
	List() []domain.Watch
}

// Publisher entrega mensajes a Kafka (la implementa publisher.Kafka).
// Debe devolver error solo cuando el broker no ha confirmado la escritura.
type Publisher interface {
	Publish(ctx context.Context, msgs ...events.Message) error
}

// Config controla el ritmo y el paralelismo de la ingesta.
type Config struct {
	// Interval entre ciclos completos.
	Interval time.Duration
	// QueryTimeout máximo por consulta a un proveedor.
	QueryTimeout time.Duration
	// Concurrency es el número máximo de consultas simultáneas. Limitarlo
	// protege a los proveedores (rate limits) y a nuestra memoria.
	Concurrency int
}

func (c Config) validate() error {
	var errs []error
	if c.Interval <= 0 {
		errs = append(errs, errors.New("Interval debe ser positivo"))
	}
	if c.QueryTimeout <= 0 {
		errs = append(errs, errors.New("QueryTimeout debe ser positivo"))
	}
	if c.Concurrency <= 0 {
		errs = append(errs, errors.New("Concurrency debe ser positivo"))
	}
	return errors.Join(errs...)
}

// CycleStats resume un ciclo; se registra en el log y sirve en los tests.
type CycleStats struct {
	Watches        int
	Quotes         int
	Published      int
	ProviderErrors int
	EncodeErrors   int
	PublishErrors  int
	Duration       time.Duration
}

// Ingestor orquesta proveedores, codificación y publicación.
type Ingestor struct {
	cfg       Config
	watches   WatchLister
	provider  provider.FareProvider
	encoder   *events.Encoder
	publisher Publisher
	log       *slog.Logger
	healthy   atomic.Bool
}

// New valida dependencias y configuración.
func New(cfg Config, watches WatchLister, p provider.FareProvider, enc *events.Encoder, pub Publisher, log *slog.Logger) (*Ingestor, error) {
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("ingest: configuración inválida: %w", err)
	}
	if watches == nil || p == nil || enc == nil || pub == nil || log == nil {
		return nil, errors.New("ingest: todas las dependencias son obligatorias")
	}
	return &Ingestor{cfg: cfg, watches: watches, provider: p, encoder: enc, publisher: pub, log: log}, nil
}

// Healthy indica si el último ciclo pudo publicar (o no tenía nada que publicar).
func (in *Ingestor) Healthy() bool { return in.healthy.Load() }

// Run ejecuta un ciclo inmediatamente y luego uno por intervalo, hasta que
// ctx se cancele. Si un ciclo tarda más que el intervalo, el siguiente
// empieza al terminar (nunca se solapan dos ciclos).
func (in *Ingestor) Run(ctx context.Context) error {
	in.healthy.Store(true)
	ticker := time.NewTicker(in.cfg.Interval)
	defer ticker.Stop()

	for {
		stats := in.RunCycle(ctx)
		in.log.LogAttrs(ctx, levelFor(stats), "ciclo de ingesta terminado",
			slog.Int("watches", stats.Watches),
			slog.Int("quotes", stats.Quotes),
			slog.Int("published", stats.Published),
			slog.Int("provider_errors", stats.ProviderErrors),
			slog.Int("encode_errors", stats.EncodeErrors),
			slog.Int("publish_errors", stats.PublishErrors),
			slog.Duration("duration", stats.Duration),
		)
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func levelFor(s CycleStats) slog.Level {
	if s.PublishErrors > 0 || s.EncodeErrors > 0 {
		return slog.LevelError
	}
	if s.ProviderErrors > 0 {
		return slog.LevelWarn
	}
	return slog.LevelInfo
}

// RunCycle consulta todas las rutas una vez. Un fallo en una ruta no detiene
// a las demás: se cuenta, se registra y el ciclo continúa.
func (in *Ingestor) RunCycle(ctx context.Context) CycleStats {
	start := time.Now()
	watches := in.watches.List()

	var (
		providerErrs, encodeErrs, publishErrs atomic.Int64
		quotes, published                     atomic.Int64
		wg                                    sync.WaitGroup
	)
	// Semáforo: canal con capacidad = concurrencia máxima.
	sem := make(chan struct{}, in.cfg.Concurrency)

loop:
	for _, w := range watches {
		select {
		case <-ctx.Done():
			break loop
		case sem <- struct{}{}:
		}
		wg.Add(1)
		go func(w domain.Watch) {
			defer wg.Done()
			defer func() { <-sem }()
			r := in.processWatch(ctx, w)
			quotes.Add(int64(r.quotes))
			published.Add(int64(r.published))
			providerErrs.Add(int64(r.providerErrs))
			encodeErrs.Add(int64(r.encodeErrs))
			publishErrs.Add(int64(r.publishErrs))
		}(w)
	}
	wg.Wait()

	stats := CycleStats{
		Watches:        len(watches),
		Quotes:         int(quotes.Load()),
		Published:      int(published.Load()),
		ProviderErrors: int(providerErrs.Load()),
		EncodeErrors:   int(encodeErrs.Load()),
		PublishErrors:  int(publishErrs.Load()),
		Duration:       time.Since(start),
	}
	in.healthy.Store(stats.PublishErrors == 0)
	return stats
}

type watchResult struct {
	quotes, published, providerErrs, encodeErrs, publishErrs int
}

func (in *Ingestor) processWatch(ctx context.Context, w domain.Watch) (res watchResult) {
	log := in.log.With(slog.String("watch_id", w.ID), slog.String("route_key", w.Spec.Key()))

	// Una goroutine con pánico tumbaría todo el proceso: lo convertimos en error.
	defer func() {
		if r := recover(); r != nil {
			log.Error("pánico procesando seguimiento", slog.Any("panic", r))
			res.providerErrs++
		}
	}()

	qctx, cancel := context.WithTimeout(ctx, in.cfg.QueryTimeout)
	quotes, err := in.provider.Quote(qctx, w.Spec)
	cancel()
	if err != nil {
		res.providerErrs++
		level := slog.LevelWarn
		if errors.Is(err, provider.ErrRateLimited) {
			level = slog.LevelInfo
		}
		log.Log(ctx, level, "fallo consultando proveedor", slog.String("provider", in.provider.Name()), slog.Any("error", err))
		return res
	}
	res.quotes = len(quotes)

	correlationID := in.encoder.NewID()
	msgs := make([]events.Message, 0, len(quotes))
	for _, q := range quotes {
		msg, err := in.encoder.EncodePriceObserved(domain.PriceObservation{Watch: w, Provider: in.provider.Name(), Quote: q}, correlationID)
		if err != nil {
			// Dato inválido del proveedor: se descarta, no se publica basura.
			res.encodeErrs++
			log.Error("observación descartada", slog.Any("error", err))
			continue
		}
		msgs = append(msgs, msg)
	}
	if len(msgs) == 0 {
		return res
	}
	if err := in.publisher.Publish(ctx, msgs...); err != nil {
		res.publishErrs += len(msgs)
		log.Error("fallo publicando en Kafka", slog.Int("messages", len(msgs)), slog.Any("error", err))
		return res
	}
	res.published = len(msgs)
	return res
}
