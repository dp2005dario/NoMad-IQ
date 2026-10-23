package config

import (
	"strings"
	"testing"
	"time"
)

// env convierte un mapa en una LookupFunc: así los tests no tocan las
// variables de entorno reales del ordenador.
func env(m map[string]string) LookupFunc {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func minimal() map[string]string {
	return map[string]string{
		"KAFKA_BROKERS": "localhost:29092",
		"PGHOST":        "localhost",
		"PGUSER":        "nomadiq",
		"PGPASSWORD":    "s3cr3t/+=",
		"PGDATABASE":    "nomadiq",
		// La API de vuelos exige mTLS: con los tres certificados vale.
		"TLS_CERT_FILE":      "/certs/api.crt",
		"TLS_KEY_FILE":       "/certs/api.key",
		"TLS_CLIENT_CA_FILE": "/certs/edge-ca.crt",
	}
}

func TestDefaults(t *testing.T) {
	cfg, err := Load(env(minimal()))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PGSSLMode != "verify-full" || cfg.KafkaGroupID != "price-consumer" || cfg.HTTPAddr != ":8082" ||
		cfg.DropBasisPoints != 2000 || cfg.ErrorFareBasisPoints != 5000 || cfg.HistoryWindow != 30*24*time.Hour ||
		cfg.TopicDLQ != "flights.price-observed-dlq.v1" {
		t.Errorf("valores por defecto inesperados: %+v", cfg)
	}
}

func TestMissingRequiredAreAllReported(t *testing.T) {
	_, err := Load(env(map[string]string{}))
	if err == nil {
		t.Fatal("esperaba error")
	}
	for _, key := range []string{"KAFKA_BROKERS", "PGHOST", "PGUSER", "PGPASSWORD", "PGDATABASE"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("el error debería mencionar %s: %v", key, err)
		}
	}
}

func TestInsecureDatabaseRefused(t *testing.T) {
	m := minimal()
	m["PGSSLMODE"] = "disable"
	if _, err := Load(env(m)); err == nil {
		t.Fatal("sslmode=disable sin DB_INSECURE_DEV debe rechazarse")
	}
	m["DB_INSECURE_DEV"] = "true"
	if _, err := Load(env(m)); err != nil {
		t.Fatalf("en desarrollo local debe permitirse: %v", err)
	}
	m["PGSSLMODE"] = "verify-full"
	if _, err := Load(env(m)); err == nil {
		t.Fatal("DB_INSECURE_DEV con TLS seguro es contradictorio")
	}
}

func TestPasswordNeverInErrors(t *testing.T) {
	m := minimal()
	m["PGPORT"] = "no-numero"
	_, err := Load(env(m))
	if err == nil || strings.Contains(err.Error(), m["PGPASSWORD"]) {
		t.Fatalf("el error no debe contener la contraseña: %v", err)
	}
}

func TestInvalidValues(t *testing.T) {
	cases := map[string]string{
		"DETECTOR_DROP_BP":        "0",
		"DETECTOR_ERROR_FARE_BP":  "1000", // menor que la bajada (2000)
		"DETECTOR_HISTORY_LIMIT":  "2",    // menor que MIN_SAMPLES (5)
		"DETECTOR_HISTORY_WINDOW": "1m",
		"ALERT_COOLDOWN":          "mucho",
		"PGSSLMODE":               "casi",
		"LOG_LEVEL":               "chillón",
	}
	for key, value := range cases {
		t.Run(key, func(t *testing.T) {
			m := minimal()
			m[key] = value
			if _, err := Load(env(m)); err == nil {
				t.Fatalf("%s=%s debería rechazarse", key, value)
			}
		})
	}
}

func TestSeedSubscriptionsList(t *testing.T) {
	m := minimal()
	m["SEED_SUBSCRIPTIONS"] = "ana|MAD-NRT:2026-12-01:ECONOMY, luis|BCN-JFK:2026-12-10:BUSINESS|90000|EUR ,"
	cfg, err := Load(env(m))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.SeedSubscriptions) != 2 || cfg.SeedSubscriptions[1] != "luis|BCN-JFK:2026-12-10:BUSINESS|90000|EUR" {
		t.Errorf("lista mal leída: %q", cfg.SeedSubscriptions)
	}
}

func TestAPIRequiresMTLS(t *testing.T) {
	base := minimal()
	delete(base, "TLS_KEY_FILE")
	if _, err := Load(env(base)); err == nil || !strings.Contains(err.Error(), "van juntas") {
		t.Errorf("con un certificado de menos esperaba error, se obtuvo %v", err)
	}
	delete(base, "TLS_CERT_FILE")
	delete(base, "TLS_CLIENT_CA_FILE")
	if _, err := Load(env(base)); err == nil || !strings.Contains(err.Error(), "exige mTLS") {
		t.Errorf("sin certificados esperaba error, se obtuvo %v", err)
	}
	base["HTTP_INSECURE_DEV"] = "true"
	if _, err := Load(env(base)); err != nil {
		t.Errorf("en local sin TLS debería arrancar: %v", err)
	}
}

func TestIngestorSync(t *testing.T) {
	base := minimal()
	base["INGESTOR_GRPC_ADDR"] = "flight-ingestor:50051"
	if _, err := Load(env(base)); err == nil || !strings.Contains(err.Error(), "INGESTOR_TLS") {
		t.Errorf("sin certificados para el ingestor esperaba error, se obtuvo %v", err)
	}
	base["INGESTOR_INSECURE_DEV"] = "true"
	base["POPULAR_ROUTES"] = "MAD-JFK, BCN-LIS"
	cfg, err := Load(env(base))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.PopularRoutes) != 2 || cfg.WatchSyncInterval != time.Minute || !cfg.WatchSyncPrune || cfg.APIAddr != ":8092" {
		t.Errorf("configuración inesperada: %+v", cfg)
	}
}
