// Tests de la API gRPC: se hacen llamadas reales a través de un cliente gRPC,
// igual que haría el auth-gateway, y se comprueban respuestas y códigos de error.

package grpcserver

import (
	"context"
	"io"
	"log/slog"
	"net"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/watchlist"
)

// newClient levanta el servidor sobre una conexión en memoria (bufconn):
// es gRPC real, con serialización y todo, pero sin abrir puertos.
func newClient(t *testing.T, maxWatches int) flightsv1.RouteWatchServiceClient {
	t.Helper()
	store, err := watchlist.New(maxWatches)
	if err != nil {
		t.Fatal(err)
	}
	srv, _ := NewServer(NewService(store), nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
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
	return flightsv1.NewRouteWatchServiceClient(conn)
}

// validRequest devuelve una petición correcta. "mad" va en minúsculas a
// propósito para comprobar que el servidor lo normaliza a "MAD".
func validRequest() *flightsv1.WatchRouteRequest {
	return &flightsv1.WatchRouteRequest{
		Route:         &flightsv1.Route{OriginIata: "mad", DestinationIata: "NRT"},
		DepartureDate: &commonv1.Date{Year: 2026, Month: 12, Day: 1},
		Cabin:         flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
	}
}

// Pedir dos veces la misma ruta no debe crear dos seguimientos.
func TestWatchRouteIdempotent(t *testing.T) {
	client := newClient(t, 10)
	ctx := context.Background()

	first, err := client.WatchRoute(ctx, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	if first.GetAlreadyExisted() || first.GetWatch().GetRoute().GetOriginIata() != "MAD" {
		t.Fatalf("respuesta inesperada: %v", first)
	}
	second, err := client.WatchRoute(ctx, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	if !second.GetAlreadyExisted() || second.GetWatch().GetWatchId() != first.GetWatch().GetWatchId() {
		t.Fatalf("la segunda llamada debería devolver el mismo seguimiento: %v", second)
	}

	list, err := client.ListRouteWatches(ctx, &flightsv1.ListRouteWatchesRequest{})
	if err != nil || len(list.GetWatches()) != 1 {
		t.Fatalf("List: %v, %v", list, err)
	}
}

// Cada tipo de error debe traducirse a su código gRPC estándar, para que el
// cliente sepa si la culpa es suya (InvalidArgument) o un límite (ResourceExhausted).
func TestWatchRouteErrorCodes(t *testing.T) {
	client := newClient(t, 1)
	ctx := context.Background()

	bad := validRequest()
	bad.DepartureDate = &commonv1.Date{Year: 2026, Month: 2, Day: 30}
	if _, err := client.WatchRoute(ctx, bad); status.Code(err) != codes.InvalidArgument {
		t.Errorf("fecha imposible: código %v, se esperaba InvalidArgument", status.Code(err))
	}

	noCabin := validRequest()
	noCabin.Cabin = flightsv1.CabinClass_CABIN_CLASS_UNSPECIFIED
	if _, err := client.WatchRoute(ctx, noCabin); status.Code(err) != codes.InvalidArgument {
		t.Errorf("sin cabina: código %v, se esperaba InvalidArgument", status.Code(err))
	}

	if _, err := client.WatchRoute(ctx, validRequest()); err != nil {
		t.Fatal(err)
	}
	other := validRequest()
	other.Route.DestinationIata = "JFK"
	if _, err := client.WatchRoute(ctx, other); status.Code(err) != codes.ResourceExhausted {
		t.Errorf("sobre el límite: código %v, se esperaba ResourceExhausted", status.Code(err))
	}
}

// Borrar un seguimiento: funciona la primera vez, da NotFound la segunda y
// exige un watch_id.
func TestUnwatchRoute(t *testing.T) {
	client := newClient(t, 10)
	ctx := context.Background()

	resp, err := client.WatchRoute(ctx, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.UnwatchRoute(ctx, &flightsv1.UnwatchRouteRequest{WatchId: resp.GetWatch().GetWatchId()}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.UnwatchRoute(ctx, &flightsv1.UnwatchRouteRequest{WatchId: resp.GetWatch().GetWatchId()}); status.Code(err) != codes.NotFound {
		t.Errorf("código %v, se esperaba NotFound", status.Code(err))
	}
	if _, err := client.UnwatchRoute(ctx, &flightsv1.UnwatchRouteRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Errorf("código %v, se esperaba InvalidArgument", status.Code(err))
	}
}
