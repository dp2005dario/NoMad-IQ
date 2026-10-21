// Comando price-consumer: punto de entrada del microservicio.
//
// Qué hace el servicio, en una frase: lee los precios que publica el
// flight-ingestor en Kafka, los guarda en PostgreSQL, detecta chollos y
// publica alertas para los usuarios interesados.
//
//	flight-ingestor ──► Kafka (flights.price-observed.v1)
//	                        │
//	                        ▼
//	                  price-consumer ──► PostgreSQL (historial + alertas)
//	                        │
//	                        ▼
//	              Kafka (flights.fare-alerts.v1) ──► (futuro) notificaciones
//
// Este fichero solo "cablea" las piezas (composition root): lee la
// configuración, crea cada componente y los conecta. La lógica vive en internal/.
//
// Arranca tres tareas en paralelo y las apaga ordenadamente con Ctrl+C o
// cuando Docker/Kubernetes envía SIGTERM:
//  1. El consumidor de Kafka (procesa precios).
//  2. El relay de la bandeja de salida (publica alertas).
//  3. El servidor HTTP de salud (/healthz y /readyz).
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
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/config"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/detector"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/kafka"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/outbox"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/processor"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/store"
)

const serviceName = "price-consumer"

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

func run() error {
	cfg, err := config.Load(os.LookupEnv)
	if err != nil {
		return err
	}
	// Logs en JSON: fáciles de buscar y filtrar con herramientas (Loki, ELK...).
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With(slog.String("service", serviceName))
	slog.SetDefault(log)

	// ctx se cancela al recibir Ctrl+C (SIGINT) o SIGTERM: es la señal de apagado.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// --- PostgreSQL: conectar, migrar y cargar suscripciones de ejemplo ---
	if cfg.DBInsecureDev {
		log.Warn("PostgreSQL SIN TLS (DB_INSECURE_DEV=true): úsalo solo en desarrollo local")
	}
	db, err := store.Open(ctx, store.Config{
		Host: cfg.PGHost, Port: cfg.PGPort, User: cfg.PGUser, Password: cfg.PGPassword, Database: cfg.PGDatabase,
		SSLMode: cfg.PGSSLMode, SSLRootCert: cfg.PGSSLRootCert, MaxConns: int32(cfg.PGMaxConns),
	})
	if err != nil {
		return err
	}
	defer db.Close()

	startCtx, cancelStart := context.WithTimeout(ctx, time.Minute)
	defer cancelStart()
	applied, err := db.Migrate(startCtx)
	if err != nil {
		return err
	}
	log.Info("migraciones al día", slog.Int("applied_now", applied))

	for _, raw := range cfg.SeedSubscriptions {
		sub, err := domain.ParseSubscription(raw)
		if err != nil {
			return fmt.Errorf("SEED_SUBSCRIPTIONS: %w", err)
		}
		if err := db.UpsertSubscription(startCtx, sub); err != nil {
			return fmt.Errorf("SEED_SUBSCRIPTIONS: %w", err)
		}
	}
	cancelStart()

	// --- Kafka ---
	var kafkaTLS *tls.Config
	if cfg.KafkaTLSCAFile != "" {
		if kafkaTLS, err = clientTLS(cfg.KafkaTLSCAFile); err != nil {
			return err
		}
	}
	kc, err := kafka.New(kafka.Config{
		Brokers: cfg.KafkaBrokers, ClientID: cfg.KafkaClientID, GroupID: cfg.KafkaGroupID,
		Topic: cfg.TopicPriceObserved, TLS: kafkaTLS, MaxPollRecords: cfg.MaxPollRecords,
	}, log.With(slog.String("component", "kafka")))
	if err != nil {
		return err
	}
	defer kc.Close()

	// --- Lógica de negocio ---
	enc := events.NewEncoder(cfg.TopicFareAlerts, cfg.TopicDLQ, serviceName)
	proc, err := processor.New(processor.Config{
		Rules: detector.Rules{
			MinSamples:           cfg.MinSamples,
			DropBasisPoints:      int32(cfg.DropBasisPoints),
			ErrorFareBasisPoints: int32(cfg.ErrorFareBasisPoints),
		},
		HistoryWindow: cfg.HistoryWindow,
		HistoryLimit:  cfg.HistoryLimit,
		AlertCooldown: cfg.AlertCooldown,
	}, db, kc, enc, log.With(slog.String("component", "processor")))
	if err != nil {
		return err
	}
	relay, err := outbox.New(db, kc, enc, cfg.OutboxBatchSize, cfg.OutboxInterval, log.With(slog.String("component", "outbox")))
	if err != nil {
		return err
	}

	// consumerHealthy pasa a false mientras un mensaje está fallando (por
	// ejemplo, base de datos caída) y vuelve a true cuando se recupera.
	var consumerHealthy atomic.Bool
	consumerHealthy.Store(true)
	handle := func(ctx context.Context, rec events.Record) error {
		res, err := proc.Handle(ctx, rec)
		consumerHealthy.Store(err == nil)
		if err == nil {
			log.Debug("mensaje procesado", slog.String("outcome", res.Outcome.String()),
				slog.Int("partition", int(rec.Partition)), slog.Int64("offset", rec.Offset), slog.Int("alerts", res.Alerts))
		}
		return err
	}

	// --- HTTP de salud ---
	httpSrv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           healthHandler(kc, db, relay, &consumerHealthy),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
	}

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		log.Info("consumiendo precios", slog.String("topic", cfg.TopicPriceObserved), slog.String("group", cfg.KafkaGroupID))
		return kc.Consume(gctx, handle, kafka.Backoff{Initial: 500 * time.Millisecond, Max: 30 * time.Second}, relay.Notify)
	})
	g.Go(func() error { return relay.Run(gctx) })
	g.Go(func() error {
		log.Info("HTTP de salud escuchando", slog.String("addr", cfg.HTTPAddr))
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("servidor HTTP: %w", err)
		}
		return nil
	})
	// Apagado ordenado: cuando llega la señal (o algo falla), se deja de
	// aceptar trabajo nuevo y se espera a que termine el que está en curso.
	g.Go(func() error {
		<-gctx.Done()
		log.Info("apagando...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
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

type pinger interface {
	Ping(ctx context.Context) error
}

// healthHandler: /healthz responde si el proceso vive; /readyz solo si puede
// trabajar (Kafka y PostgreSQL accesibles, y sin fallos repetidos).
// Kubernetes usa la primera para reiniciar el contenedor y la segunda para
// decidir si le manda tráfico.
func healthHandler(kc, db pinger, relay *outbox.Relay, consumerHealthy *atomic.Bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		// Mensajes genéricos: no se revelan detalles internos a quien pregunta.
		if err := kc.Ping(ctx); err != nil {
			http.Error(w, "kafka no disponible", http.StatusServiceUnavailable)
			return
		}
		if err := db.Ping(ctx); err != nil {
			http.Error(w, "postgresql no disponible", http.StatusServiceUnavailable)
			return
		}
		if !consumerHealthy.Load() || !relay.Healthy() {
			http.Error(w, "procesado con errores, reintentando", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ready"))
	})
	return mux
}

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

// runHealthcheck lo usa Docker (HEALTHCHECK). La imagen final no tiene curl
// ni shell (por seguridad), así que el propio binario hace la comprobación.
func runHealthcheck() int {
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = ":8082"
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
