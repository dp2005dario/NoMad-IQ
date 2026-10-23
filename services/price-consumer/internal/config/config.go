// Package config lee la configuración desde variables de entorno.
//
// ¿Por qué variables de entorno? Es la práctica "12-factor": el mismo binario
// (la misma imagen Docker) funciona en tu portátil, en pruebas y en
// producción; solo cambian las variables. Y los secretos (contraseñas) nunca
// se escriben en el código ni se suben a GitHub.
//
// Se validan TODAS las variables y se devuelven todos los errores juntos:
// quien despliega ve de una vez todo lo que falta. Y si la configuración es
// insegura (base de datos sin TLS fuera de desarrollo), el servicio se niega
// a arrancar.
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
	// Kafka
	KafkaBrokers       []string
	KafkaClientID      string
	KafkaGroupID       string
	TopicPriceObserved string
	TopicFareAlerts    string
	TopicDLQ           string
	KafkaTLSCAFile     string // opcional: activa TLS hacia Kafka
	MaxPollRecords     int

	// PostgreSQL (mismos nombres que usan psql y todas las herramientas de PostgreSQL)
	PGHost        string
	PGPort        int
	PGUser        string
	PGPassword    string
	PGDatabase    string
	PGSSLMode     string
	PGSSLRootCert string
	PGMaxConns    int
	DBInsecureDev bool

	// Detector
	MinSamples           int
	DropBasisPoints      int
	ErrorFareBasisPoints int
	HistoryWindow        time.Duration
	HistoryLimit         int
	AlertCooldown        time.Duration
	SeedSubscriptions    []string

	// Bandeja de salida de alertas
	OutboxInterval  time.Duration
	OutboxBatchSize int

	// API de vuelos para la app (detrás de la puerta de entrada, con mTLS)
	APIAddr           string
	TLSCertFile       string
	TLSKeyFile        string
	TLSClientCAFile   string
	HTTPInsecureDev   bool
	MaxWatchesPerUser int
	MaxDaysAhead      int
	DealsFreshness    time.Duration

	// Sincronización de rutas con el flight-ingestor (gRPC)
	IngestorAddr        string // vacío = no se sincroniza
	IngestorCertFile    string
	IngestorKeyFile     string
	IngestorCAFile      string
	IngestorInsecureDev bool
	WatchSyncInterval   time.Duration
	WatchSyncPrune      bool
	PopularRoutes       []string

	HTTPAddr        string
	ShutdownTimeout time.Duration
	LogLevel        slog.Level
}

// LookupFunc tiene la firma de os.LookupEnv; inyectarla facilita los tests.
type LookupFunc func(key string) (string, bool)

type reader struct {
	lookup LookupFunc
	errs   []error
}

func (r *reader) str(key, def string) string {
	if v, ok := r.lookup(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return def
}

func (r *reader) required(key string) string {
	v := r.str(key, "")
	if v == "" {
		r.errs = append(r.errs, fmt.Errorf("%s es obligatoria", key))
	}
	return v
}

// secret lee un secreto SIN recortar espacios (podrían ser parte de él) y
// sin incluir nunca su valor en los mensajes de error.
func (r *reader) secret(key string) string {
	v, ok := r.lookup(key)
	if !ok || v == "" {
		r.errs = append(r.errs, fmt.Errorf("%s es obligatoria", key))
	}
	return v
}

// list lee una lista separada por el separador dado, ignorando huecos.
func (r *reader) list(key, sep string) []string {
	raw := r.str(key, "")
	if raw == "" {
		return nil
	}
	var out []string
	for _, item := range strings.Split(raw, sep) {
		if item = strings.TrimSpace(item); item != "" {
			out = append(out, item)
		}
	}
	return out
}

func (r *reader) duration(key string, def, min, max time.Duration) time.Duration {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: duración inválida %q (ejemplos: 30s, 5m, 720h)", key, raw))
		return def
	}
	if d < min || d > max {
		r.errs = append(r.errs, fmt.Errorf("%s: %s fuera del rango [%s, %s]", key, d, min, max))
	}
	return d
}

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

// allOrNone comprueba un trío de certificados: o los tres, o ninguno con el
// modo inseguro de desarrollo activado (y nunca las dos cosas a la vez).
func (r *reader) allOrNone(names, missing, devFlag string, dev bool, files ...string) {
	set := 0
	for _, f := range files {
		if f != "" {
			set++
		}
	}
	switch {
	case set > 0 && set < len(files):
		r.errs = append(r.errs, fmt.Errorf("%s van juntas: falta alguna", names))
	case set == 0 && !dev:
		r.errs = append(r.errs, errors.New(missing))
	case set == len(files) && dev:
		r.errs = append(r.errs, fmt.Errorf("%s=true contradice los certificados TLS: quita una de las dos", devFlag))
	}
}

// Modos de TLS de PostgreSQL considerados seguros. "verify-full" comprueba
// además que el certificado corresponde al servidor al que nos conectamos
// (evita que alguien se haga pasar por la base de datos).
var secureSSLModes = map[string]bool{"require": true, "verify-ca": true, "verify-full": true}
var allSSLModes = map[string]bool{"disable": true, "allow": true, "prefer": true, "require": true, "verify-ca": true, "verify-full": true}

// Load lee y valida la configuración.
func Load(lookup LookupFunc) (Config, error) {
	r := &reader{lookup: lookup}
	cfg := Config{
		KafkaBrokers:       r.list("KAFKA_BROKERS", ","),
		KafkaClientID:      r.str("KAFKA_CLIENT_ID", "price-consumer"),
		KafkaGroupID:       r.str("KAFKA_GROUP_ID", "price-consumer"),
		TopicPriceObserved: r.str("KAFKA_TOPIC_PRICE_OBSERVED", "flights.price-observed.v1"),
		TopicFareAlerts:    r.str("KAFKA_TOPIC_FARE_ALERTS", "flights.fare-alerts.v1"),
		TopicDLQ:           r.str("KAFKA_TOPIC_DLQ", "flights.price-observed-dlq.v1"),
		KafkaTLSCAFile:     r.str("KAFKA_TLS_CA_FILE", ""),
		MaxPollRecords:     r.integer("KAFKA_MAX_POLL_RECORDS", 500, 1, 10_000),

		PGHost:        r.required("PGHOST"),
		PGPort:        r.integer("PGPORT", 5432, 1, 65535),
		PGUser:        r.required("PGUSER"),
		PGPassword:    r.secret("PGPASSWORD"),
		PGDatabase:    r.required("PGDATABASE"),
		PGSSLMode:     r.str("PGSSLMODE", "verify-full"),
		PGSSLRootCert: r.str("PGSSLROOTCERT", ""),
		PGMaxConns:    r.integer("PG_MAX_CONNS", 10, 1, 500),
		DBInsecureDev: r.boolean("DB_INSECURE_DEV", false),

		MinSamples:           r.integer("DETECTOR_MIN_SAMPLES", 5, 1, 10_000),
		DropBasisPoints:      r.integer("DETECTOR_DROP_BP", 2000, 1, 10_000),
		ErrorFareBasisPoints: r.integer("DETECTOR_ERROR_FARE_BP", 5000, 1, 10_000),
		HistoryWindow:        r.duration("DETECTOR_HISTORY_WINDOW", 30*24*time.Hour, time.Hour, 365*24*time.Hour),
		HistoryLimit:         r.integer("DETECTOR_HISTORY_LIMIT", 200, 1, 10_000),
		AlertCooldown:        r.duration("ALERT_COOLDOWN", 24*time.Hour, 0, 30*24*time.Hour),
		// Separadas por comas; cada una con el formato usuario|CLAVE[|importe|DIVISA].
		SeedSubscriptions: r.list("SEED_SUBSCRIPTIONS", ","),

		OutboxInterval:  r.duration("OUTBOX_INTERVAL", 5*time.Second, 100*time.Millisecond, 10*time.Minute),
		OutboxBatchSize: r.integer("OUTBOX_BATCH_SIZE", 100, 1, 5_000),

		APIAddr:           r.str("API_ADDR", ":8092"),
		TLSCertFile:       r.str("TLS_CERT_FILE", ""),
		TLSKeyFile:        r.str("TLS_KEY_FILE", ""),
		TLSClientCAFile:   r.str("TLS_CLIENT_CA_FILE", ""),
		HTTPInsecureDev:   r.boolean("HTTP_INSECURE_DEV", false),
		MaxWatchesPerUser: r.integer("MAX_WATCHES_PER_USER", 50, 1, 1_000),
		MaxDaysAhead:      r.integer("MAX_DAYS_AHEAD", 330, 1, 730),
		DealsFreshness:    r.duration("DEALS_FRESHNESS", 48*time.Hour, time.Hour, 30*24*time.Hour),

		IngestorAddr:        r.str("INGESTOR_GRPC_ADDR", ""),
		IngestorCertFile:    r.str("INGESTOR_TLS_CERT_FILE", ""),
		IngestorKeyFile:     r.str("INGESTOR_TLS_KEY_FILE", ""),
		IngestorCAFile:      r.str("INGESTOR_TLS_CA_FILE", ""),
		IngestorInsecureDev: r.boolean("INGESTOR_INSECURE_DEV", false),
		WatchSyncInterval:   r.duration("WATCH_SYNC_INTERVAL", time.Minute, 5*time.Second, time.Hour),
		WatchSyncPrune:      r.boolean("WATCH_SYNC_PRUNE", true),
		// Separadas por comas: MAD-JFK,BCN-LIS... (rutas de la portada de chollos).
		PopularRoutes: r.list("POPULAR_ROUTES", ","),

		HTTPAddr:        r.str("HTTP_ADDR", ":8082"),
		ShutdownTimeout: r.duration("SHUTDOWN_TIMEOUT", 15*time.Second, time.Second, 2*time.Minute),
	}
	if len(cfg.KafkaBrokers) == 0 {
		r.required("KAFKA_BROKERS")
	}

	level := r.str("LOG_LEVEL", "info")
	if err := cfg.LogLevel.UnmarshalText([]byte(level)); err != nil {
		r.errs = append(r.errs, fmt.Errorf("LOG_LEVEL: nivel inválido %q (debug, info, warn, error)", level))
	}

	// Zero Trust también con la base de datos: sin cifrado solo en local.
	switch {
	case !allSSLModes[cfg.PGSSLMode]:
		r.errs = append(r.errs, fmt.Errorf("PGSSLMODE: modo desconocido %q (usa verify-full, verify-ca o require)", cfg.PGSSLMode))
	case !secureSSLModes[cfg.PGSSLMode] && !cfg.DBInsecureDev:
		r.errs = append(r.errs, fmt.Errorf("PGSSLMODE=%s no cifra de forma garantizada: usa verify-full o, solo en local, DB_INSECURE_DEV=true", cfg.PGSSLMode))
	case secureSSLModes[cfg.PGSSLMode] && cfg.DBInsecureDev:
		r.errs = append(r.errs, errors.New("DB_INSECURE_DEV=true contradice PGSSLMODE seguro: quita una de las dos"))
	}

	// La API de la app exige mTLS (solo la puerta de entrada puede llamarla).
	r.allOrNone("TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE", "la API exige mTLS: define TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE o, solo en local, HTTP_INSECURE_DEV=true",
		"HTTP_INSECURE_DEV", cfg.HTTPInsecureDev, cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSClientCAFile)
	// Hablar con el flight-ingestor también exige mTLS (si se configura).
	if cfg.IngestorAddr != "" {
		r.allOrNone("INGESTOR_TLS_CERT_FILE, INGESTOR_TLS_KEY_FILE e INGESTOR_TLS_CA_FILE", "el gRPC con el flight-ingestor exige mTLS: define INGESTOR_TLS_CERT_FILE, INGESTOR_TLS_KEY_FILE e INGESTOR_TLS_CA_FILE o, solo en local, INGESTOR_INSECURE_DEV=true",
			"INGESTOR_INSECURE_DEV", cfg.IngestorInsecureDev, cfg.IngestorCertFile, cfg.IngestorKeyFile, cfg.IngestorCAFile)
	}

	if cfg.ErrorFareBasisPoints <= cfg.DropBasisPoints {
		r.errs = append(r.errs, fmt.Errorf("DETECTOR_ERROR_FARE_BP (%d) debe ser mayor que DETECTOR_DROP_BP (%d)", cfg.ErrorFareBasisPoints, cfg.DropBasisPoints))
	}
	if cfg.HistoryLimit < cfg.MinSamples {
		r.errs = append(r.errs, fmt.Errorf("DETECTOR_HISTORY_LIMIT (%d) no puede ser menor que DETECTOR_MIN_SAMPLES (%d)", cfg.HistoryLimit, cfg.MinSamples))
	}

	if err := errors.Join(r.errs...); err != nil {
		return Config{}, fmt.Errorf("configuración inválida:\n%w", err)
	}
	return cfg, nil
}
