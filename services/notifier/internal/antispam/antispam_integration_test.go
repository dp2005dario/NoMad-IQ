//go:build integration

// Tests del script Lua contra un Redis REAL:
//
//	REDIS_HOST=localhost REDIS_PASSWORD=... go test -tags integration ./internal/antispam/
package antispam

import (
	"context"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

func gate(t *testing.T, cooldown time.Duration) (*Gate, *redis.Client) {
	t.Helper()
	host := os.Getenv("REDIS_HOST")
	if host == "" {
		t.Skip("REDIS_HOST no definido: se omiten los tests de integración con Redis")
	}
	rdb := redis.NewClient(&redis.Options{Addr: net.JoinHostPort(host, "6379"), Password: os.Getenv("REDIS_PASSWORD")})
	t.Cleanup(func() { _ = rdb.Close() })
	vault, err := sealbox.NewVault([]byte(strings.Repeat("k", 32)))
	if err != nil {
		t.Fatal(err)
	}
	g, err := New(rdb, vault, time.Hour, cooldown)
	if err != nil {
		t.Fatal(err)
	}
	return g, rdb
}

func admit(t *testing.T, g *Gate, who, zone string, urgent bool) Verdict {
	t.Helper()
	v, err := g.Admit(context.Background(), who, zone, urgent)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestCooldownRepeatAndUrgentInRealRedis(t *testing.T) {
	g, rdb := gate(t, time.Hour)
	who := "test-" + uuid.NewString()
	sol, plaza, danger := uuid.NewString(), uuid.NewString(), uuid.NewString()
	if v := admit(t, g, who, sol, false); v != Send {
		t.Fatalf("primera zona: %s", v)
	}
	if v := admit(t, g, who, plaza, false); v != Cooldown {
		t.Fatalf("segunda zona en el enfriamiento: %s", v)
	}
	if v := admit(t, g, who, sol, true); v != Repeat {
		t.Fatalf("la misma zona no se repite ni siendo urgente: %s", v)
	}
	if v := admit(t, g, who, danger, true); v != Send {
		t.Fatalf("urgente se salta el enfriamiento: %s", v)
	}
	if v := admit(t, g, "test-"+uuid.NewString(), plaza, false); v != Send {
		t.Fatalf("otra persona no comparte enfriamiento: %s", v)
	}
	// Las claves no contienen ni el seudónimo ni la zona, y caducan solas.
	zone, cooldown := g.keys(who, sol)
	for _, k := range []string{zone, cooldown} {
		if strings.Contains(k, who) || strings.Contains(k, sol) {
			t.Fatalf("clave reveladora: %s", k)
		}
		if ttl := rdb.PTTL(context.Background(), k).Val(); ttl <= 0 || ttl > time.Hour {
			t.Fatalf("%s sin caducidad correcta: %s", k, ttl)
		}
	}
	if err := g.Release(context.Background(), who, plaza); err != nil {
		t.Fatal(err)
	}
	if v := admit(t, g, who, plaza, false); v != Send {
		t.Fatalf("tras Release se puede volver a intentar: %s", v)
	}
}

func TestNoCooldownMeansOnlyZoneRepeats(t *testing.T) {
	g, _ := gate(t, 0)
	who := "test-" + uuid.NewString()
	if admit(t, g, who, "a", false) != Send || admit(t, g, who, "b", false) != Send || admit(t, g, who, "a", false) != Repeat {
		t.Fatal("con NOTIFY_COOLDOWN=0 solo se evita repetir zona")
	}
}

func TestAdmitOnceIgnoresTheCooldownInRealRedis(t *testing.T) {
	g, _ := gate(t, time.Hour)
	ctx := context.Background()
	who := "test-" + uuid.NewString()
	fare := "fare:" + uuid.NewString()
	// Acaba de recibir un aviso de zona (enfriamiento activo)...
	if v := admit(t, g, who, uuid.NewString(), false); v != Send {
		t.Fatalf("zona: %s", v)
	}
	// ...y aun así la alerta de precio sale, una sola vez.
	if v, err := g.AdmitOnce(ctx, who, fare); err != nil || v != Send {
		t.Fatalf("alerta: %v %s", err, v)
	}
	if v, err := g.AdmitOnce(ctx, who, fare); err != nil || v != Repeat {
		t.Fatalf("alerta repetida: %v %s", err, v)
	}
	// Deshacerla permite reintentar, y el enfriamiento de zona sigue ahí.
	if err := g.ReleaseOnce(ctx, who, fare); err != nil {
		t.Fatal(err)
	}
	if v, err := g.AdmitOnce(ctx, who, fare); err != nil || v != Send {
		t.Fatalf("alerta tras deshacer: %v %s", err, v)
	}
	if v := admit(t, g, who, uuid.NewString(), false); v != Cooldown {
		t.Fatalf("el enfriamiento de zona no debía desaparecer: %s", v)
	}
}
