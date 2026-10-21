// Tests del ingestor. Sustituyen al proveedor y a Kafka por "dobles" que
// podemos controlar: hacer que tarden, que fallen o que devuelvan basura.

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

// staticWatches es una lista fija de seguimientos que hace de watchlist.
type staticWatches []domain.Watch

func (s staticWatches) List() []domain.Watch { return s }

// fakeProvider simula un proveedor de precios. Además cuenta cuántas consultas
// hay en curso a la vez (inFlight) y el máximo alcanzado (maxInFlight), para
// verificar que el límite de concurrencia se cumple.
type fakeProvider struct {
	delay    time.Duration
	failFor  map[string]error
	badPrice bool

	inFlight, maxInFlight atomic.Int64
}

func (p *fakeProvider) Name() string { return "fake" }

// Quote registra la consulta en curso, espera delay (respetando la cancelación),
// y devuelve un error o un precio según cómo se haya configurado el doble.
// El bucle con CompareAndSwap actualiza el máximo de forma segura entre goroutines.
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

// fakePublisher guarda en memoria los mensajes "publicados" o devuelve err
// para simular que Kafka está caído.
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

// makeWatches crea n seguimientos distintos (cambia la fecha y, a partir del
// 28, la cabina) para no repetir claves.
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

// newIngestor construye un Ingestor de pruebas con logs descartados (io.Discard)
// para que la salida de los tests quede limpia.
func newIngestor(t *testing.T, cfg Config, w WatchLister, p *fakeProvider, pub Publisher) *Ingestor {
	t.Helper()
	in, err := New(cfg, w, p, events.NewEncoder(events.TopicPriceObserved, "test"), pub, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return in
}

// defaultCfg: intervalo largo (no se usa en RunCycle), 1 s de timeout y 4 a la vez.
var defaultCfg = Config{Interval: time.Hour, QueryTimeout: time.Second, Concurrency: 4}

// --- Tests ---

// Caso feliz: 20 rutas → 20 mensajes publicados y servicio sano.
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

// Con límite 3 y consultas lentas, nunca debe haber más de 3 a la vez, pero sí
// más de 1 (si no, no estaríamos paralelizando).
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

// Si falla una ruta, las otras cuatro se publican igualmente.
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

// Un proveedor que tarda 1 s con timeout de 10 ms debe cortarse enseguida.
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

// Precios negativos del proveedor se descartan: no se publica basura.
func TestInvalidQuotesAreDropped(t *testing.T) {
	pub := &fakePublisher{}
	in := newIngestor(t, defaultCfg, makeWatches(t, 3), &fakeProvider{badPrice: true}, pub)

	stats := in.RunCycle(context.Background())
	if stats.EncodeErrors != 3 || len(pub.msgs) != 0 {
		t.Fatalf("stats = %+v, publicados = %d", stats, len(pub.msgs))
	}
}

// Si Kafka no acepta los mensajes, /readyz debe pasar a "no listo".
func TestPublishFailureMarksUnhealthy(t *testing.T) {
	in := newIngestor(t, defaultCfg, makeWatches(t, 3), &fakeProvider{}, &fakePublisher{err: errors.New("broker caído")})

	stats := in.RunCycle(context.Background())
	if stats.PublishErrors != 3 || in.Healthy() {
		t.Fatalf("stats = %+v, healthy = %v", stats, in.Healthy())
	}
}

// Run repite ciclos hasta que se cancela el contexto (lo que pasa al recibir
// SIGTERM); entonces debe terminar rápido y sin error.
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

// Una configuración vacía (intervalo 0, concurrencia 0...) se rechaza al crear.
func TestNewValidatesConfig(t *testing.T) {
	_, err := New(Config{}, staticWatches{}, &fakeProvider{}, events.NewEncoder("t", "p"), &fakePublisher{}, slog.Default())
	if err == nil {
		t.Fatal("una configuración vacía debería rechazarse")
	}
}
