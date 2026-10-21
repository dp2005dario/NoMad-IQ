// Package outbox publica en Kafka las alertas guardadas en PostgreSQL.
//
// El problema que resuelve (se llama "patrón Transactional Outbox"):
// queremos guardar la alerta en la base de datos Y publicarla en Kafka. Pero
// son dos sistemas distintos y no existe una transacción que abarque ambos.
//   - Si publicamos primero y luego falla la base de datos -> alerta fantasma.
//   - Si guardamos primero y el servicio muere antes de publicar -> alerta perdida.
//
// Solución: la alerta se guarda en la base de datos como "pendiente" en la
// misma transacción que el precio (todo o nada). Después, este relay
// ("repetidor") busca las pendientes, las publica y las marca como enviadas.
// Si muere a mitad, al volver las encuentra todavía pendientes y las reenvía.
//
// Resultado: cada alerta se publica AL MENOS una vez. Puede repetirse en un
// caso raro (publicada pero sin marcar), por eso lleva un ID fijo que permite
// al receptor descartar la copia.
package outbox

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
)

// Store es lo que el relay necesita de la base de datos.
type Store interface {
	ClaimPending(ctx context.Context, limit int, publish func([]domain.PendingAlert) error) (int, error)
}

// Publisher envía mensajes a Kafka y espera confirmación.
type Publisher interface {
	Publish(ctx context.Context, msgs ...events.Message) error
}

// Relay mueve alertas de la bandeja de salida a Kafka.
type Relay struct {
	store     Store
	pub       Publisher
	enc       *events.Encoder
	batchSize int
	interval  time.Duration
	log       *slog.Logger

	// wake permite "despertar" al relay en cuanto hay alertas nuevas, sin
	// esperar al siguiente tic del reloj. Capacidad 1: varios avisos
	// seguidos se funden en uno solo.
	wake    chan struct{}
	healthy atomic.Bool
}

// New crea el relay.
func New(store Store, pub Publisher, enc *events.Encoder, batchSize int, interval time.Duration, log *slog.Logger) (*Relay, error) {
	if store == nil || pub == nil || enc == nil || log == nil {
		return nil, errors.New("outbox: store, publisher, encoder y logger son obligatorios")
	}
	if batchSize < 1 || interval <= 0 {
		return nil, fmt.Errorf("outbox: batchSize (%d) e interval (%s) deben ser positivos", batchSize, interval)
	}
	r := &Relay{store: store, pub: pub, enc: enc, batchSize: batchSize, interval: interval, log: log,
		wake: make(chan struct{}, 1)}
	r.healthy.Store(true)
	return r, nil
}

// Notify avisa de que puede haber alertas nuevas. Nunca bloquea.
func (r *Relay) Notify() {
	select {
	case r.wake <- struct{}{}:
	default: // ya había un aviso pendiente: no hace falta otro
	}
}

// Healthy indica si la última pasada pudo publicar.
func (r *Relay) Healthy() bool { return r.healthy.Load() }

// Flush publica lotes hasta vaciar la bandeja. Devuelve cuántas publicó.
func (r *Relay) Flush(ctx context.Context) (int, error) {
	total := 0
	for {
		n, err := r.store.ClaimPending(ctx, r.batchSize, func(alerts []domain.PendingAlert) error {
			msgs := make([]events.Message, 0, len(alerts))
			for _, a := range alerts {
				msg, err := r.enc.EncodeFareAlert(a)
				if err != nil {
					return fmt.Errorf("codificar alerta %s: %w", a.ID, err)
				}
				msgs = append(msgs, msg)
			}
			return r.pub.Publish(ctx, msgs...)
		})
		total += n
		if err != nil {
			return total, fmt.Errorf("outbox: %w", err)
		}
		if n < r.batchSize { // lote incompleto = no queda nada más
			return total, nil
		}
	}
}

// Run publica cada vez que se le avisa o, como red de seguridad, cada
// interval. Termina cuando ctx se cancela, tras una última pasada.
func (r *Relay) Run(ctx context.Context) error {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Última pasada con un tiempo límite propio, para no dejar
			// alertas esperando hasta el próximo arranque.
			final, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			r.flushAndLog(final)
			cancel()
			return nil
		case <-ticker.C:
		case <-r.wake:
		}
		r.flushAndLog(ctx)
	}
}

func (r *Relay) flushAndLog(ctx context.Context) {
	n, err := r.Flush(ctx)
	if err != nil {
		// No se aborta el servicio: las alertas siguen guardadas y se
		// reintentan en la siguiente pasada. Solo se marca como no sano.
		r.healthy.Store(false)
		r.log.Error("no se pudieron publicar alertas; se reintentará", slog.Any("error", err))
		return
	}
	r.healthy.Store(true)
	if n > 0 {
		r.log.Info("alertas publicadas", slog.Int("count", n))
	}
}
