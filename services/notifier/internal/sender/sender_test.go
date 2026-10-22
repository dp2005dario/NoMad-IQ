package sender

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/fcm"
)

type fakeQueue struct {
	mu        sync.Mutex
	pending   []Push
	deleted   []int64
	retried   map[int64]time.Time
	forgotten []string
}

func (q *fakeQueue) Claim(_ context.Context, limit int, _ time.Duration) ([]Push, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	n := min(limit, len(q.pending))
	out := q.pending[:n]
	q.pending = q.pending[n:]
	return out, nil
}

func (q *fakeQueue) Delete(_ context.Context, id int64) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.deleted = append(q.deleted, id)
	return nil
}

func (q *fakeQueue) Retry(_ context.Context, id int64, at time.Time, _ string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.retried[id] = at
	return nil
}

func (q *fakeQueue) ForgetDevice(_ context.Context, id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.forgotten = append(q.forgotten, id)
	return nil
}

type fakeTransport struct {
	mu    sync.Mutex
	sent  []fcm.Message
	reply func(m fcm.Message) error
}

func (f *fakeTransport) Send(_ context.Context, m fcm.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, m)
	if f.reply != nil {
		return f.reply(m)
	}
	return nil
}

type plainTokens struct{}

func (plainTokens) DecryptToken(_ string, sealed []byte) (string, error) {
	if string(sealed) == "dañado" {
		return "", errors.New("no se puede descifrar")
	}
	return string(sealed), nil
}

var t0 = time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)

func newSender(t *testing.T, q Queue, tr Transport) *Sender {
	t.Helper()
	s, err := New(Config{RatePerSecond: 1000, Burst: 10, Workers: 2, Batch: 10, Lease: time.Minute, MaxAttempts: 3, PollInterval: 10 * time.Millisecond},
		q, tr, plainTokens{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return t0 }
	return s
}

func push(id int64, token string, attempts int) Push {
	return Push{ID: id, DeviceID: "dev", Envelope: []byte{1, 2, 3}, Attempts: attempts, ExpiresAt: t0.Add(10 * time.Minute), TokenCiphertext: []byte(token)}
}

func TestEachOutcomeUpdatesTheQueue(t *testing.T) {
	q := &fakeQueue{retried: map[int64]time.Time{}}
	tr := &fakeTransport{reply: func(m fcm.Message) error {
		switch m.Token {
		case "gone":
			return &fcm.Error{Kind: fcm.KindUnregistered, Status: 404}
		case "bad":
			return &fcm.Error{Kind: fcm.KindInvalid, Status: 400}
		case "flaky":
			return &fcm.Error{Kind: fcm.KindRetry, Status: 503}
		case "tired":
			return &fcm.Error{Kind: fcm.KindRetry, Status: 503}
		}
		return nil
	}}
	s := newSender(t, q, tr)
	ctx := context.Background()
	s.deliver(ctx, push(1, "ok", 1))
	s.deliver(ctx, push(2, "gone", 1))
	s.deliver(ctx, push(3, "bad", 1))
	s.deliver(ctx, push(4, "flaky", 2))
	s.deliver(ctx, push(5, "tired", 3)) // último intento permitido
	s.deliver(ctx, push(6, "dañado", 1))
	late := push(7, "ok", 1)
	late.ExpiresAt = t0
	s.deliver(ctx, late)

	if len(q.deleted) != 4 { // ok, bad, tired (abandonado), late (caducado)
		t.Errorf("borrados = %v", q.deleted)
	}
	if len(q.forgotten) != 2 { // gone y el token ilegible
		t.Errorf("olvidados = %v", q.forgotten)
	}
	if at, ok := q.retried[4]; !ok || at != t0.Add(4*time.Second) {
		t.Errorf("el segundo intento espera 2 s × 2 = 4 s: %v", q.retried)
	}
	st := s.Stats()
	if st.Sent != 1 || st.GaveUp != 1 || st.Expired != 1 || st.Invalid != 1 || st.Forgotten != 2 || st.Retried != 1 {
		t.Errorf("contadores = %+v", st)
	}
	if m := tr.sent[0]; m.Data["v"] != "1" || m.Data["p"] != "AQID" || m.TTL != 10*time.Minute || m.CollapseKey != CollapseKey {
		t.Errorf("mensaje a FCM inesperado: %+v", m)
	}
}

func TestQuotaErrorsPauseEveryWorker(t *testing.T) {
	q := &fakeQueue{retried: map[int64]time.Time{}}
	tr := &fakeTransport{reply: func(fcm.Message) error {
		return &fcm.Error{Kind: fcm.KindQuota, Status: 429, RetryAfter: 45 * time.Second}
	}}
	s := newSender(t, q, tr)
	s.deliver(context.Background(), push(1, "x", 1))
	if got := time.Unix(0, s.pauseUntil.Load()); !got.Equal(t0.Add(45 * time.Second)) {
		t.Fatalf("frenazo hasta %s", got)
	}
	if at := q.retried[1]; !at.Equal(t0.Add(45 * time.Second)) {
		t.Fatalf("el reintento respeta Retry-After: %s", at)
	}
	// Un frenazo más corto no acorta el que ya hay.
	s.pause(time.Second)
	if got := time.Unix(0, s.pauseUntil.Load()); !got.Equal(t0.Add(45 * time.Second)) {
		t.Fatal("un frenazo menor no puede acortar el actual")
	}
}

func TestRetriesThatWouldArriveLateAreDropped(t *testing.T) {
	q := &fakeQueue{retried: map[int64]time.Time{}}
	tr := &fakeTransport{reply: func(fcm.Message) error { return &fcm.Error{Kind: fcm.KindRetry, RetryAfter: time.Hour} }}
	s := newSender(t, q, tr)
	s.deliver(context.Background(), push(1, "x", 1))
	if len(q.retried) != 0 || len(q.deleted) != 1 || s.Stats().Expired != 1 {
		t.Fatal("si el reintento llegaría después de caducar, se tira")
	}
}

func TestRunDrainsTheQueueAndStops(t *testing.T) {
	q := &fakeQueue{retried: map[int64]time.Time{}}
	for i := range 25 {
		q.pending = append(q.pending, push(int64(i+1), "ok", 1))
	}
	tr := &fakeTransport{}
	s := newSender(t, q, tr)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	deadline := time.Now().Add(5 * time.Second)
	for s.Stats().Sent < 25 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if s.Stats().Sent != 25 {
		t.Fatalf("enviados %d de 25", s.Stats().Sent)
	}
}

func TestTheTokenBucketLimitsTheRate(t *testing.T) {
	q := &fakeQueue{retried: map[int64]time.Time{}}
	tr := &fakeTransport{}
	s, err := New(Config{RatePerSecond: 20, Burst: 1, Workers: 8, Batch: 10, Lease: time.Minute, MaxAttempts: 3, PollInterval: time.Second},
		q, tr, plainTokens{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	var wg sync.WaitGroup
	for i := range 6 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p := push(int64(i), "ok", 1)
			p.ExpiresAt = time.Now().Add(time.Minute)
			s.deliver(context.Background(), p)
		}()
	}
	wg.Wait()
	// 6 envíos a 20/s con cubo de 1: al menos 5 esperas de 50 ms.
	if elapsed := time.Since(start); elapsed < 240*time.Millisecond {
		t.Fatalf("8 obreros no pueden saltarse el limitador: %s", elapsed)
	}
}
