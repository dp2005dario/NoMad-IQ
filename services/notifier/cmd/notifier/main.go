// Comando notifier: punto de entrada del servicio de notificaciones push.
//
// Qué hace, en una frase: recibe del geo-engine órdenes seudónimas de "avisa
// a esta persona de que ha llegado a esta zona", aplica el anti-spam, cifra
// el aviso para cada teléfono y lo entrega a través de Firebase (FCM) sin
// pasarse nunca del ritmo permitido.
//
//	geo-engine ──► Kafka (notify.zone-requests.v1) ──► intake ──► PostgreSQL (cola)
//	                    seudónimo + zona, sin coordenadas    │ anti-spam          │
//	                                                    Redis ┘                   ▼
//	   app ──(PUT /v1/devices/{id}, vía proxy con mTLS)──► API          sender ──► FCM ──► teléfono
//	                                                                   (token bucket)
//
// Este fichero solo "cablea" las piezas (composition root). La lógica vive
// en internal/. Tareas en paralelo, que se apagan en orden con SIGTERM:
//  1. El consumidor de Kafka (intake).
//  2. El sender (worker pool hacia FCM).
//  3. La API de registro de teléfonos (con mTLS).
//  4. La limpieza periódica (teléfonos inactivos, avisos caducados).
//  5. El servidor HTTP de salud (/healthz y /readyz).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/errgroup"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/antispam"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/api"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/config"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/events"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/fcm"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/intake"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/kafka"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/pseudonym"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sender"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/store"
)

const serviceName = "notifier"

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
	cfg, err := config.Load(os.LookupEnv, os.ReadFile)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With(slog.String("service", serviceName))
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	for flagName, on := range map[string]bool{
		"DB_INSECURE_DEV": cfg.DBInsecureDev, "REDIS_INSECURE_DEV": cfg.RedisInsecureDev,
		"HTTP_INSECURE_DEV": cfg.HTTPInsecureDev, "FCM_INSECURE_DEV": cfg.FCMInsecureDev,
	} {
		if on {
			log.Warn("modo de desarrollo inseguro activado: úsalo solo en local", slog.String("flag", flagName))
		}
	}

	// --- Claves: cada una para lo suyo ---
	vault, err := sealbox.NewVault(cfg.TokenKey)
	if err != nil {
		return err
	}
	pseudonyms, err := pseudonym.New(cfg.PseudonymKey)
	if err != nil {
		return err
	}

	// --- PostgreSQL ---
	db, err := store.Open(ctx, store.Config{
		Host: cfg.PGHost, Port: cfg.PGPort, User: cfg.PGUser, Password: cfg.PGPassword, Database: cfg.PGDatabase,
		SSLMode: cfg.PGSSLMode, SSLRootCert: cfg.PGSSLRootCert, MaxConns: int32(cfg.PGMaxConns),
	}, vault, cfg.MaxDevicesPerPerson)
	if err != nil {
		return err
	}
	defer db.Close()
	startCtx, cancelStart := context.WithTimeout(ctx, time.Minute)
	applied, err := db.Migrate(startCtx)
	cancelStart()
	if err != nil {
		return err
	}
	log.Info("migraciones al día", slog.Int("applied_now", applied))

	// --- Redis (anti-spam) ---
	redisOpts := &redis.Options{
		Addr:     net.JoinHostPort(cfg.RedisHost, strconv.Itoa(cfg.RedisPort)),
		Password: cfg.RedisPassword,
		// Tiempos cortos: si Redis va lento, mejor reintentar la orden que
		// dejar a todo el consumidor esperando.
		DialTimeout: 3 * time.Second, ReadTimeout: time.Second, WriteTimeout: time.Second,
	}
	if cfg.RedisTLS {
		if redisOpts.TLSConfig, err = clientTLS(cfg.RedisTLSCAFile, "Redis"); err != nil {
			return err
		}
	}
	rdb := redis.NewClient(redisOpts)
	defer rdb.Close()
	gate, err := antispam.New(rdb, vault, cfg.ZoneRepeatWindow, cfg.CooldownPeriod)
	if err != nil {
		return err
	}

	// --- Kafka ---
	var kafkaTLS *tls.Config
	if cfg.KafkaTLSCAFile != "" {
		if kafkaTLS, err = clientTLS(cfg.KafkaTLSCAFile, "Kafka"); err != nil {
			return err
		}
	}
	kc, err := kafka.New(kafka.Config{
		Brokers: cfg.KafkaBrokers, ClientID: cfg.KafkaClientID, GroupID: cfg.KafkaGroupID,
		Topic: cfg.TopicRequests, TLS: kafkaTLS, MaxPollRecords: cfg.KafkaMaxPollRecords,
	}, log.With(slog.String("component", "kafka")))
	if err != nil {
		return err
	}
	defer kc.Close()

	// --- FCM ---
	var credentials []byte
	if cfg.FCMCredentialsFile != "" {
		if credentials, err = os.ReadFile(cfg.FCMCredentialsFile); err != nil {
			return fmt.Errorf("FCM_CREDENTIALS_FILE: no se pudo leer %s", cfg.FCMCredentialsFile)
		}
	}
	push, err := fcm.New(ctx, fcm.Config{Endpoint: cfg.FCMEndpoint, ProjectID: cfg.FCMProjectID, CredentialsJSON: credentials})
	if err != nil {
		return err
	}

	// --- Lógica ---
	snd, err := sender.New(sender.Config{
		RatePerSecond: cfg.SendRatePerSecond, Burst: cfg.SendBurst, Workers: cfg.SendWorkers, Batch: cfg.SendBatch,
		Lease: cfg.SendLease, MaxAttempts: cfg.SendMaxAttempts, PollInterval: cfg.SendPollInterval,
	}, db, push, vault, log.With(slog.String("component", "sender")))
	if err != nil {
		return err
	}
	proc, err := intake.New(intake.Config{DLQTopic: cfg.TopicDLQ, MaxRequestAge: cfg.MaxRequestAge, DeliveryTTL: cfg.DeliveryTTL},
		db, db, gate, kc, snd.Wake, log.With(slog.String("component", "intake")))
	if err != nil {
		return err
	}

	var consumerHealthy atomic.Bool
	consumerHealthy.Store(true)
	handle := func(ctx context.Context, rec events.Record) error {
		outcome, err := proc.Handle(ctx, rec)
		consumerHealthy.Store(err == nil)
		if err == nil {
			log.Debug("orden procesada", slog.String("outcome", string(outcome)))
		}
		return err
	}

	// --- Servidores HTTP ---
	apiSrv := &http.Server{
		Addr:              cfg.APIAddr,
		Handler:           api.Handler(db, pseudonyms, log.With(slog.String("component", "api"))),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: time.Minute,
	}
	if !cfg.HTTPInsecureDev {
		if apiSrv.TLSConfig, err = serverMTLS(cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSClientCAFile); err != nil {
			return err
		}
	}
	healthSrv := &http.Server{
		Addr:              cfg.HealthAddr,
		Handler:           healthHandler(kc, db, rdb, snd, &consumerHealthy),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second,
	}

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		log.Info("consumiendo órdenes de notificación", slog.String("topic", cfg.TopicRequests), slog.String("group", cfg.KafkaGroupID))
		return kc.Consume(gctx, handle, kafka.Backoff{Initial: 500 * time.Millisecond, Max: 30 * time.Second}, nil)
	})
	g.Go(func() error { return snd.Run(gctx) })
	g.Go(func() error {
		cleanup(gctx, db, time.Duration(cfg.DeviceInactivityDays)*24*time.Hour, log)
		return nil
	})
	g.Go(func() error {
		log.Info("API de teléfonos escuchando", slog.String("addr", cfg.APIAddr), slog.Bool("mtls", !cfg.HTTPInsecureDev))
		var err error
		if cfg.HTTPInsecureDev {
			err = apiSrv.ListenAndServe()
		} else {
			err = apiSrv.ListenAndServeTLS("", "") // certificados ya cargados en TLSConfig
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("API: %w", err)
		}
		return nil
	})
	g.Go(func() error {
		log.Info("HTTP de salud escuchando", slog.String("addr", cfg.HealthAddr))
		if err := healthSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("servidor de salud: %w", err)
		}
		return nil
	})
	g.Go(func() error {
		<-gctx.Done()
		log.Info("apagando...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		return errors.Join(apiSrv.Shutdown(shutdownCtx), healthSrv.Shutdown(shutdownCtx))
	})
	if err := g.Wait(); err != nil {
		return err
	}
	log.Info("apagado completo", slog.Any("stats", snd.Stats()))
	return nil
}

// cleanup borra cada hora los teléfonos que llevan meses sin dar señales y
// los avisos caducados. Si hay varias copias, todas limpian: borrar dos
// veces lo mismo no hace daño.
func cleanup(ctx context.Context, db *store.Postgres, inactiveFor time.Duration, log *slog.Logger) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		devices, deliveries, err := db.Cleanup(ctx, inactiveFor)
		if err != nil && ctx.Err() == nil {
			log.Warn("limpieza fallida; se reintentará", slog.Any("error", err))
		} else if devices+deliveries > 0 {
			log.Info("limpieza", slog.Int64("devices", devices), slog.Int64("deliveries", deliveries))
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

type pinger interface {
	Ping(ctx context.Context) error
}

// healthHandler: /healthz = el proceso vive; /readyz = puede trabajar
// (Kafka, PostgreSQL y Redis accesibles, sin fallos repetidos). /readyz
// devuelve además los contadores de envíos (sin datos de nadie).
func healthHandler(kc, db pinger, rdb *redis.Client, snd *sender.Sender, consumerHealthy *atomic.Bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		problem := ""
		switch {
		case kc.Ping(ctx) != nil:
			problem = "kafka no disponible"
		case db.Ping(ctx) != nil:
			problem = "postgresql no disponible"
		case rdb.Ping(ctx).Err() != nil:
			problem = "redis no disponible"
		case !consumerHealthy.Load() || !snd.Healthy():
			problem = "procesado con errores, reintentando"
		}
		w.Header().Set("Content-Type", "application/json")
		if problem != "" {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ready": problem == "", "problem": problem, "sender": snd.Stats()})
	})
	return mux
}

func clientTLS(caFile, what string) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS13}
	if caFile == "" {
		return cfg, nil // CA del sistema
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("leer CA de %s: %w", what, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("la CA de %s no contiene certificados PEM válidos", what)
	}
	cfg.RootCAs = pool
	return cfg, nil
}

// serverMTLS: TLS 1.3 y certificado de cliente OBLIGATORIO, firmado por la
// CA interna. Sin él, la conexión se corta antes de leer una sola cabecera.
func serverMTLS(certFile, keyFile, clientCAFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("cargar certificado de la API: %w", err)
	}
	caPEM, err := os.ReadFile(clientCAFile)
	if err != nil {
		return nil, fmt.Errorf("leer TLS_CLIENT_CA_FILE: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("TLS_CLIENT_CA_FILE no contiene certificados PEM válidos")
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
	}, nil
}

// runHealthcheck lo usa Docker (HEALTHCHECK): la imagen no tiene curl ni shell.
func runHealthcheck() int {
	addr := os.Getenv("HEALTH_ADDR")
	if addr == "" {
		addr = ":8090"
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
