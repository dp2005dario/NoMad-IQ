// Tests de la configuración. Cada test simula un conjunto de variables de
// entorno distinto y comprueba que Load acepta lo correcto y rechaza lo inseguro.

package config

import (
	"os"
	"strings"
	"testing"
	"time"
)

// env convierte un mapa en una LookupFunc: así el test decide qué variables
// "existen" sin modificar las variables de entorno reales del ordenador.
func env(m map[string]string) LookupFunc {
	return func(k string) (string, bool) {
		v, ok := m[k]
		return v, ok
	}
}

// Con solo lo obligatorio, el resto debe tomar valores por defecto sensatos.
// También comprueba que los espacios alrededor de las comas se ignoran.
func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"KAFKA_BROKERS":     "kafka-1:9092, kafka-2:9092",
		"GRPC_INSECURE_DEV": "true",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.KafkaBrokers) != 2 || cfg.KafkaBrokers[1] != "kafka-2:9092" {
		t.Errorf("KafkaBrokers = %v", cfg.KafkaBrokers)
	}
	if cfg.PollInterval != 5*time.Minute || cfg.Concurrency != 32 || cfg.TopicPriceObserved != "flights.price-observed.v1" {
		t.Errorf("valores por defecto inesperados: %+v", cfg)
	}
}

// Si hay varios errores, deben aparecer todos en el mismo mensaje: así quien
// despliega los arregla de una vez y no uno por arranque.
func TestLoadReportsAllErrorsAtOnce(t *testing.T) {
	_, err := Load(env(map[string]string{
		"POLL_INTERVAL":      "rápido",
		"INGEST_CONCURRENCY": "0",
		"LOG_LEVEL":          "verbose",
	}))
	if err == nil {
		t.Fatal("se esperaba error")
	}
	for _, want := range []string{"KAFKA_BROKERS", "POLL_INTERVAL", "INGEST_CONCURRENCY", "LOG_LEVEL", "gRPC sin TLS"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("el error no menciona %s:\n%v", want, err)
		}
	}
}

// Reglas de seguridad de gRPC: o certificados completos, o modo desarrollo
// explícito. Cualquier otra combinación debe impedir el arranque.
// Es un "test de tabla": cada fila es un caso con su resultado esperado.
func TestLoadTLSRules(t *testing.T) {
	base := map[string]string{"KAFKA_BROKERS": "k:9092"}
	tests := []struct {
		name    string
		extra   map[string]string
		wantErr bool
	}{
		{name: "sin TLS ni modo dev", extra: nil, wantErr: true},
		{name: "modo dev", extra: map[string]string{"GRPC_INSECURE_DEV": "true"}},
		{name: "TLS incompleto", extra: map[string]string{"GRPC_TLS_CERT_FILE": "c.pem"}, wantErr: true},
		{name: "TLS completo", extra: map[string]string{"GRPC_TLS_CERT_FILE": "c", "GRPC_TLS_KEY_FILE": "k", "GRPC_TLS_CLIENT_CA_FILE": "ca"}},
		{name: "TLS y modo dev a la vez", extra: map[string]string{"GRPC_TLS_CERT_FILE": "c", "GRPC_TLS_KEY_FILE": "k", "GRPC_TLS_CLIENT_CA_FILE": "ca", "GRPC_INSECURE_DEV": "true"}, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := map[string]string{}
			for k, v := range base {
				m[k] = v
			}
			for k, v := range tt.extra {
				m[k] = v
			}
			_, err := Load(env(m))
			if tt.wantErr != (err != nil) {
				t.Fatalf("error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

// El proveedor real exige token y marker; el token puede venir de un fichero
// (secret de Kubernetes) y nunca aparece en los errores.
func TestTravelpayoutsConfig(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"KAFKA_BROKERS": "k:9092", "GRPC_INSECURE_DEV": "true", "FARE_PROVIDER": "travelpayouts"}
	}
	m := base()
	m["TRAVELPAYOUTS_TOKEN"] = "tok-secreto-123"
	m["TRAVELPAYOUTS_MARKER"] = "123456"
	cfg, err := Load(env(m))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TravelpayoutsToken != "tok-secreto-123" || cfg.TravelpayoutsCurrency != "EUR" || cfg.TravelpayoutsRefresh != 30*time.Minute {
		t.Errorf("valores inesperados: %+v", cfg)
	}

	file := t.TempDir() + "/token"
	if err := os.WriteFile(file, []byte("tok-de-fichero\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	m = base()
	m["TRAVELPAYOUTS_TOKEN_FILE"] = file
	m["TRAVELPAYOUTS_MARKER"] = "123456"
	if cfg, err = Load(env(m)); err != nil || cfg.TravelpayoutsToken != "tok-de-fichero" {
		t.Fatalf("token desde fichero: %v %q", err, cfg.TravelpayoutsToken)
	}

	_, err = Load(env(base()))
	if err == nil || !strings.Contains(err.Error(), "TRAVELPAYOUTS_TOKEN") || !strings.Contains(err.Error(), "TRAVELPAYOUTS_MARKER") {
		t.Fatalf("sin token ni marker debe fallar avisando de los dos: %v", err)
	}
	m = base()
	m["TRAVELPAYOUTS_TOKEN"] = "tok-secreto-123"
	m["TRAVELPAYOUTS_TOKEN_FILE"] = file
	m["TRAVELPAYOUTS_MARKER"] = "1"
	if _, err = Load(env(m)); err == nil || strings.Contains(err.Error(), "tok-secreto-123") {
		t.Fatalf("token y fichero a la vez: debe fallar sin enseñar el token: %v", err)
	}
	m = base()
	m["FARE_PROVIDER"] = "skyscanner"
	if _, err = Load(env(m)); err == nil {
		t.Fatal("un proveedor desconocido debe rechazarse")
	}
}
