package events

import (
	"errors"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"
)

const fareUser = "8d6c1f9e-3b0a-4c55-9e0f-6a7b8c9d0e1f"

func fareRecord(t *testing.T, mutate func(*flightsv1.FareAlertTriggered)) Record {
	t.Helper()
	evt := &flightsv1.FareAlertTriggered{
		Metadata: &commonv1.EventMetadata{
			EventId:    "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d",
			OccurredAt: timestamppb.New(time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)),
			Producer:   "price-consumer",
		},
		AlertId:         "5A4B3C2D-1E0F-4A9B-8C7D-6E5F4A3B2C1D",
		UserId:          fareUser,
		AlertType:       flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE,
		Route:           &flightsv1.Route{OriginIata: "MAD", DestinationIata: "NRT"},
		DepartureDate:   &commonv1.Date{Year: 2026, Month: 12, Day: 15},
		Cabin:           flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		ReferencePrice:  &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 90000},
		CurrentPrice:    &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 31500},
		DropBasisPoints: 6500,
	}
	if mutate != nil {
		mutate(evt)
	}
	value, err := proto.Marshal(evt)
	if err != nil {
		t.Fatal(err)
	}
	return Record{
		Topic: "flights.fare-alerts.v1", Key: []byte(evt.GetUserId()), Value: value,
		Headers: []Header{{Key: HeaderContentType, Value: []byte(ContentTypeProtobuf)}, {Key: HeaderType, Value: []byte(typeFareAlertTriggered)}},
	}
}

func TestDecodeValidFareAlert(t *testing.T) {
	a, err := DecodeFareAlert(fareRecord(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	want := FareAlert{
		AlertID: "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d", OccurredAt: time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC),
		UserID: fareUser, Type: "error_fare", Origin: "MAD", Destination: "NRT", Departure: "2026-12-15",
		Cabin: "ECONOMY", Currency: "EUR", PriceMinor: 31500, DropBP: 6500,
	}
	if a != want {
		t.Fatalf("leída\n%+v\nesperada\n%+v", a, want)
	}
}

func TestDecodeFareAlertRejectsBadData(t *testing.T) {
	cases := map[string]func(*flightsv1.FareAlertTriggered){
		"alert_id raro":      func(e *flightsv1.FareAlertTriggered) { e.AlertId = "x" },
		"sin fecha":          func(e *flightsv1.FareAlertTriggered) { e.Metadata.OccurredAt = nil },
		"sin usuario":        func(e *flightsv1.FareAlertTriggered) { e.UserId = "" },
		"usuario gigante":    func(e *flightsv1.FareAlertTriggered) { e.UserId = strings.Repeat("u", 200) },
		"tipo desconocido":   func(e *flightsv1.FareAlertTriggered) { e.AlertType = 0 },
		"mismo aeropuerto":   func(e *flightsv1.FareAlertTriggered) { e.Route.DestinationIata = "MAD" },
		"IATA en minúsculas": func(e *flightsv1.FareAlertTriggered) { e.Route.OriginIata = "mad" },
		"31 de febrero":      func(e *flightsv1.FareAlertTriggered) { e.DepartureDate = &commonv1.Date{Year: 2027, Month: 2, Day: 31} },
		"sin cabina":         func(e *flightsv1.FareAlertTriggered) { e.Cabin = 0 },
		"precio cero":        func(e *flightsv1.FareAlertTriggered) { e.CurrentPrice.AmountMinor = 0 },
		"divisa rara":        func(e *flightsv1.FareAlertTriggered) { e.CurrentPrice.CurrencyCode = "euro" },
		"bajada de 150 %":    func(e *flightsv1.FareAlertTriggered) { e.DropBasisPoints = 15000 },
	}
	for name, mutate := range cases {
		_, err := DecodeFareAlert(fareRecord(t, mutate))
		if !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: se esperaba ErrInvalid, llegó %v", name, err)
		}
	}
	rec := fareRecord(t, nil)
	rec.Key = []byte("otra-persona")
	if _, err := DecodeFareAlert(rec); !errors.Is(err, ErrInvalid) {
		t.Errorf("clave distinta del user_id: %v", err)
	}
	rec = fareRecord(t, nil)
	rec.Headers[1].Value = []byte(typeZoneNotificationRequested)
	if _, err := DecodeFareAlert(rec); !errors.Is(err, ErrInvalid) {
		t.Errorf("ce_type equivocado: %v", err)
	}
}

func TestFareErrorsNeverLeakTheUser(t *testing.T) {
	rec := fareRecord(t, func(e *flightsv1.FareAlertTriggered) { e.AlertType = 0 })
	rec.Key = []byte("otra")
	_, err := DecodeFareAlert(rec)
	if err == nil || strings.Contains(err.Error(), fareUser) {
		t.Fatalf("el user_id no puede aparecer en el error: %v", err)
	}
}
