//go:build integration

// Test de integración contra un Kafka real. Requiere el docker-compose de
// infrastructure/ levantado:
//
//	KAFKA_BROKERS=localhost:29092 go test -tags integration ./internal/publisher/
package publisher

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/events"
)

func TestKafkaPublishAndConsume(t *testing.T) {
	brokers := strings.Split(os.Getenv("KAFKA_BROKERS"), ",")
	if brokers[0] == "" {
		t.Skip("KAFKA_BROKERS no definido")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pub, err := NewKafka(KafkaConfig{Brokers: brokers, ClientID: "integration-test"})
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close(ctx)
	if err := pub.Ping(ctx); err != nil {
		t.Fatal(err)
	}

	key := "TEST-" + time.Now().Format("150405.000000000")
	msg := events.Message{Topic: events.TopicPriceObserved, Key: []byte(key), Value: []byte("hola"),
		Headers: []events.Header{{Key: events.HeaderType, Value: []byte("test")}}}
	if err := pub.Publish(ctx, msg); err != nil {
		t.Fatal(err)
	}

	consumer, err := kgo.NewClient(kgo.SeedBrokers(brokers...), kgo.ConsumeTopics(events.TopicPriceObserved),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()
	for {
		fetches := consumer.PollFetches(ctx)
		if err := ctx.Err(); err != nil {
			t.Fatalf("mensaje no recibido: %v", err)
		}
		found := false
		fetches.EachRecord(func(r *kgo.Record) {
			if string(r.Key) == key && string(r.Value) == "hola" {
				found = true
			}
		})
		if found {
			return
		}
	}
}

func TestPublishToMissingTopicFails(t *testing.T) {
	brokers := strings.Split(os.Getenv("KAFKA_BROKERS"), ",")
	if brokers[0] == "" {
		t.Skip("KAFKA_BROKERS no definido")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pub, err := NewKafka(KafkaConfig{Brokers: brokers, ClientID: "integration-test"})
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close(ctx)
	if err := pub.Publish(ctx, events.Message{Topic: "topic.que.no.existe", Value: []byte("x")}); err == nil {
		t.Fatal("publicar en un topic inexistente debería fallar")
	}
}
