// Package protomap traduce entre los tipos de dominio y los mensajes protobuf.
//
// Es la única pieza que conoce ambos mundos. Gracias a ella, si mañana cambia
// el contrato .proto, solo se toca este fichero y no la lógica de negocio.
package protomap

import (
	"fmt"
	"time"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// cabinToProto es la tabla de equivalencias entre la cabina de dominio y el
// enum generado desde el .proto. Se usa en los dos sentidos.
var cabinToProto = map[domain.CabinClass]flightsv1.CabinClass{
	domain.CabinEconomy:        flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
	domain.CabinPremiumEconomy: flightsv1.CabinClass_CABIN_CLASS_PREMIUM_ECONOMY,
	domain.CabinBusiness:       flightsv1.CabinClass_CABIN_CLASS_BUSINESS,
	domain.CabinFirst:          flightsv1.CabinClass_CABIN_CLASS_FIRST,
}

// CabinToProto convierte la cabina de dominio a su enum protobuf.
func CabinToProto(c domain.CabinClass) flightsv1.CabinClass {
	if p, ok := cabinToProto[c]; ok {
		return p
	}
	return flightsv1.CabinClass_CABIN_CLASS_UNSPECIFIED
}

// CabinFromProto convierte el enum protobuf a dominio (UNSPECIFIED si no se conoce).
func CabinFromProto(p flightsv1.CabinClass) domain.CabinClass {
	for c, v := range cabinToProto {
		if v == p {
			return c
		}
	}
	return domain.CabinUnspecified
}

// DateToProto convierte una fecha; devuelve nil para la fecha vacía.
func DateToProto(d *domain.Date) *commonv1.Date {
	if d == nil || d.IsZero() {
		return nil
	}
	return &commonv1.Date{Year: int32(d.Year), Month: int32(d.Month), Day: int32(d.Day)}
}

// DateFromProto valida y convierte una fecha protobuf.
func DateFromProto(field string, p *commonv1.Date) (domain.Date, error) {
	if p == nil {
		return domain.Date{}, nil
	}
	return domain.NewDate(field, int(p.GetYear()), time.Month(p.GetMonth()), int(p.GetDay()))
}

// MoneyToProto convierte un importe.
func MoneyToProto(m domain.Money) *commonv1.Money {
	return &commonv1.Money{CurrencyCode: m.Currency, AmountMinor: m.AmountMinor}
}

// SpecFromProto valida la petición entrante y la convierte a dominio.
// Todo dato que llega de fuera pasa por aquí antes de usarse (zero trust).
func SpecFromProto(route *flightsv1.Route, departure, ret *commonv1.Date, cabin flightsv1.CabinClass) (domain.WatchSpec, error) {
	if route == nil {
		return domain.WatchSpec{}, &domain.ValidationError{Field: "route", Reason: "obligatoria"}
	}
	origin, err := domain.ParseAirport("route.origin_iata", route.GetOriginIata())
	if err != nil {
		return domain.WatchSpec{}, err
	}
	destination, err := domain.ParseAirport("route.destination_iata", route.GetDestinationIata())
	if err != nil {
		return domain.WatchSpec{}, err
	}
	dep, err := DateFromProto("departure_date", departure)
	if err != nil {
		return domain.WatchSpec{}, err
	}
	spec := domain.WatchSpec{
		Route:     domain.Route{Origin: origin, Destination: destination},
		Departure: dep,
		Cabin:     CabinFromProto(cabin),
	}
	if ret != nil {
		r, err := DateFromProto("return_date", ret)
		if err != nil {
			return domain.WatchSpec{}, err
		}
		spec.Return = &r
	}
	if err := spec.Validate(); err != nil {
		return domain.WatchSpec{}, fmt.Errorf("petición inválida: %w", err)
	}
	return spec, nil
}

// RouteToProto convierte una ruta.
func RouteToProto(r domain.Route) *flightsv1.Route {
	return &flightsv1.Route{OriginIata: string(r.Origin), DestinationIata: string(r.Destination)}
}

// WatchToProto convierte un seguimiento registrado.
func WatchToProto(w domain.Watch) *flightsv1.RouteWatch {
	return &flightsv1.RouteWatch{
		WatchId:       w.ID,
		Route:         RouteToProto(w.Spec.Route),
		DepartureDate: DateToProto(&w.Spec.Departure),
		ReturnDate:    DateToProto(w.Spec.Return),
		Cabin:         CabinToProto(w.Spec.Cabin),
	}
}

// RouteFromProto valida una ruta que llega de fuera ("MAD" → "NRT").
func RouteFromProto(route *flightsv1.Route) (domain.Route, error) {
	if route == nil {
		return domain.Route{}, &domain.ValidationError{Field: "route", Reason: "obligatoria"}
	}
	origin, err := domain.ParseAirport("route.origin_iata", route.GetOriginIata())
	if err != nil {
		return domain.Route{}, err
	}
	destination, err := domain.ParseAirport("route.destination_iata", route.GetDestinationIata())
	if err != nil {
		return domain.Route{}, err
	}
	if origin == destination {
		return domain.Route{}, &domain.ValidationError{Field: "route", Reason: "origen y destino iguales"}
	}
	return domain.Route{Origin: origin, Destination: destination}, nil
}
