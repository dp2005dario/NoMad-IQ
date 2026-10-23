// Package grpcserver expone RouteWatchService por gRPC.
//
// Seguridad (zero trust): en producción el servidor exige mTLS con TLS 1.3,
// es decir, el cliente también presenta un certificado firmado por nuestra CA
// interna. Sin certificado válido la conexión se corta antes de llegar al código.
package grpcserver

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"runtime/debug"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/status"

	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/protomap"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/watchlist"
)

// Store es lo que el servidor necesita del registro de seguimientos.
type Store interface {
	Add(spec domain.WatchSpec) (domain.Watch, bool, error)
	Remove(id string) error
	List() []domain.Watch
}

// Service implementa flightsv1.RouteWatchServiceServer.
type Service struct {
	flightsv1.UnimplementedRouteWatchServiceServer
	store Store
}

// NewService crea el servicio.
func NewService(store Store) *Service { return &Service{store: store} }

// WatchRoute implementa el RPC del mismo nombre.
func (s *Service) WatchRoute(_ context.Context, req *flightsv1.WatchRouteRequest) (*flightsv1.WatchRouteResponse, error) {
	spec, err := protomap.SpecFromProto(req.GetRoute(), req.GetDepartureDate(), req.GetReturnDate(), req.GetCabin())
	if err != nil {
		return nil, toStatus(err)
	}
	watch, existed, err := s.store.Add(spec)
	if err != nil {
		return nil, toStatus(err)
	}
	return &flightsv1.WatchRouteResponse{Watch: protomap.WatchToProto(watch), AlreadyExisted: existed}, nil
}

// UnwatchRoute implementa el RPC del mismo nombre.
func (s *Service) UnwatchRoute(_ context.Context, req *flightsv1.UnwatchRouteRequest) (*flightsv1.UnwatchRouteResponse, error) {
	if req.GetWatchId() == "" {
		return nil, status.Error(codes.InvalidArgument, "watch_id es obligatorio")
	}
	if err := s.store.Remove(req.GetWatchId()); err != nil {
		return nil, toStatus(err)
	}
	return &flightsv1.UnwatchRouteResponse{}, nil
}

// ListRouteWatches implementa el RPC del mismo nombre.
func (s *Service) ListRouteWatches(context.Context, *flightsv1.ListRouteWatchesRequest) (*flightsv1.ListRouteWatchesResponse, error) {
	watches := s.store.List()
	out := make([]*flightsv1.RouteWatch, len(watches))
	for i, w := range watches {
		out[i] = protomap.WatchToProto(w)
	}
	return &flightsv1.ListRouteWatchesResponse{Watches: out}, nil
}

// toStatus traduce errores de dominio a códigos gRPC. Los errores
// desconocidos se devuelven como Internal sin detalles, para no filtrar
// información interna al cliente.
func toStatus(err error) error {
	// errors.Is / errors.As miran también dentro de errores envueltos con %w.
	switch {
	case domain.IsValidation(err):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, watchlist.ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, watchlist.ErrCapacity):
		return status.Error(codes.ResourceExhausted, err.Error())
	default:
		return status.Error(codes.Internal, "error interno")
	}
}

// TLSFiles son las rutas de los certificados para mTLS.
type TLSFiles struct {
	CertFile     string
	KeyFile      string
	ClientCAFile string
}

// ServerTLSConfig carga certificados y devuelve una configuración mTLS estricta.
func ServerTLSConfig(f TLSFiles) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(f.CertFile, f.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("grpcserver: cargar certificado del servidor: %w", err)
	}
	caPEM, err := os.ReadFile(f.ClientCAFile)
	if err != nil {
		return nil, fmt.Errorf("grpcserver: leer CA de clientes: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("grpcserver: la CA de clientes no contiene certificados PEM válidos")
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    pool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}, nil
}

// NewServer crea el *grpc.Server con los servicios (seguimientos y, si search
// no es nil, el buscador), health checks estándar,
// límites de tamaño, keepalive e interceptores de log y recuperación de pánicos.
// tlsCfg nil solo debe usarse en desarrollo local.
func NewServer(svc *Service, search *SearchService, tlsCfg *tls.Config, log *slog.Logger) (*grpc.Server, *health.Server) {
	opts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(recoverInterceptor(log), logInterceptor(log)),
		grpc.MaxRecvMsgSize(1 << 20), // 1 MiB: las peticiones legítimas son diminutas.
		grpc.KeepaliveParams(keepalive.ServerParameters{MaxConnectionIdle: 5 * time.Minute}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{MinTime: 30 * time.Second}),
	}
	if tlsCfg != nil {
		opts = append(opts, grpc.Creds(credentials.NewTLS(tlsCfg)))
	}
	srv := grpc.NewServer(opts...)
	flightsv1.RegisterRouteWatchServiceServer(srv, svc)

	hs := health.NewServer()
	healthpb.RegisterHealthServer(srv, hs)
	hs.SetServingStatus(flightsv1.RouteWatchService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	if search != nil {
		flightsv1.RegisterFareSearchServiceServer(srv, search)
		hs.SetServingStatus(flightsv1.FareSearchService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	}
	return srv, hs
}

// logInterceptor envuelve cada llamada: mide cuánto tarda y deja una línea de
// log con el método y el código de respuesta. Es como un middleware web.
func logInterceptor(log *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		code := status.Code(err)
		level := slog.LevelInfo
		if code == codes.Internal || code == codes.Unknown {
			level = slog.LevelError
		}
		log.LogAttrs(ctx, level, "rpc", slog.String("method", info.FullMethod),
			slog.String("code", code.String()), slog.Duration("duration", time.Since(start)))
		return resp, err
	}
}

// recoverInterceptor captura cualquier pánico dentro de una llamada para que un
// error inesperado no tumbe el servidor entero; el cliente recibe Internal.
func recoverInterceptor(log *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
		defer func() {
			if r := recover(); r != nil {
				log.Error("pánico en rpc", slog.String("method", info.FullMethod),
					slog.Any("panic", r), slog.String("stack", string(debug.Stack())))
				err = status.Error(codes.Internal, "error interno")
			}
		}()
		return handler(ctx, req)
	}
}
