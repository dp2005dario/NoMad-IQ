package domain

// Tipos del BUSCADOR de vuelos: "de MAD a NRT, ida el 15, vuelta el 22,
// para 2 adultos". Se diferencia de un seguimiento (WatchSpec) en que lleva
// el número de viajeros y en que se responde al momento con varias ofertas.

import (
	"errors"
	"time"
)

// MaxAdults es el máximo de viajeros por búsqueda (como en las aerolíneas:
// los grupos más grandes se reservan por otro canal).
const MaxAdults = 9

// MaxSearchDaysAhead: las aerolíneas venden billetes como mucho ~1 año antes.
const MaxSearchDaysAhead = 365

// SearchSpec es lo que pide el viajero en el buscador.
type SearchSpec struct {
	Trip   WatchSpec // ruta, fechas y cabina (mismas reglas que un seguimiento)
	Adults int
}

// Validate aplica las reglas del buscador. today es "hoy" en UTC (se pasa
// desde fuera para que los tests no dependan del reloj).
func (s SearchSpec) Validate(today Date) error {
	var errs []error
	if err := s.Trip.Validate(); err != nil {
		errs = append(errs, err)
	}
	if s.Adults < 1 || s.Adults > MaxAdults {
		errs = append(errs, invalid("adults", "entre 1 y %d, se recibió %d", MaxAdults, s.Adults))
	}
	if !s.Trip.Departure.IsZero() {
		dep := s.Trip.Departure.Time()
		switch {
		// Un día de margen: cuando en UTC ya es mañana, en Hawái aún es hoy.
		case dep.Before(today.Time().AddDate(0, 0, -1)):
			errs = append(errs, invalid("departure_date", "ya ha pasado (%s)", s.Trip.Departure))
		case dep.After(today.Time().AddDate(0, 0, MaxSearchDaysAhead)):
			errs = append(errs, invalid("departure_date", "demasiado lejana (máximo %d días)", MaxSearchDaysAhead))
		}
	}
	return errors.Join(errs...)
}

// Today devuelve la fecha de hoy (UTC) como Date.
func Today(now time.Time) Date {
	y, m, d := now.UTC().Date()
	return Date{Year: y, Month: m, Day: d}
}

// Offer es una opción concreta de vuelo encontrada por el buscador.
type Offer struct {
	PricePerAdult   Money
	CarrierIATA     string // "" si no se sabe
	DepartureAt     string // RFC 3339 con la hora local del aeropuerto
	ReturnAt        string // "" si es solo ida
	Transfers       int    // escalas de la ida (0 = directo)
	ReturnTransfers int
	DurationMinutes int    // 0 si no se sabe
	DeepLink        string // enlace https de reserva, con el código de afiliado
}

// Total es el precio para todos los viajeros.
func (o Offer) Total(adults int) Money {
	return Money{Currency: o.PricePerAdult.Currency, AmountMinor: o.PricePerAdult.AmountMinor * int64(adults)}
}
