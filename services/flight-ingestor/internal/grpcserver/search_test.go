package grpcserver

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/provider"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/watchlist"
)

// fakeSearcher cuenta cuántas veces se le pregunta de verdad.
type fakeSearcher struct {
	calls atomic.Int64
	delay time.Duration
	err   error
}

func (f *fakeSearcher) Name() string { return "fake" }

func (f *fakeSearcher) Search(ctx context.Context, spec domain.SearchSpec, limit int) ([]domain.Offer, error) {
	f.calls.Add(1)
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	if f.err != nil {
		return nil, f.err
	}
	return []domain.Offer{{
		PricePerAdult: domain.Money{Currency: "EUR", AmountMinor: 31550},
		CarrierIATA:   "IB",
		DepartureAt:   spec.Trip.Departure.String() + "T22:40:00+01:00",
		Transfers:     1,
		DeepLink:      "https://www.aviasales.com/search/MAD1512NRT1?marker=1",
	}}, nil
}

var searchNow = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

func newSearchClient(t *testing.T, f *fakeSearcher, ttl time.Duration) (flightsv1.FareSearchServiceClient, *SearchService) {
	t.Helper()
	store, err := watchlist.New(10)
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	search := NewSearchService(SearchConfig{CacheTTL: ttl, CacheEntries: 2, Timeout: time.Second}, f, log)
	search.now = func() time.Time { return searchNow }
	srv, _ := NewServer(NewService(store), search, nil, log)
	lis := bufconn.Listen(1 << 20)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return flightsv1.NewFareSearchServiceClient(conn), search
}

func searchReq(day int32, adults int32) *flightsv1.SearchFaresRequest {
	return &flightsv1.SearchFaresRequest{
		Route:         &flightsv1.Route{OriginIata: "MAD", DestinationIata: "NRT"},
		DepartureDate: &commonv1.Date{Year: 2026, Month: 12, Day: day},
		Cabin:         flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		Adults:        adults,
	}
}

func TestSearchFaresReturnsTotalsAndCaches(t *testing.T) {
	f := &fakeSearcher{}
	client, _ := newSearchClient(t, f, 10*time.Minute)
	resp, err := client.SearchFares(context.Background(), searchReq(15, 2))
	if err != nil {
		t.Fatal(err)
	}
	o := resp.GetOffers()[0]
	if o.GetPricePerAdult().GetAmountMinor() != 31550 || o.GetTotal().GetAmountMinor() != 63100 || o.GetTransfers() != 1 {
		t.Errorf("oferta: %v", o)
	}
	if resp.GetProvider() != "fake" || !resp.GetObservedAt().AsTime().Equal(searchNow) {
		t.Errorf("respuesta: %v", resp)
	}
	// La misma búsqueda otra vez: sale de la caché.
	if _, err := client.SearchFares(context.Background(), searchReq(15, 2)); err != nil {
		t.Fatal(err)
	}
	if f.calls.Load() != 1 {
		t.Errorf("llamadas al proveedor = %d, se esperaba 1", f.calls.Load())
	}
}

func TestSearchFaresSharesOneRequestBetweenConcurrentUsers(t *testing.T) {
	f := &fakeSearcher{delay: 100 * time.Millisecond}
	client, _ := newSearchClient(t, f, 0) // sin caché: solo el singleflight
	var wg sync.WaitGroup
	for range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := client.SearchFares(context.Background(), searchReq(15, 1)); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if n := f.calls.Load(); n > 3 {
		t.Errorf("50 búsquedas iguales a la vez hicieron %d peticiones al proveedor", n)
	}
}

func TestSearchFaresCacheIsBounded(t *testing.T) {
	f := &fakeSearcher{}
	client, search := newSearchClient(t, f, time.Hour)
	for day := int32(1); day <= 5; day++ {
		if _, err := client.SearchFares(context.Background(), searchReq(day, 1)); err != nil {
			t.Fatal(err)
		}
	}
	search.mu.Lock()
	n := len(search.cache)
	search.mu.Unlock()
	if n > 2 {
		t.Errorf("la caché tiene %d entradas (máximo 2)", n)
	}
}

func TestSearchFaresErrors(t *testing.T) {
	client, _ := newSearchClient(t, &fakeSearcher{err: provider.ErrRateLimited}, time.Minute)
	_, err := client.SearchFares(context.Background(), searchReq(15, 1))
	if status.Code(err) != codes.ResourceExhausted {
		t.Errorf("límite del proveedor: %v", err)
	}
	for name, req := range map[string]*flightsv1.SearchFaresRequest{
		"0 viajeros":   searchReq(15, 0),
		"10 viajeros":  searchReq(15, 10),
		"fecha pasada": {Route: searchReq(1, 1).Route, DepartureDate: &commonv1.Date{Year: 2026, Month: 1, Day: 1}, Cabin: flightsv1.CabinClass_CABIN_CLASS_ECONOMY, Adults: 1},
		"sin ruta":     {DepartureDate: searchReq(1, 1).DepartureDate, Cabin: flightsv1.CabinClass_CABIN_CLASS_ECONOMY, Adults: 1},
	} {
		if _, err := client.SearchFares(context.Background(), req); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%s: %v", name, err)
		}
	}
	other, _ := newSearchClient(t, &fakeSearcher{err: io.ErrUnexpectedEOF}, time.Minute)
	if _, err := other.SearchFares(context.Background(), searchReq(15, 1)); status.Code(err) != codes.Unavailable {
		t.Errorf("fallo del proveedor: %v", err)
	}
}
