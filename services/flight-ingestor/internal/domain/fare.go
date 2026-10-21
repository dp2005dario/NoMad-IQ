// Package domain contiene los tipos de negocio del flight-ingestor.
//
// No depende de Kafka, gRPC ni de ningún proveedor: solo de la librería
// estándar. Así las reglas de negocio se prueban sin infraestructura y los
// adaptadores (proto, Kafka, HTTP) se pueden cambiar sin tocar este paquete.
package domain

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// ValidationError describe un dato de entrada inválido. Los adaptadores lo
// detectan con errors.As para responder, por ejemplo, InvalidArgument en gRPC.
type ValidationError struct {
	Field  string
	Reason string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("campo %q inválido: %s", e.Field, e.Reason)
}

func invalid(field, format string, args ...any) error {
	return &ValidationError{Field: field, Reason: fmt.Sprintf(format, args...)}
}

// IsValidation indica si err (o alguno de los que envuelve) es de validación.
func IsValidation(err error) bool {
	var ve *ValidationError
	return errors.As(err, &ve)
}

// Airport es un código IATA de aeropuerto ya validado (3 letras mayúsculas).
type Airport string

// ParseAirport normaliza y valida un código IATA de aeropuerto.
func ParseAirport(field, raw string) (Airport, error) {
	code := strings.ToUpper(strings.TrimSpace(raw))
	if len(code) != 3 {
		return "", invalid(field, "un código IATA tiene 3 letras, se recibió %q", raw)
	}
	for _, r := range code {
		if r < 'A' || r > 'Z' {
			return "", invalid(field, "un código IATA solo contiene letras A-Z, se recibió %q", raw)
		}
	}
	return Airport(code), nil
}

// CabinClass es la clase de cabina. El valor cero es deliberadamente inválido.
type CabinClass int

const (
	CabinUnspecified CabinClass = iota
	CabinEconomy
	CabinPremiumEconomy
	CabinBusiness
	CabinFirst
)

var cabinNames = map[CabinClass]string{
	CabinEconomy:        "ECONOMY",
	CabinPremiumEconomy: "PREMIUM_ECONOMY",
	CabinBusiness:       "BUSINESS",
	CabinFirst:          "FIRST",
}

func (c CabinClass) String() string {
	if name, ok := cabinNames[c]; ok {
		return name
	}
	return "UNSPECIFIED"
}

// Valid indica si la cabina es una de las clases reales.
func (c CabinClass) Valid() bool {
	_, ok := cabinNames[c]
	return ok
}

// ParseCabinClass convierte "ECONOMY", "business", etc. en CabinClass.
func ParseCabinClass(raw string) (CabinClass, error) {
	name := strings.ToUpper(strings.TrimSpace(raw))
	for class, n := range cabinNames {
		if n == name {
			return class, nil
		}
	}
	return CabinUnspecified, invalid("cabin", "clase de cabina desconocida %q", raw)
}

// Date es una fecha de calendario (sin hora), como la fecha de un vuelo.
type Date struct {
	Year  int
	Month time.Month
	Day   int
}

const dateLayout = "2006-01-02"

// NewDate construye y valida una fecha; rechaza fechas imposibles (30 de febrero).
func NewDate(field string, year int, month time.Month, day int) (Date, error) {
	t := time.Date(year, month, day, 0, 0, 0, 0, time.UTC)
	if t.Year() != year || t.Month() != month || t.Day() != day {
		return Date{}, invalid(field, "fecha inexistente %04d-%02d-%02d", year, month, day)
	}
	return Date{Year: year, Month: month, Day: day}, nil
}

// ParseDate lee una fecha en formato AAAA-MM-DD.
func ParseDate(field, raw string) (Date, error) {
	t, err := time.Parse(dateLayout, strings.TrimSpace(raw))
	if err != nil {
		return Date{}, invalid(field, "se esperaba AAAA-MM-DD, se recibió %q", raw)
	}
	return Date{Year: t.Year(), Month: t.Month(), Day: t.Day()}, nil
}

func (d Date) String() string { return d.Time().Format(dateLayout) }

// Time devuelve la fecha a medianoche UTC, útil para comparar.
func (d Date) Time() time.Time { return time.Date(d.Year, d.Month, d.Day, 0, 0, 0, 0, time.UTC) }

// IsZero indica si la fecha no se ha rellenado.
func (d Date) IsZero() bool { return d == Date{} }

// Money es un importe en la unidad mínima de su divisa (céntimos para EUR).
type Money struct {
	Currency    string
	AmountMinor int64
}

// Validate comprueba la divisa (ISO 4217) y que el importe sea positivo.
func (m Money) Validate(field string) error {
	if len(m.Currency) != 3 || strings.ToUpper(m.Currency) != m.Currency {
		return invalid(field+".currency", "se esperaba un código ISO 4217 como EUR, se recibió %q", m.Currency)
	}
	if m.AmountMinor <= 0 {
		return invalid(field+".amount", "el precio debe ser positivo, se recibió %d", m.AmountMinor)
	}
	return nil
}

// Route es un trayecto entre dos aeropuertos distintos.
type Route struct {
	Origin      Airport
	Destination Airport
}

// WatchSpec es lo que define un seguimiento: ruta, fechas y cabina.
type WatchSpec struct {
	Route     Route
	Departure Date
	Return    *Date // nil = solo ida
	Cabin     CabinClass
}

// Validate aplica las reglas de negocio de un seguimiento.
func (s WatchSpec) Validate() error {
	var errs []error
	if s.Route.Origin == "" {
		errs = append(errs, invalid("route.origin_iata", "obligatorio"))
	}
	if s.Route.Destination == "" {
		errs = append(errs, invalid("route.destination_iata", "obligatorio"))
	}
	if s.Route.Origin != "" && s.Route.Origin == s.Route.Destination {
		errs = append(errs, invalid("route", "origen y destino no pueden ser iguales (%s)", s.Route.Origin))
	}
	if s.Departure.IsZero() {
		errs = append(errs, invalid("departure_date", "obligatoria"))
	}
	if s.Return != nil && s.Return.Time().Before(s.Departure.Time()) {
		errs = append(errs, invalid("return_date", "la vuelta (%s) es anterior a la ida (%s)", s.Return, s.Departure))
	}
	if !s.Cabin.Valid() {
		errs = append(errs, invalid("cabin", "obligatoria"))
	}
	return errors.Join(errs...)
}

// Key es la identidad natural del seguimiento y la clave del mensaje Kafka:
// "MAD-NRT:2026-12-01:ECONOMY" o, con vuelta, "MAD-NRT:2026-12-01:2026-12-15:ECONOMY".
// Misma clave => misma partición => eventos de la ruta en orden.
func (s WatchSpec) Key() string {
	parts := []string{fmt.Sprintf("%s-%s", s.Route.Origin, s.Route.Destination), s.Departure.String()}
	if s.Return != nil {
		parts = append(parts, s.Return.String())
	}
	parts = append(parts, s.Cabin.String())
	return strings.Join(parts, ":")
}

// ParseWatchKey hace la operación inversa de Key. Se usa para cargar
// seguimientos de ejemplo desde una variable de entorno.
func ParseWatchKey(raw string) (WatchSpec, error) {
	parts := strings.Split(strings.TrimSpace(raw), ":")
	if len(parts) != 3 && len(parts) != 4 {
		return WatchSpec{}, invalid("watch_key", "formato ORIGEN-DESTINO:AAAA-MM-DD[:AAAA-MM-DD]:CABINA, se recibió %q", raw)
	}
	airports := strings.Split(parts[0], "-")
	if len(airports) != 2 {
		return WatchSpec{}, invalid("watch_key", "ruta sin formato ORIGEN-DESTINO en %q", raw)
	}
	origin, err := ParseAirport("route.origin_iata", airports[0])
	if err != nil {
		return WatchSpec{}, err
	}
	destination, err := ParseAirport("route.destination_iata", airports[1])
	if err != nil {
		return WatchSpec{}, err
	}
	departure, err := ParseDate("departure_date", parts[1])
	if err != nil {
		return WatchSpec{}, err
	}
	spec := WatchSpec{Route: Route{Origin: origin, Destination: destination}, Departure: departure}
	if len(parts) == 4 {
		ret, err := ParseDate("return_date", parts[2])
		if err != nil {
			return WatchSpec{}, err
		}
		spec.Return = &ret
	}
	if spec.Cabin, err = ParseCabinClass(parts[len(parts)-1]); err != nil {
		return WatchSpec{}, err
	}
	return spec, spec.Validate()
}

// Watch es un seguimiento registrado, con su identificador.
type Watch struct {
	ID   string
	Spec WatchSpec
}

// Quote es un precio tal y como lo devuelve un proveedor.
type Quote struct {
	Price       Money
	CarrierIATA string
	DeepLink    string
	ObservedAt  time.Time
}

// PriceObservation es el hecho de negocio que se publica en Kafka:
// "para este seguimiento, este proveedor ofreció este precio en este momento".
type PriceObservation struct {
	Watch    Watch
	Provider string
	Quote    Quote
}

// Validate evita publicar basura: un evento inválido en Kafka contamina a
// todos los consumidores, así que se rechaza antes de salir del servicio.
func (o PriceObservation) Validate() error {
	var errs []error
	if o.Watch.ID == "" {
		errs = append(errs, invalid("watch_id", "obligatorio"))
	}
	if err := o.Watch.Spec.Validate(); err != nil {
		errs = append(errs, err)
	}
	if o.Provider == "" {
		errs = append(errs, invalid("provider", "obligatorio"))
	}
	if err := o.Quote.Price.Validate("price"); err != nil {
		errs = append(errs, err)
	}
	if o.Quote.ObservedAt.IsZero() {
		errs = append(errs, invalid("observed_at", "obligatorio"))
	}
	return errors.Join(errs...)
}
