package events

// Avisos de los viajes en grupo, que publica el ai-orchestrator:
//
//   - ai.group-chat-activity.v1 → GroupChatActivity: hay mensajes nuevos en
//     el chat del viaje.
//   - ai.group-negotiations.v1  → GroupNegotiationConcluded: los agentes ya
//     han elegido destino.
//
// Los dos llevan los destinatarios como SEUDÓNIMOS (nunca user_id) y ningún
// texto de mensajes ni nombres. Aquí solo se comprueba que todo tenga la
// forma correcta.

import (
	"fmt"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	aiv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/ai/v1"
	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/pseudonym"
)

var (
	typeGroupChatActivity         = string((&aiv1.GroupChatActivity{}).ProtoReflect().Descriptor().FullName())
	typeGroupNegotiationConcluded = string((&aiv1.GroupNegotiationConcluded{}).ProtoReflect().Descriptor().FullName())
)

// GroupKind dice de qué es el aviso de grupo.
type GroupKind string

// Tipos de aviso de grupo.
const (
	GroupChat   GroupKind = "chat"   // mensajes nuevos en el chat del viaje
	GroupResult GroupKind = "result" // ya hay destino
)

// MaxGroupRecipients: un viaje tiene como mucho 8 personas.
const MaxGroupRecipients = 8

// GroupEvent es un aviso de grupo ya validado.
type GroupEvent struct {
	Kind          GroupKind
	EventID       string
	OccurredAt    time.Time
	NegotiationID string
	Recipients    []string
}

type groupFields interface {
	proto.Message
	GetMetadata() *commonv1.EventMetadata
	GetNegotiationId() string
	GetRecipients() []string
}

// DecodeGroup valida un mensaje de [kind] (el topic decide cuál es).
func DecodeGroup(rec Record, kind GroupKind) (GroupEvent, error) {
	if ct, ok := header(rec.Headers, HeaderContentType); ok && ct != ContentTypeProtobuf {
		return GroupEvent{}, invalid(HeaderContentType, fmt.Sprintf("se esperaba %s", ContentTypeProtobuf))
	}
	var (
		evt      groupFields
		wantType string
	)
	switch kind {
	case GroupChat:
		evt, wantType = &aiv1.GroupChatActivity{}, typeGroupChatActivity
	case GroupResult:
		evt, wantType = &aiv1.GroupNegotiationConcluded{}, typeGroupNegotiationConcluded
	default:
		return GroupEvent{}, invalid("kind", "desconocido")
	}
	if t, ok := header(rec.Headers, HeaderType); ok && t != wantType {
		return GroupEvent{}, invalid(HeaderType, fmt.Sprintf("se esperaba %s", wantType))
	}
	if err := proto.Unmarshal(rec.Value, evt); err != nil {
		return GroupEvent{}, invalid("value", "protobuf ilegible")
	}
	id, err := uuid.Parse(evt.GetMetadata().GetEventId())
	if err != nil {
		return GroupEvent{}, invalid("metadata.event_id", "no es un UUID")
	}
	ts := evt.GetMetadata().GetOccurredAt()
	if ts == nil || ts.CheckValid() != nil {
		return GroupEvent{}, invalid("metadata.occurred_at", "ausente o inválida")
	}
	at := ts.AsTime().UTC()
	trip, err := uuid.Parse(evt.GetNegotiationId())
	if err != nil {
		return GroupEvent{}, invalid("negotiation_id", "no es un UUID")
	}
	if string(rec.Key) != evt.GetNegotiationId() {
		return GroupEvent{}, invalid("key", "la clave Kafka debe ser el negotiation_id")
	}
	recipients := evt.GetRecipients()
	if len(recipients) > MaxGroupRecipients {
		return GroupEvent{}, invalid("recipients", "demasiados")
	}
	seen := make(map[string]bool, len(recipients))
	out := make([]string, 0, len(recipients))
	for _, r := range recipients {
		if !pseudonym.Valid(r) {
			// El valor NO va en el error (acabaría en logs y en la DLQ).
			return GroupEvent{}, invalid("recipients", "no es un seudónimo válido")
		}
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	return GroupEvent{Kind: kind, EventID: id.String(), OccurredAt: at, NegotiationID: trip.String(), Recipients: out}, nil
}
