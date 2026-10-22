// Package events traduce los mensajes de Kafka del notifier.
//
// Lo que entra: ZoneNotificationRequested (proto/nomadiq/notify/v1), la
// "orden" seudónima que publica el geo-engine. Aquí se comprueba que los
// papeles estén en regla; si no lo están, el mensaje va a la DLQ ("buzón de
// cartas devueltas") en lugar de bloquear la cola. Este paquete no habla con
// Kafka: solo lee y construye estructuras, así se prueba sin broker.
package events

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"
	notifyv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/notify/v1"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/pseudonym"
)

// Cabeceras estilo CloudEvents (las mismas que en el resto de servicios).
const (
	HeaderContentType   = "content-type"
	HeaderType          = "ce_type"
	ContentTypeProtobuf = "application/x-protobuf"

	HeaderDLQReason    = "dlq_reason"
	HeaderDLQTopic     = "dlq_source_topic"
	HeaderDLQPartition = "dlq_source_partition"
	HeaderDLQOffset    = "dlq_source_offset"
)

var typeZoneNotificationRequested = string((&notifyv1.ZoneNotificationRequested{}).ProtoReflect().Descriptor().FullName())

// Header es una cabecera de mensaje (sin depender de la librería de Kafka).
type Header struct {
	Key   string
	Value []byte
}

// Record es un mensaje LEÍDO de Kafka.
type Record struct {
	Topic     string
	Partition int32
	Offset    int64
	Key       []byte
	Value     []byte
	Headers   []Header
}

// Message es un mensaje listo para ESCRIBIR en Kafka (aquí, solo la DLQ).
type Message struct {
	Topic   string
	Key     []byte
	Value   []byte
	Headers []Header
}

// Request es una orden de notificación ya validada.
type Request struct {
	EventID    string
	OccurredAt time.Time
	Recipient  string
	ZoneID     string
	Kind       geov1.ZoneKind
	Language   string
}

// ErrInvalid marca los errores de DATOS: reintentar no los arregla.
var ErrInvalid = errors.New("orden de notificación inválida")

func invalid(field, reason string) error {
	return fmt.Errorf("%w: %s: %s", ErrInvalid, field, reason)
}

var language = regexp.MustCompile(`^[a-z]{2,3}$`)

func header(headers []Header, key string) (string, bool) {
	for _, h := range headers {
		if h.Key == key {
			return string(h.Value), true
		}
	}
	return "", false
}

// DecodeRequest valida y traduce un mensaje de notify.zone-requests.v1.
func DecodeRequest(rec Record) (Request, error) {
	if ct, ok := header(rec.Headers, HeaderContentType); ok && ct != ContentTypeProtobuf {
		return Request{}, invalid(HeaderContentType, fmt.Sprintf("se esperaba %s", ContentTypeProtobuf))
	}
	if t, ok := header(rec.Headers, HeaderType); ok && t != typeZoneNotificationRequested {
		return Request{}, invalid(HeaderType, fmt.Sprintf("se esperaba %s", typeZoneNotificationRequested))
	}
	var evt notifyv1.ZoneNotificationRequested
	if err := proto.Unmarshal(rec.Value, &evt); err != nil {
		return Request{}, invalid("value", "protobuf ilegible")
	}
	id, err := uuid.Parse(evt.GetMetadata().GetEventId())
	if err != nil {
		return Request{}, invalid("metadata.event_id", "no es un UUID")
	}
	at := evt.GetMetadata().GetOccurredAt()
	if at == nil || at.CheckValid() != nil {
		return Request{}, invalid("metadata.occurred_at", "ausente o inválida")
	}
	if !pseudonym.Valid(evt.GetRecipient()) {
		// Ojo: el valor NO se incluye en el error (iría a los logs y a la DLQ).
		return Request{}, invalid("recipient", "no es un seudónimo válido")
	}
	if string(rec.Key) != evt.GetRecipient() {
		return Request{}, invalid("key", "la clave Kafka debe ser el seudónimo")
	}
	zone, err := uuid.Parse(evt.GetZoneId())
	if err != nil {
		return Request{}, invalid("zone_id", "no es un UUID")
	}
	kind := evt.GetZoneKind()
	if _, known := geov1.ZoneKind_name[int32(kind)]; !known || kind == geov1.ZoneKind_ZONE_KIND_UNSPECIFIED {
		return Request{}, invalid("zone_kind", "desconocido")
	}
	lang := evt.GetLanguage()
	if lang != "" && !language.MatchString(lang) {
		return Request{}, invalid("language", "se esperaba un código ISO 639 en minúsculas")
	}
	return Request{
		EventID:    id.String(),
		OccurredAt: at.AsTime().UTC(),
		Recipient:  evt.GetRecipient(),
		ZoneID:     zone.String(),
		Kind:       kind,
		Language:   lang,
	}, nil
}

// EncodeDLQ envuelve un mensaje imposible de procesar para la DLQ: el
// contenido original intacto, más el motivo y su procedencia.
func EncodeDLQ(dlqTopic string, rec Record, reason error) Message {
	headers := make([]Header, 0, len(rec.Headers)+4)
	headers = append(headers, rec.Headers...)
	headers = append(headers,
		Header{Key: HeaderDLQReason, Value: []byte(reason.Error())},
		Header{Key: HeaderDLQTopic, Value: []byte(rec.Topic)},
		Header{Key: HeaderDLQPartition, Value: []byte(strconv.FormatInt(int64(rec.Partition), 10))},
		Header{Key: HeaderDLQOffset, Value: []byte(strconv.FormatInt(rec.Offset, 10))},
	)
	return Message{Topic: dlqTopic, Key: rec.Key, Value: rec.Value, Headers: headers}
}
