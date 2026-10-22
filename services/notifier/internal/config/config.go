// Package config lee la configuración del notifier desde variables de entorno.
//
// Igual que en el resto de servicios Go de NomadIQ (práctica "12-factor"):
// el mismo binario sirve en tu portátil y en producción, solo cambian las
// variables. Se validan TODAS y se devuelven todos los errores juntos, y si
// la configuración es insegura (sin TLS fuera de desarrollo), el servicio se
// niega a arrancar.
//
// Los secretos (claves) se pueden pasar en una variable o, mejor, en un
// fichero montado (CLAVE_FILE=/run/secrets/...): así no aparecen en
// "docker inspect" ni en la lista de procesos del sistema.
package config

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// MinKeyBytes es el tamaño mínimo de cada clave secreta: 32 bytes = 256 bits.
const MinKeyBytes = 32

// Config es la configuración completa y ya validada del servicio.
type Config struct {
	// Kafka
	KafkaBrokers         []string
	KafkaClientID        string
	KafkaGroupID         string
	TopicRequests        string
	TopicDLQ             string
	KafkaTLSCAFile       string
	KafkaMaxPollRecords  int
	PseudonymKey         []byte // la MISMA clave que usa el geo-engine
	TokenKey             []byte // cifra los tokens de FCM guardados (AES-256)
	MaxRequestAge        time.Duration
	DeliveryTTL          time.Duration
	CooldownPeriod       time.Duration
	ZoneRepeatWindow     time.Duration
	MaxDevicesPerPerson  int
	DeviceInactivityDays int

	// PostgreSQL
	PGHost        string
	PGPort        int
	PGUser        string
	PGPassword    string
	PGDatabase    string
	PGSSLMode     string
	PGSSLRootCert string
	PGMaxConns    int
	DBInsecureDev bool

	// Redis (anti-spam)
	RedisHost        string
	RedisPort        int
	RedisPassword    string
	RedisTLS         bool
	RedisTLSCAFile   string
	RedisInsecureDev bool

	// Envío a Firebase Cloud Messaging
	FCMEndpoint        string // https://fcm.googleapis.com en producción
	FCMProjectID       string
	FCMCredentialsFile string // cuenta de servicio de Google (JSON)
	FCMInsecureDev     bool   // solo local: FCM falso sin credenciales ni TLS
	SendRatePerSecond  float64
	SendBurst          int
	SendWorkers        int
	SendBatch          int
	SendLease          time.Duration
	SendMaxAttempts    int
	SendPollInterval   time.Duration

	// API de registro de teléfonos (detrás del proxy de borde, con mTLS)
	APIAddr         string
	TLSCertFile     string
	TLSKeyFile      string
	TLSClientCAFile string
	HTTPInsecureDev bool

	HealthAddr      string
	ShutdownTimeout time.Duration
	LogLevel        slog.Level
}

// LookupFunc tiene la firma de os.LookupEnv; inyectarla facilita los tests.
type LookupFunc func(key string) (string, bool)

// ReadFileFunc tiene la firma de os.ReadFile (también inyectable en tests).
type ReadFileFunc func(name string) ([]byte, error)

type reader struct {
	lookup   LookupFunc
	readFile ReadFileFunc
	errs     []error
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

// secret lee un secreto SIN recortar espacios y sin incluir nunca su valor
// en los mensajes de error.
func (r *reader) secret(key string) string {
	v, ok := r.lookup(key)
	if !ok || v == "" {
		r.errs = append(r.errs, fmt.Errorf("%s es obligatoria", key))
	}
	return v
}

// key lee una clave en hexadecimal de CLAVE o de CLAVE_FILE (excluyentes).
func (r *reader) key(name string) []byte {
	fileKey := name + "_FILE"
	value, file := r.str(name, ""), r.str(fileKey, "")
	switch {
	case value != "" && file != "":
		r.errs = append(r.errs, fmt.Errorf("%s y %s son excluyentes: usa solo una", name, fileKey))
		return nil
	case file != "":
		raw, err := r.readFile(file)
		if err != nil {
			// La ruta sí se muestra; el contenido, nunca.
			r.errs = append(r.errs, fmt.Errorf("%s: no se pudo leer %s", fileKey, file))
			return nil
		}
		value = strings.TrimSpace(string(raw))
	case value == "":
		r.errs = append(r.errs, fmt.Errorf("%s (o %s) es obligatoria; genera una con: openssl rand -hex 32", name, fileKey))
		return nil
	}
	decoded, err := hex.DecodeString(value)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: debe estar en hexadecimal", name))
		return nil
	}
	if len(decoded) < MinKeyBytes {
		r.errs = append(r.errs, fmt.Errorf("%s: necesita al menos %d bytes (%d caracteres hex)", name, MinKeyBytes, 2*MinKeyBytes))
		return nil
	}
	return decoded
}

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

func (r *reader) duration(key string, def, min, max time.Duration) time.Duration {
	raw := r.str(key, "")
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		r.errs = append(r.errs, fmt.Errorf("%s: duración inválida %q (ejemplos: 30s, 5m, 1h)", key, raw))
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

var secureSSLModes = map[string]bool{"require": true, "verify-ca": true, "verify-full": true}
var allSSLModes = map[string]bool{"disable": true, "allow": true, "prefer": true, "require": true, "verify-ca": true, "verify-full": true}

// Load lee y valida la configuración.
func Load(lookup LookupFunc, readFile ReadFileFunc) (Config, error) {
	if readFile == nil {
		readFile = os.ReadFile
	}
	r := &reader{lookup: lookup, readFile: readFile}
	cfg := Config{
		KafkaBrokers:        r.list("KAFKA_BROKERS"),
		KafkaClientID:       r.str("KAFKA_CLIENT_ID", "notifier"),
		KafkaGroupID:        r.str("KAFKA_GROUP_ID", "notifier"),
		TopicRequests:       r.str("KAFKA_TOPIC_NOTIFY_REQUESTS", "notify.zone-requests.v1"),
		TopicDLQ:            r.str("KAFKA_TOPIC_NOTIFY_REQUESTS_DLQ", "notify.zone-requests-dlq.v1"),
		KafkaTLSCAFile:      r.str("KAFKA_TLS_CA_FILE", ""),
		KafkaMaxPollRecords: r.integer("KAFKA_MAX_POLL_RECORDS", 500, 1, 10_000),
		PseudonymKey:        r.key("NOTIFY_PSEUDONYM_KEY"),
		TokenKey:            r.key("NOTIFY_TOKEN_KEY"),
		// Un "acabas de llegar" con más de 10 minutos ya no sirve: la persona
		// puede estar en otro sitio. Se descarta en lugar de molestar.
		MaxRequestAge: r.duration("NOTIFY_MAX_REQUEST_AGE", 10*time.Minute, 30*time.Second, 2*time.Hour),
		DeliveryTTL:   r.duration("NOTIFY_DELIVERY_TTL", 10*time.Minute, 30*time.Second, 2*time.Hour),
		// Anti-spam: como mucho un aviso cada 45 minutos por persona...
		CooldownPeriod: r.duration("NOTIFY_COOLDOWN", 45*time.Minute, 0, 24*time.Hour),
		// ...y nunca dos veces la misma zona en el mismo día.
		ZoneRepeatWindow:     r.duration("NOTIFY_ZONE_REPEAT_WINDOW", 24*time.Hour, time.Minute, 30*24*time.Hour),
		MaxDevicesPerPerson:  r.integer("NOTIFY_MAX_DEVICES", 5, 1, 50),
		DeviceInactivityDays: r.integer("NOTIFY_DEVICE_INACTIVITY_DAYS", 60, 1, 365),

		PGHost:        r.required("PGHOST"),
		PGPort:        r.integer("PGPORT", 5432, 1, 65535),
		PGUser:        r.required("PGUSER"),
		PGPassword:    r.secret("PGPASSWORD"),
		PGDatabase:    r.required("PGDATABASE"),
		PGSSLMode:     r.str("PGSSLMODE", "verify-full"),
		PGSSLRootCert: r.str("PGSSLROOTCERT", ""),
		PGMaxConns:    r.integer("PG_MAX_CONNS", 10, 1, 500),
		DBInsecureDev: r.boolean("DB_INSECURE_DEV", false),

		RedisHost:        r.required("REDIS_HOST"),
		RedisPort:        r.integer("REDIS_PORT", 6379, 1, 65535),
		RedisPassword:    r.secret("REDIS_PASSWORD"),
		RedisTLS:         r.boolean("REDIS_TLS", true),
		RedisTLSCAFile:   r.str("REDIS_TLS_CA_FILE", ""),
		RedisInsecureDev: r.boolean("REDIS_INSECURE_DEV", false),

		FCMEndpoint:        r.str("FCM_ENDPOINT", "https://fcm.googleapis.com"),
		FCMProjectID:       r.required("FCM_PROJECT_ID"),
		FCMCredentialsFile: r.str("FCM_CREDENTIALS_FILE", ""),
		FCMInsecureDev:     r.boolean("FCM_INSECURE_DEV", false),
		// 50 envíos/s por copia: muy por debajo del límite de FCM (600.000
		// por minuto y proyecto), así una avalancha nunca agota la cuota.
		SendRatePerSecond: r.float("SEND_RATE_PER_SECOND", 50, 0.1, 10_000),
		SendBurst:         r.integer("SEND_BURST", 50, 1, 10_000),
		SendWorkers:       r.integer("SEND_WORKERS", 8, 1, 256),
		SendBatch:         r.integer("SEND_BATCH", 100, 1, 1_000),
		SendLease:         r.duration("SEND_LEASE", time.Minute, 5*time.Second, 30*time.Minute),
		SendMaxAttempts:   r.integer("SEND_MAX_ATTEMPTS", 5, 1, 50),
		SendPollInterval:  r.duration("SEND_POLL_INTERVAL", time.Second, 100*time.Millisecond, time.Minute),

		APIAddr:         r.str("API_ADDR", ":8089"),
		TLSCertFile:     r.str("TLS_CERT_FILE", ""),
		TLSKeyFile:      r.str("TLS_KEY_FILE", ""),
		TLSClientCAFile: r.str("TLS_CLIENT_CA_FILE", ""),
		HTTPInsecureDev: r.boolean("HTTP_INSECURE_DEV", false),

		HealthAddr:      r.str("HEALTH_ADDR", ":8090"),
		ShutdownTimeout: r.duration("SHUTDOWN_TIMEOUT", 15*time.Second, time.Second, 2*time.Minute),
	}
	if len(cfg.KafkaBrokers) == 0 {
		r.required("KAFKA_BROKERS")
	}

	level := r.str("LOG_LEVEL", "info")
	if err := cfg.LogLevel.UnmarshalText([]byte(level)); err != nil {
		r.errs = append(r.errs, fmt.Errorf("LOG_LEVEL: nivel inválido %q (debug, info, warn, error)", level))
	}

	// Dos claves distintas para dos usos distintos: si se filtrara una, la
	// otra sigue protegiendo lo suyo.
	if cfg.PseudonymKey != nil && cfg.TokenKey != nil && string(cfg.PseudonymKey) == string(cfg.TokenKey) {
		r.errs = append(r.errs, errors.New("NOTIFY_PSEUDONYM_KEY y NOTIFY_TOKEN_KEY deben ser claves distintas"))
	}

	// --- Zero Trust: sin cifrado solo en local, y siempre a propósito ---
	switch {
	case !allSSLModes[cfg.PGSSLMode]:
		r.errs = append(r.errs, fmt.Errorf("PGSSLMODE: modo desconocido %q (usa verify-full)", cfg.PGSSLMode))
	case !secureSSLModes[cfg.PGSSLMode] && !cfg.DBInsecureDev:
		r.errs = append(r.errs, fmt.Errorf("PGSSLMODE=%s no cifra de forma garantizada: usa verify-full o, solo en local, DB_INSECURE_DEV=true", cfg.PGSSLMode))
	case secureSSLModes[cfg.PGSSLMode] && cfg.DBInsecureDev:
		r.errs = append(r.errs, errors.New("DB_INSECURE_DEV=true contradice PGSSLMODE seguro: quita una de las dos"))
	}
	if !cfg.RedisTLS && !cfg.RedisInsecureDev {
		r.errs = append(r.errs, errors.New("REDIS_TLS=false solo se permite con REDIS_INSECURE_DEV=true (solo en local)"))
	}
	if cfg.RedisTLS && cfg.RedisInsecureDev {
		r.errs = append(r.errs, errors.New("REDIS_INSECURE_DEV=true contradice REDIS_TLS=true: quita una de las dos"))
	}

	tlsFiles := []string{cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSClientCAFile}
	set := 0
	for _, f := range tlsFiles {
		if f != "" {
			set++
		}
	}
	switch {
	case set > 0 && set < len(tlsFiles):
		r.errs = append(r.errs, errors.New("TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE van juntas: falta alguna"))
	case set == 0 && !cfg.HTTPInsecureDev:
		r.errs = append(r.errs, errors.New("la API exige mTLS: define TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE o, solo en local, HTTP_INSECURE_DEV=true"))
	case set == len(tlsFiles) && cfg.HTTPInsecureDev:
		r.errs = append(r.errs, errors.New("HTTP_INSECURE_DEV=true contradice los certificados TLS: quita una de las dos"))
	}

	endpoint, err := url.Parse(cfg.FCMEndpoint)
	switch {
	case err != nil || endpoint.Host == "" || endpoint.User != nil || (endpoint.Path != "" && endpoint.Path != "/"):
		r.errs = append(r.errs, fmt.Errorf("FCM_ENDPOINT: URL inválida %q (ejemplo: https://fcm.googleapis.com)", cfg.FCMEndpoint))
	case endpoint.Scheme != "https" && !cfg.FCMInsecureDev:
		r.errs = append(r.errs, errors.New("FCM_ENDPOINT debe usar https (http solo con FCM_INSECURE_DEV=true, en local)"))
	}
	switch {
	case cfg.FCMCredentialsFile == "" && !cfg.FCMInsecureDev:
		r.errs = append(r.errs, errors.New("FCM_CREDENTIALS_FILE es obligatoria (o, solo en local con el FCM falso, FCM_INSECURE_DEV=true)"))
	case cfg.FCMCredentialsFile != "" && cfg.FCMInsecureDev:
		r.errs = append(r.errs, errors.New("FCM_INSECURE_DEV=true contradice FCM_CREDENTIALS_FILE: quita una de las dos"))
	}
	if cfg.FCMProjectID != "" && !validProjectID(cfg.FCMProjectID) {
		r.errs = append(r.errs, fmt.Errorf("FCM_PROJECT_ID: identificador inválido %q", cfg.FCMProjectID))
	}

	// El préstamo de un lote tiene que dar tiempo a enviarlo entero al ritmo
	// permitido; si no, otra copia lo cogería a medias y se duplicarían avisos.
	if need := time.Duration(float64(cfg.SendBatch) / cfg.SendRatePerSecond * float64(time.Second)); need*2 > cfg.SendLease {
		r.errs = append(r.errs, fmt.Errorf("SEND_LEASE (%s) es corto para SEND_BATCH=%d a %g/s: usa al menos %s", cfg.SendLease, cfg.SendBatch, cfg.SendRatePerSecond, (need*2).Round(time.Second)))
	}

	if err := errors.Join(r.errs...); err != nil {
		return Config{}, fmt.Errorf("configuración inválida:\n%w", err)
	}
	return cfg, nil
}

// validProjectID sigue las reglas de Google Cloud: 6-30 caracteres,
// minúsculas, dígitos y guiones. Se valida porque va dentro de una URL.
func validProjectID(id string) bool {
	if len(id) < 6 || len(id) > 30 {
		return false
	}
	for _, c := range id {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
			return false
		}
	}
	return true
}
