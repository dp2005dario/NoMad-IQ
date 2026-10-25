package intake

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	aiv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/ai/v1"
	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

const (
	trip1   = "0f1e2d3c-4b5a-4968-8776-655443322110"
	event1  = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
	phonely = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA" // sin teléfonos
)

func newGroupRig(t *testing.T) (*rig, *GroupProcessor) {
	t.Helper()
	r := newRig(t)
	p, err := NewGroup(GroupConfig{DLQTopic: "group-dlq", MaxAge: 6 * time.Hour, DeliveryTTL: 6 * time.Hour},
		r.dir, r.outbox, r.gate, r.dlq, func() { r.woken++ }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	p.now = func() time.Time { return now }
	return r, p
}

func chatRecord(t *testing.T, eventID string, at time.Time, recipients ...string) events.Record {
	t.Helper()
	value, err := proto.Marshal(&aiv1.GroupChatActivity{
		Metadata:      &commonv1.EventMetadata{EventId: eventID, OccurredAt: timestamppb.New(at), Producer: "ai-orchestrator"},
		NegotiationId: trip1,
		Recipients:    recipients,
	})
	if err != nil {
		t.Fatal(err)
	}
	return events.Record{Topic: "ai.group-chat-activity.v1", Key: []byte(trip1), Value: value}
}

func TestGroupChatBecomesAnEncryptedNoticeOnce(t *testing.T) {
	r, p := newGroupRig(t)
	out, err := p.Handle(context.Background(), chatRecord(t, event1, now, ana, phonely, ana), events.GroupChat)
	if err != nil || out != Queued {
		t.Fatalf("outcome = %s, %v", out, err)
	}
	if len(r.outbox.got) != 1 || r.woken != 1 {
		t.Fatalf("un aviso (Ana; el otro no tiene teléfono): %d", len(r.outbox.got))
	}
	d := r.outbox.got[0]
	plain, err := sealbox.OpenOnDevice(r.priv, d.Envelope, []byte(d.DeviceID))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(plain, &got); err != nil {
		t.Fatal(err)
	}
	if got["type"] != "group_chat" || got["negotiation_id"] != trip1 {
		t.Fatalf("contenido inesperado: %s", plain)
	}
	// Kafka lo entrega otra vez: no suena dos veces.
	if out, _ := p.Handle(context.Background(), chatRecord(t, event1, now, ana), events.GroupChat); out != NoDevices {
		t.Fatalf("repetido: %s", out)
	}
	if len(r.outbox.got) != 1 {
		t.Fatal("no debe repetir el aviso")
	}
}

func TestGroupResultUsesItsOwnTemplate(t *testing.T) {
	r, p := newGroupRig(t)
	value, err := proto.Marshal(&aiv1.GroupNegotiationConcluded{
		Metadata:      &commonv1.EventMetadata{EventId: event1, OccurredAt: timestamppb.New(now)},
		NegotiationId: trip1,
		Recipients:    []string{ana},
	})
	if err != nil {
		t.Fatal(err)
	}
	rec := events.Record{Topic: "ai.group-negotiations.v1", Key: []byte(trip1), Value: value}
	if out, err := p.Handle(context.Background(), rec, events.GroupResult); err != nil || out != Queued {
		t.Fatalf("outcome = %s, %v", out, err)
	}
	d := r.outbox.got[0]
	plain, _ := sealbox.OpenOnDevice(r.priv, d.Envelope, []byte(d.DeviceID))
	var got map[string]any
	_ = json.Unmarshal(plain, &got)
	if got["type"] != "group_result" {
		t.Fatalf("plantilla: %s", plain)
	}
}

func TestBadOrOldGroupNotices(t *testing.T) {
	r, p := newGroupRig(t)
	if out, _ := p.Handle(context.Background(), chatRecord(t, event1, now.Add(-7*time.Hour), ana), events.GroupChat); out != Stale {
		t.Fatalf("viejo: %s", out)
	}
	if out, _ := p.Handle(context.Background(), chatRecord(t, event1, now, "no-es-un-seudonimo"), events.GroupChat); out != DeadLettered {
		t.Fatalf("seudónimo inválido: %s", out)
	}
	bad := chatRecord(t, event1, now, ana)
	bad.Key = []byte("otra-clave")
	if out, _ := p.Handle(context.Background(), bad, events.GroupChat); out != DeadLettered {
		t.Fatalf("clave mala: %s", out)
	}
	if len(r.dlq.got) != 2 || r.dlq.got[0].Topic != "group-dlq" || len(r.outbox.got) != 0 {
		t.Fatalf("a SU DLQ y sin avisos: %d %d", len(r.dlq.got), len(r.outbox.got))
	}
}
