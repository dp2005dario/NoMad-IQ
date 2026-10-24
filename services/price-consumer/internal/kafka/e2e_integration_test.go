//go:build integration

// Test de punta a punta con Kafka y PostgreSQL REALES:
//
//	producir precios -> Consume -> processor -> PostgreSQL -> outbox -> Kafka (alertas)
//
// Se ejecuta con la infraestructura de docker compose levantada:
//
//	KAFKA_BROKERS=localhost:29092 PGHOST=localhost PGUSER=... PGPASSWORD=... PGDATABASE=... \
//	  go test -tags integration ./internal/kafka/
package kafka

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/detector"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/outbox"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/processor"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/store"
)

func TestEndToEnd(t *testing.T) {
	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" || os.Getenv("PGHOST") == "" {
		t.Skip("KAFKA_BROKERS o PGHOST no definidos: se omite el test de punta a punta")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	// --- PostgreSQL ---
	port, _ := strconv.Atoi(os.Getenv("PGPORT"))
	if port == 0 {
		port = 5432
	}
	db, err := store.Open(ctx, store.Config{Host: os.Getenv("PGHOST"), Port: port, User: os.Getenv("PGUSER"),
		Password: os.Getenv("PGPASSWORD"), Database: os.Getenv("PGDATABASE"), SSLMode: "disable", MaxConns: 4})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}

	// Ruta y usuario únicos para este test (la base de datos y los topics se comparten).
	suffix := uuid.NewString()[:8]
	user := "e2e-" + suffix
	dep := &commonv1.Date{Year: 2027, Month: int32(1 + time.Now().Nanosecond()%12), Day: int32(1 + time.Now().Nanosecond()%28)}
	routeKey := fmt.Sprintf("ZZA-ZZB:%04d-%02d-%02d:ECONOMY", dep.Year, dep.Month, dep.Day)
	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: user, RouteKey: routeKey}); err != nil {
		t.Fatal(err)
	}

	// --- Producir: 5 precios normales, 1 tarifa error y 1 mensaje basura ---
	producer, err := kgo.NewClient(kgo.SeedBrokers(strings.Split(brokers, ",")...))
	if err != nil {
		t.Fatal(err)
	}
	defer producer.Close()
	base := time.Now().UTC().Add(-time.Hour)
	var records []*kgo.Record
	for i, amount := range []int64{50000, 51000, 49000, 50500, 49500, 15000} {
		evt := &flightsv1.FlightPriceObserved{
			Metadata:      &commonv1.EventMetadata{EventId: uuid.NewString(), CorrelationId: "e2e"},
			Route:         &flightsv1.Route{OriginIata: "ZZA", DestinationIata: "ZZB"},
			DepartureDate: dep,
			Cabin:         flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
			Price:         &commonv1.Money{CurrencyCode: "EUR", AmountMinor: amount},
			Provider:      "e2e",
			ObservedAt:    timestamppb.New(base.Add(time.Duration(i) * time.Minute)),
		}
		value, err := proto.Marshal(evt)
		if err != nil {
			t.Fatal(err)
		}
		records = append(records, &kgo.Record{Topic: events.TopicPriceObserved, Key: []byte(routeKey), Value: value})
	}
	poisonKey := "poison-" + suffix
	records = append(records, &kgo.Record{Topic: events.TopicPriceObserved, Key: []byte(poisonKey), Value: []byte("no soy protobuf")})
	if err := producer.ProduceSync(ctx, records...).FirstErr(); err != nil {
		t.Fatal(err)
	}

	// --- Arrancar el consumidor con un grupo propio ---
	kc, err := New(Config{Brokers: strings.Split(brokers, ","), ClientID: "e2e", GroupID: "e2e-" + suffix,
		Topic: events.TopicPriceObserved, MaxPollRecords: 500}, log)
	if err != nil {
		t.Fatal(err)
	}
	enc := events.NewEncoder(events.TopicFareAlerts, events.TopicPriceObservedDLQ, "price-consumer-e2e")
	proc, err := processor.New(processor.Config{
		Rules:         detector.Rules{MinSamples: 5, DropBasisPoints: 2000, ErrorFareBasisPoints: 5000},
		HistoryWindow: 24 * time.Hour, HistoryLimit: 100, AlertCooldown: time.Hour,
	}, db, kc, enc, log)
	if err != nil {
		t.Fatal(err)
	}
	relay, err := outbox.New(db, kc, enc, 100, 500*time.Millisecond, log)
	if err != nil {
		t.Fatal(err)
	}
	runCtx, stop := context.WithCancel(ctx)
	consumeDone := make(chan error, 1)
	relayDone := make(chan error, 1)
	go func() {
		consumeDone <- kc.Consume(runCtx, func(ctx context.Context, rec events.Record) error {
			_, err := proc.Handle(ctx, rec)
			return err
		}, Backoff{Initial: 100 * time.Millisecond, Max: time.Second}, relay.Notify)
	}()
	go func() { relayDone <- relay.Run(runCtx) }()

	// --- Leer las salidas: alertas y DLQ ---
	reader, err := kgo.NewClient(kgo.SeedBrokers(strings.Split(brokers, ",")...),
		kgo.ConsumeTopics(events.TopicFareAlerts, events.TopicPriceObservedDLQ),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	// La alerta que esperamos. El price-consumer del docker compose comparte
	// la base de datos y el topic, así que puede publicar OTRA alerta para el
	// mismo usuario (con su propio historial): no cuenta como error, se
	// espera a la nuestra y se guarda la última distinta solo para el mensaje.
	expected := func(a *flightsv1.FareAlertTriggered) bool {
		return a.GetAlertType() == flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE &&
			a.GetCurrentPrice().GetAmountMinor() == 15000 && a.GetReferencePrice().GetAmountMinor() == 50000 &&
			a.GetDropBasisPoints() == 7000 && a.GetRoute().GetOriginIata() == "ZZA"
	}
	var alert, other *flightsv1.FareAlertTriggered
	dlqSeen := false
	for (alert == nil || !dlqSeen) && ctx.Err() == nil {
		fetches := reader.PollFetches(ctx)
		fetches.EachRecord(func(r *kgo.Record) {
			switch {
			case r.Topic == events.TopicFareAlerts && string(r.Key) == user:
				var evt flightsv1.FareAlertTriggered
				if err := proto.Unmarshal(r.Value, &evt); err != nil {
					t.Errorf("alerta ilegible: %v", err)
					return
				}
				if expected(&evt) {
					alert = &evt
				} else {
					other = &evt
				}
			case r.Topic == events.TopicPriceObservedDLQ && string(r.Key) == poisonKey:
				dlqSeen = true
			}
		})
	}
	stop()
	if err := <-consumeDone; err != nil {
		t.Errorf("Consume terminó con error: %v", err)
	}
	<-relayDone

	if alert == nil {
		t.Fatalf("no llegó la alerta esperada a flights.fare-alerts.v1 (otra: %v)", other)
	}
	if !dlqSeen {
		t.Error("el mensaje basura no llegó a la DLQ")
	}
}
