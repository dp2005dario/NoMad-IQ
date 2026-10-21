// Package processor decide qué hacer con CADA mensaje de precio que llega.
//
// Es el "director de orquesta": no sabe hablar con Kafka ni con PostgreSQL
// directamente, solo usa interfaces (Store, Publisher). Pasos por mensaje:
//
//  1. Traducir y validar el mensaje. Si está roto -> a la DLQ y seguir.
//  2. En UNA transacción de base de datos:
//     a. guardar el precio (si ya existía, es un duplicado: no hacer nada más);
//     b. leer el historial reciente, las suscripciones y las alertas recientes;
//     c. preguntar al detector si es un chollo;
//     d. guardar las alertas como "pendientes de publicar".
//  3. El paquete outbox publicará después esas alertas en Kafka.
//
// ¿Por qué todo en una transacción? Porque o se guarda TODO (precio +
// alertas) o NADA. Si el servicio se cae a mitad, no queda un precio guardado
// sin sus alertas: el mensaje se volverá a leer y se procesará entero.
package processor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/detector"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
)

// Tx son las operaciones disponibles dentro de una transacción.
type Tx interface {
	// InsertObservation guarda el precio. Devuelve false si ese event_id ya
	// estaba guardado (mensaje repetido): es la clave de la idempotencia.
	InsertObservation(ctx context.Context, obs domain.Observation, partition int32, offset int64) (bool, error)
	// RecentPrices devuelve hasta limit importes de la ruta y divisa,
	// observados en [since, before), del más reciente al más antiguo.
	RecentPrices(ctx context.Context, routeKey, currency string, since, before time.Time, limit int) ([]int64, error)
	// Subscriptions devuelve quién vigila la ruta.
	Subscriptions(ctx context.Context, routeKey string) ([]domain.Subscription, error)
	// RecentlyAlerted devuelve, por usuario, el precio más bajo ya avisado
	// para la ruta y divisa desde since (para el anti-spam).
	RecentlyAlerted(ctx context.Context, routeKey, currency string, since time.Time) (map[string]int64, error)
	// InsertAlerts guarda las alertas como pendientes de publicar.
	InsertAlerts(ctx context.Context, alerts []domain.Alert) error
}

// Store abre transacciones. Si fn devuelve error, se deshace todo (rollback).
type Store interface {
	InTx(ctx context.Context, fn func(Tx) error) error
}

// Publisher envía mensajes a Kafka (aquí solo se usa para la DLQ).
type Publisher interface {
	Publish(ctx context.Context, msgs ...events.Message) error
}

// Config agrupa los parámetros del procesado.
type Config struct {
	Rules detector.Rules
	// HistoryWindow: hasta cuándo atrás se mira el historial (p. ej. 30 días).
	HistoryWindow time.Duration
	// HistoryLimit: máximo de precios a leer (protege la base de datos).
	HistoryLimit int
	// AlertCooldown: periodo anti-spam por usuario y ruta.
	AlertCooldown time.Duration
}

// Validate comprueba la configuración.
func (c Config) Validate() error {
	var errs []error
	if err := c.Rules.Validate(); err != nil {
		errs = append(errs, err)
	}
	if c.HistoryWindow <= 0 {
		errs = append(errs, errors.New("HistoryWindow debe ser positivo"))
	}
	if c.HistoryLimit < c.Rules.MinSamples {
		errs = append(errs, fmt.Errorf("HistoryLimit (%d) no puede ser menor que MinSamples (%d)", c.HistoryLimit, c.Rules.MinSamples))
	}
	if c.AlertCooldown < 0 {
		errs = append(errs, errors.New("AlertCooldown no puede ser negativo"))
	}
	return errors.Join(errs...)
}

// Outcome dice qué pasó con un mensaje (para logs y tests).
type Outcome int

const (
	OutcomeStored    Outcome = iota + 1 // precio nuevo guardado
	OutcomeDuplicate                    // ya se había procesado antes: ignorado
	OutcomeRejected                     // mensaje inválido: enviado a la DLQ
)

func (o Outcome) String() string {
	switch o {
	case OutcomeStored:
		return "stored"
	case OutcomeDuplicate:
		return "duplicate"
	case OutcomeRejected:
		return "rejected"
	}
	return "unknown"
}

// Result es el resumen del procesado de un mensaje.
type Result struct {
	Outcome Outcome
	Alerts  int
	Market  detector.Market
}

// Processor procesa mensajes de FlightPriceObserved.
type Processor struct {
	cfg   Config
	store Store
	dlq   Publisher
	enc   *events.Encoder
	log   *slog.Logger
}

// New valida la configuración y crea el Processor.
func New(cfg Config, store Store, dlq Publisher, enc *events.Encoder, log *slog.Logger) (*Processor, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("processor: configuración inválida: %w", err)
	}
	if store == nil || dlq == nil || enc == nil || log == nil {
		return nil, errors.New("processor: store, dlq, encoder y logger son obligatorios")
	}
	return &Processor{cfg: cfg, store: store, dlq: dlq, enc: enc, log: log}, nil
}

// Handle procesa un mensaje.
//
// Contrato de errores (muy importante para no perder ni atascar mensajes):
//   - Devuelve nil si el mensaje quedó resuelto (guardado, duplicado o en DLQ).
//     Entonces es seguro avanzar el offset de Kafka.
//   - Devuelve error solo si el fallo es TEMPORAL (base de datos o Kafka
//     caídos). Quien llama debe reintentar el MISMO mensaje más tarde.
func (p *Processor) Handle(ctx context.Context, rec events.Record) (Result, error) {
	obs, err := events.DecodePriceObserved(rec)
	if err != nil {
		return p.reject(ctx, rec, err)
	}

	var res Result
	err = p.store.InTx(ctx, func(tx Tx) error {
		res = Result{} // la transacción puede reintentarse: empezar limpio
		inserted, err := tx.InsertObservation(ctx, obs, rec.Partition, rec.Offset)
		if err != nil {
			return err
		}
		if !inserted {
			res.Outcome = OutcomeDuplicate
			return nil
		}
		res.Outcome = OutcomeStored

		routeKey := obs.RouteKey()
		history, err := tx.RecentPrices(ctx, routeKey, obs.Price.Currency,
			obs.ObservedAt.Add(-p.cfg.HistoryWindow), obs.ObservedAt, p.cfg.HistoryLimit)
		if err != nil {
			return err
		}
		subs, err := tx.Subscriptions(ctx, routeKey)
		if err != nil {
			return err
		}
		recent := map[string]int64{}
		if len(subs) > 0 && p.cfg.AlertCooldown > 0 {
			if recent, err = tx.RecentlyAlerted(ctx, routeKey, obs.Price.Currency, obs.ObservedAt.Add(-p.cfg.AlertCooldown)); err != nil {
				return err
			}
		}

		alerts, market := p.cfg.Rules.Evaluate(detector.Input{
			Observation: obs, History: history, Subscriptions: subs, RecentlyAlerted: recent,
		})
		res.Market = market
		res.Alerts = len(alerts)
		if len(alerts) == 0 {
			return nil
		}
		return tx.InsertAlerts(ctx, alerts)
	})
	if err != nil {
		// Si la base de datos rechaza los DATOS (no la conexión), reintentar
		// no sirve: el store lo marca como error de validación y va a la DLQ.
		if domain.IsValidation(err) {
			return p.reject(ctx, rec, err)
		}
		return Result{}, fmt.Errorf("procesar evento %s: %w", obs.EventID, err)
	}

	if res.Market.Signal != "" {
		p.log.Info("chollo detectado",
			slog.String("route_key", obs.RouteKey()), slog.String("signal", string(res.Market.Signal)),
			slog.String("price", obs.Price.String()), slog.Int64("baseline_minor", res.Market.Baseline),
			slog.Int("drop_bp", int(res.Market.DropBasisPoints)), slog.Int("alerts", res.Alerts))
	}
	return res, nil
}

// reject manda el mensaje a la DLQ. Si la DLQ no está disponible devuelve
// error para que se reintente: NUNCA se descarta un mensaje en silencio.
func (p *Processor) reject(ctx context.Context, rec events.Record, reason error) (Result, error) {
	p.log.Warn("mensaje inválido enviado a la DLQ",
		slog.String("topic", rec.Topic), slog.Int("partition", int(rec.Partition)),
		slog.Int64("offset", rec.Offset), slog.Any("reason", reason))
	if err := p.dlq.Publish(ctx, p.enc.EncodeDLQ(rec, reason)); err != nil {
		return Result{}, fmt.Errorf("enviar a la DLQ (offset %d): %w", rec.Offset, err)
	}
	return Result{Outcome: OutcomeRejected}, nil
}
