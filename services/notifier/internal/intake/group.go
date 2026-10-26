package intake

// Avisos de los viajes en grupo → push cifrado a cada miembro.
//
// Mismo camino que las alertas de precio (cifrar para cada teléfono y meter
// en la cola; el sender envía). Dos tipos:
//
//   - "group_chat": mensajes nuevos en el chat del viaje. El ai-orchestrator
//     ya manda como mucho uno por viaje cada 2 minutos.
//   - "group_result": los agentes ya han elegido destino.
//
// Al teléfono solo le llega el tipo y el id del viaje (cifrados): el texto lo
// pone la app en el idioma de cada uno y, al tocarlo, abre ese viaje.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/antispam"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/policy"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

// GroupConfig del procesador de avisos de grupo.
type GroupConfig struct {
	DLQTopic    string
	MaxAge      time.Duration
	DeliveryTTL time.Duration
}

// GroupProcessor procesa los avisos de grupo.
type GroupProcessor struct {
	cfg       GroupConfig
	directory Directory
	outbox    Outbox
	gate      OnceGate
	dlq       Publisher
	wake      func()
	now       func() time.Time
	log       *slog.Logger
}

// NewGroup crea el procesador de avisos de grupo.
func NewGroup(cfg GroupConfig, directory Directory, outbox Outbox, gate OnceGate, dlq Publisher, wake func(), log *slog.Logger) (*GroupProcessor, error) {
	if directory == nil || outbox == nil || gate == nil || dlq == nil || log == nil {
		return nil, errors.New("intake: faltan dependencias")
	}
	if cfg.DLQTopic == "" || cfg.MaxAge <= 0 || cfg.DeliveryTTL <= 0 {
		return nil, errors.New("intake: configuración incompleta")
	}
	if wake == nil {
		wake = func() {}
	}
	return &GroupProcessor{cfg: cfg, directory: directory, outbox: outbox, gate: gate, dlq: dlq, wake: wake, now: time.Now, log: log}, nil
}

type groupPayload struct {
	Version       int             `json:"v"`
	Type          policy.Template `json:"type"`
	NegotiationID string          `json:"negotiation_id"`
	At            string          `json:"at"`
}

// Handle procesa un aviso de grupo. Devuelve error SOLO si es temporal.
func (p *GroupProcessor) Handle(ctx context.Context, rec events.Record, kind events.GroupKind) (Outcome, error) {
	evt, err := events.DecodeGroup(rec, kind)
	if err != nil {
		if pubErr := p.dlq.Publish(ctx, events.EncodeDLQ(p.cfg.DLQTopic, rec, err)); pubErr != nil {
			return "", fmt.Errorf("intake: publicar en la DLQ: %w", pubErr)
		}
		p.log.Warn("aviso de grupo inválido enviado a la DLQ", slog.Int("partition", int(rec.Partition)), slog.Int64("offset", rec.Offset), slog.Any("reason", err))
		return DeadLettered, nil
	}
	if p.now().Sub(evt.OccurredAt) > p.cfg.MaxAge {
		return Stale, nil
	}
	template := policy.TemplateGroupChat
	if kind == events.GroupResult {
		template = policy.TemplateGroupResult
	}
	body, err := json.Marshal(groupPayload{Version: 1, Type: template, NegotiationID: evt.NegotiationID, At: evt.OccurredAt.Format(time.RFC3339)})
	if err != nil {
		return "", fmt.Errorf("intake: %w", err)
	}
	key := "group:" + evt.EventID
	expires := p.now().Add(p.cfg.DeliveryTTL)
	queued := 0
	for _, recipient := range evt.Recipients {
		targets, err := p.directory.DevicesFor(ctx, recipient)
		if err != nil {
			return "", fmt.Errorf("intake: buscar teléfonos: %w", err)
		}
		if len(targets) == 0 {
			continue
		}
		// Si Kafka entrega el mismo aviso dos veces, no se repite.
		verdict, err := p.gate.AdmitOnce(ctx, recipient, key)
		if err != nil {
			return "", fmt.Errorf("intake: %w", err)
		}
		if verdict != antispam.Send {
			continue
		}
		deliveries := make([]Delivery, 0, len(targets))
		for _, t := range targets {
			envelope, err := sealbox.SealForDevice(t.PublicKey, body, []byte(t.DeviceID))
			if err != nil {
				p.log.Error("no se pudo cifrar para un teléfono; se omite", slog.Any("error", err))
				continue
			}
			deliveries = append(deliveries, Delivery{DeviceID: t.DeviceID, Envelope: envelope, ExpiresAt: expires})
		}
		if len(deliveries) == 0 {
			continue
		}
		if err := p.outbox.Enqueue(ctx, deliveries); err != nil {
			if relErr := p.gate.ReleaseOnce(ctx, recipient, key); relErr != nil {
				err = errors.Join(err, relErr)
			}
			return "", fmt.Errorf("intake: encolar: %w", err)
		}
		queued += len(deliveries)
	}
	if queued == 0 {
		return NoDevices, nil
	}
	p.wake()
	// Ni viaje ni personas en el log: solo el tipo y cuántos teléfonos.
	p.log.Info("aviso de grupo encolado", slog.String("kind", string(kind)), slog.Int("devices", queued))
	return Queued, nil
}
