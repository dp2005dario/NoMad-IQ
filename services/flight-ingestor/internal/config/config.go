// Package config lee la configuración desde variables de entorno (12-factor).
//
// Se validan TODAS las variables y se devuelven todos los errores juntos, para
// que quien despliega vea de una vez todo lo que falta en lugar de ir fallo a fallo.
// Si la configuración es insegura (gRPC sin TLS fuera de desarrollo), el
// servicio se niega a arrancar.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"
)

// Config es la configuración completa y ya validada del servicio.
type Config struct {
	KafkaBrokers       []string
	KafkaClientID      string
	TopicPriceObserved string
	KafkaTLSCAFile     string // opcional: activa TLS hacia Kafka

	GRPCAddr         string
	GRPCCertFile     string
	GRPCKeyFile      string
	GRPCClientCAFile string
	GRPCInsecureDev  bool
	HTTPAddr         string

	PollInterval     time.Duration
	ProviderTimeout  time.Duration
	Concurrency      int
	MaxWatches       int
	SeedWatches      []string
	SimulatedLatency time.Duration
	ErrorFareRate    float64

	ShutdownTimeout time.Duration
	LogLevel        slog.Level
}

// GRPCTLSEnabled indica si se configuraron los certificados de mTLS.
func (c Config) GRPCTLSEnabled() bool { return c.GRPCCertFile != "" }

// LookupFunc tiene la firma de os.LookupEnv; inyectarla facilita los tests.
type LookupFunc func(key string) (string, bool)

// reader acumula los errores mientras lee variables, para devolverlos todos
// juntos al final en vez de parar en el primero.
type reader struct {
	lookup LookupFunc
	errs   []error
}

// str devuelve la variable sin espacios, o def si no existe o está vacía.
func (r *reader) str(key, def string) string {
	if v, ok := r.lookup(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return def
}

// required apunta un error si la variable no existe o está vacía.
func (r *reader) required(key string) string {
	v := r.str(key, "")
	if v == "" {
		r.errs = append(r.errs, fmt.Errorf("%s es obligatoria", key))
	}
	return v
}

// list lee una lista separada por comas ("a, b,c") ignorando huecos vacíos.
func (r *reader) list(key string) []string {
	raw := r.str(key, "")
	if raw == "" {
		return nil
	}
	var out []string
	for _, item := range strings.Split(raw, ",") {
		if item = strings.TrimSpace(item); item != "" {
			out = append(out, item)
		}
	}
	return out
}

// duration lee una duración ("30s", "5m") y comprueba que esté entre min y max.
func (r *reader) duration(key string, def, min, max time.Duration) time.Duration {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: duración inválida %q (ejemplos: 30s, 5m)", key, raw))
		return def
	}
	if d < min || d > max {
		r.errs = append(r.errs, fmt.Errorf("%s: %s fuera del rango [%s, %s]", key, d, min, max))
	}
	return d
}

// integer lee un número entero y comprueba que esté entre min y max.
func (r *reader) integer(key string, def, min, max int) int {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: entero inválido %q", key, raw))
		return def
	}
	if n < min || n > max {
		r.errs = append(r.errs, fmt.Errorf("%s: %d fuera del rango [%d, %d]", key, n, min, max))
	}
	return n
}

// float lee un número decimal y comprueba que esté entre min y max.
func (r *reader) float(key string, def, min, max float64) float64 {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || f < min || f > max {
		r.errs = append(r.errs, fmt.Errorf("%s: se esperaba un número entre %g y %g, se recibió %q", key, min, max, raw))
		return def
	}
	return f
}

// boolean lee true/false (también acepta 1/0, t/f).
func (r *reader) boolean(key string, def bool) bool {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: booleano inválido %q (usa true/false)", key, raw))
		return def
	}
	return b
}

// Load lee y valida la configuración.
func Load(lookup LookupFunc) (Config, error) {
	r := &reader{lookup: lookup}
	cfg := Config{
		KafkaBrokers:       r.list("KAFKA_BROKERS"),
		KafkaClientID:      r.str("KAFKA_CLIENT_ID", "flight-ingestor"),
		TopicPriceObserved: r.str("KAFKA_TOPIC_PRICE_OBSERVED", "flights.price-observed.v1"),
		KafkaTLSCAFile:     r.str("KAFKA_TLS_CA_FILE", ""),

		GRPCAddr:         r.str("GRPC_ADDR", ":50051"),
		GRPCCertFile:     r.str("GRPC_TLS_CERT_FILE", ""),
		GRPCKeyFile:      r.str("GRPC_TLS_KEY_FILE", ""),
		GRPCClientCAFile: r.str("GRPC_TLS_CLIENT_CA_FILE", ""),
		GRPCInsecureDev:  r.boolean("GRPC_INSECURE_DEV", false),
		HTTPAddr:         r.str("HTTP_ADDR", ":8081"),

		PollInterval:     r.duration("POLL_INTERVAL", 5*time.Minute, 5*time.Second, 24*time.Hour),
		ProviderTimeout:  r.duration("PROVIDER_TIMEOUT", 10*time.Second, 100*time.Millisecond, 2*time.Minute),
		Concurrency:      r.integer("INGEST_CONCURRENCY", 32, 1, 1024),
		MaxWatches:       r.integer("MAX_WATCHES", 10_000, 1, 1_000_000),
		SeedWatches:      r.list("SEED_WATCHES"),
		SimulatedLatency: r.duration("SIMULATED_LATENCY", 200*time.Millisecond, 0, 30*time.Second),
		ErrorFareRate:    r.float("SIMULATED_ERROR_FARE_RATE", 0.01, 0, 1),

		ShutdownTimeout: r.duration("SHUTDOWN_TIMEOUT", 15*time.Second, time.Second, 2*time.Minute),
	}
	if len(cfg.KafkaBrokers) == 0 {
		r.required("KAFKA_BROKERS")
	}

	level := r.str("LOG_LEVEL", "info")
	if err := cfg.LogLevel.UnmarshalText([]byte(level)); err != nil {
		r.errs = append(r.errs, fmt.Errorf("LOG_LEVEL: nivel inválido %q (debug, info, warn, error)", level))
	}

	// mTLS: o los tres ficheros, o ninguno.
	tlsSet := 0
	for _, f := range []string{cfg.GRPCCertFile, cfg.GRPCKeyFile, cfg.GRPCClientCAFile} {
		if f != "" {
			tlsSet++
		}
	}
	switch {
	case tlsSet != 0 && tlsSet != 3:
		r.errs = append(r.errs, errors.New("mTLS de gRPC: define GRPC_TLS_CERT_FILE, GRPC_TLS_KEY_FILE y GRPC_TLS_CLIENT_CA_FILE juntas"))
	case tlsSet == 0 && !cfg.GRPCInsecureDev:
		r.errs = append(r.errs, errors.New("gRPC sin TLS no está permitido: configura los certificados mTLS o, solo en local, GRPC_INSECURE_DEV=true"))
	case tlsSet == 3 && cfg.GRPCInsecureDev:
		r.errs = append(r.errs, errors.New("GRPC_INSECURE_DEV=true contradice los certificados configurados"))
	}

	if err := errors.Join(r.errs...); err != nil {
		return Config{}, fmt.Errorf("configuración inválida:\n%w", err)
	}
	return cfg, nil
}
