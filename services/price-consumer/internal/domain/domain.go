// Package domain contiene los tipos de negocio del price-consumer.
//
// ¿Por qué un paquete "domain" separado?
// Aquí solo hay reglas y datos de negocio (qué es un precio, qué es una
// alerta), sin nada de Kafka, PostgreSQL ni protobuf. Así:
//   - las reglas se prueban con tests rapidísimos, sin levantar infraestructura;
//   - si mañana cambiamos Kafka por otra cosa, este paquete no se toca.
//
// Nota: el flight-ingestor tiene su propio paquete domain parecido. No se
// comparte a propósito: cada microservicio es dueño de su modelo y solo
// comparten el CONTRATO (los .proto). Compartir código interno acoplaría los
// despliegues de ambos servicios.
package domain

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// ValidationError describe un dato inválido. Se distingue de los errores de
// infraestructura (base de datos caída, red...) porque se trata distinto:
// un dato inválido no se arregla reintentando, así que se aparta (DLQ).
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

// Invalid crea un error de validación desde otro paquete (p. ej. cuando el
// flight-ingestor rechaza una búsqueda por un dato incorrecto).
func Invalid(field, format string, args ...any) error { return invalid(field, format, args...) }

// IsValidation indica si err (o alguno de los errores que envuelve) es de
// validación. errors.As "desenvuelve" los errores creados con %w.
func IsValidation(err error) bool {
	var ve *ValidationError
	return errors.As(err, &ve)
}

// ---------------------------------------------------------------------------
// Tipos básicos
// ---------------------------------------------------------------------------

// Cabin es la clase de cabina. Se guarda como texto ("ECONOMY") porque así
// la base de datos es legible para una persona que la consulte a mano.
type Cabin string

const (
	CabinEconomy        Cabin = "ECONOMY"
	CabinPremiumEconomy Cabin = "PREMIUM_ECONOMY"
	CabinBusiness       Cabin = "BUSINESS"
	CabinFirst          Cabin = "FIRST"
)

// Valid indica si la cabina es una de las clases reales.
func (c Cabin) Valid() bool {
	switch c {
	case CabinEconomy, CabinPremiumEconomy, CabinBusiness, CabinFirst:
		return true
	}
	return false
}

// Date es un día del calendario sin hora (la fecha de un vuelo).
type Date struct {
	Year  int
	Month time.Month
	Day   int
}

const dateLayout = "2006-01-02"

// NewDate valida que el día exista (rechaza, por ejemplo, el 31 de febrero).
func NewDate(field string, year int, month time.Month, day int) (Date, error) {
	t := time.Date(year, month, day, 0, 0, 0, 0, time.UTC)
	// time.Date "normaliza" fechas imposibles (31-feb pasa a 3-mar). Si al
	// volver a leerla no coincide, la fecha original no existía.
	if t.Year() != year || t.Month() != month || t.Day() != day || year < 2000 || year > 2200 {
		return Date{}, invalid(field, "fecha inexistente %04d-%02d-%02d", year, int(month), day)
	}
	return Date{Year: year, Month: month, Day: day}, nil
}

// ParseDate lee una fecha con formato AAAA-MM-DD.
func ParseDate(field, raw string) (Date, error) {
	t, err := time.Parse(dateLayout, strings.TrimSpace(raw))
	if err != nil {
		return Date{}, invalid(field, "se esperaba AAAA-MM-DD, se recibió %q", raw)
	}
	return NewDate(field, t.Year(), t.Month(), t.Day())
}

func (d Date) String() string { return d.Time().Format(dateLayout) }

// Time devuelve la fecha como medianoche UTC (útil para guardarla en SQL).
func (d Date) Time() time.Time { return time.Date(d.Year, d.Month, d.Day, 0, 0, 0, 0, time.UTC) }

// Money es un importe en la unidad mínima de la divisa (céntimos en EUR).
// NUNCA usamos float para dinero: 0.1 + 0.2 da 0.30000000000000004.
type Money struct {
	Currency    string // código ISO 4217, por ejemplo "EUR"
	AmountMinor int64  // 12999 con EUR = 129,99 €
}

// Validate comprueba divisa de 3 letras mayúsculas e importe positivo.
func (m Money) Validate(field string) error {
	if !isUpperLetters(m.Currency, 3) {
		return invalid(field+".currency_code", "se esperaba un código ISO 4217 como EUR, se recibió %q", m.Currency)
	}
	if m.AmountMinor <= 0 {
		return invalid(field+".amount_minor", "debe ser mayor que 0, se recibió %d", m.AmountMinor)
	}
	return nil
}

func (m Money) String() string {
	return fmt.Sprintf("%d.%02d %s", m.AmountMinor/100, m.AmountMinor%100, m.Currency)
}

func isUpperLetters(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, r := range s {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Observación de precio (lo que llega por Kafka)
// ---------------------------------------------------------------------------

// Observation es un precio visto por el flight-ingestor en un momento dado.
type Observation struct {
	EventID       string // UUID único del evento: sirve para no procesarlo dos veces
	CorrelationID string
	WatchID       string
	Origin        string // código IATA, por ejemplo "MAD"
	Destination   string
	Departure     Date
	Return        *Date // nil si es solo ida
	Cabin         Cabin
	Price         Money
	Provider      string
	CarrierIATA   string
	DeepLink      string // enlace de reserva con afiliado (monetización)
	ObservedAt    time.Time
}

// RouteKey es la clave natural de la ruta: "MAD-NRT:2026-12-01:ECONOMY".
// Debe coincidir EXACTAMENTE con la que usa el flight-ingestor como clave de
// Kafka, porque los usuarios se suscriben a rutas con este mismo formato.
func (o Observation) RouteKey() string {
	parts := []string{o.Origin + "-" + o.Destination, o.Departure.String()}
	if o.Return != nil {
		parts = append(parts, o.Return.String())
	}
	parts = append(parts, string(o.Cabin))
	return strings.Join(parts, ":")
}

// Validate aplica todas las reglas a una observación recién decodificada.
// Un mensaje que no las cumple jamás llega a la base de datos.
func (o Observation) Validate() error {
	if o.EventID == "" {
		return invalid("metadata.event_id", "es obligatorio")
	}
	if !isUpperLetters(o.Origin, 3) {
		return invalid("route.origin_iata", "se esperaba un código IATA de 3 letras, se recibió %q", o.Origin)
	}
	if !isUpperLetters(o.Destination, 3) {
		return invalid("route.destination_iata", "se esperaba un código IATA de 3 letras, se recibió %q", o.Destination)
	}
	if o.Origin == o.Destination {
		return invalid("route", "origen y destino no pueden ser el mismo aeropuerto (%s)", o.Origin)
	}
	if o.Departure == (Date{}) {
		return invalid("departure_date", "es obligatoria")
	}
	if o.Return != nil && o.Return.Time().Before(o.Departure.Time()) {
		return invalid("return_date", "la vuelta (%s) no puede ser anterior a la ida (%s)", o.Return, o.Departure)
	}
	if !o.Cabin.Valid() {
		return invalid("cabin", "clase de cabina desconocida %q", o.Cabin)
	}
	if err := o.Price.Validate("price"); err != nil {
		return err
	}
	if strings.TrimSpace(o.Provider) == "" {
		return invalid("provider", "es obligatorio")
	}
	if o.ObservedAt.IsZero() {
		return invalid("observed_at", "es obligatorio")
	}
	return nil
}

// ---------------------------------------------------------------------------
// Suscripciones: qué usuario quiere enterarse de qué ruta
// ---------------------------------------------------------------------------

// Subscription une a un usuario con una ruta. Target (opcional) es el precio
// que el usuario está dispuesto a pagar: si se alcanza, se le avisa.
type Subscription struct {
	UserID   string
	RouteKey string
	Target   *Money
}

// Validate comprueba la suscripción antes de guardarla.
func (s Subscription) Validate() error {
	if s.UserID == "" || len(s.UserID) > 128 {
		return invalid("user_id", "debe tener entre 1 y 128 caracteres")
	}
	if err := ValidateRouteKey(s.RouteKey); err != nil {
		return err
	}
	if s.Target != nil {
		return s.Target.Validate("target")
	}
	return nil
}

// ValidateRouteKey comprueba el formato ORIGEN-DESTINO:AAAA-MM-DD[:AAAA-MM-DD]:CABINA.
func ValidateRouteKey(key string) error {
	parts := strings.Split(key, ":")
	if len(parts) != 3 && len(parts) != 4 {
		return invalid("route_key", "formato ORIGEN-DESTINO:AAAA-MM-DD[:AAAA-MM-DD]:CABINA, se recibió %q", key)
	}
	airports := strings.Split(parts[0], "-")
	if len(airports) != 2 || !isUpperLetters(airports[0], 3) || !isUpperLetters(airports[1], 3) {
		return invalid("route_key", "ruta sin formato ORIGEN-DESTINO (IATA en mayúsculas) en %q", key)
	}
	for _, d := range parts[1 : len(parts)-1] {
		if _, err := ParseDate("route_key", d); err != nil {
			return err
		}
	}
	if !Cabin(parts[len(parts)-1]).Valid() {
		return invalid("route_key", "cabina desconocida en %q", key)
	}
	return nil
}

// ParseSubscription lee una suscripción de ejemplo desde texto (variable de
// entorno SEED_SUBSCRIPTIONS) con el formato:
//
//	usuario|CLAVE_DE_RUTA                    -> sin precio objetivo
//	usuario|CLAVE_DE_RUTA|45000|EUR          -> avisar si baja de 450,00 €
//
// Se usa "|" como separador porque la clave de ruta ya contiene ":" y "-".
func ParseSubscription(raw string) (Subscription, error) {
	parts := strings.Split(strings.TrimSpace(raw), "|")
	if len(parts) != 2 && len(parts) != 4 {
		return Subscription{}, invalid("subscription", "formato usuario|CLAVE[|importe_minimo|DIVISA], se recibió %q", raw)
	}
	sub := Subscription{UserID: strings.TrimSpace(parts[0]), RouteKey: strings.TrimSpace(parts[1])}
	if len(parts) == 4 {
		amount, err := strconv.ParseInt(strings.TrimSpace(parts[2]), 10, 64)
		if err != nil {
			return Subscription{}, invalid("subscription.target", "importe no numérico %q (en céntimos, sin decimales)", parts[2])
		}
		sub.Target = &Money{Currency: strings.ToUpper(strings.TrimSpace(parts[3])), AmountMinor: amount}
	}
	if err := sub.Validate(); err != nil {
		return Subscription{}, err
	}
	return sub, nil
}

// ---------------------------------------------------------------------------
// Alertas: la oportunidad detectada para un usuario concreto
// ---------------------------------------------------------------------------

// AlertType es el motivo de una alerta (mismos valores que el enum del .proto).
type AlertType string

const (
	AlertPriceDrop     AlertType = "PRICE_DROP"     // bajada relevante frente a lo habitual
	AlertErrorFare     AlertType = "ERROR_FARE"     // precio absurdamente bajo: posible error de la aerolínea
	AlertTargetReached AlertType = "TARGET_REACHED" // se alcanzó el precio que pidió el usuario
)

// Alert es una oportunidad detectada para un usuario.
type Alert struct {
	ID              string // determinista: el mismo evento + usuario da siempre el mismo ID
	EventID         string
	UserID          string
	RouteKey        string
	Type            AlertType
	Reference       Money // con qué se compara (precio habitual u objetivo)
	Current         Money // precio actual
	DropBasisPoints int32 // 2500 = 25,00 % más barato que la referencia
	ObservedAt      time.Time
}

// PendingAlert es una alerta guardada que aún no se ha publicado en Kafka,
// junto con los datos de la observación que hacen falta para el evento.
type PendingAlert struct {
	Alert
	WatchID       string
	Origin        string
	Destination   string
	Departure     Date
	Cabin         Cabin
	DeepLink      string
	CorrelationID string
}

// ---------------------------------------------------------------------------
// Rutas (lo que el usuario elige vigilar desde la app)
// ---------------------------------------------------------------------------

// RouteSpec es una ruta concreta: de dónde a dónde, qué días y en qué clase.
// Su forma de texto es la clave de ruta (RouteKey).
type RouteSpec struct {
	Origin      string
	Destination string
	Departure   Date
	Return      *Date // nil = solo ida
	Cabin       Cabin
}

// Key devuelve la clave de ruta, idéntica a la del flight-ingestor.
func (s RouteSpec) Key() string {
	parts := []string{s.Origin + "-" + s.Destination, s.Departure.String()}
	if s.Return != nil {
		parts = append(parts, s.Return.String())
	}
	parts = append(parts, string(s.Cabin))
	return strings.Join(parts, ":")
}

// ParseRouteKey lee una clave como "MAD-NRT:2026-12-01:2026-12-15:ECONOMY".
// Además del formato, comprueba que tenga sentido: origen distinto del
// destino y vuelta no anterior a la ida.
func ParseRouteKey(key string) (RouteSpec, error) {
	if err := ValidateRouteKey(key); err != nil {
		return RouteSpec{}, err
	}
	parts := strings.Split(key, ":")
	airports := strings.Split(parts[0], "-")
	spec := RouteSpec{Origin: airports[0], Destination: airports[1], Cabin: Cabin(parts[len(parts)-1])}
	spec.Departure, _ = ParseDate("route_key", parts[1])
	if len(parts) == 4 {
		ret, _ := ParseDate("route_key", parts[2])
		spec.Return = &ret
	}
	if spec.Origin == spec.Destination {
		return RouteSpec{}, invalid("route_key", "origen y destino no pueden ser el mismo aeropuerto (%s)", spec.Origin)
	}
	if spec.Return != nil && spec.Return.Time().Before(spec.Departure.Time()) {
		return RouteSpec{}, invalid("route_key", "la vuelta no puede ser anterior a la ida")
	}
	return spec, nil
}

// ---------------------------------------------------------------------------
// Lo que ve la app (respuestas de la API de vuelos)
// ---------------------------------------------------------------------------

// Fare es el último precio visto de una ruta.
type Fare struct {
	Spec        RouteSpec
	Price       Money
	CarrierIATA string
	DeepLink    string
	ObservedAt  time.Time
}

// Deal es un precio de la portada "Cazador de vuelos": el último precio de
// una ruta comparado con lo que suele costar.
type Deal struct {
	Fare
	// Usual es la mediana del historial (0 si aún no hay bastantes datos).
	UsualMinor int64
	// DropBasisPoints: cuánto más barato que lo habitual (2500 = 25 %).
	DropBasisPoints int32
}

// Watch es una ruta que vigila el usuario, con su último precio (si lo hay).
type Watch struct {
	Spec      RouteSpec
	Target    *Money
	CreatedAt time.Time
	Latest    *Fare
}

// PricePoint es el precio más bajo visto en un día (para la gráfica).
type PricePoint struct {
	Day      Date
	MinMinor int64
}

// AlertView es una alerta ya enviada, para la lista de avisos de la app.
type AlertView struct {
	ID              string
	Spec            RouteSpec
	Type            AlertType
	Reference       Money
	Current         Money
	DropBasisPoints int32
	DeepLink        string
	ObservedAt      time.Time
}

// ---------------------------------------------------------------------------
// Buscador de vuelos ("de MAD a NRT, ida el 15, vuelta el 22, 2 adultos")
// ---------------------------------------------------------------------------

// MaxAdults es el máximo de viajeros por búsqueda.
const MaxAdults = 9

// ErrSearchBusy: el proveedor de precios pide frenar (mucha gente buscando a
// la vez). La app dice "inténtalo en unos segundos": la carga se degrada en
// lugar de costar dinero.
var ErrSearchBusy = errors.New("buscador: demasiadas búsquedas ahora mismo")

// Offer es una opción concreta de vuelo del buscador.
type Offer struct {
	PricePerAdult   Money
	Total           Money // para todos los viajeros
	CarrierIATA     string
	DepartureAt     string // RFC 3339, hora local del aeropuerto
	ReturnAt        string // "" si es solo ida
	Transfers       int
	ReturnTransfers int
	DurationMinutes int
	DeepLink        string
}

// SearchResult es la respuesta del buscador.
type SearchResult struct {
	Offers     []Offer
	ObservedAt time.Time
	Provider   string
}
