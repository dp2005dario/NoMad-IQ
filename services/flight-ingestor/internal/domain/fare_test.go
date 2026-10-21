package domain

import (
	"testing"
	"time"
)

func mustDate(t *testing.T, raw string) Date {
	t.Helper()
	d, err := ParseDate("date", raw)
	if err != nil {
		t.Fatalf("ParseDate(%q): %v", raw, err)
	}
	return d
}

func TestParseAirport(t *testing.T) {
	tests := []struct {
		in      string
		want    Airport
		wantErr bool
	}{
		{in: "MAD", want: "MAD"},
		{in: " nrt ", want: "NRT"},
		{in: "MA", wantErr: true},
		{in: "MADR", wantErr: true},
		{in: "M4D", wantErr: true},
		{in: "", wantErr: true},
	}
	for _, tt := range tests {
		got, err := ParseAirport("origin", tt.in)
		if tt.wantErr {
			if !IsValidation(err) {
				t.Errorf("ParseAirport(%q): se esperaba ValidationError, error = %v", tt.in, err)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("ParseAirport(%q) = %q, %v; se esperaba %q", tt.in, got, err, tt.want)
		}
	}
}

func TestNewDateRejectsImpossibleDates(t *testing.T) {
	if _, err := NewDate("d", 2026, time.February, 30); !IsValidation(err) {
		t.Fatalf("30 de febrero debería ser inválido, error = %v", err)
	}
	if _, err := NewDate("d", 2028, time.February, 29); err != nil {
		t.Fatalf("29/02/2028 es bisiesto y válido: %v", err)
	}
}

func TestWatchSpecValidate(t *testing.T) {
	dep := mustDate(t, "2026-12-01")
	before := mustDate(t, "2026-11-20")
	valid := WatchSpec{Route: Route{Origin: "MAD", Destination: "NRT"}, Departure: dep, Cabin: CabinEconomy}

	tests := []struct {
		name    string
		mutate  func(*WatchSpec)
		wantErr bool
	}{
		{name: "válido", mutate: func(*WatchSpec) {}},
		{name: "mismo origen y destino", mutate: func(s *WatchSpec) { s.Route.Destination = "MAD" }, wantErr: true},
		{name: "sin fecha", mutate: func(s *WatchSpec) { s.Departure = Date{} }, wantErr: true},
		{name: "vuelta antes que ida", mutate: func(s *WatchSpec) { s.Return = &before }, wantErr: true},
		{name: "sin cabina", mutate: func(s *WatchSpec) { s.Cabin = CabinUnspecified }, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			spec := valid
			tt.mutate(&spec)
			err := spec.Validate()
			if tt.wantErr != (err != nil) {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil && !IsValidation(err) {
				t.Fatalf("el error debería ser de validación: %v", err)
			}
		})
	}
}

func TestWatchKeyRoundTrip(t *testing.T) {
	for _, key := range []string{
		"MAD-NRT:2026-12-01:ECONOMY",
		"BCN-JFK:2026-12-01:2026-12-15:BUSINESS",
	} {
		spec, err := ParseWatchKey(key)
		if err != nil {
			t.Fatalf("ParseWatchKey(%q): %v", key, err)
		}
		if got := spec.Key(); got != key {
			t.Errorf("Key() = %q, se esperaba %q", got, key)
		}
	}
}

func TestParseWatchKeyErrors(t *testing.T) {
	for _, key := range []string{"", "MAD:2026-12-01:ECONOMY", "MAD-NRT:2026-13-01:ECONOMY", "MAD-NRT:2026-12-01:SOFA", "MAD-MAD:2026-12-01:ECONOMY"} {
		if _, err := ParseWatchKey(key); !IsValidation(err) {
			t.Errorf("ParseWatchKey(%q) debería fallar con ValidationError, error = %v", key, err)
		}
	}
}

func TestPriceObservationValidate(t *testing.T) {
	spec, err := ParseWatchKey("MAD-NRT:2026-12-01:ECONOMY")
	if err != nil {
		t.Fatal(err)
	}
	obs := PriceObservation{
		Watch:    Watch{ID: "w1", Spec: spec},
		Provider: "simulated",
		Quote:    Quote{Price: Money{Currency: "EUR", AmountMinor: 54900}, ObservedAt: time.Now()},
	}
	if err := obs.Validate(); err != nil {
		t.Fatalf("observación válida rechazada: %v", err)
	}
	obs.Quote.Price.AmountMinor = 0
	obs.Quote.Price.Currency = "eur"
	if err := obs.Validate(); !IsValidation(err) {
		t.Fatalf("precio 0 y divisa en minúsculas deberían fallar, error = %v", err)
	}
}
