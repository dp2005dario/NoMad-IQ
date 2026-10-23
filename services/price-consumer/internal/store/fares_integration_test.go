//go:build integration

package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/processor"
)

// Las consultas de la API de vuelos contra un PostgreSQL de verdad.
func TestFaresQueries(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	origin, destination, _ := uniqueRoute(t)
	// Fecha futura: los chollos de vuelos que ya salieron no se enseñan.
	dep := domain.Date{Year: time.Now().Year() + 1, Month: 3, Day: 15}
	now := time.Now().UTC().Truncate(time.Second)

	// Historial: 4 precios normales hace días y un chollo ahora.
	var latest domain.Observation
	err := db.InTx(ctx, func(tx processor.Tx) error {
		for i, amount := range []int64{100_000, 102_000, 98_000, 100_000} {
			o := observation(origin, destination, dep, amount, now.Add(-time.Duration(48+i)*time.Hour))
			if _, err := tx.InsertObservation(ctx, o, 0, int64(i)); err != nil {
				return err
			}
		}
		latest = observation(origin, destination, dep, 40_000, now)
		_, err := tx.InsertObservation(ctx, latest, 0, 9)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	key := latest.RouteKey()

	deals, err := db.Deals(ctx, origin, now.Add(-time.Hour), 30*24*time.Hour, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(deals) != 1 || deals[0].Price.AmountMinor != 40_000 || deals[0].UsualMinor != 100_000 || deals[0].Spec.Key() != key {
		t.Fatalf("chollos inesperados: %+v", deals)
	}

	user := "fares-" + origin + destination
	target := &domain.Money{Currency: "EUR", AmountMinor: 50_000}
	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: user, RouteKey: key, Target: target}); err != nil {
		t.Fatal(err)
	}
	watches, err := db.Watches(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	if len(watches) != 1 || watches[0].Target == nil || watches[0].Latest == nil || watches[0].Latest.Price.AmountMinor != 40_000 {
		t.Fatalf("seguimientos inesperados: %+v", watches)
	}

	keys, err := db.SubscribedRouteKeys(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, k := range keys {
		found = found || k == key
	}
	if !found {
		t.Errorf("la ruta vigilada no aparece para el ingestor: %v", keys)
	}

	currency, points, err := db.History(ctx, key, now.Add(-30*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if currency != "EUR" || len(points) < 2 || points[len(points)-1].MinMinor != 40_000 {
		t.Errorf("historial inesperado: %s %+v", currency, points)
	}

	if err := db.DeleteSubscription(ctx, user, key); err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteSubscription(ctx, user, key); !errors.Is(err, ErrNotFound) {
		t.Errorf("borrar dos veces: %v", err)
	}

	// Una suscripción a un vuelo que ya salió se borra sola.
	past := observation(origin, destination, domain.Date{Year: 2020, Month: 1, Day: 1}, 1, now).RouteKey()
	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: user, RouteKey: past}); err != nil {
		t.Fatal(err)
	}
	if n, err := db.DeleteExpiredSubscriptions(ctx, now); err != nil || n < 1 {
		t.Errorf("caducadas: n=%d err=%v", n, err)
	}

	alerts, err := db.Alerts(ctx, user, 10)
	if err != nil || len(alerts) != 0 {
		t.Errorf("alertas: %v %v", alerts, err)
	}
}
