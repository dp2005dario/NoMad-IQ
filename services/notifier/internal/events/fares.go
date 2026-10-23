package events

// Alertas de precio de vuelos (FareAlertTriggered), que publica el
// price-consumer en flights.fare-alerts.v1 cuando un vuelo que alguien vigila
// baja de precio, llega a su precio objetivo o parece una tarifa error.
//
// Diferencia importante con las órdenes de zona: aquí llega el user_id REAL
// (es la clave Kafka del topic de vuelos). El notifier lo usa un instante
// para calcular el seudónimo y lo olvida: nunca va a la base de datos, ni a
// Redis, ni a los logs, ni a los errores (que acaban en la DLQ).

import (
	"fmt"
	"regexp"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"
)

var typeFareAlertTriggered = string((&flightsv1.FareAlertTriggered{}).ProtoReflect().Descriptor().FullName())

// FareAlert es una alerta de precio ya validada.
type FareAlert struct {
	AlertID     string
	OccurredAt  time.Time
	UserID      string
	Type        string // "price_drop", "error_fare" o "target_reached"
	Origin      string // IATA, por ejemplo "MAD"
	Destination string
	Departure   string // "2026-12-15"
	Cabin       string // "ECONOMY", "BUSINESS"...
	Currency    string // ISO 4217, por ejemplo "EUR"
	PriceMinor  int64  // 12999 = 129,99
	DropBP      int32  // bajada en puntos básicos: 2500 = 25 %
}

// Nombres cortos que entiende la app (sin el prefijo del enum de proto).
var fareAlertTypes = map[flightsv1.FareAlertType]string{
	flightsv1.FareAlertType_FARE_ALERT_TYPE_PRICE_DROP:     "price_drop",
	flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE:     "error_fare",
	flightsv1.FareAlertType_FARE_ALERT_TYPE_TARGET_REACHED: "target_reached",
}

var cabins = map[flightsv1.CabinClass]string{
	flightsv1.CabinClass_CABIN_CLASS_ECONOMY:         "ECONOMY",
	flightsv1.CabinClass_CABIN_CLASS_PREMIUM_ECONOMY: "PREMIUM_ECONOMY",
	flightsv1.CabinClass_CABIN_CLASS_BUSINESS:        "BUSINESS",
	flightsv1.CabinClass_CABIN_CLASS_FIRST:           "FIRST",
}

var (
	iata     = regexp.MustCompile(`^[A-Z]{3}$`)
	currency = regexp.MustCompile(`^[A-Z]{3}$`)
)

// maxUserIDLength: los user_id del auth-gateway son UUID; se deja margen
// pero se pone un tope para que nadie meta un texto gigante.
const maxUserIDLength = 128

// DecodeFareAlert valida y traduce un mensaje de flights.fare-alerts.v1.
func DecodeFareAlert(rec Record) (FareAlert, error) {
	if ct, ok := header(rec.Headers, HeaderContentType); ok && ct != ContentTypeProtobuf {
		return FareAlert{}, invalid(HeaderContentType, fmt.Sprintf("se esperaba %s", ContentTypeProtobuf))
	}
	if t, ok := header(rec.Headers, HeaderType); ok && t != typeFareAlertTriggered {
		return FareAlert{}, invalid(HeaderType, fmt.Sprintf("se esperaba %s", typeFareAlertTriggered))
	}
	var evt flightsv1.FareAlertTriggered
	if err := proto.Unmarshal(rec.Value, &evt); err != nil {
		return FareAlert{}, invalid("value", "protobuf ilegible")
	}
	alertID, err := uuid.Parse(evt.GetAlertId())
	if err != nil {
		return FareAlert{}, invalid("alert_id", "no es un UUID")
	}
	at := evt.GetMetadata().GetOccurredAt()
	if at == nil || at.CheckValid() != nil {
		return FareAlert{}, invalid("metadata.occurred_at", "ausente o inválida")
	}
	user := evt.GetUserId()
	if user == "" || len(user) > maxUserIDLength {
		// Igual que con el seudónimo: el valor NUNCA se copia en el error.
		return FareAlert{}, invalid("user_id", "vacío o demasiado largo")
	}
	if string(rec.Key) != user {
		return FareAlert{}, invalid("key", "la clave Kafka debe ser el user_id")
	}
	kind, ok := fareAlertTypes[evt.GetAlertType()]
	if !ok {
		return FareAlert{}, invalid("alert_type", "desconocido")
	}
	origin, destination := evt.GetRoute().GetOriginIata(), evt.GetRoute().GetDestinationIata()
	if !iata.MatchString(origin) || !iata.MatchString(destination) || origin == destination {
		return FareAlert{}, invalid("route", "se esperaban dos códigos IATA distintos")
	}
	d := evt.GetDepartureDate()
	departure := time.Date(int(d.GetYear()), time.Month(d.GetMonth()), int(d.GetDay()), 0, 0, 0, 0, time.UTC)
	// time.Date "arregla" fechas imposibles (31 de febrero → 3 de marzo):
	// si al volver a leerla no coincide, la fecha era inválida.
	if d.GetYear() < 2000 || departure.Year() != int(d.GetYear()) || int32(departure.Month()) != d.GetMonth() || departure.Day() != int(d.GetDay()) {
		return FareAlert{}, invalid("departure_date", "fecha imposible")
	}
	cabin, ok := cabins[evt.GetCabin()]
	if !ok {
		return FareAlert{}, invalid("cabin", "desconocida")
	}
	price := evt.GetCurrentPrice()
	if !currency.MatchString(price.GetCurrencyCode()) || price.GetAmountMinor() <= 0 {
		return FareAlert{}, invalid("current_price", "divisa o importe inválidos")
	}
	if evt.GetDropBasisPoints() < 0 || evt.GetDropBasisPoints() > 10_000 {
		return FareAlert{}, invalid("drop_basis_points", "fuera de 0..10000")
	}
	return FareAlert{
		AlertID:     alertID.String(),
		OccurredAt:  at.AsTime().UTC(),
		UserID:      user,
		Type:        kind,
		Origin:      origin,
		Destination: destination,
		Departure:   departure.Format(time.DateOnly),
		Cabin:       cabin,
		Currency:    price.GetCurrencyCode(),
		PriceMinor:  price.GetAmountMinor(),
		DropBP:      evt.GetDropBasisPoints(),
	}, nil
}
