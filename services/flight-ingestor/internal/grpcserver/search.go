package grpcserver

// SearchService: el BUSCADOR de vuelos por gRPC.
//
// Para aguantar millones de usuarios SIN pagar más al proveedor, cada
// búsqueda pasa por dos filtros antes de llegar a Travelpayouts:
//
//  1. Caché (SEARCH_CACHE_TTL, 10 min): si alguien buscó lo mismo hace poco,
//     se responde con lo guardado. "Madrid-Tokio el 15 de diciembre" lo
//     buscan miles de personas: solo la primera cuesta una petición.
//  2. "singleflight": si 500 personas buscan lo mismo A LA VEZ (y aún no
//     está en caché), solo sale UNA petición; las otras 499 esperan su
//     respuesta y la comparten.
//
// Si aun así el proveedor pide frenar, se responde RESOURCE_EXHAUSTED y la
// app dice "mucha gente buscando, inténtalo en unos segundos": la carga se
// degrada, no se dispara la factura.

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/protomap"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/provider"
)

// MaxOffers es cuántas ofertas se devuelven como mucho por búsqueda.
const MaxOffers = 20

// SearchConfig son los límites del buscador.
type SearchConfig struct {
	CacheTTL     time.Duration // 0 = sin caché
	CacheEntries int           // búsquedas que se recuerdan como mucho
	Timeout      time.Duration // espera máxima al proveedor
}

// SearchService implementa flightsv1.FareSearchServiceServer.
type SearchService struct {
	flightsv1.UnimplementedFareSearchServiceServer
	cfg      SearchConfig
	searcher provider.Searcher
	log      *slog.Logger
	now      func() time.Time

	flight singleflight.Group
	mu     sync.Mutex
	cache  map[string]cached
}

type cached struct {
	offers   []domain.Offer
	observed time.Time
	expires  time.Time
}

// NewSearchService crea el buscador.
func NewSearchService(cfg SearchConfig, searcher provider.Searcher, log *slog.Logger) *SearchService {
	return &SearchService{
		cfg: cfg, searcher: searcher, log: log, now: time.Now,
		cache: make(map[string]cached),
	}
}

// SearchFares implementa el RPC del mismo nombre.
func (s *SearchService) SearchFares(ctx context.Context, req *flightsv1.SearchFaresRequest) (*flightsv1.SearchFaresResponse, error) {
	trip, err := protomap.SpecFromProto(req.GetRoute(), req.GetDepartureDate(), req.GetReturnDate(), req.GetCabin())
	if err != nil {
		return nil, toStatus(err)
	}
	spec := domain.SearchSpec{Trip: trip, Adults: int(req.GetAdults())}
	if err := spec.Validate(domain.Today(s.now())); err != nil {
		return nil, toStatus(err)
	}
	key := trip.Key() + "|" + strconv.Itoa(spec.Adults)

	entry, ok := s.lookup(key)
	if !ok {
		// Do junta las peticiones iguales que llegan a la vez. Se usa un
		// contexto propio (no el de este cliente): si el primero en llegar
		// cuelga, los demás que esperan la misma respuesta no deben perderla.
		v, err, _ := s.flight.Do(key, func() (any, error) {
			if e, ok := s.lookup(key); ok {
				return e, nil
			}
			fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), s.cfg.Timeout)
			defer cancel()
			offers, err := s.searcher.Search(fetchCtx, spec, MaxOffers)
			if err != nil {
				return nil, err
			}
			e := cached{offers: offers, observed: s.now().UTC()}
			s.store(key, e)
			return e, nil
		})
		if err != nil {
			return nil, s.searchStatus(err)
		}
		entry = v.(cached)
	}

	out := make([]*flightsv1.FareOffer, len(entry.offers))
	for i, o := range entry.offers {
		out[i] = &flightsv1.FareOffer{
			PricePerAdult:   protomap.MoneyToProto(o.PricePerAdult),
			Total:           protomap.MoneyToProto(o.Total(spec.Adults)),
			CarrierIata:     o.CarrierIATA,
			DepartureAt:     o.DepartureAt,
			ReturnAt:        o.ReturnAt,
			Transfers:       int32(o.Transfers),
			ReturnTransfers: int32(o.ReturnTransfers),
			DurationMinutes: int32(o.DurationMinutes),
			BookingUrl:      o.DeepLink,
		}
	}
	return &flightsv1.SearchFaresResponse{
		Offers:     out,
		ObservedAt: timestamppb.New(entry.observed),
		Provider:   s.searcher.Name(),
	}, nil
}

// searchStatus traduce los errores del proveedor a códigos gRPC.
func (s *SearchService) searchStatus(err error) error {
	switch {
	case errors.Is(err, provider.ErrRateLimited):
		return status.Error(codes.ResourceExhausted, "demasiadas búsquedas ahora mismo: inténtalo en unos segundos")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "el proveedor de precios tarda demasiado")
	case domain.IsValidation(err):
		return status.Error(codes.InvalidArgument, err.Error())
	default:
		// El detalle (sin secretos: el adaptador nunca los pone) va al log.
		s.log.Error("búsqueda de vuelos", slog.Any("error", err))
		return status.Error(codes.Unavailable, "el proveedor de precios no responde")
	}
}

func (s *SearchService) lookup(key string) (cached, bool) {
	if s.cfg.CacheTTL <= 0 {
		return cached{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.cache[key]
	if !ok || !s.now().Before(e.expires) {
		return cached{}, false
	}
	return e, true
}

// store guarda una búsqueda. Si la caché está llena, primero se tiran las
// caducadas y, si sigue llena, una cualquiera: la memoria nunca crece sin fin.
func (s *SearchService) store(key string, e cached) {
	if s.cfg.CacheTTL <= 0 || s.cfg.CacheEntries <= 0 {
		return
	}
	now := s.now()
	e.expires = now.Add(s.cfg.CacheTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.cache) >= s.cfg.CacheEntries {
		for k, v := range s.cache {
			if !now.Before(v.expires) {
				delete(s.cache, k)
			}
		}
		for k := range s.cache {
			if len(s.cache) < s.cfg.CacheEntries {
				break
			}
			delete(s.cache, k)
		}
	}
	s.cache[key] = e
}
