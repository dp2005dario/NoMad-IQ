package intake

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"
	notifyv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/notify/v1"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/antispam"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

const (
	ana  = "L3EwJq7E81uOwDP3QpkOd8aLg_sQhE63kbas17KB9rk"
	zone = "6f0e0d0c-0b0a-4908-8706-050403020100"
)

var now = time.Date(2026, 10, 22, 12, 30, 20, 0, time.UTC)

type fakeDirectory struct {
	targets map[string][]Target
	err     error
}

func (f *fakeDirectory) DevicesFor(_ context.Context, r string) ([]Target, error) {
	return f.targets[r], f.err
}

type fakeOutbox struct {
	got []Delivery
	err error
}

func (f *fakeOutbox) Enqueue(_ context.Context, d []Delivery) error {
	if f.err != nil {
		return f.err
	}
	f.got = append(f.got, d...)
	return nil
}

// fakeGate imita antispam.Gate en memoria (la versión real, con Lua en
// Redis, se prueba en antispam/antispam_integration_test.go).
type fakeGate struct {
	zones    map[string]bool
	cooling  map[string]bool
	released int
	err      error
}

func (f *fakeGate) Admit(_ context.Context, r, z string, urgent bool) (antispam.Verdict, error) {
	if f.err != nil {
		return 0, f.err
	}
	if f.zones[r+z] {
		return antispam.Repeat, nil
	}
	if !urgent && f.cooling[r] {
		return antispam.Cooldown, nil
	}
	f.zones[r+z], f.cooling[r] = true, true
	return antispam.Send, nil
}

func (f *fakeGate) Release(_ context.Context, r, z string) error {
	delete(f.zones, r+z)
	delete(f.cooling, r)
	f.released++
	return nil
}

type fakeDLQ struct{ got []events.Message }

func (f *fakeDLQ) Publish(_ context.Context, m ...events.Message) error {
	f.got = append(f.got, m...)
	return nil
}

type rig struct {
	p      *Processor
	dir    *fakeDirectory
	outbox *fakeOutbox
	gate   *fakeGate
	dlq    *fakeDLQ
	woken  int
	priv   []byte
}

func newRig(t *testing.T) *rig {
	t.Helper()
	pub, priv, err := sealbox.GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	r := &rig{
		dir:    &fakeDirectory{targets: map[string][]Target{ana: {{DeviceID: "11111111-1111-4111-8111-111111111111", PublicKey: pub}}}},
		outbox: &fakeOutbox{},
		gate:   &fakeGate{zones: map[string]bool{}, cooling: map[string]bool{}},
		dlq:    &fakeDLQ{},
		priv:   priv,
	}
	p, err := New(Config{DLQTopic: "dlq", MaxRequestAge: 10 * time.Minute, DeliveryTTL: 10 * time.Minute},
		r.dir, r.outbox, r.gate, r.dlq, func() { r.woken++ }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	p.now = func() time.Time { return now }
	r.p = p
	return r
}

func request(t *testing.T, recipient, zoneID string, kind geov1.ZoneKind, at time.Time) events.Record {
	t.Helper()
	value, err := proto.Marshal(&notifyv1.ZoneNotificationRequested{
		Metadata:  &commonv1.EventMetadata{EventId: "0b8f6a52-5b1e-4f7e-9a51-8f4a2b6c9d10", OccurredAt: timestamppb.New(at), Producer: "geo-engine"},
		Recipient: recipient, ZoneId: zoneID, ZoneKind: kind, Language: "es",
	})
	if err != nil {
		t.Fatal(err)
	}
	return events.Record{Topic: "notify.zone-requests.v1", Key: []byte(recipient), Value: value}
}

func (r *rig) handle(t *testing.T, rec events.Record) Outcome {
	t.Helper()
	out, err := r.p.Handle(context.Background(), rec)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestAnEntryBecomesAnEncryptedDeliveryOnlyThePhoneCanRead(t *testing.T) {
	r := newRig(t)
	minute := now.Truncate(time.Minute)
	if out := r.handle(t, request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, minute)); out != Queued {
		t.Fatalf("outcome = %s", out)
	}
	if len(r.outbox.got) != 1 || r.woken != 1 {
		t.Fatalf("se esperaba 1 aviso encolado y el sender despierto: %d, %d", len(r.outbox.got), r.woken)
	}
	d := r.outbox.got[0]
	if !d.ExpiresAt.Equal(now.Add(10 * time.Minute)) {
		t.Errorf("caducidad = %s", d.ExpiresAt)
	}
	plain, err := sealbox.OpenOnDevice(r.priv, d.Envelope, []byte(d.DeviceID))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(plain, &got); err != nil {
		t.Fatal(err)
	}
	if got["type"] != "zone_audioguide" || got["zone_id"] != zone || got["zone_kind"] != "TOURIST_AREA" || got["lang"] != "es" {
		t.Fatalf("contenido inesperado: %v", got)
	}
}

func TestAWalkThroughTheCentreGivesOneNotification(t *testing.T) {
	r := newRig(t)
	plaza := request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)
	sol := request(t, ana, "6f0e0d0c-0b0a-4908-8706-0504030201ff", geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)
	restricted := request(t, ana, "6f0e0d0c-0b0a-4908-8706-0504030201ee", geov1.ZoneKind_ZONE_KIND_RESTRICTED, now)
	if out := r.handle(t, plaza); out != Queued {
		t.Fatalf("primera zona: %s", out)
	}
	if out := r.handle(t, sol); out != CoolingDown {
		t.Fatalf("segunda zona en el enfriamiento: %s", out)
	}
	if out := r.handle(t, plaza); out != Repeated {
		t.Fatalf("misma zona otra vez: %s", out)
	}
	// Un aviso de seguridad se salta el enfriamiento.
	if out := r.handle(t, restricted); out != Queued {
		t.Fatalf("aviso urgente: %s", out)
	}
	if len(r.outbox.got) != 2 {
		t.Fatalf("se esperaban 2 avisos, hay %d", len(r.outbox.got))
	}
}

func TestPeopleWithoutPhonesLeaveNoTraceInRedis(t *testing.T) {
	r := newRig(t)
	other := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	if out := r.handle(t, request(t, other, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)); out != NoDevices {
		t.Fatalf("outcome = %s", out)
	}
	if len(r.gate.zones) != 0 {
		t.Fatal("sin teléfonos no se debe apuntar nada en el anti-spam")
	}
}

func TestStaleAndBadRequests(t *testing.T) {
	r := newRig(t)
	if out := r.handle(t, request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now.Add(-12*time.Minute))); out != Stale {
		t.Fatalf("una orden vieja debe descartarse: %s", out)
	}
	if out := r.handle(t, request(t, ana, "no-es-uuid", geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)); out != DeadLettered || len(r.dlq.got) != 1 {
		t.Fatalf("una orden inválida debe ir a la DLQ: %s", out)
	}
	if len(r.outbox.got) != 0 {
		t.Fatal("nada de esto debe encolar avisos")
	}
}

func TestAFailedEnqueueUndoesTheAntiSpamMark(t *testing.T) {
	r := newRig(t)
	r.outbox.err = errors.New("postgres caído")
	rec := request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)
	if _, err := r.p.Handle(context.Background(), rec); err == nil {
		t.Fatal("un fallo de PostgreSQL es temporal: debe devolver error para reintentar")
	}
	if r.gate.released != 1 {
		t.Fatal("hay que deshacer el apunte anti-spam")
	}
	r.outbox.err = nil
	if out := r.handle(t, rec); out != Queued {
		t.Fatalf("el reintento no debe tomarse por repetido: %s", out)
	}
}

func TestRedisDownIsTemporary(t *testing.T) {
	r := newRig(t)
	r.gate.err = errors.New("redis caído")
	if _, err := r.p.Handle(context.Background(), request(t, ana, zone, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA, now)); err == nil {
		t.Fatal("sin Redis se reintenta (no se envía sin anti-spam)")
	}
}
