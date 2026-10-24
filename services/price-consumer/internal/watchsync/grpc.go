package watchsync

// Cliente gRPC del RouteWatchService del flight-ingestor.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// ClientTLS son los certificados para hablar con el ingestor por mTLS: el
// nuestro (para que él sepa quién llama) y la CA con la que comprobamos el suyo.
type ClientTLS struct {
	CertFile string
	KeyFile  string
	CAFile   string
}

// GRPCIngestor implementa Ingestor con gRPC.
type GRPCIngestor struct {
	conn   *grpc.ClientConn
	client flightsv1.RouteWatchServiceClient
}

// Dial prepara la conexión (gRPC conecta de verdad en la primera llamada).
// tlsFiles == nil solo se permite en local (INGESTOR_INSECURE_DEV=true).
func Dial(addr string, tlsFiles *ClientTLS) (*GRPCIngestor, error) {
	creds := insecure.NewCredentials()
	if tlsFiles != nil {
		cfg, err := clientTLSConfig(*tlsFiles)
		if err != nil {
			return nil, err
		}
		creds = credentials.NewTLS(cfg)
	}
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(creds))
	if err != nil {
		return nil, fmt.Errorf("watchsync: conectar con el flight-ingestor: %w", err)
	}
	return &GRPCIngestor{conn: conn, client: flightsv1.NewRouteWatchServiceClient(conn)}, nil
}

// Close cierra la conexión.
func (g *GRPCIngestor) Close() error { return g.conn.Close() }

var cabins = map[domain.Cabin]flightsv1.CabinClass{
	domain.CabinEconomy:        flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
	domain.CabinPremiumEconomy: flightsv1.CabinClass_CABIN_CLASS_PREMIUM_ECONOMY,
	domain.CabinBusiness:       flightsv1.CabinClass_CABIN_CLASS_BUSINESS,
	domain.CabinFirst:          flightsv1.CabinClass_CABIN_CLASS_FIRST,
}

func dateToProto(d domain.Date) *commonv1.Date {
	return &commonv1.Date{Year: int32(d.Year), Month: int32(d.Month), Day: int32(d.Day)}
}

// Watch implementa Ingestor (idempotente en el ingestor).
func (g *GRPCIngestor) Watch(ctx context.Context, spec domain.RouteSpec) error {
	req := &flightsv1.WatchRouteRequest{
		Route:         &flightsv1.Route{OriginIata: spec.Origin, DestinationIata: spec.Destination},
		DepartureDate: dateToProto(spec.Departure),
		Cabin:         cabins[spec.Cabin],
	}
	if spec.Return != nil {
		req.ReturnDate = dateToProto(*spec.Return)
	}
	if _, err := g.client.WatchRoute(ctx, req); err != nil {
		return fmt.Errorf("WatchRoute %s: %w", spec.Key(), err)
	}
	return nil
}

// List implementa Ingestor.
func (g *GRPCIngestor) List(ctx context.Context) ([]Remote, error) {
	resp, err := g.client.ListRouteWatches(ctx, &flightsv1.ListRouteWatchesRequest{})
	if err != nil {
		return nil, fmt.Errorf("ListRouteWatches: %w", err)
	}
	out := make([]Remote, 0, len(resp.GetWatches()))
	for _, w := range resp.GetWatches() {
		key, ok := keyOf(w)
		if !ok {
			continue
		}
		out = append(out, Remote{ID: w.GetWatchId(), Key: key})
	}
	return out, nil
}

// Unwatch implementa Ingestor.
func (g *GRPCIngestor) Unwatch(ctx context.Context, id string) error {
	if _, err := g.client.UnwatchRoute(ctx, &flightsv1.UnwatchRouteRequest{WatchId: id}); err != nil {
		return fmt.Errorf("UnwatchRoute %s: %w", id, err)
	}
	return nil
}

// keyOf rehace la clave de ruta de un seguimiento del ingestor.
func keyOf(w *flightsv1.RouteWatch) (string, bool) {
	spec := domain.RouteSpec{
		Origin:      w.GetRoute().GetOriginIata(),
		Destination: w.GetRoute().GetDestinationIata(),
	}
	for c, p := range cabins {
		if p == w.GetCabin() {
			spec.Cabin = c
		}
	}
	dep, err := domain.NewDate("departure_date", int(w.GetDepartureDate().GetYear()),
		timeMonth(w.GetDepartureDate().GetMonth()), int(w.GetDepartureDate().GetDay()))
	if err != nil {
		return "", false
	}
	spec.Departure = dep
	if r := w.GetReturnDate(); r != nil && r.GetYear() != 0 {
		ret, err := domain.NewDate("return_date", int(r.GetYear()), timeMonth(r.GetMonth()), int(r.GetDay()))
		if err != nil {
			return "", false
		}
		spec.Return = &ret
	}
	if _, err := domain.ParseRouteKey(spec.Key()); err != nil {
		return "", false
	}
	return spec.Key(), true
}

func clientTLSConfig(f ClientTLS) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(f.CertFile, f.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("watchsync: cargar certificado de cliente: %w", err)
	}
	caPEM, err := os.ReadFile(f.CAFile)
	if err != nil {
		return nil, fmt.Errorf("watchsync: leer CA del flight-ingestor: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("watchsync: la CA del flight-ingestor no contiene certificados PEM válidos")
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: pool, MinVersion: tls.VersionTLS13}, nil
}

func timeMonth(m int32) time.Month { return time.Month(m) }

// Search pregunta al buscador del flight-ingestor (FareSearchService). Usa la
// misma conexión mTLS que los seguimientos.
func (g *GRPCIngestor) Search(ctx context.Context, spec domain.RouteSpec, adults int) (domain.SearchResult, error) {
	req := &flightsv1.SearchFaresRequest{
		Route:         &flightsv1.Route{OriginIata: spec.Origin, DestinationIata: spec.Destination},
		DepartureDate: dateToProto(spec.Departure),
		Cabin:         cabins[spec.Cabin],
		Adults:        int32(adults),
	}
	if spec.Return != nil {
		req.ReturnDate = dateToProto(*spec.Return)
	}
	resp, err := flightsv1.NewFareSearchServiceClient(g.conn).SearchFares(ctx, req)
	switch status.Code(err) {
	case codes.OK:
	case codes.ResourceExhausted, codes.DeadlineExceeded:
		return domain.SearchResult{}, domain.ErrSearchBusy
	case codes.InvalidArgument:
		return domain.SearchResult{}, domain.Invalid("search", "%s", status.Convert(err).Message())
	default:
		return domain.SearchResult{}, fmt.Errorf("SearchFares %s: %w", spec.Key(), err)
	}
	out := domain.SearchResult{Provider: resp.GetProvider(), ObservedAt: resp.GetObservedAt().AsTime()}
	for _, o := range resp.GetOffers() {
		out.Offers = append(out.Offers, domain.Offer{
			PricePerAdult:   moneyFromProto(o.GetPricePerAdult()),
			Total:           moneyFromProto(o.GetTotal()),
			CarrierIATA:     o.GetCarrierIata(),
			DepartureAt:     o.GetDepartureAt(),
			ReturnAt:        o.GetReturnAt(),
			Transfers:       int(o.GetTransfers()),
			ReturnTransfers: int(o.GetReturnTransfers()),
			DurationMinutes: int(o.GetDurationMinutes()),
			DeepLink:        o.GetBookingUrl(),
		})
	}
	return out, nil
}

// Monthly pide al flight-ingestor el precio más barato de cada mes
// (MonthlyFares), por la misma conexión mTLS.
func (g *GRPCIngestor) Monthly(ctx context.Context, origin, destination string) (domain.MonthlyResult, error) {
	resp, err := flightsv1.NewFareSearchServiceClient(g.conn).MonthlyFares(ctx, &flightsv1.MonthlyFaresRequest{
		Route: &flightsv1.Route{OriginIata: origin, DestinationIata: destination},
	})
	switch status.Code(err) {
	case codes.OK:
	case codes.ResourceExhausted, codes.DeadlineExceeded:
		return domain.MonthlyResult{}, domain.ErrSearchBusy
	case codes.InvalidArgument:
		return domain.MonthlyResult{}, domain.Invalid("months", "%s", status.Convert(err).Message())
	default:
		return domain.MonthlyResult{}, fmt.Errorf("MonthlyFares %s-%s: %w", origin, destination, err)
	}
	out := domain.MonthlyResult{Provider: resp.GetProvider(), ObservedAt: resp.GetObservedAt().AsTime()}
	for _, m := range resp.GetMonths() {
		out.Months = append(out.Months, domain.MonthFare{
			Year:          int(m.GetYear()),
			Month:         timeMonth(m.GetMonth()),
			PricePerAdult: moneyFromProto(m.GetPricePerAdult()),
			CarrierIATA:   m.GetCarrierIata(),
			DepartureAt:   m.GetDepartureAt(),
			ReturnAt:      m.GetReturnAt(),
			Transfers:     int(m.GetTransfers()),
			DeepLink:      m.GetBookingUrl(),
		})
	}
	return out, nil
}

func moneyFromProto(m *commonv1.Money) domain.Money {
	return domain.Money{Currency: m.GetCurrencyCode(), AmountMinor: m.GetAmountMinor()}
}
