package intake

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"
	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

const anaUserID = "8d6c1f9e-3b0a-4c55-9e0f-6a7b8c9d0e1f"

// fakePseudonyms: el user_id de Ana se convierte en su seudónimo.
type fakePseudonyms struct{}

func (fakePseudonyms) Recipient(userID string) string {
	if userID == anaUserID {
		return ana
	}
	return "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
}

func newFareRig(t *testing.T) (*rig, *FareProcessor) {
	t.Helper()
	r := newRig(t)
	p, err := NewFares(FareConfig{DLQTopic: "fare-dlq", MaxAlertAge: 6 * time.Hour, DeliveryTTL: 6 * time.Hour},
		fakePseudonyms{}, r.dir, r.outbox, r.gate, r.dlq, func() { r.woken++ }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	p.now = func() time.Time { return now }
	return r, p
}

func fareAlert(t *testing.T, user, alertID string, at time.Time) []byte {
	t.Helper()
	value, err := proto.Marshal(&flightsv1.FareAlertTriggered{
		Metadata:        &commonv1.EventMetadata{EventId: alertID, OccurredAt: timestamppb.New(at), Producer: "price-consumer"},
		AlertId:         alertID,
		UserId:          user,
		AlertType:       flightsv1.FareAlertType_FARE_ALERT_TYPE_PRICE_DROP,
		Route:           &flightsv1.Route{OriginIata: "MAD", DestinationIata: "LIS"},
		DepartureDate:   &commonv1.Date{Year: 2026, Month: 12, Day: 2},
		Cabin:           flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		ReferencePrice:  &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 6000},
		CurrentPrice:    &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 3900},
		DropBasisPoints: 3500,
	})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func handleFare(t *testing.T, p *FareProcessor, user, alertID string, at time.Time) Outcome {
	t.Helper()
	rec := events.Record{Topic: "flights.fare-alerts.v1", Key: []byte(user), Value: fareAlert(t, user, alertID, at)}
	out, err := p.Handle(context.Background(), rec)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

const alert1 = "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d"

func TestAFareAlertBecomesAnEncryptedNoticeWithoutTheUserID(t *testing.T) {
	r, p := newFareRig(t)
	if out := handleFare(t, p, anaUserID, alert1, now.Add(-time.Hour)); out != Queued {
		t.Fatalf("outcome = %s", out)
	}
	if len(r.outbox.got) != 1 || r.woken != 1 {
		t.Fatalf("se esperaba 1 aviso y el sender despierto: %d, %d", len(r.outbox.got), r.woken)
	}
	d := r.outbox.got[0]
	if !d.ExpiresAt.Equal(now.Add(6 * time.Hour)) {
		t.Errorf("caducidad = %s", d.ExpiresAt)
	}
	plain, err := sealbox.OpenOnDevice(r.priv, d.Envelope, []byte(d.DeviceID))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plain), anaUserID) {
		t.Fatal("el aviso no necesita (ni debe llevar) el user_id")
	}
	var got struct {
		Type, AlertID, AlertType, Origin, Destination, Departure, Cabin string
		Price                                                           struct {
			AmountMinor int64  `json:"amount_minor"`
			Currency    string `json:"currency"`
		}
		DropBP int `json:"drop_bp"`
	}
	if err := json.Unmarshal(plain, &got); err != nil {
		t.Fatal(err)
	}
	if got.Type != "fare_alert" || got.Origin != "MAD" || got.Destination != "LIS" || got.Departure != "2026-12-02" ||
		got.Price.AmountMinor != 3900 || got.Price.Currency != "EUR" || got.DropBP != 3500 {
		t.Fatalf("contenido inesperado: %s", plain)
	}
	var raw map[string]any
	_ = json.Unmarshal(plain, &raw)
	if raw["alert_id"] != alert1 || raw["alert_type"] != "price_drop" {
		t.Fatalf("faltan alert_id/alert_type: %s", plain)
	}
}

func TestFareAlertsIgnoreTheZoneCooldownButNeverRingTwice(t *testing.T) {
	r, p := newFareRig(t)
	// Ana acaba de recibir la audioguía de una plaza (enfriamiento activo)...
	if out := r.handle(t, request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)); out != Queued {
		t.Fatalf("zona: %s", out)
	}
	// ...y la bajada de precio llega igual.
	if out := handleFare(t, p, anaUserID, alert1, now); out != Queued {
		t.Fatalf("alerta: %s", out)
	}
	// Kafka la entrega otra vez (tras un reinicio): no suena dos veces.
	if out := handleFare(t, p, anaUserID, alert1, now); out != Repeated {
		t.Fatalf("alerta repetida: %s", out)
	}
	// Otra alerta distinta sí suena.
	if out := handleFare(t, p, anaUserID, "6b5c4d3e-2f10-4b0c-9d8e-7f6a5b4c3d2e", now); out != Queued {
		t.Fatalf("segunda alerta: %s", out)
	}
	if len(r.outbox.got) != 3 {
		t.Fatalf("se esperaban 3 avisos, hay %d", len(r.outbox.got))
	}
}

func TestOldBadOrPhonelessFareAlerts(t *testing.T) {
	r, p := newFareRig(t)
	if out := handleFare(t, p, anaUserID, alert1, now.Add(-7*time.Hour)); out != Stale {
		t.Fatalf("una alerta de hace 7 h ya no se avisa: %s", out)
	}
	if out := handleFare(t, p, "otra-persona", alert1, now); out != NoDevices {
		t.Fatalf("sin teléfonos: %s", out)
	}
	if len(r.gate.zones) != 0 {
		t.Fatal("sin teléfonos no se apunta nada en Redis")
	}
	if out := handleFare(t, p, anaUserID, "no-es-uuid", now); out != DeadLettered {
		t.Fatalf("alerta inválida: %s", out)
	}
	if len(r.dlq.got) != 1 || r.dlq.got[0].Topic != "fare-dlq" {
		t.Fatalf("la alerta inválida va a SU DLQ: %+v", r.dlq.got)
	}
	if len(r.outbox.got) != 0 {
		t.Fatal("nada de esto debe encolar avisos")
	}
}

func TestAFailedFareEnqueueCanBeRetried(t *testing.T) {
	r, p := newFareRig(t)
	r.outbox.err = errors.New("postgres caído")
	rec := events.Record{Topic: "flights.fare-alerts.v1", Key: []byte(anaUserID), Value: fareAlert(t, anaUserID, alert1, now)}
	if _, err := p.Handle(context.Background(), rec); err == nil {
		t.Fatal("un fallo de PostgreSQL es temporal: debe devolver error")
	}
	r.outbox.err = nil
	if out := handleFare(t, p, anaUserID, alert1, now); out != Queued {
		t.Fatalf("el reintento no debe tomarse por repetido: %s", out)
	}
}
