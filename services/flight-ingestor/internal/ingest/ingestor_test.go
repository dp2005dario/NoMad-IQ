package ingest

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/events"
)

// --- Dobles de prueba: sustituyen a proveedor y Kafka sin red ---

type staticWatches []domain.Watch

func (s staticWatches) List() []domain.Watch { return s }

type fakeProvider struct {
	delay    time.Duration
	failFor  map[string]error
	badPrice bool

	inFlight, maxInFlight atomic.Int64
}

func (p *fakeProvider) Name() string { return "fake" }

func (p *fakeProvider) Quote(ctx context.Context, spec domain.WatchSpec) ([]domain.Quote, error) {
	n := p.inFlight.Add(1)
	defer p.inFlight.Add(-1)
	for {
		cur := p.maxInFlight.Load()
		if n <= cur || p.maxInFlight.CompareAndSwap(cur, n) {
			break
		}
	}
	if p.delay > 0 {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(p.delay):
		}
	}
	if err := p.failFor[spec.Key()]; err != nil {
		return nil, err
	}
	amount := int64(10000)
	if p.badPrice {
		amount = -1
	}
	return []domain.Quote{{Price: domain.Money{Currency: "EUR", AmountMinor: amount}, ObservedAt: time.Now()}}, nil
}

type fakePublisher struct {
	mu   sync.Mutex
	msgs []events.Message
	err  error
}

func (p *fakePublisher) Publish(_ context.Context, msgs ...events.Message) error {
	if p.err != nil {
		return p.err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.msgs = append(p.msgs, msgs...)
	return nil
}

func makeWatches(t *testing.T, n int) staticWatches {
	t.Helper()
	out := make(staticWatches, 0, n)
	for i := 0; i < n; i++ {
		spec, err := domain.ParseWatchKey(fmt.Sprintf("MAD-NRT:2027-01-%02d:ECONOMY", i%28+1))
		if err != nil {
			t.Fatal(err)
		}
		if i >= 28 {
			spec.Cabin = domain.CabinBusiness
		}
		out = append(out, domain.Watch{ID: fmt.Sprintf("w%d", i), Spec: spec})
	}
	return out
}

func newIngestor(t *testing.T, cfg Config, w WatchLister, p *fakeProvider, pub Publisher) *Ingestor {
	t.Helper()
	in, err := New(cfg, w, p, events.NewEncoder(events.TopicPriceObserved, "test"), pub, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return in
}

var defaultCfg = Config{Interval: time.Hour, QueryTimeout: time.Second, Concurrency: 4}

// --- Tests ---

func TestRunCyclePublishesEveryWatch(t *testing.T) {
	pub := &fakePublisher{}
	in := newIngestor(t, defaultCfg, makeWatches(t, 20), &fakeProvider{}, pub)

	stats := in.RunCycle(context.Background())
	if stats.Watches != 20 || stats.Published != 20 || len(pub.msgs) != 20 {
		t.Fatalf("stats = %+v, publicados = %d", stats, len(pub.msgs))
	}
	if !in.Healthy() {
		t.Fatal("el ingestor debería estar sano")
	}
}

func TestConcurrencyLimitIsRespected(t *testing.T) {
	p := &fakeProvider{delay: 20 * time.Millisecond}
	cfg := defaultCfg
	cfg.Concurrency = 3
	in := newIngestor(t, cfg, makeWatches(t, 30), p, &fakePublisher{})

	in.RunCycle(context.Background())
	if got := p.maxInFlight.Load(); got > 3 {
		t.Fatalf("hubo %d consultas simultáneas, el límite era 3", got)
	}
	if got := p.maxInFlight.Load(); got < 2 {
		t.Fatalf("solo %d consulta simultánea: no se está paralelizando", got)
	}
}

func TestProviderFailureDoesNotStopOthers(t *testing.T) {
	watches := makeWatches(t, 5)
	p := &fakeProvider{failFor: map[string]error{watches[2].Spec.Key(): errors.New("API caída")}}
	pub := &fakePublisher{}
	in := newIngestor(t, defaultCfg, watches, p, pub)

	stats := in.RunCycle(context.Background())
	if stats.ProviderErrors != 1 || stats.Published != 4 {
		t.Fatalf("stats = %+v", stats)
	}
	if !in.Healthy() {
		t.Fatal("un fallo del proveedor no debe marcar el servicio como no sano")
	}
}

func TestQueryTimeout(t *testing.T) {
	cfg := defaultCfg
	cfg.QueryTimeout = 10 * time.Millisecond
	in := newIngestor(t, cfg, makeWatches(t, 2), &fakeProvider{delay: time.Second}, &fakePublisher{})

	start := time.Now()
	stats := in.RunCycle(context.Background())
	if stats.ProviderErrors != 2 {
		t.Fatalf("stats = %+v", stats)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("el timeout por consulta no se aplicó")
	}
}

func TestInvalidQuotesAreDropped(t *testing.T) {
	pub := &fakePublisher{}
	in := newIngestor(t, defaultCfg, makeWatches(t, 3), &fakeProvider{badPrice: true}, pub)

	stats := in.RunCycle(context.Background())
	if stats.EncodeErrors != 3 || len(pub.msgs) != 0 {
		t.Fatalf("stats = %+v, publicados = %d", stats, len(pub.msgs))
	}
}

func TestPublishFailureMarksUnhealthy(t *testing.T) {
	in := newIngestor(t, defaultCfg, makeWatches(t, 3), &fakeProvider{}, &fakePublisher{err: errors.New("broker caído")})

	stats := in.RunCycle(context.Background())
	if stats.PublishErrors != 3 || in.Healthy() {
		t.Fatalf("stats = %+v, healthy = %v", stats, in.Healthy())
	}
}

func TestRunStopsOnCancel(t *testing.T) {
	cfg := defaultCfg
	cfg.Interval = 5 * time.Millisecond
	pub := &fakePublisher{}
	in := newIngestor(t, cfg, makeWatches(t, 1), &fakeProvider{}, pub)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- in.Run(ctx) }()

	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run devolvió %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Run no terminó tras cancelar el contexto")
	}
	pub.mu.Lock()
	defer pub.mu.Unlock()
	if len(pub.msgs) < 2 {
		t.Fatalf("se esperaban varios ciclos, publicados = %d", len(pub.msgs))
	}
}

func TestNewValidatesConfig(t *testing.T) {
	_, err := New(Config{}, staticWatches{}, &fakeProvider{}, events.NewEncoder("t", "p"), &fakePublisher{}, slog.Default())
	if err == nil {
		t.Fatal("una configuración vacía debería rechazarse")
	}
}
