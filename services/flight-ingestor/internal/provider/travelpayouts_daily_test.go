package provider

import (
	"context"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

const days = `{"success":true,"currency":"eur","data":{
 "2026-11-12":{"price":389,"airline":"tk","transfers":1,"departure_at":"2026-11-12T10:05:00+01:00","return_at":"2026-11-26T12:00:00+09:00"},
 "2026-11-02":{"price":402,"airline":"IB","transfers":0,"departure_at":"2026-11-02T10:05:00+01:00"},
 "2026-10-30":{"price":100,"departure_at":"2026-10-30"},
 "2026-12-01":{"price":100,"departure_at":"2026-12-01"},
 "2026-11-20":{"price":300,"departure_at":"2026-11-21"},
 "2026-11-21":{"price":-3,"departure_at":"2026-11-21"},
 "basura":{"price":1,"departure_at":"2026-11-22"}
}}`

func TestTravelpayoutsDailyKeepsTheDaysOfThatMonth(t *testing.T) {
	api := &fakeAPI{body: days}
	tp := newTP(t, api)
	tp.now = func() time.Time { return time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC) }
	route := domain.Route{Origin: "MAD", Destination: "HND"}
	got, err := tp.Daily(context.Background(), route, time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Date.Day() != 2 || got[1].Date.Day() != 12 {
		t.Fatalf("días = %+v, se esperaban el 2 y el 12", got)
	}
	d := got[1]
	if d.PricePerAdult.AmountMinor != 38900 || d.CarrierIATA != "TK" || d.Transfers != 1 {
		t.Errorf("día: %+v", d)
	}
	if d.DeepLink != "https://www.aviasales.com/search/MAD1211HND26111?marker=123456" {
		t.Errorf("enlace: %s", d.DeepLink)
	}
	q := api.last.URL.Query()
	if api.last.URL.Path != "/aviasales/v3/grouped_prices" || q.Get("departure_at") != "2026-11" ||
		q.Get("group_by") != "departure_at" || q.Get("one_way") != "false" {
		t.Errorf("petición: %s", api.last.URL)
	}
	if api.last.Header.Get("X-Access-Token") != "tok-secreto" {
		t.Error("el token va en la cabecera")
	}
}

func TestTravelpayoutsDailyOneWayHasNoReturn(t *testing.T) {
	tp := newTP(t, &fakeAPI{body: days})
	tp.now = func() time.Time { return time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC) }
	got, err := tp.Daily(context.Background(), domain.Route{Origin: "MAD", Destination: "HND"},
		time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), true)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range got {
		if d.ReturnAt != "" {
			t.Errorf("solo ida con vuelta: %+v", d)
		}
	}
	if got[1].DeepLink != "https://www.aviasales.com/search/MAD1211HND1?marker=123456" {
		t.Errorf("enlace: %s", got[1].DeepLink)
	}
}

func TestTravelpayoutsDailyErrors(t *testing.T) {
	route := domain.Route{Origin: "MAD", Destination: "HND"}
	month := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	tp := newTP(t, &fakeAPI{status: 429})
	if _, err := tp.Daily(context.Background(), route, month, true); err != ErrRateLimited {
		t.Errorf("429 → %v", err)
	}
	tp = newTP(t, &fakeAPI{body: `{"success":false,"error":"nope"}`})
	if _, err := tp.Daily(context.Background(), route, month, true); err == nil {
		t.Error("success=false debería fallar")
	}
}

func TestSimulatedDailyFromTodayOn(t *testing.T) {
	s := NewSimulated(1, 0, 0)
	s.now = func() time.Time { return time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC) }
	got, err := s.Daily(context.Background(), domain.Route{Origin: "MAD", Destination: "HND"},
		time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), true)
	if err != nil || len(got) != 11 || got[0].Date.Day() != 20 {
		t.Fatalf("%v %+v", err, got)
	}
}
