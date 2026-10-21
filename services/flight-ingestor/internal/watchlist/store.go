// Package watchlist guarda en memoria las rutas que el ingestor vigila.
//
// Es seguro para uso concurrente: el servidor gRPC escribe mientras los
// workers del ingestor leen. Más adelante se respaldará en PostgreSQL
// (esquema "flights") para sobrevivir a reinicios; la interfaz no cambiará.
package watchlist

import (
	"errors"
	"fmt"
	"sort"
	"sync"

	"github.com/google/uuid"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

var (
	// ErrNotFound: no existe un seguimiento con ese identificador.
	ErrNotFound = errors.New("seguimiento no encontrado")
	// ErrCapacity: se alcanzó el máximo configurado. Evita que un cliente
	// agote la memoria del servicio creando seguimientos sin fin.
	ErrCapacity = errors.New("límite de seguimientos alcanzado")
)

// Store es el registro en memoria de seguimientos.
type Store struct {
	mu      sync.RWMutex
	max     int
	byID    map[string]domain.Watch
	idByKey map[string]string
}

// New crea un Store que admite como mucho max seguimientos.
func New(max int) (*Store, error) {
	if max <= 0 {
		return nil, fmt.Errorf("watchlist: max debe ser positivo, se recibió %d", max)
	}
	return &Store{max: max, byID: make(map[string]domain.Watch), idByKey: make(map[string]string)}, nil
}

// Add registra un seguimiento. Es idempotente: si ya existe uno con la misma
// clave natural devuelve ese y existed=true.
func (s *Store) Add(spec domain.WatchSpec) (watch domain.Watch, existed bool, err error) {
	if err := spec.Validate(); err != nil {
		return domain.Watch{}, false, err
	}
	key := spec.Key()

	s.mu.Lock()
	defer s.mu.Unlock()

	if id, ok := s.idByKey[key]; ok {
		return s.byID[id], true, nil
	}
	if len(s.byID) >= s.max {
		return domain.Watch{}, false, fmt.Errorf("%w (%d)", ErrCapacity, s.max)
	}
	watch = domain.Watch{ID: uuid.NewString(), Spec: spec}
	s.byID[watch.ID] = watch
	s.idByKey[key] = watch.ID
	return watch, false, nil
}

// Remove borra un seguimiento por su identificador.
func (s *Store) Remove(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	watch, ok := s.byID[id]
	if !ok {
		return fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	delete(s.byID, id)
	delete(s.idByKey, watch.Spec.Key())
	return nil
}

// List devuelve una copia ordenada por clave, para resultados deterministas.
func (s *Store) List() []domain.Watch {
	s.mu.RLock()
	out := make([]domain.Watch, 0, len(s.byID))
	for _, w := range s.byID {
		out = append(out, w)
	}
	s.mu.RUnlock()

	sort.Slice(out, func(i, j int) bool { return out[i].Spec.Key() < out[j].Spec.Key() })
	return out
}
