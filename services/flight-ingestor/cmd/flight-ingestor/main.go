// Comando flight-ingestor: punto de entrada del microservicio.
//
// Aquí solo se "cablea" todo (composition root): se lee la configuración, se
// crean las piezas y se conectan. La lógica vive en internal/.
//
// Arranca tres cosas en paralelo y las apaga ordenadamente con SIGINT/SIGTERM:
//  1. Servidor gRPC (RouteWatchService) para registrar rutas a vigilar.
//  2. Servidor HTTP con /healthz (vivo) y /readyz (listo) para Docker/Kubernetes.
//  3. El bucle de ingesta que consulta precios y publica en Kafka.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/config"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/grpcserver"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/ingest"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/provider"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/publisher"
	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/watchlist"
)

// serviceName aparece en cada log y en la cabecera ce_source de los eventos.
const serviceName = "flight-ingestor"

// main es lo primero que se ejecuta. Solo decide el modo (healthcheck o servicio)
// y traduce un error de run() en código de salida 1, que Docker interpreta como fallo.
func main() {
	healthcheck := flag.Bool("healthcheck", false, "consulta /healthz del propio servicio y sale con 0 si está sano (para el HEALTHCHECK del contenedor)")
	flag.Parse()

	if *healthcheck {
		os.Exit(runHealthcheck())
	}
	if err := run(); err != nil {
		slog.Error("el servicio terminó con error", slog.Any("error", err))
		os.Exit(1)
	}
}

// run arranca el servicio completo y no vuelve hasta que se apaga.
func run() error {
	cfg, err := config.Load(os.LookupEnv)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With(slog.String("service", serviceName))
	slog.SetDefault(log)

	// ctx se cancela solo cuando llega Ctrl+C (SIGINT) o la orden de parada de
	// Docker/Kubernetes (SIGTERM). Todas las piezas escuchan este ctx para apagarse.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// --- Registro de seguimientos (+ semillas opcionales para demos) ---
	store, err := watchlist.New(cfg.MaxWatches)
	if err != nil {
		return err
	}
	for _, key := range cfg.SeedWatches {
		spec, err := domain.ParseWatchKey(key)
		if err != nil {
			return fmt.Errorf("SEED_WATCHES: %w", err)
		}
		if _, _, err := store.Add(spec); err != nil {
			return fmt.Errorf("SEED_WATCHES: %w", err)
		}
	}

	// --- Kafka ---
	var kafkaTLS *tls.Config
	if cfg.KafkaTLSCAFile != "" {
		if kafkaTLS, err = clientTLS(cfg.KafkaTLSCAFile); err != nil {
			return err
		}
	}
	pub, err := publisher.NewKafka(publisher.KafkaConfig{
		Brokers: cfg.KafkaBrokers, ClientID: cfg.KafkaClientID, TLS: kafkaTLS, Linger: 5 * time.Millisecond,
	})
	if err != nil {
		return err
	}
	// defer: esto se ejecuta al salir de run(), es decir, al final del apagado,
	// para enviar a Kafka los mensajes que aún estuvieran en cola.
	defer func() {
		closeCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		if err := pub.Close(closeCtx); err != nil {
			log.Error("cerrando Kafka", slog.Any("error", err))
		}
	}()

	// --- Proveedor de precios ---
	var fares provider.FareProvider
	switch cfg.Provider {
	case "travelpayouts":
		fares, err = provider.NewTravelpayouts(provider.TravelpayoutsConfig{
			BaseURL: cfg.TravelpayoutsBaseURL, Token: cfg.TravelpayoutsToken, Marker: cfg.TravelpayoutsMarker,
			Currency: cfg.TravelpayoutsCurrency, BookingHost: cfg.TravelpayoutsBooking,
			RatePerSecond: cfg.TravelpayoutsRate, Refresh: cfg.TravelpayoutsRefresh,
		})
		if err != nil {
			return err
		}
	default:
		fares = provider.NewSimulated(uint64(time.Now().UnixNano()), cfg.SimulatedLatency, cfg.ErrorFareRate)
	}
	log.Info("proveedor de precios", slog.String("provider", fares.Name()))

	// --- Ingestor ---
	ing, err := ingest.New(
		ingest.Config{Interval: cfg.PollInterval, QueryTimeout: cfg.ProviderTimeout, Concurrency: cfg.Concurrency},
		store,
		fares,
		events.NewEncoder(cfg.TopicPriceObserved, serviceName),
		pub,
		log.With(slog.String("component", "ingest")),
	)
	if err != nil {
		return err
	}

	// --- gRPC ---
	var grpcTLS *tls.Config
	if cfg.GRPCTLSEnabled() {
		grpcTLS, err = grpcserver.ServerTLSConfig(grpcserver.TLSFiles{
			CertFile: cfg.GRPCCertFile, KeyFile: cfg.GRPCKeyFile, ClientCAFile: cfg.GRPCClientCAFile,
		})
		if err != nil {
			return err
		}
	} else {
		log.Warn("gRPC SIN TLS (GRPC_INSECURE_DEV=true): úsalo solo en desarrollo local")
	}
	grpcSrv, grpcHealth := grpcserver.NewServer(grpcserver.NewService(store), grpcTLS, log.With(slog.String("component", "grpc")))
	grpcLis, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		return fmt.Errorf("escuchar gRPC en %s: %w", cfg.GRPCAddr, err)
	}

	// --- HTTP de salud ---
	httpSrv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           healthHandler(pub, ing),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
	}

	// errgroup lanza varias goroutines y, si una devuelve error, cancela gctx
	// para que las demás también se detengan. g.Wait() espera a todas.
	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		log.Info("gRPC escuchando", slog.String("addr", cfg.GRPCAddr), slog.Bool("mtls", grpcTLS != nil))
		if err := grpcSrv.Serve(grpcLis); err != nil {
			return fmt.Errorf("servidor gRPC: %w", err)
		}
		return nil
	})
	g.Go(func() error {
		log.Info("HTTP de salud escuchando", slog.String("addr", cfg.HTTPAddr))
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("servidor HTTP: %w", err)
		}
		return nil
	})
	g.Go(func() error {
		log.Info("ingesta iniciada", slog.Duration("interval", cfg.PollInterval), slog.Int("concurrency", cfg.Concurrency),
			slog.Int("seed_watches", len(cfg.SeedWatches)))
		return ing.Run(gctx)
	})
	// Apagado ordenado: cuando llega la señal (o algo falla), se deja de
	// aceptar trabajo nuevo y se espera a que termine el que está en curso.
	g.Go(func() error {
		<-gctx.Done()
		log.Info("apagando...")
		grpcHealth.Shutdown()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()

		stopped := make(chan struct{})
		go func() { grpcSrv.GracefulStop(); close(stopped) }()
		select {
		case <-stopped:
		case <-shutdownCtx.Done():
			grpcSrv.Stop()
		}
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("apagando HTTP: %w", err)
		}
		return nil
	})

	if err := g.Wait(); err != nil {
		return err
	}
	log.Info("apagado completo")
	return nil
}

// healthHandler: /healthz responde si el proceso vive; /readyz solo si puede
// hacer su trabajo (Kafka accesible y el último ciclo pudo publicar).
func healthHandler(pub *publisher.Kafka, ing *ingest.Ingestor) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pub.Ping(ctx); err != nil {
			http.Error(w, "kafka no disponible", http.StatusServiceUnavailable)
			return
		}
		if !ing.Healthy() {
			http.Error(w, "el último ciclo no pudo publicar", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ready"))
	})
	return mux
}

// clientTLS crea la configuración TLS para conectarse a Kafka confiando solo
// en la CA indicada y exigiendo TLS 1.3.
func clientTLS(caFile string) (*tls.Config, error) {
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("leer CA de Kafka: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("la CA de Kafka no contiene certificados PEM válidos")
	}
	return &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS13}, nil
}

// runHealthcheck pide /healthz al propio proceso. Devuelve 0 (sano) o 1 (enfermo),
// que es el código de salida que espera el HEALTHCHECK de Docker.
func runHealthcheck() int {
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = ":8081"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
