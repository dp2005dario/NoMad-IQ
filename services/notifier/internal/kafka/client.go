// Package kafka conecta el servicio con Apache Kafka usando franz-go.
//
// Conceptos clave para entender este fichero:
//
//   - Topic: un "canal" de mensajes, como una cinta transportadora.
//   - Partición: el topic se divide en varias cintas paralelas. Los mensajes
//     con la misma clave (la misma ruta) caen siempre en la misma partición y
//     se leen EN ORDEN. Particiones distintas se procesan a la vez.
//   - Grupo de consumidores: si arrancas 3 copias de este servicio con el
//     mismo group id, Kafka reparte las particiones entre ellas. Así se escala
//     horizontalmente: más copias = más velocidad. Si una muere, sus
//     particiones pasan a las demás ("rebalanceo").
//   - Offset: la posición de lectura en una partición ("voy por el mensaje
//     1.532"). Confirmarlo (commit) es decirle a Kafka "hasta aquí ya está
//     hecho"; si el servicio se reinicia, continúa desde ahí.
//
// Garantía elegida: "al menos una vez". Solo se confirma el offset DESPUÉS
// de procesar y guardar el mensaje. Si el servicio muere en medio, el mensaje
// se vuelve a leer; como el procesado es idempotente, repetirlo no hace daño.
package kafka

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"golang.org/x/sync/errgroup"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
)

// Config agrupa las opciones del cliente.
type Config struct {
	Brokers  []string
	ClientID string
	GroupID  string
	Topic    string // topic que se consume
	TLS      *tls.Config
	// MaxPollRecords limita cuántos mensajes se traen de golpe (memoria acotada).
	MaxPollRecords int
}

// Client consume en grupo y también publica (solo la DLQ).
type Client struct {
	cl  *kgo.Client
	cfg Config
	log *slog.Logger
}

// New crea el cliente. La conexión se abre de forma perezosa.
func New(cfg Config, log *slog.Logger) (*Client, error) {
	if len(cfg.Brokers) == 0 || cfg.GroupID == "" || cfg.Topic == "" {
		return nil, errors.New("kafka: brokers, group id y topic son obligatorios")
	}
	if cfg.MaxPollRecords < 1 {
		return nil, errors.New("kafka: MaxPollRecords debe ser >= 1")
	}
	opts := []kgo.Opt{
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ClientID(cfg.ClientID),

		// --- Consumo ---
		kgo.ConsumerGroup(cfg.GroupID),
		kgo.ConsumeTopics(cfg.Topic),
		// Si el grupo es nuevo, empezar por el FINAL: las órdenes viejas ya no
		// sirven ("acabas de llegar" de hace horas). Las que se acumulen
		// mientras el servicio está parado sí se leen (el offset confirmado
		// se conserva), y las que lleguen tarde se descartan por antigüedad.
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()),
		// Desactivamos el commit automático: lo hacemos nosotros tras guardar.
		kgo.DisableAutoCommit(),
		// Evita que Kafka quite particiones a mitad de un lote: el rebalanceo
		// espera a que llamemos a AllowRebalance (tras confirmar offsets).
		kgo.BlockRebalanceOnPoll(),
		// Estrategia "cooperative-sticky": en un rebalanceo solo se mueven las
		// particiones necesarias, el resto sigue trabajando sin pausa.
		kgo.Balancers(kgo.CooperativeStickyBalancer()),

		// --- Producción (DLQ) ---
		kgo.RequiredAcks(kgo.AllISRAcks()),
		kgo.ProducerBatchCompression(kgo.ZstdCompression(), kgo.Lz4Compression(), kgo.NoCompression()),
		kgo.ProducerLinger(5 * time.Millisecond),
		kgo.RecordDeliveryTimeout(30 * time.Second),
	}
	if cfg.TLS != nil {
		opts = append(opts, kgo.DialTLSConfig(cfg.TLS))
	}
	cl, err := kgo.NewClient(opts...)
	if err != nil {
		return nil, fmt.Errorf("kafka: crear cliente: %w", err)
	}
	return &Client{cl: cl, cfg: cfg, log: log}, nil
}

// Publish envía los mensajes y espera la confirmación de todos.
func (c *Client) Publish(ctx context.Context, msgs ...events.Message) error {
	if len(msgs) == 0 {
		return nil
	}
	records := make([]*kgo.Record, len(msgs))
	for i, m := range msgs {
		headers := make([]kgo.RecordHeader, len(m.Headers))
		for j, h := range m.Headers {
			headers[j] = kgo.RecordHeader{Key: h.Key, Value: h.Value}
		}
		records[i] = &kgo.Record{Topic: m.Topic, Key: m.Key, Value: m.Value, Headers: headers}
	}
	if err := c.cl.ProduceSync(ctx, records...).FirstErr(); err != nil {
		return fmt.Errorf("kafka: producir %d mensajes: %w", len(records), err)
	}
	return nil
}

// Ping comprueba que hay conexión con algún broker.
func (c *Client) Ping(ctx context.Context) error {
	if err := c.cl.Ping(ctx); err != nil {
		return fmt.Errorf("kafka: ping: %w", err)
	}
	return nil
}

// Close abandona el grupo (sus particiones pasan a otras copias de inmediato)
// y cierra las conexiones.
func (c *Client) Close() { c.cl.Close() }

// Handler procesa un mensaje. Debe devolver error SOLO si el fallo es
// temporal: el consumidor reintentará el mismo mensaje.
type Handler func(ctx context.Context, rec events.Record) error

// Backoff define la espera entre reintentos: empieza en Initial y se duplica
// hasta Max ("backoff exponencial"). Así, si la base de datos está caída, no
// la bombardeamos con miles de reintentos por segundo.
type Backoff struct {
	Initial time.Duration
	Max     time.Duration
}

func (b Backoff) next(d time.Duration) time.Duration {
	if d == 0 {
		return b.Initial
	}
	return min(d*2, b.Max)
}

// Consume es el bucle principal. Termina cuando ctx se cancela (apagado) o
// ante un error irrecuperable de Kafka. afterBatch (opcional) se llama tras
// cada lote confirmado.
func (c *Client) Consume(ctx context.Context, handle Handler, backoff Backoff, afterBatch func()) error {
	for {
		fetches := c.cl.PollRecords(ctx, c.cfg.MaxPollRecords)
		if fetches.IsClientClosed() || ctx.Err() != nil {
			return nil
		}
		var fatal error
		fetches.EachError(func(topic string, partition int32, err error) {
			// Los errores de lectura suelen ser temporales y franz-go reintenta
			// solo, así que únicamente se registran. La excepción es que el
			// cliente esté cerrado: entonces no tiene sentido seguir.
			if errors.Is(err, context.Canceled) {
				return
			}
			if errors.Is(err, kgo.ErrClientClosed) {
				fatal = err
				return
			}
			c.log.Error("error leyendo de Kafka", slog.String("topic", topic), slog.Int("partition", int(partition)), slog.Any("error", err))
		})
		if fatal != nil {
			return fmt.Errorf("kafka: %w", fatal)
		}

		// Cada partición se procesa en su propia goroutine (en paralelo), pero
		// dentro de una partición los mensajes van uno detrás de otro (orden).
		var partitions [][]*kgo.Record
		fetches.EachPartition(func(p kgo.FetchTopicPartition) {
			if len(p.Records) > 0 {
				partitions = append(partitions, p.Records)
			}
		})
		// Cada goroutine escribe solo en SU casilla del slice: no hay carreras.
		processed := make([][]*kgo.Record, len(partitions))
		var g errgroup.Group
		for i, recs := range partitions {
			g.Go(func() error {
				processed[i] = c.processPartition(ctx, recs, handle, backoff)
				return nil
			})
		}
		_ = g.Wait() // las goroutines nunca devuelven error: reintentan o paran

		// Confirmamos SOLO lo que se terminó. Contexto propio: en un apagado
		// ctx ya está cancelado, pero queremos guardar el progreso igualmente.
		var toCommit []*kgo.Record
		for _, done := range processed {
			toCommit = append(toCommit, done...)
		}
		if len(toCommit) > 0 {
			commitCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
			err := c.cl.CommitRecords(commitCtx, toCommit...)
			cancel()
			if err != nil {
				// No es grave: esos mensajes se releerán y, al ser idempotente,
				// no se duplicará nada. Solo se registra.
				c.log.Warn("no se pudieron confirmar offsets; se reprocesarán", slog.Any("error", err))
			}
		}
		c.cl.AllowRebalance()
		if afterBatch != nil && len(toCommit) > 0 {
			afterBatch()
		}
		if ctx.Err() != nil {
			return nil
		}
	}
}

// processPartition procesa en orden los mensajes de una partición. Si uno
// falla temporalmente lo reintenta (con espera creciente) hasta que funcione
// o hasta el apagado. Devuelve los mensajes completados, en orden.
func (c *Client) processPartition(ctx context.Context, recs []*kgo.Record, handle Handler, backoff Backoff) []*kgo.Record {
	done := make([]*kgo.Record, 0, len(recs))
	for _, r := range recs {
		rec := toRecord(r)
		var wait time.Duration
		for {
			// El mensaje en curso se termina aunque llegue la señal de apagado
			// (WithoutCancel): cortar una transacción a medias no rompe nada,
			// pero terminarla evita repetir trabajo al arrancar.
			err := handle(context.WithoutCancel(ctx), rec)
			if err == nil {
				break
			}
			wait = backoff.next(wait)
			c.log.Error("fallo temporal procesando mensaje; se reintentará",
				slog.String("topic", rec.Topic), slog.Int("partition", int(rec.Partition)),
				slog.Int64("offset", rec.Offset), slog.Duration("retry_in", wait), slog.Any("error", err))
			timer := time.NewTimer(wait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return done // apagado: este mensaje y los siguientes se releerán
			case <-timer.C:
			}
		}
		done = append(done, r)
		if ctx.Err() != nil {
			return done // apagado: no empezar mensajes nuevos
		}
	}
	return done
}

func toRecord(r *kgo.Record) events.Record {
	headers := make([]events.Header, len(r.Headers))
	for i, h := range r.Headers {
		headers[i] = events.Header{Key: h.Key, Value: h.Value}
	}
	return events.Record{Topic: r.Topic, Partition: r.Partition, Offset: r.Offset, Key: r.Key, Value: r.Value, Headers: headers}
}
