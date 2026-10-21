//go:build integration

// Tests contra un PostgreSQL REAL. No se ejecutan con "go test ./..." normal
// (gracias a la etiqueta "integration" de la primera línea), sino con:
//
//	PGHOST=localhost PGUSER=... PGPASSWORD=... PGDATABASE=... go test -tags integration ./internal/store/
//
// En la CI se lanzan contra el PostgreSQL de docker compose.
package store

import (
	"context"
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/processor"
)

func openTestDB(t *testing.T) *Postgres {
	t.Helper()
	port, _ := strconv.Atoi(os.Getenv("PGPORT"))
	if port == 0 {
		port = 5432
	}
	sslmode := os.Getenv("PGSSLMODE")
	if sslmode == "" {
		sslmode = "disable"
	}
	cfg := Config{Host: os.Getenv("PGHOST"), Port: port, User: os.Getenv("PGUSER"), Password: os.Getenv("PGPASSWORD"),
		Database: os.Getenv("PGDATABASE"), SSLMode: sslmode, MaxConns: 4}
	if cfg.Host == "" {
		t.Skip("PGHOST no definido: se omiten los tests de integración con PostgreSQL")
	}
	ctx := context.Background()
	db, err := Open(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	return db
}

// uniqueRoute devuelve una ruta distinta en cada test, para que los datos de
// un test no interfieran con los de otro (la base de datos se comparte).
func uniqueRoute(t *testing.T) (origin, destination string, departure domain.Date) {
	t.Helper()
	n := time.Now().UnixNano()
	letters := func(v int64) string {
		return string([]byte{byte('A' + v%26), byte('A' + (v/26)%26), byte('A' + (v/676)%26)})
	}
	origin, destination = letters(n), letters(n/17576+1)
	if origin == destination { // origen y destino iguales los rechaza la base de datos
		destination = letters(n/17576 + 2)
	}
	return origin, destination, domain.Date{Year: 2027, Month: time.Month(1 + n%12), Day: 1 + int(n%28)}
}

func observation(origin, destination string, dep domain.Date, amount int64, at time.Time) domain.Observation {
	return domain.Observation{
		EventID: uuid.NewString(), Origin: origin, Destination: destination, Departure: dep,
		Cabin: domain.CabinEconomy, Price: domain.Money{Currency: "EUR", AmountMinor: amount},
		Provider: "test", ObservedAt: at, DeepLink: "https://example.invalid", WatchID: "w1",
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	db := openTestDB(t)
	n, err := db.Migrate(context.Background())
	if err != nil || n != 0 {
		t.Fatalf("la segunda migración no debe aplicar nada: n=%d err=%v", n, err)
	}
}

func TestObservationsHistoryAndDuplicates(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	origin, dest, dep := uniqueRoute(t)
	t0 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)

	first := observation(origin, dest, dep, 50000, t0)
	err := db.InTx(ctx, func(tx processor.Tx) error {
		for i, amount := range []int64{50000, 51000, 52000} {
			o := observation(origin, dest, dep, amount, t0.Add(time.Duration(i)*time.Hour))
			if i == 0 {
				o = first
			}
			if ok, err := tx.InsertObservation(ctx, o, 1, int64(i)); err != nil || !ok {
				return errors.Join(err, errors.New("inserción fallida"))
			}
		}
		// Mismo event_id otra vez: debe detectarse como duplicado sin error.
		if ok, err := tx.InsertObservation(ctx, first, 1, 99); err != nil || ok {
			t.Errorf("duplicado no detectado: ok=%v err=%v", ok, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	_ = db.InTx(ctx, func(tx processor.Tx) error {
		prices, err := tx.RecentPrices(ctx, first.RouteKey(), "EUR", t0, t0.Add(2*time.Hour), 10)
		if err != nil {
			t.Fatal(err)
		}
		// [since, before): la observación de las 2h queda fuera; orden descendente.
		if len(prices) != 2 || prices[0] != 51000 || prices[1] != 50000 {
			t.Errorf("historial = %v, quería [51000 50000]", prices)
		}
		if usd, _ := tx.RecentPrices(ctx, first.RouteKey(), "USD", t0, t0.Add(time.Hour*5), 10); len(usd) != 0 {
			t.Errorf("no debe mezclar divisas: %v", usd)
		}
		return nil
	})
}

func TestRollbackOnError(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	origin, dest, dep := uniqueRoute(t)
	o := observation(origin, dest, dep, 50000, time.Now().UTC())
	boom := errors.New("fallo a mitad")
	err := db.InTx(ctx, func(tx processor.Tx) error {
		if _, err := tx.InsertObservation(ctx, o, 0, 0); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("esperaba el error original, obtuve %v", err)
	}
	// Tras el rollback la observación NO debe existir: se puede insertar de nuevo.
	_ = db.InTx(ctx, func(tx processor.Tx) error {
		ok, err := tx.InsertObservation(ctx, o, 0, 0)
		if err != nil || !ok {
			t.Errorf("el rollback no deshizo la inserción: ok=%v err=%v", ok, err)
		}
		return nil
	})
}

func TestConstraintViolationIsValidationError(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	origin, dest, dep := uniqueRoute(t)
	o := observation(origin, dest, dep, -1, time.Now().UTC()) // precio negativo: lo frena el CHECK
	err := db.InTx(ctx, func(tx processor.Tx) error {
		_, err := tx.InsertObservation(ctx, o, 0, 0)
		return err
	})
	if !domain.IsValidation(err) {
		t.Fatalf("una restricción violada debe ser error de validación (DLQ), obtuve %v", err)
	}
}

func TestSubscriptionsAlertsAndOutbox(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	origin, dest, dep := uniqueRoute(t)
	at := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	o := observation(origin, dest, dep, 15000, at)
	key := o.RouteKey()

	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: "ana", RouteKey: key}); err != nil {
		t.Fatal(err)
	}
	target := &domain.Money{Currency: "EUR", AmountMinor: 45000}
	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: "luis", RouteKey: key, Target: target}); err != nil {
		t.Fatal(err)
	}
	// Upsert: repetir actualiza en vez de fallar.
	if err := db.UpsertSubscription(ctx, domain.Subscription{UserID: "ana", RouteKey: key}); err != nil {
		t.Fatal(err)
	}

	alert := domain.Alert{
		ID: uuid.NewString(), EventID: o.EventID, UserID: "ana", RouteKey: key, Type: domain.AlertErrorFare,
		Reference: domain.Money{Currency: "EUR", AmountMinor: 50000}, Current: o.Price,
		DropBasisPoints: 7000, ObservedAt: at,
	}
	err := db.InTx(ctx, func(tx processor.Tx) error {
		subs, err := tx.Subscriptions(ctx, key)
		if err != nil {
			return err
		}
		if len(subs) != 2 || subs[0].UserID != "ana" || subs[0].Target != nil || subs[1].Target == nil || *subs[1].Target != *target {
			t.Errorf("suscripciones = %+v", subs)
		}
		if _, err := tx.InsertObservation(ctx, o, 0, 0); err != nil {
			return err
		}
		if err := tx.InsertAlerts(ctx, []domain.Alert{alert}); err != nil {
			return err
		}
		// Reinsertar la misma alerta no debe fallar ni duplicar (idempotencia).
		if err := tx.InsertAlerts(ctx, []domain.Alert{alert}); err != nil {
			return err
		}
		recent, err := tx.RecentlyAlerted(ctx, key, "EUR", at.Add(-time.Hour))
		if err != nil {
			return err
		}
		if recent["ana"] != 15000 || len(recent) != 1 {
			t.Errorf("alertas recientes = %v", recent)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Outbox: si publicar falla, la alerta sigue pendiente.
	_, err = db.ClaimPending(ctx, 1000, func(p []domain.PendingAlert) error { return errors.New("kafka caído") })
	if err == nil {
		t.Fatal("esperaba el error de publicación")
	}
	var got *domain.PendingAlert
	_, err = db.ClaimPending(ctx, 1000, func(p []domain.PendingAlert) error {
		for i := range p {
			if p[i].ID == alert.ID {
				got = &p[i]
			}
		}
		return nil
	})
	if err != nil || got == nil {
		t.Fatalf("la alerta debía seguir pendiente tras el fallo: %v", err)
	}
	if got.Origin != origin || got.Departure != dep || got.Cabin != domain.CabinEconomy || got.Type != domain.AlertErrorFare ||
		got.Current.AmountMinor != 15000 || got.Reference.Currency != "EUR" || got.WatchID != "w1" || !got.ObservedAt.Equal(at) {
		t.Errorf("alerta pendiente mal leída: %+v", got)
	}
	// Ya publicada: no debe volver a salir.
	_, _ = db.ClaimPending(ctx, 1000, func(p []domain.PendingAlert) error {
		for _, a := range p {
			if a.ID == alert.ID {
				t.Error("una alerta ya publicada no debe volver a reclamarse")
			}
		}
		return nil
	})
}
