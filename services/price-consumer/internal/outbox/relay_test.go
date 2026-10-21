package outbox

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
)

// fakeStore guarda alertas pendientes en memoria y solo las marca como
// publicadas si la función publish termina bien (igual que la real).
type fakeStore struct {
	pending []domain.PendingAlert
}

func (s *fakeStore) ClaimPending(_ context.Context, limit int, publish func([]domain.PendingAlert) error) (int, error) {
	n := min(limit, len(s.pending))
	if n == 0 {
		return 0, nil
	}
	if err := publish(s.pending[:n]); err != nil {
		return 0, err
	}
	s.pending = s.pending[n:]
	return n, nil
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

func pending(n int) []domain.PendingAlert {
	out := make([]domain.PendingAlert, n)
	for i := range out {
		out[i] = domain.PendingAlert{Alert: domain.Alert{
			ID: "a" + string(rune('0'+i)), UserID: "ana", Type: domain.AlertPriceDrop,
			Reference: domain.Money{Currency: "EUR", AmountMinor: 100},
			Current:   domain.Money{Currency: "EUR", AmountMinor: 50},
		}, Cabin: domain.CabinEconomy}
	}
	return out
}

func newRelay(t *testing.T, s Store, p Publisher) *Relay {
	t.Helper()
	r, err := New(s, p, events.NewEncoder(events.TopicFareAlerts, events.TopicPriceObservedDLQ, "test"),
		2, time.Hour, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestFlushPublishesEverythingInBatches(t *testing.T) {
	store := &fakeStore{pending: pending(5)}
	pub := &fakePublisher{}
	n, err := newRelay(t, store, pub).Flush(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 5 || len(pub.msgs) != 5 || len(store.pending) != 0 {
		t.Fatalf("publicadas %d, mensajes %d, pendientes %d", n, len(pub.msgs), len(store.pending))
	}
}

func TestFlushKeepsAlertsWhenKafkaFails(t *testing.T) {
	store := &fakeStore{pending: pending(3)}
	r := newRelay(t, store, &fakePublisher{err: errors.New("kafka caído")})
	if _, err := r.Flush(context.Background()); err == nil {
		t.Fatal("esperaba error")
	}
	if len(store.pending) != 3 {
		t.Fatal("si Kafka falla, las alertas deben seguir pendientes")
	}
}

func TestRunPublishesOnNotifyAndStops(t *testing.T) {
	store := &fakeStore{pending: pending(1)}
	pub := &fakePublisher{}
	r := newRelay(t, store, pub)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error)
	go func() { done <- r.Run(ctx) }()

	r.Notify()
	r.Notify() // varios avisos seguidos no bloquean
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	// Tanto si lo publicó el aviso como la pasada final, debe estar enviado.
	if len(store.pending) != 0 || len(pub.msgs) != 1 || !r.Healthy() {
		t.Fatalf("pendientes %d, mensajes %d", len(store.pending), len(pub.msgs))
	}
}
