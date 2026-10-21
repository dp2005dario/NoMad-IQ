// Package events traduce entre los mensajes de Kafka (bytes protobuf +
// cabeceras) y los tipos de dominio.
//
// Analogía: es el "traductor de la aduana". Lo que entra por Kafka viene en
// un idioma (protobuf binario); aquí se traduce al idioma interno (domain) y
// se revisa que los papeles estén en regla. Lo que sale, igual pero al revés.
//
// Este paquete no habla con Kafka directamente: solo construye y lee
// estructuras Message/Record. Así se prueba sin ningún broker.
package events

import (
	"fmt"
	"strconv"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// Topics por defecto (convención del proyecto: <dominio>.<evento>.v<versión>).
const (
	TopicPriceObserved = "flights.price-observed.v1"
	TopicFareAlerts    = "flights.fare-alerts.v1"
	// DLQ = Dead Letter Queue ("buzón de cartas devueltas"): aquí van los
	// mensajes imposibles de procesar, para revisarlos sin bloquear al resto.
	TopicPriceObservedDLQ = "flights.price-observed-dlq.v1"
)

// Cabeceras compartidas con el flight-ingestor (estilo CloudEvents).
const (
	HeaderContentType = "content-type"
	HeaderID          = "ce_id"
	HeaderType        = "ce_type"
	HeaderSource      = "ce_source"
	HeaderTime        = "ce_time"
	HeaderSpecVersion = "ce_specversion"

	// Cabeceras extra que se añaden al mandar algo a la DLQ, para saber de
	// dónde venía y por qué falló sin tener que investigar.
	HeaderDLQReason    = "dlq_reason"
	HeaderDLQTopic     = "dlq_source_topic"
	HeaderDLQPartition = "dlq_source_partition"
	HeaderDLQOffset    = "dlq_source_offset"

	ContentTypeProtobuf = "application/x-protobuf"
)

// Nombres completos de los mensajes protobuf, que viajan en la cabecera ce_type.
var (
	typePriceObserved = string((&flightsv1.FlightPriceObserved{}).ProtoReflect().Descriptor().FullName())
	typeFareAlert     = string((&flightsv1.FareAlertTriggered{}).ProtoReflect().Descriptor().FullName())
)

// Header es una cabecera de mensaje (sin depender de la librería de Kafka).
type Header struct {
	Key   string
	Value []byte
}

// Record es un mensaje LEÍDO de Kafka, con su posición exacta en el log.
type Record struct {
	Topic     string
	Partition int32
	Offset    int64
	Key       []byte
	Value     []byte
	Headers   []Header
}

// Message es un mensaje listo para ESCRIBIR en Kafka.
type Message struct {
	Topic   string
	Key     []byte
	Value   []byte
	Headers []Header
}

func header(headers []Header, key string) (string, bool) {
	for _, h := range headers {
		if h.Key == key {
			return string(h.Value), true
		}
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Entrada: FlightPriceObserved -> domain.Observation
// ---------------------------------------------------------------------------

// DecodePriceObserved convierte un Record en una Observation validada.
// Cualquier error devuelto es de validación (domain.IsValidation lo confirma):
// el mensaje está mal y reintentarlo no lo arreglará.
func DecodePriceObserved(rec Record) (domain.Observation, error) {
	// Si el productor dice qué contiene, lo comprobamos ANTES de deserializar:
	// así un mensaje de otro tipo publicado por error no se malinterpreta.
	if ct, ok := header(rec.Headers, HeaderContentType); ok && ct != ContentTypeProtobuf {
		return domain.Observation{}, &domain.ValidationError{Field: HeaderContentType, Reason: fmt.Sprintf("se esperaba %s, llegó %q", ContentTypeProtobuf, ct)}
	}
	if t, ok := header(rec.Headers, HeaderType); ok && t != typePriceObserved {
		return domain.Observation{}, &domain.ValidationError{Field: HeaderType, Reason: fmt.Sprintf("se esperaba %s, llegó %q", typePriceObserved, t)}
	}

	var evt flightsv1.FlightPriceObserved
	if err := proto.Unmarshal(rec.Value, &evt); err != nil {
		return domain.Observation{}, &domain.ValidationError{Field: "value", Reason: "protobuf ilegible: " + err.Error()}
	}

	// El event_id es la base de la idempotencia: debe ser un UUID de verdad.
	// Se normaliza (minúsculas, con guiones) para que "ABC..." y "abc..." no
	// cuenten como eventos distintos.
	id, err := uuid.Parse(evt.GetMetadata().GetEventId())
	if err != nil {
		return domain.Observation{}, &domain.ValidationError{Field: "metadata.event_id", Reason: "no es un UUID válido"}
	}

	departure, err := dateFromProto("departure_date", evt.GetDepartureDate())
	if err != nil {
		return domain.Observation{}, err
	}
	var ret *domain.Date
	if evt.GetReturnDate() != nil {
		d, err := dateFromProto("return_date", evt.GetReturnDate())
		if err != nil {
			return domain.Observation{}, err
		}
		ret = &d
	}
	cabin, err := cabinFromProto(evt.GetCabin())
	if err != nil {
		return domain.Observation{}, err
	}
	if evt.GetObservedAt() == nil || evt.GetObservedAt().CheckValid() != nil {
		return domain.Observation{}, &domain.ValidationError{Field: "observed_at", Reason: "marca de tiempo ausente o inválida"}
	}

	obs := domain.Observation{
		EventID:       id.String(),
		CorrelationID: evt.GetMetadata().GetCorrelationId(),
		WatchID:       evt.GetWatchId(),
		Origin:        evt.GetRoute().GetOriginIata(),
		Destination:   evt.GetRoute().GetDestinationIata(),
		Departure:     departure,
		Return:        ret,
		Cabin:         cabin,
		Price:         domain.Money{Currency: evt.GetPrice().GetCurrencyCode(), AmountMinor: evt.GetPrice().GetAmountMinor()},
		Provider:      evt.GetProvider(),
		CarrierIATA:   evt.GetCarrierIata(),
		DeepLink:      evt.GetBookingDeepLink(),
		ObservedAt:    evt.GetObservedAt().AsTime().UTC(),
	}
	if err := obs.Validate(); err != nil {
		return domain.Observation{}, err
	}
	return obs, nil
}

func dateFromProto(field string, d *commonv1.Date) (domain.Date, error) {
	if d == nil {
		return domain.Date{}, &domain.ValidationError{Field: field, Reason: "es obligatoria"}
	}
	return domain.NewDate(field, int(d.GetYear()), time.Month(d.GetMonth()), int(d.GetDay()))
}

func cabinFromProto(c flightsv1.CabinClass) (domain.Cabin, error) {
	switch c {
	case flightsv1.CabinClass_CABIN_CLASS_ECONOMY:
		return domain.CabinEconomy, nil
	case flightsv1.CabinClass_CABIN_CLASS_PREMIUM_ECONOMY:
		return domain.CabinPremiumEconomy, nil
	case flightsv1.CabinClass_CABIN_CLASS_BUSINESS:
		return domain.CabinBusiness, nil
	case flightsv1.CabinClass_CABIN_CLASS_FIRST:
		return domain.CabinFirst, nil
	}
	return "", &domain.ValidationError{Field: "cabin", Reason: fmt.Sprintf("valor desconocido %v", c)}
}

func cabinToProto(c domain.Cabin) flightsv1.CabinClass {
	switch c {
	case domain.CabinEconomy:
		return flightsv1.CabinClass_CABIN_CLASS_ECONOMY
	case domain.CabinPremiumEconomy:
		return flightsv1.CabinClass_CABIN_CLASS_PREMIUM_ECONOMY
	case domain.CabinBusiness:
		return flightsv1.CabinClass_CABIN_CLASS_BUSINESS
	case domain.CabinFirst:
		return flightsv1.CabinClass_CABIN_CLASS_FIRST
	}
	return flightsv1.CabinClass_CABIN_CLASS_UNSPECIFIED
}

func alertTypeToProto(t domain.AlertType) (flightsv1.FareAlertType, error) {
	switch t {
	case domain.AlertPriceDrop:
		return flightsv1.FareAlertType_FARE_ALERT_TYPE_PRICE_DROP, nil
	case domain.AlertErrorFare:
		return flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE, nil
	case domain.AlertTargetReached:
		return flightsv1.FareAlertType_FARE_ALERT_TYPE_TARGET_REACHED, nil
	}
	return flightsv1.FareAlertType_FARE_ALERT_TYPE_UNSPECIFIED, fmt.Errorf("tipo de alerta desconocido %q", t)
}

// ---------------------------------------------------------------------------
// Salida: domain.PendingAlert -> FareAlertTriggered
// ---------------------------------------------------------------------------

// Encoder construye los mensajes que publica este servicio.
type Encoder struct {
	AlertsTopic string
	DLQTopic    string
	Producer    string
	// Now es inyectable para que los tests sean deterministas.
	Now func() time.Time
}

// NewEncoder crea un Encoder con el reloj real.
func NewEncoder(alertsTopic, dlqTopic, producer string) *Encoder {
	return &Encoder{AlertsTopic: alertsTopic, DLQTopic: dlqTopic, Producer: producer, Now: time.Now}
}

// EncodeFareAlert crea el evento FareAlertTriggered de una alerta.
//
// El event_id del evento es el propio ID de la alerta (determinista). Si por
// un fallo la misma alerta se publica dos veces, ambas copias llevan el mismo
// ID y quien las consuma puede descartar la repetida.
func (e *Encoder) EncodeFareAlert(a domain.PendingAlert) (Message, error) {
	alertType, err := alertTypeToProto(a.Type)
	if err != nil {
		return Message{}, err
	}
	evt := &flightsv1.FareAlertTriggered{
		Metadata: &commonv1.EventMetadata{
			EventId:       a.ID,
			OccurredAt:    timestamppb.New(a.ObservedAt),
			Producer:      e.Producer,
			CorrelationId: a.CorrelationID,
		},
		AlertId:   a.ID,
		UserId:    a.UserID,
		AlertType: alertType,
		WatchId:   a.WatchID,
		Route:     &flightsv1.Route{OriginIata: a.Origin, DestinationIata: a.Destination},
		DepartureDate: &commonv1.Date{
			Year: int32(a.Departure.Year), Month: int32(a.Departure.Month), Day: int32(a.Departure.Day),
		},
		Cabin:           cabinToProto(a.Cabin),
		ReferencePrice:  &commonv1.Money{CurrencyCode: a.Reference.Currency, AmountMinor: a.Reference.AmountMinor},
		CurrentPrice:    &commonv1.Money{CurrencyCode: a.Current.Currency, AmountMinor: a.Current.AmountMinor},
		DropBasisPoints: a.DropBasisPoints,
		BookingDeepLink: a.DeepLink,
	}
	value, err := proto.Marshal(evt)
	if err != nil {
		return Message{}, fmt.Errorf("serializar FareAlertTriggered: %w", err)
	}
	return Message{
		Topic: e.AlertsTopic,
		// Clave = usuario: todas las alertas de una persona van a la misma
		// partición y le llegan en orden.
		Key:   []byte(a.UserID),
		Value: value,
		Headers: []Header{
			{Key: HeaderContentType, Value: []byte(ContentTypeProtobuf)},
			{Key: HeaderSpecVersion, Value: []byte("1.0")},
			{Key: HeaderID, Value: []byte(a.ID)},
			{Key: HeaderType, Value: []byte(typeFareAlert)},
			{Key: HeaderSource, Value: []byte(e.Producer)},
			{Key: HeaderTime, Value: []byte(e.Now().UTC().Format(time.RFC3339Nano))},
		},
	}, nil
}

// EncodeDLQ envuelve un mensaje que no se pudo procesar para la DLQ.
// Se conserva el contenido ORIGINAL intacto (para poder reprocesarlo cuando
// se corrija el problema) y se añade el motivo y su procedencia.
func (e *Encoder) EncodeDLQ(rec Record, reason error) Message {
	headers := make([]Header, 0, len(rec.Headers)+4)
	headers = append(headers, rec.Headers...)
	headers = append(headers,
		Header{Key: HeaderDLQReason, Value: []byte(reason.Error())},
		Header{Key: HeaderDLQTopic, Value: []byte(rec.Topic)},
		Header{Key: HeaderDLQPartition, Value: []byte(strconv.FormatInt(int64(rec.Partition), 10))},
		Header{Key: HeaderDLQOffset, Value: []byte(strconv.FormatInt(rec.Offset, 10))},
	)
	return Message{Topic: e.DLQTopic, Key: rec.Key, Value: rec.Value, Headers: headers}
}
