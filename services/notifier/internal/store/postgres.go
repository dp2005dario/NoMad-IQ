// Package store guarda los teléfonos y la cola de avisos en PostgreSQL (pgx).
//
// Reglas de seguridad (las mismas que en el resto de servicios):
//   - SIEMPRE consultas con parámetros ($1, $2...), nunca texto pegado en el SQL.
//   - La contraseña nunca aparece en logs ni en mensajes de error.
//   - TLS obligatorio con la base de datos salvo en desarrollo local.
//
// Y las propias del notifier: los tokens de FCM se guardan cifrados
// (AES-256-GCM) y las personas solo aparecen como seudónimos.
package store

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/api"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/intake"
	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sender"
)

// Config son los datos de conexión a PostgreSQL.
type Config struct {
	Host        string
	Port        int
	User        string
	Password    string
	Database    string
	SSLMode     string
	SSLRootCert string
	MaxConns    int32
}

func (c Config) connString() string {
	q := url.Values{}
	q.Set("sslmode", c.SSLMode)
	if c.SSLRootCert != "" {
		q.Set("sslrootcert", c.SSLRootCert)
	}
	q.Set("application_name", "notifier")
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(c.User, c.Password),
		Host:     net.JoinHostPort(c.Host, strconv.Itoa(c.Port)),
		Path:     "/" + c.Database,
		RawQuery: q.Encode(),
	}
	return u.String()
}

// TokenSealer cifra tokens de FCM y calcula su índice ciego (sealbox.Vault).
type TokenSealer interface {
	EncryptToken(deviceID, token string) ([]byte, error)
	TokenIndex(token string) []byte
}

// Postgres implementa las interfaces de intake, sender y api.
type Postgres struct {
	pool       *pgxpool.Pool
	tokens     TokenSealer
	maxDevices int
}

// Comprobaciones en tiempo de compilación: si Postgres dejara de cumplir
// alguna interfaz, el programa no compilaría.
var (
	_ intake.Directory = (*Postgres)(nil)
	_ intake.Outbox    = (*Postgres)(nil)
	_ sender.Queue     = (*Postgres)(nil)
	_ api.Registry     = (*Postgres)(nil)
)

// Open crea el pool de conexiones.
func Open(ctx context.Context, cfg Config, tokens TokenSealer, maxDevices int) (*Postgres, error) {
	if tokens == nil || maxDevices < 1 {
		return nil, errors.New("store: faltan dependencias")
	}
	pcfg, err := pgxpool.ParseConfig(cfg.connString())
	if err != nil {
		// No se incluye err tal cual por si contuviera la URL con la contraseña.
		return nil, errors.New("store: configuración de PostgreSQL inválida (revisa PGHOST, PGPORT, PGSSLMODE...)")
	}
	pcfg.MaxConns = cfg.MaxConns
	pcfg.MaxConnIdleTime = 5 * time.Minute
	pcfg.HealthCheckPeriod = 30 * time.Second
	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		return nil, fmt.Errorf("store: crear pool: %w", err)
	}
	return &Postgres{pool: pool, tokens: tokens, maxDevices: maxDevices}, nil
}

// Ping comprueba que la base de datos responde.
func (p *Postgres) Ping(ctx context.Context) error {
	if err := p.pool.Ping(ctx); err != nil {
		return fmt.Errorf("store: ping a PostgreSQL: %w", err)
	}
	return nil
}

// Close cierra todas las conexiones.
func (p *Postgres) Close() { p.pool.Close() }

// ---------------------------------------------------------------------------
// Teléfonos
// ---------------------------------------------------------------------------

// RegisterDevice registra o renueva un teléfono, todo en una transacción.
func (p *Postgres) RegisterDevice(ctx context.Context, r api.Registration) error {
	sealed, err := p.tokens.EncryptToken(r.DeviceID, r.FCMToken)
	if err != nil {
		return err
	}
	index := p.tokens.TokenIndex(r.FCMToken)
	return pgx.BeginTxFunc(ctx, p.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		// El mismo token de FCM bajo OTRO device_id es el mismo teléfono
		// (reinstalación, o cambio de cuenta en un móvil compartido): la fila
		// vieja sobra. Solo el teléfono conoce su token, así que esto no
		// permite "robar" el de nadie.
		if _, err := tx.Exec(ctx, `DELETE FROM notify.devices WHERE token_index = $1 AND device_id <> $2`, index, r.DeviceID); err != nil {
			return fmt.Errorf("store: registrar teléfono: %w", err)
		}
		// Si el device_id ya existe y es de OTRA persona, no se toca (el
		// WHERE del DO UPDATE no se cumple y no se actualiza ninguna fila):
		// nadie puede "secuestrar" el teléfono de otro adivinando su id.
		tag, err := tx.Exec(ctx, `
			INSERT INTO notify.devices (device_id, recipient, platform, token_ciphertext, token_index, public_key)
			VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (device_id) DO UPDATE
			   SET platform = EXCLUDED.platform,
			       token_ciphertext = EXCLUDED.token_ciphertext,
			       token_index = EXCLUDED.token_index,
			       public_key = EXCLUDED.public_key,
			       last_seen_at = now()
			 WHERE notify.devices.recipient = EXCLUDED.recipient`,
			r.DeviceID, r.Recipient, r.Platform, sealed, index, r.PublicKey)
		if err != nil {
			return fmt.Errorf("store: registrar teléfono: %w", err)
		}
		if tag.RowsAffected() == 0 {
			return api.ErrDeviceOwnedByOther
		}
		// Como mucho NOTIFY_MAX_DEVICES teléfonos por persona: se olvidan
		// los que llevan más tiempo sin dar señales.
		if _, err := tx.Exec(ctx, `
			DELETE FROM notify.devices WHERE device_id IN (
			    SELECT device_id FROM notify.devices WHERE recipient = $1
			    ORDER BY last_seen_at DESC OFFSET $2)`, r.Recipient, p.maxDevices); err != nil {
			return fmt.Errorf("store: limitar teléfonos: %w", err)
		}
		return nil
	})
}

// DeleteDevice borra un teléfono (solo si es de esa persona).
func (p *Postgres) DeleteDevice(ctx context.Context, recipient, deviceID string) error {
	if _, err := p.pool.Exec(ctx, `DELETE FROM notify.devices WHERE device_id = $1 AND recipient = $2`, deviceID, recipient); err != nil {
		return fmt.Errorf("store: borrar teléfono: %w", err)
	}
	return nil
}

// DevicesFor devuelve los teléfonos de un seudónimo (los más recientes primero).
func (p *Postgres) DevicesFor(ctx context.Context, recipient string) ([]intake.Target, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT device_id::text, public_key FROM notify.devices
		 WHERE recipient = $1 ORDER BY last_seen_at DESC LIMIT $2`, recipient, p.maxDevices)
	if err != nil {
		return nil, fmt.Errorf("store: buscar teléfonos: %w", err)
	}
	targets, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (intake.Target, error) {
		var t intake.Target
		err := row.Scan(&t.DeviceID, &t.PublicKey)
		return t, err
	})
	if err != nil {
		return nil, fmt.Errorf("store: buscar teléfonos: %w", err)
	}
	return targets, nil
}

// ForgetDevice borra un teléfono que Google ya no reconoce (y, en cascada,
// sus avisos pendientes).
func (p *Postgres) ForgetDevice(ctx context.Context, deviceID string) error {
	if _, err := p.pool.Exec(ctx, `DELETE FROM notify.devices WHERE device_id = $1`, deviceID); err != nil {
		return fmt.Errorf("store: olvidar teléfono: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Cola de avisos
// ---------------------------------------------------------------------------

// Enqueue mete los avisos en la cola, todos en una sola sentencia (o todos
// o ninguno). unnest convierte las listas en filas.
func (p *Postgres) Enqueue(ctx context.Context, deliveries []intake.Delivery) error {
	if len(deliveries) == 0 {
		return nil
	}
	ids := make([]string, len(deliveries))
	envelopes := make([][]byte, len(deliveries))
	expires := make([]time.Time, len(deliveries))
	for i, d := range deliveries {
		ids[i], envelopes[i], expires[i] = d.DeviceID, d.Envelope, d.ExpiresAt
	}
	// Si el teléfono se borró entre medias, su aviso simplemente no entra
	// (el JOIN lo descarta) en vez de romper la sentencia por la clave foránea.
	_, err := p.pool.Exec(ctx, `
		INSERT INTO notify.deliveries (device_id, envelope, expires_at)
		SELECT d.device_id, n.envelope, n.expires_at
		  FROM unnest($1::text[], $2::bytea[], $3::timestamptz[]) AS n(device_id, envelope, expires_at)
		  JOIN notify.devices d ON d.device_id = n.device_id::uuid`, ids, envelopes, expires)
	if err != nil {
		return fmt.Errorf("store: encolar avisos: %w", err)
	}
	return nil
}

// Claim presta hasta limit avisos listos. FOR UPDATE SKIP LOCKED: si otra
// copia está cogiendo filas a la vez, cada una se salta las de la otra en
// lugar de esperar. El préstamo (locked_until) evita que se cojan dos veces.
func (p *Postgres) Claim(ctx context.Context, limit int, lease time.Duration) ([]sender.Push, error) {
	rows, err := p.pool.Query(ctx, `
		WITH picked AS (
		    SELECT delivery_id FROM notify.deliveries
		     WHERE available_at <= now() AND (locked_until IS NULL OR locked_until < now())
		     ORDER BY available_at
		     LIMIT $1
		     FOR UPDATE SKIP LOCKED)
		UPDATE notify.deliveries q
		   SET locked_until = now() + make_interval(secs => $2), attempts = q.attempts + 1
		  FROM picked, notify.devices d
		 WHERE q.delivery_id = picked.delivery_id AND d.device_id = q.device_id
		RETURNING q.delivery_id, q.device_id::text, q.envelope, q.attempts, q.expires_at, d.token_ciphertext`,
		limit, lease.Seconds())
	if err != nil {
		return nil, fmt.Errorf("store: coger avisos: %w", err)
	}
	pushes, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (sender.Push, error) {
		var s sender.Push
		err := row.Scan(&s.ID, &s.DeviceID, &s.Envelope, &s.Attempts, &s.ExpiresAt, &s.TokenCiphertext)
		return s, err
	})
	if err != nil {
		return nil, fmt.Errorf("store: coger avisos: %w", err)
	}
	return pushes, nil
}

// Delete quita un aviso de la cola (enviado, caducado o abandonado).
func (p *Postgres) Delete(ctx context.Context, id int64) error {
	if _, err := p.pool.Exec(ctx, `DELETE FROM notify.deliveries WHERE delivery_id = $1`, id); err != nil {
		return fmt.Errorf("store: borrar aviso: %w", err)
	}
	return nil
}

// Retry devuelve un aviso a la cola para más tarde.
func (p *Postgres) Retry(ctx context.Context, id int64, at time.Time, reason string) error {
	if len(reason) > 300 {
		reason = reason[:300]
	}
	if _, err := p.pool.Exec(ctx, `
		UPDATE notify.deliveries SET available_at = $2, locked_until = NULL, last_error = $3
		 WHERE delivery_id = $1`, id, at, reason); err != nil {
		return fmt.Errorf("store: reprogramar aviso: %w", err)
	}
	return nil
}

// Cleanup borra teléfonos inactivos y avisos caducados que nadie llegó a
// coger. Devuelve cuántos de cada.
func (p *Postgres) Cleanup(ctx context.Context, inactiveFor time.Duration) (devices, deliveries int64, err error) {
	tag, err := p.pool.Exec(ctx, `DELETE FROM notify.devices WHERE last_seen_at < now() - make_interval(secs => $1)`, inactiveFor.Seconds())
	if err != nil {
		return 0, 0, fmt.Errorf("store: limpiar teléfonos: %w", err)
	}
	devices = tag.RowsAffected()
	tag, err = p.pool.Exec(ctx, `DELETE FROM notify.deliveries WHERE expires_at < now()`)
	if err != nil {
		return devices, 0, fmt.Errorf("store: limpiar avisos: %w", err)
	}
	return devices, tag.RowsAffected(), nil
}
