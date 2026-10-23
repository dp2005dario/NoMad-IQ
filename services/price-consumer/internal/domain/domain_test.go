package domain

import (
	"testing"
	"time"
)

func TestRouteKeyMatchesIngestorFormat(t *testing.T) {
	ret := Date{Year: 2026, Month: time.December, Day: 20}
	o := Observation{Origin: "BCN", Destination: "JFK", Departure: Date{Year: 2026, Month: time.December, Day: 10},
		Return: &ret, Cabin: CabinBusiness}
	// Mismo formato que domain.WatchSpec.Key() del flight-ingestor.
	if got := o.RouteKey(); got != "BCN-JFK:2026-12-10:2026-12-20:BUSINESS" {
		t.Errorf("RouteKey = %s", got)
	}
	o.Return = nil
	if got := o.RouteKey(); got != "BCN-JFK:2026-12-10:BUSINESS" {
		t.Errorf("RouteKey solo ida = %s", got)
	}
}

func TestValidateRouteKey(t *testing.T) {
	ok := []string{"MAD-NRT:2026-12-01:ECONOMY", "BCN-JFK:2026-12-10:2026-12-20:FIRST"}
	for _, k := range ok {
		if err := ValidateRouteKey(k); err != nil {
			t.Errorf("%s debería ser válida: %v", k, err)
		}
	}
	bad := []string{"", "MAD-NRT", "mad-NRT:2026-12-01:ECONOMY", "MAD-NRT:2026-02-30:ECONOMY",
		"MAD-NRT:2026-12-01:TURISTA", "MADNRT:2026-12-01:ECONOMY", "MAD-NRT:2026-12-01:2026-12-02:2026-12-03:ECONOMY"}
	for _, k := range bad {
		if err := ValidateRouteKey(k); err == nil || !IsValidation(err) {
			t.Errorf("%q debería ser inválida", k)
		}
	}
}

func TestParseSubscription(t *testing.T) {
	s, err := ParseSubscription(" ana | MAD-NRT:2026-12-01:ECONOMY | 45000 | eur ")
	if err != nil {
		t.Fatal(err)
	}
	if s.UserID != "ana" || s.RouteKey != "MAD-NRT:2026-12-01:ECONOMY" || s.Target == nil ||
		*s.Target != (Money{Currency: "EUR", AmountMinor: 45000}) {
		t.Errorf("suscripción mal leída: %+v", s)
	}
	s, err = ParseSubscription("luis|MAD-NRT:2026-12-01:ECONOMY")
	if err != nil || s.Target != nil {
		t.Errorf("sin objetivo: %+v, %v", s, err)
	}
	for _, raw := range []string{"ana", "ana|MAD-NRT:2026-12-01:ECONOMY|45000", "|MAD-NRT:2026-12-01:ECONOMY",
		"ana|MAD-NRT:2026-12-01:ECONOMY|450.00|EUR", "ana|MAD-NRT:2026-12-01:ECONOMY|-1|EUR", "ana|ruta-mala"} {
		if _, err := ParseSubscription(raw); err == nil {
			t.Errorf("%q debería rechazarse", raw)
		}
	}
}

func TestNewDateRejectsImpossibleDays(t *testing.T) {
	if _, err := NewDate("d", 2026, time.February, 29); err == nil {
		t.Error("2026 no es bisiesto")
	}
	if _, err := NewDate("d", 2028, time.February, 29); err != nil {
		t.Errorf("2028 sí es bisiesto: %v", err)
	}
}

func TestMoneyString(t *testing.T) {
	if got := (Money{Currency: "EUR", AmountMinor: 12905}).String(); got != "129.05 EUR" {
		t.Errorf("String = %s", got)
	}
}

func TestParseRouteKey(t *testing.T) {
	spec, err := ParseRouteKey("MAD-NRT:2026-12-01:2026-12-15:BUSINESS")
	if err != nil {
		t.Fatal(err)
	}
	if spec.Origin != "MAD" || spec.Destination != "NRT" || spec.Return == nil || spec.Cabin != CabinBusiness {
		t.Errorf("ruta mal leída: %+v", spec)
	}
	// Ida y vuelta: la clave se rehace idéntica.
	if got := spec.Key(); got != "MAD-NRT:2026-12-01:2026-12-15:BUSINESS" {
		t.Errorf("Key() = %q", got)
	}
	for _, bad := range []string{
		"MAD-MAD:2026-12-01:ECONOMY",            // mismo aeropuerto
		"MAD-NRT:2026-12-15:2026-12-01:ECONOMY", // vuelta antes que la ida
		"mad-nrt:2026-12-01:ECONOMY",            // minúsculas
		"MAD-NRT:2026-02-30:ECONOMY",            // día inexistente
		"MAD-NRT:ECONOMY",
	} {
		if _, err := ParseRouteKey(bad); err == nil {
			t.Errorf("%q debería ser inválida", bad)
		}
	}
}
