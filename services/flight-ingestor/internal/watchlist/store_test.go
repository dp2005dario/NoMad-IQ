// Tests del registro de seguimientos.

package watchlist

import (
	"errors"
	"fmt"
	"sync"
	"testing"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// spec es un ayudante que crea un WatchSpec desde su clave de texto.
func spec(t *testing.T, key string) domain.WatchSpec {
	t.Helper()
	s, err := domain.ParseWatchKey(key)
	if err != nil {
		t.Fatalf("ParseWatchKey(%q): %v", key, err)
	}
	return s
}

// Añadir dos veces la misma ruta devuelve el mismo ID y no duplica.
func TestAddIsIdempotent(t *testing.T) {
	store, err := New(10)
	if err != nil {
		t.Fatal(err)
	}
	first, existed, err := store.Add(spec(t, "MAD-NRT:2026-12-01:ECONOMY"))
	if err != nil || existed {
		t.Fatalf("primer Add: existed=%v err=%v", existed, err)
	}
	second, existed, err := store.Add(spec(t, "MAD-NRT:2026-12-01:ECONOMY"))
	if err != nil || !existed {
		t.Fatalf("segundo Add: existed=%v err=%v", existed, err)
	}
	if first.ID != second.ID {
		t.Fatalf("la misma ruta devolvió IDs distintos: %s vs %s", first.ID, second.ID)
	}
	if n := len(store.List()); n != 1 {
		t.Fatalf("List() tiene %d elementos, se esperaba 1", n)
	}
}

// Un seguimiento vacío se rechaza con un error de validación.
func TestAddRejectsInvalidSpec(t *testing.T) {
	store, _ := New(10)
	if _, _, err := store.Add(domain.WatchSpec{}); !domain.IsValidation(err) {
		t.Fatalf("se esperaba ValidationError, error = %v", err)
	}
}

// Con capacidad 1, el segundo seguimiento distinto debe rechazarse.
func TestCapacity(t *testing.T) {
	store, _ := New(1)
	if _, _, err := store.Add(spec(t, "MAD-NRT:2026-12-01:ECONOMY")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Add(spec(t, "MAD-JFK:2026-12-01:ECONOMY")); !errors.Is(err, ErrCapacity) {
		t.Fatalf("se esperaba ErrCapacity, error = %v", err)
	}
}

// Borrar funciona una vez; la segunda da ErrNotFound; y después la ruta se
// puede volver a añadir (con un ID nuevo).
func TestRemove(t *testing.T) {
	store, _ := New(10)
	w, _, _ := store.Add(spec(t, "MAD-NRT:2026-12-01:ECONOMY"))
	if err := store.Remove(w.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.Remove(w.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("se esperaba ErrNotFound, error = %v", err)
	}
	// Tras borrar, la misma ruta se puede volver a añadir con un ID nuevo.
	again, existed, err := store.Add(spec(t, "MAD-NRT:2026-12-01:ECONOMY"))
	if err != nil || existed || again.ID == w.ID {
		t.Fatalf("re-Add tras Remove: existed=%v err=%v id=%s", existed, err, again.ID)
	}
}

// 50 goroutines añadiendo y 50 leyendo a la vez. Ejecutado con -race, el
// detector de carreras de Go fallaría si el mutex no protegiera bien el mapa.
// Las 50 altas usan solo 28 fechas distintas, así que deben quedar 28 rutas.
func TestConcurrentAccess(t *testing.T) {
	store, _ := New(1000)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func(i int) {
			defer wg.Done()
			key := fmt.Sprintf("MAD-NRT:2026-12-%02d:ECONOMY", i%28+1)
			if _, _, err := store.Add(spec(t, key)); err != nil {
				t.Error(err)
			}
		}(i)
		go func() {
			defer wg.Done()
			_ = store.List()
		}()
	}
	wg.Wait()
	if n := len(store.List()); n != 28 {
		t.Fatalf("List() tiene %d elementos, se esperaban 28 rutas únicas", n)
	}
}
