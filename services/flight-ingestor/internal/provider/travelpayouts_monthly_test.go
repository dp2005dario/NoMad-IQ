package provider

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

const months = `{"success":true,"currency":"eur","data":{
 "2027-03":{"origin":"MAD","destination":"NRT","price":512,"airline":"qr","transfers":1,"departure_at":"2027-03-11T10:05:00+01:00","return_at":"2027-03-20T12:00:00+09:00"},
 "2026-11":{"origin":"MAD","destination":"NRT","price":640,"airline":"IB","transfers":0,"departure_at":"2026-11-05T10:05:00+01:00","return_at":"2026-11-12T12:00:00+09:00"},
 "2026-09":{"price":100,"departure_at":"2026-09-05"},
 "2028-01":{"price":100,"departure_at":"2028-01-05"},
 "2027-04":{"price":300,"departure_at":"2027-05-01"},
 "2027-05":{"price":-3,"departure_at":"2027-05-01"},
 "basura":{"price":1,"departure_at":"2027-06-01"}
}}`

func TestTravelpayoutsMonthlyKeepsTheNextTwelveMonthsWithOurMarker(t *testing.T) {
	api := &fakeAPI{body: months}
	tp := newTP(t, api)
	tp.now = func() time.Time { return time.Date(2026, 10, 24, 0, 0, 0, 0, time.UTC) }
	route := domain.Route{Origin: "MAD", Destination: "NRT"}
	got, err := tp.Monthly(context.Background(), route)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("meses = %+v, se esperaban 2 (nov-26 y mar-27)", got)
	}
	if got[0].Month != time.November || got[1].Month != time.March || got[1].Year != 2027 {
		t.Errorf("orden: %+v", got)
	}
	m := got[1]
	if m.PricePerAdult.AmountMinor != 51200 || m.CarrierIATA != "QR" || m.Transfers != 1 {
		t.Errorf("mes: %+v", m)
	}
	if m.DeepLink != "https://www.aviasales.com/search/MAD1103NRT20031?marker=123456" {
		t.Errorf("enlace: %s", m.DeepLink)
	}
	// El token va en la cabecera, nunca en la URL.
	if api.last.Header.Get("X-Access-Token") != "tok-secreto" || strings.Contains(api.last.URL.String(), "tok") {
		t.Errorf("token mal enviado: %s", api.last.URL)
	}
	if api.last.URL.Path != "/v1/prices/monthly" || api.last.URL.Query().Get("currency") != "eur" {
		t.Errorf("petición: %s", api.last.URL)
	}
}

func TestTravelpayoutsMonthlyErrors(t *testing.T) {
	route := domain.Route{Origin: "MAD", Destination: "NRT"}
	tp := newTP(t, &fakeAPI{status: 429})
	if _, err := tp.Monthly(context.Background(), route); err != ErrRateLimited {
		t.Errorf("429 → %v", err)
	}
	tp = newTP(t, &fakeAPI{body: `{"success":false,"error":"nope"}`})
	if _, err := tp.Monthly(context.Background(), route); err == nil {
		t.Error("success=false debería fallar")
	}
}

func TestSimulatedMonthlyGivesAYearWithSummerDearer(t *testing.T) {
	s := NewSimulated(1, 0, 0)
	s.now = func() time.Time { return time.Date(2026, 10, 24, 0, 0, 0, 0, time.UTC) }
	got, err := s.Monthly(context.Background(), domain.Route{Origin: "MAD", Destination: "NRT"})
	if err != nil || len(got) != domain.MaxMonths {
		t.Fatalf("%v %d", err, len(got))
	}
	byMonth := map[time.Month]int64{}
	for _, m := range got {
		byMonth[m.Month] = m.PricePerAdult.AmountMinor
	}
	if byMonth[time.August] <= byMonth[time.February] {
		t.Errorf("agosto %d no es más caro que febrero %d", byMonth[time.August], byMonth[time.February])
	}
}
