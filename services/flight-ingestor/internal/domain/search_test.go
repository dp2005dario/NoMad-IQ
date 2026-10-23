package domain

import (
	"testing"
	"time"
)

func TestSearchSpecValidate(t *testing.T) {
	today := Today(time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC))
	trip := func(dep string) WatchSpec {
		s, err := ParseWatchKey("MAD-NRT:" + dep + ":ECONOMY")
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	cases := []struct {
		name  string
		spec  SearchSpec
		valid bool
	}{
		{"normal", SearchSpec{Trip: trip("2026-12-15"), Adults: 2}, true},
		{"ayer (margen de zona horaria)", SearchSpec{Trip: trip("2026-10-22"), Adults: 1}, true},
		{"pasado", SearchSpec{Trip: trip("2026-10-20"), Adults: 1}, false},
		{"más de un año", SearchSpec{Trip: trip("2027-12-01"), Adults: 1}, false},
		{"sin viajeros", SearchSpec{Trip: trip("2026-12-15"), Adults: 0}, false},
		{"demasiados", SearchSpec{Trip: trip("2026-12-15"), Adults: 10}, false},
	}
	for _, c := range cases {
		err := c.spec.Validate(today)
		if (err == nil) != c.valid {
			t.Errorf("%s: %v", c.name, err)
		}
		if err != nil && !IsValidation(err) {
			t.Errorf("%s: debe ser de validación: %v", c.name, err)
		}
	}
}
