package events

import (
	"errors"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

var observedAt = time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)

// validEvent devuelve un FlightPriceObserved correcto, igual que los que
// publica el flight-ingestor. Cada test lo estropea de una forma distinta.
func validEvent() *flightsv1.FlightPriceObserved {
	return &flightsv1.FlightPriceObserved{
		Metadata: &commonv1.EventMetadata{
			EventId:       "0192F0A0-0000-7000-8000-000000000001", // mayúsculas a propósito
			OccurredAt:    timestamppb.New(observedAt),
			Producer:      "flight-ingestor",
			CorrelationId: "corr-1",
		},
		WatchId:         "watch-1",
		Route:           &flightsv1.Route{OriginIata: "MAD", DestinationIata: "NRT"},
		DepartureDate:   &commonv1.Date{Year: 2026, Month: 12, Day: 1},
		ReturnDate:      &commonv1.Date{Year: 2026, Month: 12, Day: 15},
		Cabin:           flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		Price:           &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 45000},
		Provider:        "simulated",
		CarrierIata:     "IB",
		ObservedAt:      timestamppb.New(observedAt),
		BookingDeepLink: "https://example.invalid/book",
	}
}

func record(t *testing.T, evt *flightsv1.FlightPriceObserved, headers ...Header) Record {
	t.Helper()
	value, err := proto.Marshal(evt)
	if err != nil {
		t.Fatal(err)
	}
	return Record{Topic: TopicPriceObserved, Partition: 3, Offset: 42, Key: []byte("k"), Value: value, Headers: headers}
}

func TestDecodePriceObservedOK(t *testing.T) {
	rec := record(t, validEvent(),
		Header{Key: HeaderContentType, Value: []byte(ContentTypeProtobuf)},
		Header{Key: HeaderType, Value: []byte("nomadiq.flights.v1.FlightPriceObserved")},
	)
	obs, err := DecodePriceObserved(rec)
	if err != nil {
		t.Fatalf("error inesperado: %v", err)
	}
	if obs.EventID != "0192f0a0-0000-7000-8000-000000000001" {
		t.Errorf("event_id no normalizado: %s", obs.EventID)
	}
	if got := obs.RouteKey(); got != "MAD-NRT:2026-12-01:2026-12-15:ECONOMY" {
		t.Errorf("RouteKey = %s", got)
	}
	if obs.Price != (domain.Money{Currency: "EUR", AmountMinor: 45000}) || !obs.ObservedAt.Equal(observedAt) {
		t.Errorf("observación mal traducida: %+v", obs)
	}
}

func TestDecodePriceObservedRejects(t *testing.T) {
	cases := map[string]func(*flightsv1.FlightPriceObserved){
		"event_id no UUID":   func(e *flightsv1.FlightPriceObserved) { e.Metadata.EventId = "hola" },
		"sin metadata":       func(e *flightsv1.FlightPriceObserved) { e.Metadata = nil },
		"IATA en minúsculas": func(e *flightsv1.FlightPriceObserved) { e.Route.OriginIata = "mad" },
		"sin ruta":           func(e *flightsv1.FlightPriceObserved) { e.Route = nil },
		"fecha imposible":    func(e *flightsv1.FlightPriceObserved) { e.DepartureDate.Day = 31; e.DepartureDate.Month = 2 },
		"vuelta antes de ida": func(e *flightsv1.FlightPriceObserved) {
			e.ReturnDate = &commonv1.Date{Year: 2026, Month: 11, Day: 1}
		},
		"cabina sin especificar": func(e *flightsv1.FlightPriceObserved) { e.Cabin = flightsv1.CabinClass_CABIN_CLASS_UNSPECIFIED },
		"precio cero":            func(e *flightsv1.FlightPriceObserved) { e.Price.AmountMinor = 0 },
		"precio negativo":        func(e *flightsv1.FlightPriceObserved) { e.Price.AmountMinor = -5 },
		"divisa rara":            func(e *flightsv1.FlightPriceObserved) { e.Price.CurrencyCode = "euro" },
		"sin proveedor":          func(e *flightsv1.FlightPriceObserved) { e.Provider = "" },
		"sin observed_at":        func(e *flightsv1.FlightPriceObserved) { e.ObservedAt = nil },
	}
	for name, spoil := range cases {
		t.Run(name, func(t *testing.T) {
			evt := validEvent()
			spoil(evt)
			_, err := DecodePriceObserved(record(t, evt))
			if err == nil || !domain.IsValidation(err) {
				t.Fatalf("esperaba error de validación, obtuve %v", err)
			}
		})
	}

	t.Run("bytes basura", func(t *testing.T) {
		_, err := DecodePriceObserved(Record{Value: []byte{0xff, 0xff, 0xff}})
		if !domain.IsValidation(err) {
			t.Fatalf("esperaba error de validación, obtuve %v", err)
		}
	})
	t.Run("tipo de mensaje equivocado", func(t *testing.T) {
		_, err := DecodePriceObserved(record(t, validEvent(), Header{Key: HeaderType, Value: []byte("otra.Cosa")}))
		if !domain.IsValidation(err) {
			t.Fatalf("esperaba error de validación, obtuve %v", err)
		}
	})
	t.Run("content-type JSON", func(t *testing.T) {
		_, err := DecodePriceObserved(record(t, validEvent(), Header{Key: HeaderContentType, Value: []byte("application/json")}))
		if !domain.IsValidation(err) {
			t.Fatalf("esperaba error de validación, obtuve %v", err)
		}
	})
}

func TestEncodeFareAlert(t *testing.T) {
	enc := NewEncoder(TopicFareAlerts, TopicPriceObservedDLQ, "price-consumer")
	enc.Now = func() time.Time { return observedAt }
	alert := domain.PendingAlert{
		Alert: domain.Alert{
			ID: "alert-1", EventID: "evt-1", UserID: "ana", RouteKey: "MAD-NRT:2026-12-01:ECONOMY",
			Type:            domain.AlertErrorFare,
			Reference:       domain.Money{Currency: "EUR", AmountMinor: 50000},
			Current:         domain.Money{Currency: "EUR", AmountMinor: 15000},
			DropBasisPoints: 7000, ObservedAt: observedAt,
		},
		WatchID: "watch-1", Origin: "MAD", Destination: "NRT",
		Departure: domain.Date{Year: 2026, Month: time.December, Day: 1},
		Cabin:     domain.CabinEconomy, DeepLink: "https://example.invalid/book", CorrelationID: "corr-1",
	}
	msg, err := enc.EncodeFareAlert(alert)
	if err != nil {
		t.Fatal(err)
	}
	if msg.Topic != TopicFareAlerts || string(msg.Key) != "ana" {
		t.Errorf("topic/clave incorrectos: %s / %s", msg.Topic, msg.Key)
	}
	if v, _ := header(msg.Headers, HeaderType); v != "nomadiq.flights.v1.FareAlertTriggered" {
		t.Errorf("ce_type = %q", v)
	}
	var evt flightsv1.FareAlertTriggered
	if err := proto.Unmarshal(msg.Value, &evt); err != nil {
		t.Fatal(err)
	}
	if evt.GetAlertId() != "alert-1" || evt.GetMetadata().GetEventId() != "alert-1" ||
		evt.GetAlertType() != flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE ||
		evt.GetCurrentPrice().GetAmountMinor() != 15000 || evt.GetReferencePrice().GetAmountMinor() != 50000 ||
		evt.GetDropBasisPoints() != 7000 || evt.GetDepartureDate().GetMonth() != 12 ||
		evt.GetCabin() != flightsv1.CabinClass_CABIN_CLASS_ECONOMY || evt.GetUserId() != "ana" {
		t.Errorf("evento mal construido: %v", &evt)
	}

	alert.Type = "INVENTADO"
	if _, err := enc.EncodeFareAlert(alert); err == nil {
		t.Error("un tipo de alerta desconocido debe dar error")
	}
}

func TestEncodeDLQKeepsOriginal(t *testing.T) {
	enc := NewEncoder(TopicFareAlerts, TopicPriceObservedDLQ, "price-consumer")
	rec := Record{Topic: TopicPriceObserved, Partition: 7, Offset: 99, Key: []byte("k"), Value: []byte("v"),
		Headers: []Header{{Key: HeaderID, Value: []byte("x")}}}
	msg := enc.EncodeDLQ(rec, errors.New("roto"))
	if msg.Topic != TopicPriceObservedDLQ || string(msg.Value) != "v" || string(msg.Key) != "k" {
		t.Errorf("la DLQ debe conservar el mensaje original: %+v", msg)
	}
	want := map[string]string{HeaderID: "x", HeaderDLQReason: "roto", HeaderDLQTopic: TopicPriceObserved,
		HeaderDLQPartition: "7", HeaderDLQOffset: "99"}
	for k, v := range want {
		if got, _ := header(msg.Headers, k); got != v {
			t.Errorf("cabecera %s = %q, quería %q", k, got, v)
		}
	}
}
