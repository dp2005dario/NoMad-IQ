package watchsync

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sort"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

type fakeStore struct {
	keys    []string
	expired int64
}

func (f *fakeStore) SubscribedRouteKeys(context.Context, time.Time) ([]string, error) {
	return f.keys, nil
}

func (f *fakeStore) DeleteExpiredSubscriptions(context.Context, time.Time) (int64, error) {
	return f.expired, nil
}

type fakeIngestor struct {
	watches map[string]string // id → clave
	n       int
	failOn  string
}

func (f *fakeIngestor) Watch(_ context.Context, spec domain.RouteSpec) error {
	if spec.Key() == f.failOn {
		return errors.New("capacidad agotada")
	}
	f.n++
	f.watches["w"+string(rune('0'+f.n))] = spec.Key()
	return nil
}

func (f *fakeIngestor) List(context.Context) ([]Remote, error) {
	var out []Remote
	for id, k := range f.watches {
		out = append(out, Remote{ID: id, Key: k})
	}
	return out, nil
}

func (f *fakeIngestor) Unwatch(_ context.Context, id string) error {
	delete(f.watches, id)
	return nil
}

func (f *fakeIngestor) keys() []string {
	var out []string
	for _, k := range f.watches {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestPopularSpecsAreStableWithinAMonth(t *testing.T) {
	routes, err := ParseRoutes([]string{"mad-jfk", " BCN-LIS "})
	if err != nil {
		t.Fatal(err)
	}
	a := PopularSpecs(routes, time.Date(2026, 10, 3, 0, 0, 0, 0, time.UTC))
	b := PopularSpecs(routes, time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC))
	if len(a) != 4 || a[0].Key() != "MAD-JFK:2026-11-15:ECONOMY" || a[1].Key() != "MAD-JFK:2026-12-15:ECONOMY" {
		t.Errorf("fechas inesperadas: %v", a)
	}
	for i := range a {
		if a[i].Key() != b[i].Key() {
			t.Errorf("dentro del mismo mes las fechas no deben cambiar: %s vs %s", a[i].Key(), b[i].Key())
		}
	}
	for _, bad := range []string{"MADJFK", "MAD-MAD", "MA-JFK"} {
		if _, err := ParseRoutes([]string{bad}); err == nil {
			t.Errorf("%q debería ser inválida", bad)
		}
	}
}

func TestSyncAddsMissingAndPrunesOrphans(t *testing.T) {
	st := &fakeStore{keys: []string{"MAD-NRT:2026-12-01:ECONOMY"}, expired: 3}
	ing := &fakeIngestor{watches: map[string]string{
		"old": "MAD-CDG:2026-10-01:ECONOMY", // ya nadie la quiere
		"nrt": "MAD-NRT:2026-12-01:ECONOMY", // ya estaba: no se duplica
	}}
	s, err := New(Config{
		Interval: time.Minute,
		Popular:  []Route{{Origin: "MAD", Destination: "JFK"}},
		Prune:    true,
		Now:      func() time.Time { return time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC) },
	}, st, ing, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.syncOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"MAD-JFK:2026-11-15:ECONOMY", "MAD-JFK:2026-12-15:ECONOMY", "MAD-NRT:2026-12-01:ECONOMY"}
	got := ing.keys()
	if len(got) != len(want) {
		t.Fatalf("rutas en el ingestor: %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("rutas en el ingestor: %v, se esperaba %v", got, want)
		}
	}
	if res.Added != 2 || res.Removed != 1 || res.Expired != 3 {
		t.Errorf("resultado inesperado: %+v", res)
	}

	// Una segunda vuelta no hace nada (ya cuadra).
	if res, _ := s.syncOnce(context.Background()); res.Added != 0 || res.Removed != 0 {
		t.Errorf("segunda vuelta: %+v", res)
	}

	// Un fallo en una ruta no frena a las demás, y se informa.
	st.keys = append(st.keys, "MAD-LIS:2026-12-01:ECONOMY", "MAD-AMS:2026-12-01:ECONOMY")
	ing.failOn = "MAD-LIS:2026-12-01:ECONOMY"
	res, err = s.syncOnce(context.Background())
	if err == nil || res.Added != 1 {
		t.Errorf("con un fallo: res=%+v err=%v", res, err)
	}
}

func TestSyncWithoutPruneKeepsForeignWatches(t *testing.T) {
	ing := &fakeIngestor{watches: map[string]string{"x": "MAD-CDG:2026-12-01:ECONOMY"}}
	s, _ := New(Config{Interval: time.Minute}, &fakeStore{}, ing, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if _, err := s.syncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(ing.watches) != 1 {
		t.Errorf("sin Prune no se debe quitar nada: %v", ing.watches)
	}
}
