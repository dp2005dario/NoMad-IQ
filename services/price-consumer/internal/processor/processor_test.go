package processor

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sort"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/detector"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
)

// fakeStore imita la base de datos en memoria. Las transacciones se simulan
// trabajando sobre una copia y aplicándola solo si fn termina sin error.
type fakeStore struct {
	observations map[string]storedObs
	subs         []domain.Subscription
	alerts       map[string]domain.Alert
	failNext     error // si no es nil, la próxima transacción falla con él
}

type storedObs struct {
	obs domain.Observation
}

func newFakeStore() *fakeStore {
	return &fakeStore{observations: map[string]storedObs{}, alerts: map[string]domain.Alert{}}
}

type fakeTx struct {
	s            *fakeStore
	observations map[string]storedObs
	alerts       map[string]domain.Alert
}

func (s *fakeStore) InTx(_ context.Context, fn func(Tx) error) error {
	if err := s.failNext; err != nil {
		s.failNext = nil
		return err
	}
	tx := &fakeTx{s: s, observations: map[string]storedObs{}, alerts: map[string]domain.Alert{}}
	for k, v := range s.observations {
		tx.observations[k] = v
	}
	for k, v := range s.alerts {
		tx.alerts[k] = v
	}
	if err := fn(tx); err != nil {
		return err // rollback: no se copia nada
	}
	s.observations, s.alerts = tx.observations, tx.alerts // commit
	return nil
}

func (t *fakeTx) InsertObservation(_ context.Context, obs domain.Observation, _ int32, _ int64) (bool, error) {
	if _, ok := t.observations[obs.EventID]; ok {
		return false, nil
	}
	t.observations[obs.EventID] = storedObs{obs: obs}
	return true, nil
}

func (t *fakeTx) RecentPrices(_ context.Context, routeKey, currency string, since, before time.Time, limit int) ([]int64, error) {
	var all []domain.Observation
	for _, o := range t.observations {
		if o.obs.RouteKey() == routeKey && o.obs.Price.Currency == currency &&
			!o.obs.ObservedAt.Before(since) && o.obs.ObservedAt.Before(before) {
			all = append(all, o.obs)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ObservedAt.After(all[j].ObservedAt) })
	var out []int64
	for i := 0; i < len(all) && i < limit; i++ {
		out = append(out, all[i].Price.AmountMinor)
	}
	return out, nil
}

func (t *fakeTx) Subscriptions(_ context.Context, routeKey string) ([]domain.Subscription, error) {
	var out []domain.Subscription
	for _, s := range t.s.subs {
		if s.RouteKey == routeKey {
			out = append(out, s)
		}
	}
	return out, nil
}

func (t *fakeTx) RecentlyAlerted(_ context.Context, routeKey, currency string, since time.Time) (map[string]int64, error) {
	out := map[string]int64{}
	for _, a := range t.alerts {
		if a.RouteKey == routeKey && a.Current.Currency == currency && !a.ObservedAt.Before(since) {
			if v, ok := out[a.UserID]; !ok || a.Current.AmountMinor < v {
				out[a.UserID] = a.Current.AmountMinor
			}
		}
	}
	return out, nil
}

func (t *fakeTx) InsertAlerts(_ context.Context, alerts []domain.Alert) error {
	for _, a := range alerts {
		t.alerts[a.ID] = a
	}
	return nil
}

type fakePublisher struct {
	msgs []events.Message
	err  error
}

func (p *fakePublisher) Publish(_ context.Context, msgs ...events.Message) error {
	if p.err != nil {
		return p.err
	}
	p.msgs = append(p.msgs, msgs...)
	return nil
}

var cfg = Config{
	Rules:         detector.Rules{MinSamples: 5, DropBasisPoints: 2000, ErrorFareBasisPoints: 5000},
	HistoryWindow: 30 * 24 * time.Hour,
	HistoryLimit:  100,
	AlertCooldown: 24 * time.Hour,
}

var t0 = time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)

// priceRecord fabrica un mensaje de Kafka como los del flight-ingestor.
func priceRecord(t *testing.T, n int, amount int64, at time.Time) events.Record {
	t.Helper()
	evt := &flightsv1.FlightPriceObserved{
		Metadata:      &commonv1.EventMetadata{EventId: eventID(n)},
		Route:         &flightsv1.Route{OriginIata: "MAD", DestinationIata: "NRT"},
		DepartureDate: &commonv1.Date{Year: 2026, Month: 12, Day: 1},
		Cabin:         flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		Price:         &commonv1.Money{CurrencyCode: "EUR", AmountMinor: amount},
		Provider:      "simulated",
		ObservedAt:    timestamppb.New(at),
	}
	value, err := proto.Marshal(evt)
	if err != nil {
		t.Fatal(err)
	}
	return events.Record{Topic: events.TopicPriceObserved, Partition: 0, Offset: int64(n), Value: value}
}

func eventID(n int) string {
	const base = "0192f0a0-0000-7000-8000-000000000000"
	s := []byte(base)
	for i := len(s) - 1; n > 0; i-- {
		s[i] = "0123456789"[n%10]
		n /= 10
	}
	return string(s)
}

func newProcessor(t *testing.T, store *fakeStore, pub *fakePublisher) *Processor {
	t.Helper()
	p, err := New(cfg, store, pub, events.NewEncoder(events.TopicFareAlerts, events.TopicPriceObservedDLQ, "test"),
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// seedHistory procesa 5 precios normales (~500 €) para tener referencia.
func seedHistory(t *testing.T, p *Processor) {
	t.Helper()
	for i, amount := range []int64{48000, 52000, 50000, 49000, 51000} {
		if _, err := p.Handle(context.Background(), priceRecord(t, i+1, amount, t0.Add(time.Duration(i)*time.Hour))); err != nil {
			t.Fatal(err)
		}
	}
}

func TestErrorFareCreatesAlertForEachSubscriber(t *testing.T) {
	store := newFakeStore()
	store.subs = []domain.Subscription{
		{UserID: "ana", RouteKey: "MAD-NRT:2026-12-01:ECONOMY"},
		{UserID: "luis", RouteKey: "MAD-NRT:2026-12-01:ECONOMY"},
		{UserID: "eva", RouteKey: "BCN-JFK:2026-12-10:BUSINESS"}, // otra ruta: no debe recibir nada
	}
	p := newProcessor(t, store, &fakePublisher{})
	seedHistory(t, p)

	res, err := p.Handle(context.Background(), priceRecord(t, 100, 15000, t0.Add(10*time.Hour)))
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeStored || res.Alerts != 2 || res.Market.Signal != domain.AlertErrorFare {
		t.Fatalf("resultado inesperado: %+v", res)
	}
	if len(store.alerts) != 2 {
		t.Fatalf("esperaba 2 alertas guardadas, hay %d", len(store.alerts))
	}
}

func TestDuplicateMessageIsIgnored(t *testing.T) {
	store := newFakeStore()
	store.subs = []domain.Subscription{{UserID: "ana", RouteKey: "MAD-NRT:2026-12-01:ECONOMY"}}
	p := newProcessor(t, store, &fakePublisher{})
	seedHistory(t, p)

	rec := priceRecord(t, 100, 15000, t0.Add(10*time.Hour))
	if _, err := p.Handle(context.Background(), rec); err != nil {
		t.Fatal(err)
	}
	// Kafka entrega "al menos una vez": el mismo mensaje puede llegar dos veces.
	res, err := p.Handle(context.Background(), rec)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != OutcomeDuplicate || res.Alerts != 0 {
		t.Fatalf("el duplicado no debe generar nada: %+v", res)
	}
	if len(store.observations) != 6 || len(store.alerts) != 1 {
		t.Fatalf("estado alterado por el duplicado: %d obs, %d alertas", len(store.observations), len(store.alerts))
	}
}

func TestCooldownAvoidsSpam(t *testing.T) {
	store := newFakeStore()
	store.subs = []domain.Subscription{{UserID: "ana", RouteKey: "MAD-NRT:2026-12-01:ECONOMY"}}
	p := newProcessor(t, store, &fakePublisher{})
	seedHistory(t, p)

	ctx := context.Background()
	first, _ := p.Handle(ctx, priceRecord(t, 100, 15000, t0.Add(10*time.Hour)))
	same, _ := p.Handle(ctx, priceRecord(t, 101, 15000, t0.Add(11*time.Hour)))
	better, _ := p.Handle(ctx, priceRecord(t, 102, 14000, t0.Add(12*time.Hour)))
	later, _ := p.Handle(ctx, priceRecord(t, 103, 15000, t0.Add(40*time.Hour))) // pasó el periodo anti-spam
	got := []int{first.Alerts, same.Alerts, better.Alerts, later.Alerts}
	want := []int{1, 0, 1, 1}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("alertas por mensaje = %v, quería %v", got, want)
		}
	}
}

func TestInvalidMessageGoesToDLQ(t *testing.T) {
	store := newFakeStore()
	pub := &fakePublisher{}
	p := newProcessor(t, store, pub)

	rec := events.Record{Topic: events.TopicPriceObserved, Offset: 9, Value: []byte("esto no es protobuf")}
	res, err := p.Handle(context.Background(), rec)
	if err != nil {
		t.Fatalf("un mensaje inválido no es un error temporal: %v", err)
	}
	if res.Outcome != OutcomeRejected || len(pub.msgs) != 1 || pub.msgs[0].Topic != events.TopicPriceObservedDLQ {
		t.Fatalf("debía ir a la DLQ: %+v / %+v", res, pub.msgs)
	}
	if len(store.observations) != 0 {
		t.Fatal("un mensaje inválido no debe guardarse")
	}
}

func TestDLQDownIsRetried(t *testing.T) {
	p := newProcessor(t, newFakeStore(), &fakePublisher{err: errors.New("kafka caído")})
	_, err := p.Handle(context.Background(), events.Record{Value: []byte("basura")})
	if err == nil {
		t.Fatal("si la DLQ falla, hay que devolver error para reintentar (nunca descartar)")
	}
}

func TestDatabaseErrorIsTemporary(t *testing.T) {
	store := newFakeStore()
	store.failNext = errors.New("conexión rechazada")
	pub := &fakePublisher{}
	p := newProcessor(t, store, pub)

	rec := priceRecord(t, 1, 50000, t0)
	if _, err := p.Handle(context.Background(), rec); err == nil {
		t.Fatal("un fallo de base de datos debe devolver error para reintentar")
	}
	if len(pub.msgs) != 0 {
		t.Fatal("un fallo temporal NO debe mandar el mensaje a la DLQ")
	}
	// Al reintentar (la base de datos ya responde) se procesa con normalidad.
	if res, err := p.Handle(context.Background(), rec); err != nil || res.Outcome != OutcomeStored {
		t.Fatalf("el reintento debía funcionar: %+v, %v", res, err)
	}
}

func TestDataRejectedByDatabaseGoesToDLQ(t *testing.T) {
	store := newFakeStore()
	store.failNext = &domain.ValidationError{Field: "database", Reason: "viola una restricción"}
	pub := &fakePublisher{}
	p := newProcessor(t, store, pub)
	res, err := p.Handle(context.Background(), priceRecord(t, 1, 50000, t0))
	if err != nil || res.Outcome != OutcomeRejected || len(pub.msgs) != 1 {
		t.Fatalf("datos rechazados por la BD deben ir a la DLQ: %+v, %v", res, err)
	}
}

func TestConfigValidate(t *testing.T) {
	bad := cfg
	bad.HistoryLimit = 2
	if err := bad.Validate(); err == nil {
		t.Error("HistoryLimit < MinSamples debe fallar")
	}
	bad = cfg
	bad.HistoryWindow = 0
	if err := bad.Validate(); err == nil {
		t.Error("HistoryWindow = 0 debe fallar")
	}
}
