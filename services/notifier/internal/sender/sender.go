// Package sender vacía la cola de avisos hacia Google (FCM) sin pasarse nunca
// del ritmo permitido.
//
// Piezas:
//
//   - Un "despachador" coge lotes de la cola con FOR UPDATE SKIP LOCKED y un
//     préstamo (lease): si arrancas 3 copias del notifier, cada una coge
//     filas distintas, y si una muere a mitad, sus filas vuelven a la cola
//     al caducar el préstamo.
//   - Un grupo de "obreros" (worker pool, goroutines) que envían en paralelo.
//   - Un limitador de tipo "cubo de fichas" (token bucket): el cubo se
//     rellena a SEND_RATE_PER_SECOND fichas por segundo y cada envío gasta
//     una. Si el cubo está vacío, el obrero espera. Analogía: la taquilla
//     de un concierto que deja pasar a 50 personas por segundo, por mucha
//     cola que haya. Así un pico (un concierto, 10.000 personas entrando a
//     la vez en la Sagrada Familia) se convierte en una cola que baja a ritmo
//     constante, en lugar de en una ráfaga que agota la cuota de Google.
//   - Si Google responde 429 ("más despacio"), se FRENA A TODOS los obreros
//     durante el tiempo que indique (Retry-After), no solo al que lo recibió.
//
// Cada aviso tiene caducidad: si no se pudo entregar a tiempo, se tira.
package sender

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/fcm"
)

// CollapseKey: Google entrega solo el último aviso pendiente con esta clave
// si el teléfono estaba sin cobertura. Es igual para todos: no revela nada.
const CollapseKey = "nomadiq-zone"

// Push es un aviso prestado de la cola.
type Push struct {
	ID              int64
	DeviceID        string
	Envelope        []byte
	Attempts        int // ya incluye este intento
	ExpiresAt       time.Time
	TokenCiphertext []byte
}

// Queue es la cola de PostgreSQL (store.Postgres en producción).
type Queue interface {
	Claim(ctx context.Context, limit int, lease time.Duration) ([]Push, error)
	Delete(ctx context.Context, id int64) error
	Retry(ctx context.Context, id int64, at time.Time, reason string) error
	ForgetDevice(ctx context.Context, deviceID string) error
}

// Transport envía a FCM (fcm.Client en producción).
type Transport interface {
	Send(ctx context.Context, m fcm.Message) error
}

// TokenOpener descifra el token de FCM (sealbox.Vault en producción).
type TokenOpener interface {
	DecryptToken(deviceID string, sealed []byte) (string, error)
}

// Config del sender.
type Config struct {
	RatePerSecond float64
	Burst         int
	Workers       int
	Batch         int
	Lease         time.Duration
	MaxAttempts   int
	PollInterval  time.Duration
	// Espera del primer reintento (se duplica en cada uno, hasta MaxBackoff).
	InitialBackoff time.Duration
	MaxBackoff     time.Duration
}

// Stats son contadores para /readyz y los logs.
type Stats struct {
	Sent, Retried, Expired, GaveUp, Forgotten, Invalid int64
}

// Sender envía los avisos.
type Sender struct {
	cfg       Config
	queue     Queue
	transport Transport
	tokens    TokenOpener
	limiter   *rate.Limiter
	log       *slog.Logger
	now       func() time.Time

	wake       chan struct{}
	pauseUntil atomic.Int64 // UnixNano: nadie envía antes (frenazo por 429)
	healthy    atomic.Bool

	sent, retried, expired, gaveUp, forgotten, invalid atomic.Int64
}

// New crea el sender.
func New(cfg Config, queue Queue, transport Transport, tokens TokenOpener, log *slog.Logger) (*Sender, error) {
	if queue == nil || transport == nil || tokens == nil || log == nil {
		return nil, errors.New("sender: faltan dependencias")
	}
	if cfg.RatePerSecond <= 0 || cfg.Burst < 1 || cfg.Workers < 1 || cfg.Batch < 1 || cfg.Lease <= 0 || cfg.MaxAttempts < 1 || cfg.PollInterval <= 0 {
		return nil, errors.New("sender: configuración inválida")
	}
	if cfg.InitialBackoff <= 0 {
		cfg.InitialBackoff = 2 * time.Second
	}
	if cfg.MaxBackoff < cfg.InitialBackoff {
		cfg.MaxBackoff = 5 * time.Minute
	}
	s := &Sender{
		cfg: cfg, queue: queue, transport: transport, tokens: tokens, log: log, now: time.Now,
		limiter: rate.NewLimiter(rate.Limit(cfg.RatePerSecond), cfg.Burst),
		wake:    make(chan struct{}, 1),
	}
	s.healthy.Store(true)
	return s, nil
}

// Wake avisa de que hay trabajo nuevo (no bloquea nunca).
func (s *Sender) Wake() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// Healthy es false mientras la cola (PostgreSQL) está fallando.
func (s *Sender) Healthy() bool { return s.healthy.Load() }

// Stats devuelve los contadores.
func (s *Sender) Stats() Stats {
	return Stats{
		Sent: s.sent.Load(), Retried: s.retried.Load(), Expired: s.expired.Load(),
		GaveUp: s.gaveUp.Load(), Forgotten: s.forgotten.Load(), Invalid: s.invalid.Load(),
	}
}

// Run trabaja hasta que ctx se cancela.
func (s *Sender) Run(ctx context.Context) error {
	jobs := make(chan Push)
	var wg sync.WaitGroup
	for range s.cfg.Workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for push := range jobs {
				s.deliver(ctx, push)
			}
		}()
	}
	defer func() {
		close(jobs)
		wg.Wait()
	}()

	ticker := time.NewTicker(s.cfg.PollInterval)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return nil
		}
		pushes, err := s.queue.Claim(ctx, s.cfg.Batch, s.cfg.Lease)
		s.healthy.Store(err == nil)
		if err != nil && ctx.Err() == nil {
			s.log.Warn("no se pudo leer la cola de avisos; se reintentará", slog.Any("error", err))
		}
		for _, p := range pushes {
			select {
			case jobs <- p:
			case <-ctx.Done():
				// Los que quedan sin enviar vuelven a la cola al caducar el préstamo.
				return nil
			}
		}
		if len(pushes) == s.cfg.Batch {
			continue // hay más trabajo: a por el siguiente lote sin esperar
		}
		select {
		case <-ctx.Done():
			return nil
		case <-s.wake:
		case <-ticker.C:
		}
	}
}

func (s *Sender) deliver(ctx context.Context, p Push) {
	// Contexto propio para las escrituras en la cola: si llega el apagado
	// justo después de enviar, el resultado se apunta igualmente.
	bg := context.WithoutCancel(ctx)
	if !s.now().Before(p.ExpiresAt) {
		s.expired.Add(1)
		s.must(bg, "borrar aviso caducado", s.queue.Delete(bg, p.ID))
		return
	}
	token, err := s.tokens.DecryptToken(p.DeviceID, p.TokenCiphertext)
	if err != nil {
		// Un token que no se puede descifrar no se arregla solo (clave
		// cambiada o fila dañada): se olvida el teléfono; la app lo
		// registrará de nuevo la próxima vez que se abra.
		s.forgotten.Add(1)
		s.log.Error("token ilegible: se olvida el teléfono", slog.Any("error", err))
		s.must(bg, "olvidar teléfono", s.queue.ForgetDevice(bg, p.DeviceID))
		return
	}
	if err := s.waitTurn(ctx); err != nil {
		return // apagado: el préstamo caducará y otra copia lo enviará
	}
	err = s.transport.Send(ctx, fcm.Message{
		Token:       token,
		Data:        map[string]string{"v": "1", "p": base64.RawURLEncoding.EncodeToString(p.Envelope)},
		TTL:         p.ExpiresAt.Sub(s.now()),
		CollapseKey: CollapseKey,
	})
	if err == nil {
		s.sent.Add(1)
		s.must(bg, "borrar aviso enviado", s.queue.Delete(bg, p.ID))
		return
	}
	var fe *fcm.Error
	if !errors.As(err, &fe) {
		fe = &fcm.Error{Kind: fcm.KindRetry}
	}
	switch fe.Kind {
	case fcm.KindUnregistered:
		// La app se desinstaló o el token cambió: olvidar el teléfono (y,
		// en cascada, sus avisos pendientes).
		s.forgotten.Add(1)
		s.must(bg, "olvidar teléfono", s.queue.ForgetDevice(bg, p.DeviceID))
	case fcm.KindInvalid:
		s.invalid.Add(1)
		s.log.Error("FCM rechazó el aviso como inválido; se descarta", slog.Int("status", fe.Status), slog.String("code", fe.Code))
		s.must(bg, "borrar aviso inválido", s.queue.Delete(bg, p.ID))
	default:
		if fe.Kind == fcm.KindQuota {
			s.pause(max(fe.RetryAfter, 30*time.Second))
		}
		if fe.Kind == fcm.KindAuth {
			s.log.Error("FCM rechaza nuestras credenciales: revisa FCM_CREDENTIALS_FILE", slog.Int("status", fe.Status))
		}
		s.retry(bg, p, fe)
	}
}

func (s *Sender) retry(ctx context.Context, p Push, fe *fcm.Error) {
	if p.Attempts >= s.cfg.MaxAttempts {
		s.gaveUp.Add(1)
		s.log.Warn("aviso abandonado tras varios intentos", slog.Int("attempts", p.Attempts), slog.String("kind", fe.Kind.String()))
		s.must(ctx, "borrar aviso abandonado", s.queue.Delete(ctx, p.ID))
		return
	}
	wait := s.cfg.InitialBackoff << (p.Attempts - 1)
	if wait <= 0 || wait > s.cfg.MaxBackoff {
		wait = s.cfg.MaxBackoff
	}
	wait = max(wait, fe.RetryAfter)
	at := s.now().Add(wait)
	if !at.Before(p.ExpiresAt) {
		// El próximo intento ya llegaría tarde: no tiene sentido guardarlo.
		s.expired.Add(1)
		s.must(ctx, "borrar aviso caducado", s.queue.Delete(ctx, p.ID))
		return
	}
	s.retried.Add(1)
	s.must(ctx, "reprogramar aviso", s.queue.Retry(ctx, p.ID, at, fe.Error()))
}

// pause frena a todos los obreros hasta dentro de d (si no había un frenazo
// mayor). Es un bucle de "comparar e intercambiar" (CAS): seguro entre
// goroutines sin necesidad de cerrojos.
func (s *Sender) pause(d time.Duration) {
	until := s.now().Add(d).UnixNano()
	for {
		cur := s.pauseUntil.Load()
		if cur >= until || s.pauseUntil.CompareAndSwap(cur, until) {
			return
		}
	}
}

// waitTurn espera al frenazo global (si lo hay) y a una ficha del cubo.
func (s *Sender) waitTurn(ctx context.Context) error {
	if until := time.Unix(0, s.pauseUntil.Load()); s.now().Before(until) {
		timer := time.NewTimer(until.Sub(s.now()))
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	if err := s.limiter.Wait(ctx); err != nil {
		return fmt.Errorf("sender: %w", err)
	}
	return nil
}

func (s *Sender) must(_ context.Context, what string, err error) {
	if err != nil {
		// La fila sigue prestada: al caducar el préstamo se volverá a
		// intentar. Como mucho, un aviso duplicado (y FCM con collapse_key
		// lo absorbe si aún no se entregó).
		s.log.Warn("no se pudo actualizar la cola", slog.String("op", what), slog.Any("error", err))
	}
}
