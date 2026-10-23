package config

import (
	"errors"
	"strings"
	"testing"
	"time"
)

var (
	keyA = strings.Repeat("0a", 32)
	keyB = strings.Repeat("0b", 32)
)

func dev() map[string]string {
	return map[string]string{
		"KAFKA_BROKERS": "localhost:29092", "PGHOST": "localhost", "PGUSER": "nomadiq", "PGPASSWORD": "secreto",
		"PGDATABASE": "nomadiq", "PGSSLMODE": "disable", "DB_INSECURE_DEV": "true",
		"REDIS_HOST": "localhost", "REDIS_PASSWORD": "secreto", "REDIS_TLS": "false", "REDIS_INSECURE_DEV": "true",
		"NOTIFY_PSEUDONYM_KEY": keyA, "NOTIFY_TOKEN_KEY": keyB,
		"FCM_PROJECT_ID": "nomadiq-dev", "FCM_ENDPOINT": "http://localhost:8099", "FCM_INSECURE_DEV": "true",
		"HTTP_INSECURE_DEV": "true",
	}
}

func load(vars map[string]string, files map[string]string) (Config, error) {
	return Load(func(k string) (string, bool) { v, ok := vars[k]; return v, ok },
		func(name string) ([]byte, error) {
			if v, ok := files[name]; ok {
				return []byte(v), nil
			}
			return nil, errors.New("no existe")
		})
}

func TestDevConfigIsValid(t *testing.T) {
	cfg, err := load(dev(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CooldownPeriod != 45*time.Minute || cfg.ZoneRepeatWindow != 24*time.Hour || cfg.TopicRequests != "notify.zone-requests.v1" {
		t.Errorf("valores por defecto inesperados: %+v", cfg)
	}
	if len(cfg.PseudonymKey) != 32 || cfg.APIAddr != ":8089" || cfg.HealthAddr != ":8090" {
		t.Errorf("claves o puertos inesperados")
	}
}

func TestEmptyConfigListsEveryProblemWithoutLeakingSecrets(t *testing.T) {
	_, err := load(map[string]string{}, nil)
	if err == nil {
		t.Fatal("debería fallar")
	}
	for _, want := range []string{"KAFKA_BROKERS", "PGHOST", "PGPASSWORD", "REDIS_HOST", "NOTIFY_PSEUDONYM_KEY", "NOTIFY_TOKEN_KEY", "FCM_PROJECT_ID", "FCM_CREDENTIALS_FILE", "mTLS"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("falta el error sobre %s", want)
		}
	}
	vars := dev()
	vars["NOTIFY_TOKEN_KEY"] = "zz" + keyB[2:]
	_, err = load(vars, nil)
	if err == nil || strings.Contains(err.Error(), keyB[2:]) {
		t.Fatalf("una clave mala no debe aparecer en el error: %v", err)
	}
}

func TestUnsafeOrContradictoryConfigIsRejected(t *testing.T) {
	cases := map[string]func(map[string]string){
		"misma clave para todo":  func(v map[string]string) { v["NOTIFY_TOKEN_KEY"] = keyA },
		"clave corta":            func(v map[string]string) { v["NOTIFY_PSEUDONYM_KEY"] = "abcd" },
		"clave y fichero":        func(v map[string]string) { v["NOTIFY_PSEUDONYM_KEY_FILE"] = "/run/secrets/k" },
		"FCM por http":           func(v map[string]string) { delete(v, "FCM_INSECURE_DEV"); v["FCM_CREDENTIALS_FILE"] = "/sa.json" },
		"FCM falso y credencial": func(v map[string]string) { v["FCM_CREDENTIALS_FILE"] = "/sa.json" },
		"endpoint con ruta":      func(v map[string]string) { v["FCM_ENDPOINT"] = "http://localhost:8099/x" },
		"proyecto raro":          func(v map[string]string) { v["FCM_PROJECT_ID"] = "Proyecto/../x" },
		"redis sin tls":          func(v map[string]string) { delete(v, "REDIS_INSECURE_DEV") },
		"postgres sin tls":       func(v map[string]string) { delete(v, "DB_INSECURE_DEV") },
		"tls a medias":           func(v map[string]string) { delete(v, "HTTP_INSECURE_DEV"); v["TLS_CERT_FILE"] = "/c.pem" },
		"préstamo corto":         func(v map[string]string) { v["SEND_RATE_PER_SECOND"] = "1"; v["SEND_BATCH"] = "100" },
		"enfriamiento de un año": func(v map[string]string) { v["NOTIFY_COOLDOWN"] = "8760h" },
		"topics mezclados":       func(v map[string]string) { v["KAFKA_TOPIC_FARE_ALERTS"] = "notify.zone-requests.v1" },
		"alerta de una semana":   func(v map[string]string) { v["NOTIFY_FARE_MAX_ALERT_AGE"] = "168h" },
	}
	for name, mutate := range cases {
		vars := dev()
		mutate(vars)
		if _, err := load(vars, nil); err == nil {
			t.Errorf("%s: debería rechazarse", name)
		}
	}
}

func TestKeysCanComeFromFiles(t *testing.T) {
	vars := dev()
	delete(vars, "NOTIFY_PSEUDONYM_KEY")
	vars["NOTIFY_PSEUDONYM_KEY_FILE"] = "/run/secrets/pseudonym"
	cfg, err := load(vars, map[string]string{"/run/secrets/pseudonym": keyA + "\n"})
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.PseudonymKey) != 32 {
		t.Fatal("la clave del fichero debe leerse (sin el salto de línea)")
	}
	if _, err := load(vars, nil); err == nil || !strings.Contains(err.Error(), "/run/secrets/pseudonym") {
		t.Fatalf("un fichero que no existe debe dar un error claro: %v", err)
	}
}
