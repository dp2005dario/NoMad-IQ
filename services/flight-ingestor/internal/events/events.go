// Package events convierte hechos de dominio en mensajes listos para Kafka.
//
// Formato elegido:
//   - Valor: protobuf binario (compacto, tipado y con evolución controlada).
//   - Clave: la clave natural del seguimiento, para conservar el orden por ruta.
//   - Cabeceras: estilo CloudEvents (ce_id, ce_type, ce_source...) para que
//     cualquier consumidor sepa qué contiene el mensaje sin deserializarlo.
package events

import (
	"fmt"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/protomap"
)

// TopicPriceObserved es el topic por defecto de las observaciones de precio.
const TopicPriceObserved = "flights.price-observed.v1"

// Nombres de cabecera compartidos por todos los servicios.
const (
	HeaderContentType = "content-type"
	HeaderID          = "ce_id"
	HeaderType        = "ce_type"
	HeaderSource      = "ce_source"
	HeaderTime        = "ce_time"
	HeaderSpecVersion = "ce_specversion"

	ContentTypeProtobuf = "application/x-protobuf"
)

// Header es una cabecera de mensaje (independiente del cliente de Kafka).
type Header struct {
	Key   string
	Value []byte
}

// Message es un mensaje listo para publicar. No depende de ninguna librería
// de Kafka, así el resto del servicio y los tests no necesitan un broker.
type Message struct {
	Topic   string
	Key     []byte
	Value   []byte
	Headers []Header
}

// Encoder construye los mensajes de evento.
type Encoder struct {
	Topic    string
	Producer string
	// NewID y Now son inyectables para obtener tests deterministas.
	NewID func() string
	Now   func() time.Time
}

// NewEncoder crea un Encoder con UUID v7 (ordenables en el tiempo) y reloj real.
func NewEncoder(topic, producer string) *Encoder {
	return &Encoder{
		Topic:    topic,
		Producer: producer,
		NewID:    func() string { return uuid.Must(uuid.NewV7()).String() },
		Now:      time.Now,
	}
}

// EncodePriceObserved valida la observación y la convierte en un Message.
func (e *Encoder) EncodePriceObserved(obs domain.PriceObservation, correlationID string) (Message, error) {
	if err := obs.Validate(); err != nil {
		return Message{}, fmt.Errorf("codificar FlightPriceObserved: %w", err)
	}
	id := e.NewID()
	spec := obs.Watch.Spec
	evt := &flightsv1.FlightPriceObserved{
		Metadata: &commonv1.EventMetadata{
			EventId:       id,
			OccurredAt:    timestamppb.New(obs.Quote.ObservedAt),
			Producer:      e.Producer,
			CorrelationId: correlationID,
		},
		WatchId:         obs.Watch.ID,
		Route:           protomap.RouteToProto(spec.Route),
		DepartureDate:   protomap.DateToProto(&spec.Departure),
		ReturnDate:      protomap.DateToProto(spec.Return),
		Cabin:           protomap.CabinToProto(spec.Cabin),
		Price:           protomap.MoneyToProto(obs.Quote.Price),
		Provider:        obs.Provider,
		CarrierIata:     obs.Quote.CarrierIATA,
		ObservedAt:      timestamppb.New(obs.Quote.ObservedAt),
		BookingDeepLink: obs.Quote.DeepLink,
	}
	value, err := proto.Marshal(evt)
	if err != nil {
		return Message{}, fmt.Errorf("serializar FlightPriceObserved: %w", err)
	}
	return Message{
		Topic: e.Topic,
		Key:   []byte(spec.Key()),
		Value: value,
		Headers: []Header{
			{Key: HeaderContentType, Value: []byte(ContentTypeProtobuf)},
			{Key: HeaderSpecVersion, Value: []byte("1.0")},
			{Key: HeaderID, Value: []byte(id)},
			{Key: HeaderType, Value: []byte(string(evt.ProtoReflect().Descriptor().FullName()))},
			{Key: HeaderSource, Value: []byte(e.Producer)},
			{Key: HeaderTime, Value: []byte(e.Now().UTC().Format(time.RFC3339Nano))},
		},
	}, nil
}
