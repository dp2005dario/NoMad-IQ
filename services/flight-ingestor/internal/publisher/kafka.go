// Package publisher implementa la publicación de eventos en Apache Kafka
// con franz-go, un cliente 100 % Go (sin dependencias de C) y muy rápido.
package publisher

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/events"
)

// KafkaConfig agrupa las opciones del productor.
type KafkaConfig struct {
	Brokers  []string
	ClientID string
	// TLS es opcional en local; en producción debe configurarse (mTLS).
	TLS *tls.Config
	// Linger: cuánto esperar para agrupar mensajes en un lote. Unos pocos
	// milisegundos multiplican el rendimiento a cambio de una latencia mínima.
	Linger time.Duration
}

// Kafka es un productor idempotente con confirmación de todas las réplicas.
type Kafka struct {
	client *kgo.Client
}

// NewKafka crea el productor. No conecta todavía: la conexión es perezosa,
// por eso conviene llamar a Ping antes de declarar el servicio listo.
func NewKafka(cfg KafkaConfig) (*Kafka, error) {
	if len(cfg.Brokers) == 0 {
		return nil, errors.New("publisher: se necesita al menos un broker de Kafka")
	}
	opts := []kgo.Opt{
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ClientID(cfg.ClientID),
		// acks=all: el mensaje solo cuenta como escrito cuando todas las
		// réplicas sincronizadas lo tienen. Junto con la idempotencia (activa
		// por defecto en franz-go) evita pérdidas y duplicados por reintentos.
		kgo.RequiredAcks(kgo.AllISRAcks()),
		kgo.ProducerBatchCompression(kgo.ZstdCompression(), kgo.Lz4Compression(), kgo.NoCompression()),
		kgo.ProducerLinger(cfg.Linger),
		kgo.ProduceRequestTimeout(10 * time.Second),
		kgo.RecordDeliveryTimeout(30 * time.Second),
		// No se usa kgo.AllowAutoTopicCreation: los topics deben existir
		// (los crea kafka-init) y un nombre mal escrito falla en lugar de
		// crear un topic fantasma.
	}
	if cfg.TLS != nil {
		opts = append(opts, kgo.DialTLSConfig(cfg.TLS))
	}
	client, err := kgo.NewClient(opts...)
	if err != nil {
		return nil, fmt.Errorf("publisher: crear cliente Kafka: %w", err)
	}
	return &Kafka{client: client}, nil
}

// Publish envía los mensajes y espera la confirmación del broker para todos.
// Si alguno falla devuelve el primer error; el llamador decide qué hacer.
func (k *Kafka) Publish(ctx context.Context, msgs ...events.Message) error {
	if len(msgs) == 0 {
		return nil
	}
	// Traducimos nuestros Message (independientes de Kafka) a kgo.Record, el
	// tipo que entiende la librería franz-go.
	records := make([]*kgo.Record, len(msgs))
	for i, m := range msgs {
		headers := make([]kgo.RecordHeader, len(m.Headers))
		for j, h := range m.Headers {
			headers[j] = kgo.RecordHeader{Key: h.Key, Value: h.Value}
		}
		records[i] = &kgo.Record{Topic: m.Topic, Key: m.Key, Value: m.Value, Headers: headers}
	}
	if err := k.client.ProduceSync(ctx, records...).FirstErr(); err != nil {
		return fmt.Errorf("publisher: producir %d mensajes: %w", len(records), err)
	}
	return nil
}

// Ping comprueba que hay conexión con algún broker.
func (k *Kafka) Ping(ctx context.Context) error {
	if err := k.client.Ping(ctx); err != nil {
		return fmt.Errorf("publisher: ping a Kafka: %w", err)
	}
	return nil
}

// Close vacía los mensajes pendientes (hasta que ctx expire) y cierra.
func (k *Kafka) Close(ctx context.Context) error {
	err := k.client.Flush(ctx)
	k.client.Close()
	if err != nil {
		return fmt.Errorf("publisher: vaciar mensajes pendientes: %w", err)
	}
	return nil
}
