// Package provider define cómo el ingestor obtiene precios de vuelos.
//
// FareProvider es un "puerto": el ingestor solo conoce esta interfaz. Cada
// fuente real (Travelpayouts, Kiwi, Amadeus...) será un "adaptador" que la
// implemente, y se podrán combinar sin tocar el resto del servicio.
package provider

import (
	"context"
	"errors"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// ErrRateLimited indica que el proveedor pidió frenar. El ingestor no lo
// trata como un fallo grave: lo reintentará en el siguiente ciclo.
var ErrRateLimited = errors.New("proveedor: límite de peticiones alcanzado")

// FareProvider devuelve los precios actuales para un seguimiento.
type FareProvider interface {
	// Name identifica al proveedor en los eventos ("travelpayouts").
	Name() string
	// Quote debe respetar la cancelación de ctx y no bloquear más allá de ella.
	Quote(ctx context.Context, spec domain.WatchSpec) ([]domain.Quote, error)
}

// Searcher es el BUSCADOR: dado un viaje concreto (ruta, fechas, viajeros),
// devuelve varias ofertas ordenadas de más barata a más cara. Lo implementan
// los mismos adaptadores que FareProvider.
type Searcher interface {
	Name() string
	// Search devuelve como mucho limit ofertas. ErrRateLimited = el
	// proveedor pide frenar (la app dirá "inténtalo en unos segundos").
	Search(ctx context.Context, spec domain.SearchSpec, limit int) ([]domain.Offer, error)
}

// MonthlySearcher da el billete más barato de cada mes para una ruta (ida
// y vuelta, turista), del mes actual en adelante. Lo usa Explorar.
type MonthlySearcher interface {
	Name() string
	Monthly(ctx context.Context, route domain.Route) ([]domain.MonthFare, error)
}
