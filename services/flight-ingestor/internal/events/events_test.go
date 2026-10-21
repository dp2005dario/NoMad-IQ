// Tests de la codificación de eventos para Kafka.

package events

import (
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// Codifica una observación y vuelve a decodificarla como lo haría un
// consumidor (por ejemplo, el futuro servicio sniper en otro lenguaje).
// Si los datos no salen iguales que entraron, el contrato está roto.
// NewID se sustituye por uno fijo para que el resultado sea predecible.
func TestEncodePriceObservedRoundTrip(t *testing.T) {
	spec, err := domain.ParseWatchKey("MAD-NRT:2026-12-01:2026-12-15:ECONOMY")
	if err != nil {
		t.Fatal(err)
	}
	observed := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	obs := domain.PriceObservation{
		Watch:    domain.Watch{ID: "watch-1", Spec: spec},
		Provider: "simulated",
		Quote: domain.Quote{
			Price:       domain.Money{Currency: "EUR", AmountMinor: 54999},
			CarrierIATA: "IB",
			ObservedAt:  observed,
		},
	}
	enc := NewEncoder(TopicPriceObserved, "flight-ingestor")
	enc.NewID = func() string { return "evt-1" }

	msg, err := enc.EncodePriceObserved(obs, "corr-1")
	if err != nil {
		t.Fatal(err)
	}
	if msg.Topic != TopicPriceObserved {
		t.Errorf("Topic = %q", msg.Topic)
	}
	if got := string(msg.Key); got != spec.Key() {
		t.Errorf("Key = %q, se esperaba %q", got, spec.Key())
	}
	headers := map[string]string{}
	for _, h := range msg.Headers {
		headers[h.Key] = string(h.Value)
	}
	if headers[HeaderType] != "nomadiq.flights.v1.FlightPriceObserved" || headers[HeaderID] != "evt-1" {
		t.Errorf("cabeceras inesperadas: %v", headers)
	}

	var decoded flightsv1.FlightPriceObserved
	if err := proto.Unmarshal(msg.Value, &decoded); err != nil {
		t.Fatalf("el valor no es protobuf válido: %v", err)
	}
	if decoded.GetPrice().GetAmountMinor() != 54999 || decoded.GetPrice().GetCurrencyCode() != "EUR" {
		t.Errorf("precio decodificado = %v", decoded.GetPrice())
	}
	if decoded.GetRoute().GetOriginIata() != "MAD" || decoded.GetReturnDate().GetDay() != 15 {
		t.Errorf("ruta/fecha decodificadas incorrectas: %v", &decoded)
	}
	if decoded.GetCabin() != flightsv1.CabinClass_CABIN_CLASS_ECONOMY {
		t.Errorf("cabina = %v", decoded.GetCabin())
	}
	if decoded.GetMetadata().GetCorrelationId() != "corr-1" || !decoded.GetObservedAt().AsTime().Equal(observed) {
		t.Errorf("metadatos incorrectos: %v", decoded.GetMetadata())
	}
}

// Una observación vacía nunca debe llegar a Kafka.
func TestEncodeRejectsInvalidObservation(t *testing.T) {
	enc := NewEncoder(TopicPriceObserved, "flight-ingestor")
	if _, err := enc.EncodePriceObserved(domain.PriceObservation{}, ""); !domain.IsValidation(err) {
		t.Fatalf("se esperaba ValidationError, error = %v", err)
	}
}
