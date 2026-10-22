// Package intake convierte cada orden de Kafka en avisos cifrados en la cola.
//
// Es el "mostrador de entrada" del notifier. Por cada ZoneNotificationRequested:
//
//  1. Validarla (si está mal → DLQ, sin bloquear al resto).
//  2. ¿Llega tarde? Si la entrada fue hace más de NOTIFY_MAX_REQUEST_AGE,
//     se descarta: la persona puede estar ya en otro sitio.
//  3. ¿Qué aviso toca? (policy). Algunos tipos de zona no avisan.
//  4. ¿Tiene teléfonos registrados? Si no, se acaba aquí, SIN tocar Redis:
//     de quien no quiere avisos no se guarda ni un rastro.
//  5. Anti-spam (enfriamiento + no repetir zona), atómico en Redis.
//  6. Cifrar el aviso para cada teléfono y meterlo en la cola de PostgreSQL.
//     El envío real lo hace el sender, a su ritmo: este paso nunca espera a
//     Google, así que una avalancha de entradas no atasca Kafka.
//
// ¿Por qué una cola intermedia y no llamar a Google directamente desde aquí?
// Porque Kafka entrega en orden por partición: si un envío tuviera que
// esperar 30 s a que Google nos deje, todos los avisos detrás de él en esa
// partición esperarían también. Con la cola, entrar es rápido y salir va al
// ritmo que marque el limitador del sender.
package intake

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/antispam"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/policy"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

// Target es un teléfono al que se puede avisar.
type Target struct {
	DeviceID  string
	PublicKey []byte
}

// Delivery es un aviso cifrado listo para la cola.
type Delivery struct {
	DeviceID  string
	Envelope  []byte
	ExpiresAt time.Time
}

// Directory encuentra los teléfonos de un seudónimo.
type Directory interface {
	DevicesFor(ctx context.Context, recipient string) ([]Target, error)
}

// Outbox guarda los avisos en la cola (todos o ninguno).
type Outbox interface {
	Enqueue(ctx context.Context, deliveries []Delivery) error
}

// Gate es el control anti-spam (antispam.Gate en producción).
type Gate interface {
	Admit(ctx context.Context, recipient, zoneID string, urgent bool) (antispam.Verdict, error)
	Release(ctx context.Context, recipient, zoneID string) error
}

// Publisher publica en Kafka (aquí, solo la DLQ).
type Publisher interface {
	Publish(ctx context.Context, msgs ...events.Message) error
}

// Outcome dice qué pasó con una orden (para logs y tests).
type Outcome string

// Resultados posibles.
const (
	Queued       Outcome = "queued"
	DeadLettered Outcome = "dead_lettered"
	Stale        Outcome = "stale"
	NotNotified  Outcome = "kind_not_notified"
	NoDevices    Outcome = "no_devices"
	Repeated     Outcome = "repeated_zone"
	CoolingDown  Outcome = "cooling_down"
)

// Config del procesador.
type Config struct {
	DLQTopic      string
	MaxRequestAge time.Duration
	DeliveryTTL   time.Duration
}

// Processor procesa órdenes.
type Processor struct {
	cfg       Config
	directory Directory
	outbox    Outbox
	gate      Gate
	dlq       Publisher
	wake      func()
	now       func() time.Time
	log       *slog.Logger
}

// New crea el procesador. wake (opcional) avisa al sender de que hay trabajo.
func New(cfg Config, directory Directory, outbox Outbox, gate Gate, dlq Publisher, wake func(), log *slog.Logger) (*Processor, error) {
	if directory == nil || outbox == nil || gate == nil || dlq == nil || log == nil {
		return nil, errors.New("intake: faltan dependencias")
	}
	if cfg.DLQTopic == "" || cfg.MaxRequestAge <= 0 || cfg.DeliveryTTL <= 0 {
		return nil, errors.New("intake: configuración incompleta")
	}
	if wake == nil {
		wake = func() {}
	}
	return &Processor{cfg: cfg, directory: directory, outbox: outbox, gate: gate, dlq: dlq, wake: wake, now: time.Now, log: log}, nil
}

// payload es lo que la app recibe (cifrado). La app pone el texto en el
// idioma del usuario y, con zone_id, pide el nombre de la zona y su
// audioguía a la API (que ya exige identidad).
type payload struct {
	Version  int             `json:"v"`
	Type     policy.Template `json:"type"`
	ZoneID   string          `json:"zone_id"`
	ZoneKind string          `json:"zone_kind"`
	Language string          `json:"lang,omitempty"`
	At       string          `json:"at"`
}

// Handle procesa una orden. Devuelve error SOLO si es temporal (Redis o
// PostgreSQL caídos): el consumidor de Kafka la reintentará.
func (p *Processor) Handle(ctx context.Context, rec events.Record) (Outcome, error) {
	req, err := events.DecodeRequest(rec)
	if err != nil {
		if pubErr := p.dlq.Publish(ctx, events.EncodeDLQ(p.cfg.DLQTopic, rec, err)); pubErr != nil {
			return "", fmt.Errorf("intake: publicar en la DLQ: %w", pubErr)
		}
		p.log.Warn("orden inválida enviada a la DLQ", slog.Int("partition", int(rec.Partition)), slog.Int64("offset", rec.Offset), slog.Any("reason", err))
		return DeadLettered, nil
	}
	// occurred_at viene redondeado al minuto hacia abajo: se le da ese
	// minuto de margen para no descartar órdenes que en realidad son recientes.
	if p.now().Sub(req.OccurredAt) > p.cfg.MaxRequestAge+time.Minute {
		return Stale, nil
	}
	decision, ok := policy.ForZone(req.Kind)
	if !ok {
		return NotNotified, nil
	}
	targets, err := p.directory.DevicesFor(ctx, req.Recipient)
	if err != nil {
		return "", fmt.Errorf("intake: buscar teléfonos: %w", err)
	}
	if len(targets) == 0 {
		return NoDevices, nil
	}
	verdict, err := p.gate.Admit(ctx, req.Recipient, req.ZoneID, decision.Urgent)
	if err != nil {
		return "", fmt.Errorf("intake: %w", err)
	}
	switch verdict {
	case antispam.Repeat:
		return Repeated, nil
	case antispam.Cooldown:
		return CoolingDown, nil
	case antispam.Send:
	default:
		return "", fmt.Errorf("intake: veredicto anti-spam desconocido %d", verdict)
	}

	body, err := json.Marshal(payload{
		Version:  1,
		Type:     decision.Template,
		ZoneID:   req.ZoneID,
		ZoneKind: strings.TrimPrefix(req.Kind.String(), "ZONE_KIND_"),
		Language: req.Language,
		At:       req.OccurredAt.Format(time.RFC3339),
	})
	if err != nil {
		return "", p.release(ctx, req, fmt.Errorf("intake: %w", err))
	}
	expires := p.now().Add(p.cfg.DeliveryTTL)
	deliveries := make([]Delivery, 0, len(targets))
	for _, t := range targets {
		envelope, err := sealbox.SealForDevice(t.PublicKey, body, []byte(t.DeviceID))
		if err != nil {
			// La clave se comprobó al registrar el teléfono: si falla aquí,
			// la fila está dañada. Se salta ese teléfono, no el resto.
			p.log.Error("no se pudo cifrar para un teléfono; se omite", slog.Any("error", err))
			continue
		}
		deliveries = append(deliveries, Delivery{DeviceID: t.DeviceID, Envelope: envelope, ExpiresAt: expires})
	}
	if len(deliveries) == 0 {
		return NoDevices, nil
	}
	if err := p.outbox.Enqueue(ctx, deliveries); err != nil {
		return "", p.release(ctx, req, fmt.Errorf("intake: encolar: %w", err))
	}
	p.wake()
	// Sin seudónimo ni zona en el log: solo el tipo de aviso y cuántos.
	p.log.Info("aviso encolado", slog.String("template", string(decision.Template)), slog.Int("devices", len(deliveries)))
	return Queued, nil
}

// release deshace el apunte anti-spam si el aviso no se pudo encolar, para
// que el reintento no lo tome por repetido.
func (p *Processor) release(ctx context.Context, req events.Request, cause error) error {
	if err := p.gate.Release(ctx, req.Recipient, req.ZoneID); err != nil {
		return errors.Join(cause, err)
	}
	return cause
}
