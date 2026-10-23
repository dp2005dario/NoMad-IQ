package intake

// Alertas de precio → aviso push cifrado.
//
// Mismo camino que los avisos de zona (cifrar para cada teléfono y meter en
// la cola; el sender envía), con tres diferencias:
//
//  1. Llega el user_id real: se convierte en seudónimo nada más entrar y no
//     se guarda en ningún sitio.
//  2. No hay enfriamiento: si has pedido que te avisemos de un vuelo, te
//     avisamos aunque hace 10 minutos te contáramos lo de la plaza. Sí se
//     evita el aviso DOBLE cuando Kafka entrega la misma alerta dos veces.
//  3. Caducan más tarde: una tarifa error vale la pena aunque enciendas el
//     teléfono dentro de unas horas (un "acabas de llegar" no).

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

// Pseudonyms calcula el seudónimo de un user_id (pseudonym.Pseudonymizer).
type Pseudonyms interface {
	Recipient(userID string) string
}

// OnceGate evita repetir el mismo aviso (antispam.Gate en producción).
type OnceGate interface {
	AdmitOnce(ctx context.Context, recipient, key string) (antispam.Verdict, error)
	ReleaseOnce(ctx context.Context, recipient, key string) error
}

// FareConfig del procesador de alertas de precio.
type FareConfig struct {
	DLQTopic    string
	MaxAlertAge time.Duration
	DeliveryTTL time.Duration
}

// FareProcessor procesa alertas de precio.
type FareProcessor struct {
	cfg        FareConfig
	pseudonyms Pseudonyms
	directory  Directory
	outbox     Outbox
	gate       OnceGate
	dlq        Publisher
	wake       func()
	now        func() time.Time
	log        *slog.Logger
}

// NewFares crea el procesador de alertas de precio.
func NewFares(cfg FareConfig, pseudonyms Pseudonyms, directory Directory, outbox Outbox, gate OnceGate, dlq Publisher, wake func(), log *slog.Logger) (*FareProcessor, error) {
	if pseudonyms == nil || directory == nil || outbox == nil || gate == nil || dlq == nil || log == nil {
		return nil, errors.New("intake: faltan dependencias")
	}
	if cfg.DLQTopic == "" || cfg.MaxAlertAge <= 0 || cfg.DeliveryTTL <= 0 {
		return nil, errors.New("intake: configuración incompleta")
	}
	if wake == nil {
		wake = func() {}
	}
	return &FareProcessor{cfg: cfg, pseudonyms: pseudonyms, directory: directory, outbox: outbox, gate: gate,
		dlq: dlq, wake: wake, now: time.Now, log: log}, nil
}

// farePayload es lo que recibe la app (cifrado). Con estos datos pinta
// "Madrid → Lisboa: 39 € (−35 %)" en el idioma del usuario sin preguntar
// nada al servidor; al tocarlo, abre la alerta (alert_id) en la app.
type farePayload struct {
	Version     int             `json:"v"`
	Type        policy.Template `json:"type"`
	AlertID     string          `json:"alert_id"`
	AlertType   string          `json:"alert_type"`
	Origin      string          `json:"origin"`
	Destination string          `json:"destination"`
	Departure   string          `json:"departure"`
	Cabin       string          `json:"cabin"`
	Price       fareMoney       `json:"price"`
	DropBP      int32           `json:"drop_bp"`
	At          string          `json:"at"`
}

type fareMoney struct {
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}

// Handle procesa una alerta. Devuelve error SOLO si es temporal.
func (p *FareProcessor) Handle(ctx context.Context, rec events.Record) (Outcome, error) {
	alert, err := events.DecodeFareAlert(rec)
	if err != nil {
		if pubErr := p.dlq.Publish(ctx, events.EncodeDLQ(p.cfg.DLQTopic, rec, err)); pubErr != nil {
			return "", fmt.Errorf("intake: publicar en la DLQ: %w", pubErr)
		}
		p.log.Warn("alerta de precio inválida enviada a la DLQ", slog.Int("partition", int(rec.Partition)), slog.Int64("offset", rec.Offset), slog.Any("reason", err))
		return DeadLettered, nil
	}
	// Un precio de hace muchas horas probablemente ya no existe: mejor
	// callar que mandar a alguien a por un chollo que ha desaparecido.
	if p.now().Sub(alert.OccurredAt) > p.cfg.MaxAlertAge {
		return Stale, nil
	}
	recipient := p.pseudonyms.Recipient(alert.UserID)
	targets, err := p.directory.DevicesFor(ctx, recipient)
	if err != nil {
		return "", fmt.Errorf("intake: buscar teléfonos: %w", err)
	}
	if len(targets) == 0 {
		return NoDevices, nil
	}
	key := "fare:" + alert.AlertID
	verdict, err := p.gate.AdmitOnce(ctx, recipient, key)
	if err != nil {
		return "", fmt.Errorf("intake: %w", err)
	}
	switch verdict {
	case antispam.Send:
	case antispam.Repeat:
		return Repeated, nil
	default:
		return "", fmt.Errorf("intake: veredicto anti-spam inesperado %d", verdict)
	}

	body, err := json.Marshal(farePayload{
		Version:     1,
		Type:        policy.TemplateFareAlert,
		AlertID:     alert.AlertID,
		AlertType:   alert.Type,
		Origin:      alert.Origin,
		Destination: alert.Destination,
		Departure:   alert.Departure,
		Cabin:       alert.Cabin,
		Price:       fareMoney{AmountMinor: alert.PriceMinor, Currency: alert.Currency},
		DropBP:      alert.DropBP,
		At:          alert.OccurredAt.Format(time.RFC3339),
	})
	if err != nil {
		return "", p.release(ctx, recipient, key, fmt.Errorf("intake: %w", err))
	}
	expires := p.now().Add(p.cfg.DeliveryTTL)
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
		return NoDevices, nil
	}
	if err := p.outbox.Enqueue(ctx, deliveries); err != nil {
		return "", p.release(ctx, recipient, key, fmt.Errorf("intake: encolar: %w", err))
	}
	p.wake()
	// Ni usuario ni ruta en el log: solo el tipo y cuántos teléfonos.
	p.log.Info("alerta de precio encolada", slog.String("alert_type", alert.Type), slog.Int("devices", len(deliveries)))
	return Queued, nil
}

func (p *FareProcessor) release(ctx context.Context, recipient, key string, cause error) error {
	if err := p.gate.ReleaseOnce(ctx, recipient, key); err != nil {
		return errors.Join(cause, err)
	}
	return cause
}
