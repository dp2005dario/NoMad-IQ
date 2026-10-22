//go:build integration

// Tests contra un PostgreSQL REAL (la etiqueta "integration" los separa de
// los unitarios). Se lanzan con:
//
//	PGHOST=localhost PGUSER=... PGPASSWORD=... PGDATABASE=... go test -tags integration ./internal/store/
package store

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/api"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/intake"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

func openTestDB(t *testing.T, maxDevices int) (*Postgres, *sealbox.Vault) {
	t.Helper()
	port, _ := strconv.Atoi(os.Getenv("PGPORT"))
	if port == 0 {
		port = 5432
	}
	cfg := Config{Host: os.Getenv("PGHOST"), Port: port, User: os.Getenv("PGUSER"), Password: os.Getenv("PGPASSWORD"),
		Database: os.Getenv("PGDATABASE"), SSLMode: "disable", MaxConns: 4}
	if cfg.Host == "" {
		t.Skip("PGHOST no definido: se omiten los tests de integración con PostgreSQL")
	}
	vault, err := sealbox.NewVault(bytes.Repeat([]byte{3}, 32))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	db, err := Open(ctx, cfg, vault, maxDevices)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	return db, vault
}

// recipient da un seudónimo único por test (la base de datos se comparte).
func recipient() string {
	id := uuid.New()
	s := []byte("TESTxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
	copy(s[4:], []byte(uuid.NewSHA1(id, nil).String()[:32]))
	for i := range s {
		if s[i] == '-' {
			s[i] = '_'
		}
	}
	return string(s)
}

func register(t *testing.T, db *Postgres, who, token string) (string, []byte) {
	t.Helper()
	pub, priv, err := sealbox.GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.NewString()
	if err := db.RegisterDevice(context.Background(), api.Registration{DeviceID: id, Recipient: who, Platform: "android", FCMToken: token, PublicKey: pub}); err != nil {
		t.Fatal(err)
	}
	return id, priv
}

func TestDevicesAreOwnedLimitedAndDeduplicated(t *testing.T) {
	db, _ := openTestDB(t, 2)
	ctx := context.Background()
	ana, eva := recipient(), recipient()
	first, _ := register(t, db, ana, "tok-"+uuid.NewString())
	time.Sleep(10 * time.Millisecond)
	register(t, db, ana, "tok-"+uuid.NewString())
	time.Sleep(10 * time.Millisecond)
	register(t, db, ana, "tok-"+uuid.NewString())
	devices, err := db.DevicesFor(ctx, ana)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 {
		t.Fatalf("como mucho 2 teléfonos por persona, hay %d", len(devices))
	}
	for _, d := range devices {
		if d.DeviceID == first {
			t.Fatal("se debe olvidar el teléfono más antiguo")
		}
	}

	// Otra persona no puede quedarse con un device_id ajeno...
	pub, _, _ := sealbox.GenerateDeviceKeys()
	err = db.RegisterDevice(ctx, api.Registration{DeviceID: devices[0].DeviceID, Recipient: eva, Platform: "android", FCMToken: "tok-x-" + uuid.NewString(), PublicKey: pub})
	if !errors.Is(err, api.ErrDeviceOwnedByOther) {
		t.Fatalf("se esperaba ErrDeviceOwnedByOther, llegó %v", err)
	}
	// ...pero el MISMO token (mismo teléfono, otra cuenta) sí se mueve.
	shared := "tok-shared-" + uuid.NewString()
	register(t, db, ana, shared)
	register(t, db, eva, shared)
	for who, want := range map[string]int{eva: 1} {
		got, _ := db.DevicesFor(ctx, who)
		if len(got) != want {
			t.Fatalf("eva debería tener %d teléfono, tiene %d", want, len(got))
		}
	}
	// El token nunca se guarda en claro.
	var raw []byte
	if err := db.pool.QueryRow(ctx, `SELECT token_ciphertext FROM notify.devices WHERE recipient = $1`, eva).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(shared)) {
		t.Fatal("token en claro en la base de datos")
	}
}

func TestTheQueueLeasesRetriesAndCascades(t *testing.T) {
	db, vault := openTestDB(t, 5)
	ctx := context.Background()
	who := recipient()
	token := "tok-" + uuid.NewString()
	device, _ := register(t, db, who, token)
	if err := db.Enqueue(ctx, []intake.Delivery{
		{DeviceID: device, Envelope: []byte("sobre-1"), ExpiresAt: time.Now().Add(time.Minute)},
		{DeviceID: uuid.NewString(), Envelope: []byte("de un teléfono que no existe"), ExpiresAt: time.Now().Add(time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	claimed, err := db.Claim(ctx, 100, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	var mine []int64
	for _, p := range claimed {
		if p.DeviceID == device {
			mine = append(mine, p.ID)
			got, err := vault.DecryptToken(p.DeviceID, p.TokenCiphertext)
			if err != nil || got != token || p.Attempts != 1 || string(p.Envelope) != "sobre-1" {
				t.Fatalf("aviso prestado inesperado: %+v (%v)", p, err)
			}
		}
	}
	if len(mine) != 1 {
		t.Fatalf("se esperaba 1 aviso de este teléfono (el huérfano no entra), hay %d", len(mine))
	}
	// Prestado: nadie más lo coge.
	again, _ := db.Claim(ctx, 100, time.Minute)
	for _, p := range again {
		if p.ID == mine[0] {
			t.Fatal("un aviso prestado no se puede coger dos veces")
		}
	}
	// Reintento inmediato: vuelve a estar disponible, con un intento más.
	if err := db.Retry(ctx, mine[0], time.Now().Add(-time.Second), "503"); err != nil {
		t.Fatal(err)
	}
	again, _ = db.Claim(ctx, 100, time.Minute)
	found := false
	for _, p := range again {
		if p.ID == mine[0] {
			found = p.Attempts == 2
		}
	}
	if !found {
		t.Fatal("tras Retry el aviso vuelve con attempts = 2")
	}
	// Olvidar el teléfono borra en cascada sus avisos.
	if err := db.ForgetDevice(ctx, device); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := db.pool.QueryRow(ctx, `SELECT count(*) FROM notify.deliveries WHERE device_id = $1`, device).Scan(&n); err != nil || n != 0 {
		t.Fatalf("quedan %d avisos de un teléfono olvidado (%v)", n, err)
	}
}

func TestCleanupForgetsSilentPhonesAndExpiredDeliveries(t *testing.T) {
	db, _ := openTestDB(t, 5)
	ctx := context.Background()
	who := recipient()
	old, _ := register(t, db, who, "tok-"+uuid.NewString())
	fresh, _ := register(t, db, who, "tok-"+uuid.NewString())
	if _, err := db.pool.Exec(ctx, `UPDATE notify.devices SET last_seen_at = now() - interval '90 days' WHERE device_id = $1`, old); err != nil {
		t.Fatal(err)
	}
	if err := db.Enqueue(ctx, []intake.Delivery{{DeviceID: fresh, Envelope: []byte("x"), ExpiresAt: time.Now().Add(-time.Second)}}); err != nil {
		t.Fatal(err)
	}
	devices, deliveries, err := db.Cleanup(ctx, 60*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if devices < 1 || deliveries < 1 {
		t.Fatalf("limpieza: %d teléfonos, %d avisos", devices, deliveries)
	}
	left, _ := db.DevicesFor(ctx, who)
	if len(left) != 1 || left[0].DeviceID != fresh {
		t.Fatalf("debe quedar solo el teléfono activo: %+v", left)
	}
	if err := db.DeleteDevice(ctx, who, fresh); err != nil {
		t.Fatal(err)
	}
}
