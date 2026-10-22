package events

import (
	"errors"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"
	notifyv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/notify/v1"
)

const recipient = "L3EwJq7E81uOwDP3QpkOd8aLg_sQhE63kbas17KB9rk"

func record(t *testing.T, mutate func(*notifyv1.ZoneNotificationRequested)) Record {
	t.Helper()
	evt := &notifyv1.ZoneNotificationRequested{
		Metadata: &commonv1.EventMetadata{
			EventId:    "0b8f6a52-5b1e-4f7e-9a51-8f4a2b6c9d10",
			OccurredAt: timestamppb.New(time.Date(2026, 10, 22, 12, 30, 0, 0, time.UTC)),
			Producer:   "geo-engine",
		},
		Recipient: recipient,
		ZoneId:    "6F0E0D0C-0B0A-4908-8706-050403020100",
		ZoneKind:  geov1.ZoneKind_ZONE_KIND_TOURIST_AREA,
		Language:  "es",
	}
	if mutate != nil {
		mutate(evt)
	}
	value, err := proto.Marshal(evt)
	if err != nil {
		t.Fatal(err)
	}
	return Record{
		Topic: "notify.zone-requests.v1", Key: []byte(evt.GetRecipient()), Value: value,
		Headers: []Header{{Key: HeaderContentType, Value: []byte(ContentTypeProtobuf)}, {Key: HeaderType, Value: []byte(typeZoneNotificationRequested)}},
	}
}

func TestDecodeValidRequest(t *testing.T) {
	req, err := DecodeRequest(record(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	if req.ZoneID != "6f0e0d0c-0b0a-4908-8706-050403020100" {
		t.Errorf("zone_id sin normalizar: %s", req.ZoneID)
	}
	if req.Kind != geov1.ZoneKind_ZONE_KIND_TOURIST_AREA || req.Language != "es" || req.Recipient != recipient {
		t.Errorf("campos mal leídos: %+v", req)
	}
}

func TestDecodeRejectsBadData(t *testing.T) {
	cases := map[string]func(*notifyv1.ZoneNotificationRequested){
		"sin metadata":   func(e *notifyv1.ZoneNotificationRequested) { e.Metadata = nil },
		"id no uuid":     func(e *notifyv1.ZoneNotificationRequested) { e.Metadata.EventId = "1" },
		"sin hora":       func(e *notifyv1.ZoneNotificationRequested) { e.Metadata.OccurredAt = nil },
		"seudónimo malo": func(e *notifyv1.ZoneNotificationRequested) { e.Recipient = "ana" },
		"zona no uuid":   func(e *notifyv1.ZoneNotificationRequested) { e.ZoneId = "madrid" },
		"tipo vacío":     func(e *notifyv1.ZoneNotificationRequested) { e.ZoneKind = geov1.ZoneKind_ZONE_KIND_UNSPECIFIED },
		"tipo futuro":    func(e *notifyv1.ZoneNotificationRequested) { e.ZoneKind = 99 },
		"idioma raro":    func(e *notifyv1.ZoneNotificationRequested) { e.Language = "es-ES" },
	}
	for name, mutate := range cases {
		if _, err := DecodeRequest(record(t, mutate)); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: se esperaba ErrInvalid, llegó %v", name, err)
		}
	}
	wrongKey := record(t, nil)
	wrongKey.Key = []byte("otra")
	if _, err := DecodeRequest(wrongKey); !errors.Is(err, ErrInvalid) {
		t.Error("la clave Kafka debe coincidir con el seudónimo")
	}
	garbage := record(t, nil)
	garbage.Value = []byte{0xff, 0xff}
	if _, err := DecodeRequest(garbage); !errors.Is(err, ErrInvalid) {
		t.Error("protobuf ilegible debe ser ErrInvalid")
	}
}

func TestErrorsNeverLeakTheRecipient(t *testing.T) {
	_, err := DecodeRequest(record(t, func(e *notifyv1.ZoneNotificationRequested) { e.ZoneId = "x" }))
	if err == nil || strings.Contains(err.Error(), recipient) {
		t.Fatalf("el error no debe contener el seudónimo: %v", err)
	}
	msg := EncodeDLQ("notify.zone-requests-dlq.v1", record(t, nil), err)
	if msg.Topic != "notify.zone-requests-dlq.v1" || len(msg.Headers) != 6 {
		t.Fatalf("DLQ mal construida: %+v", msg)
	}
}
