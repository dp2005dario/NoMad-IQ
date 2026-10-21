// Package store guarda y lee datos en PostgreSQL usando pgx, el driver de
// PostgreSQL más rápido y completo para Go.
//
// Analogía: si el processor es el director de orquesta, el store es el
// archivero. Sabe en qué cajón (tabla) va cada papel y cómo encontrarlo
// rápido (índices), pero no decide nada de negocio.
//
// Reglas de seguridad que se siguen aquí:
//   - SIEMPRE consultas con parámetros ($1, $2...). Nunca se pega texto del
//     usuario dentro del SQL: eso es lo que permite la "inyección SQL".
//   - La contraseña nunca aparece en logs ni en mensajes de error.
//   - TLS obligatorio con la base de datos salvo en desarrollo local.
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
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/processor"
)

// Config son los datos de conexión a PostgreSQL.
type Config struct {
	Host        string
	Port        int
	User        string
	Password    string
	Database    string
	SSLMode     string // disable | require | verify-ca | verify-full
	SSLRootCert string // CA para verificar el certificado del servidor (opcional)
	MaxConns    int32
}

// connString construye la URL de conexión. Se usa net/url para que una
// contraseña con caracteres especiales (/, @, +, =) no rompa la URL.
func (c Config) connString() string {
	q := url.Values{}
	q.Set("sslmode", c.SSLMode)
	if c.SSLRootCert != "" {
		q.Set("sslrootcert", c.SSLRootCert)
	}
	q.Set("application_name", "price-consumer")
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(c.User, c.Password),
		Host:     net.JoinHostPort(c.Host, strconv.Itoa(c.Port)),
		Path:     "/" + c.Database,
		RawQuery: q.Encode(),
	}
	return u.String()
}

// Postgres implementa processor.Store y la bandeja de salida (outbox).
type Postgres struct {
	pool *pgxpool.Pool
}

// Comprobación en tiempo de compilación: si Postgres dejara de cumplir la
// interfaz processor.Store, el programa no compilaría.
var _ processor.Store = (*Postgres)(nil)

// Open crea el pool de conexiones. Un "pool" es un grupo de conexiones
// abiertas que se reutilizan: abrir una conexión nueva por consulta sería
// lentísimo.
func Open(ctx context.Context, cfg Config) (*Postgres, error) {
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
	return &Postgres{pool: pool}, nil
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

// InTx ejecuta fn dentro de una transacción. Si fn devuelve error se hace
// ROLLBACK (se deshace todo); si no, COMMIT (se confirma todo de golpe).
func (p *Postgres) InTx(ctx context.Context, fn func(processor.Tx) error) error {
	err := pgx.BeginTxFunc(ctx, p.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		return fn(&pgTx{tx: tx})
	})
	return classify(err)
}

// classify distingue dos tipos de fallo de PostgreSQL:
//   - Clase 22 (dato inválido) y 23 (restricción violada): el problema son
//     los DATOS. Reintentar no sirve -> se marca como ValidationError (DLQ).
//   - Todo lo demás (conexión, timeout...): temporal -> reintentar.
//
// Ver https://www.postgresql.org/docs/current/errcodes-appendix.html
func classify(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && len(pgErr.Code) == 5 && (pgErr.Code[:2] == "22" || pgErr.Code[:2] == "23") {
		return &domain.ValidationError{Field: "database", Reason: fmt.Sprintf("%s (%s)", pgErr.Message, pgErr.Code)}
	}
	return err
}

// pgTx implementa processor.Tx sobre una transacción de pgx.
type pgTx struct {
	tx pgx.Tx
}

func (t *pgTx) InsertObservation(ctx context.Context, o domain.Observation, partition int32, offset int64) (bool, error) {
	var ret *time.Time
	if o.Return != nil {
		r := o.Return.Time()
		ret = &r
	}
	// ON CONFLICT DO NOTHING: si el event_id ya existe no falla, simplemente
	// no inserta. RowsAffected() == 0 nos dice que era un duplicado.
	tag, err := t.tx.Exec(ctx, `
		INSERT INTO flights.price_observations (
			event_id, route_key, watch_id, origin_iata, destination_iata, departure_date, return_date,
			cabin, currency, amount_minor, provider, carrier_iata, booking_deep_link, correlation_id,
			observed_at, kafka_partition, kafka_offset)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
		ON CONFLICT (event_id) DO NOTHING`,
		o.EventID, o.RouteKey(), o.WatchID, o.Origin, o.Destination, o.Departure.Time(), ret,
		string(o.Cabin), o.Price.Currency, o.Price.AmountMinor, o.Provider, o.CarrierIATA, o.DeepLink, o.CorrelationID,
		o.ObservedAt, partition, offset)
	if err != nil {
		return false, fmt.Errorf("insertar observación: %w", err)
	}
	return tag.RowsAffected() == 1, nil
}

func (t *pgTx) RecentPrices(ctx context.Context, routeKey, currency string, since, before time.Time, limit int) ([]int64, error) {
	rows, err := t.tx.Query(ctx, `
		SELECT amount_minor FROM flights.price_observations
		WHERE route_key = $1 AND currency = $2 AND observed_at >= $3 AND observed_at < $4
		ORDER BY observed_at DESC
		LIMIT $5`, routeKey, currency, since, before, limit)
	if err != nil {
		return nil, fmt.Errorf("leer historial: %w", err)
	}
	prices, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return nil, fmt.Errorf("leer historial: %w", err)
	}
	return prices, nil
}

func (t *pgTx) Subscriptions(ctx context.Context, routeKey string) ([]domain.Subscription, error) {
	rows, err := t.tx.Query(ctx, `
		SELECT user_id, target_amount_minor, target_currency FROM flights.fare_subscriptions
		WHERE route_key = $1 ORDER BY user_id`, routeKey)
	if err != nil {
		return nil, fmt.Errorf("leer suscripciones: %w", err)
	}
	subs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Subscription, error) {
		var (
			s        = domain.Subscription{RouteKey: routeKey}
			amount   *int64
			currency *string
		)
		if err := row.Scan(&s.UserID, &amount, &currency); err != nil {
			return s, err
		}
		if amount != nil && currency != nil {
			s.Target = &domain.Money{Currency: *currency, AmountMinor: *amount}
		}
		return s, nil
	})
	if err != nil {
		return nil, fmt.Errorf("leer suscripciones: %w", err)
	}
	return subs, nil
}

func (t *pgTx) RecentlyAlerted(ctx context.Context, routeKey, currency string, since time.Time) (map[string]int64, error) {
	rows, err := t.tx.Query(ctx, `
		SELECT user_id, min(current_amount_minor) FROM flights.fare_alerts
		WHERE route_key = $1 AND currency = $2 AND observed_at >= $3
		GROUP BY user_id`, routeKey, currency, since)
	if err != nil {
		return nil, fmt.Errorf("leer alertas recientes: %w", err)
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var (
			user   string
			amount int64
		)
		if err := rows.Scan(&user, &amount); err != nil {
			return nil, fmt.Errorf("leer alertas recientes: %w", err)
		}
		out[user] = amount
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("leer alertas recientes: %w", err)
	}
	return out, nil
}

func (t *pgTx) InsertAlerts(ctx context.Context, alerts []domain.Alert) error {
	// Un "batch" manda todas las inserciones en un solo viaje de red.
	batch := &pgx.Batch{}
	for _, a := range alerts {
		batch.Queue(`
			INSERT INTO flights.fare_alerts (
				alert_id, event_id, user_id, route_key, alert_type, currency,
				reference_amount_minor, current_amount_minor, drop_basis_points, observed_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
			ON CONFLICT DO NOTHING`,
			a.ID, a.EventID, a.UserID, a.RouteKey, string(a.Type), a.Current.Currency,
			a.Reference.AmountMinor, a.Current.AmountMinor, a.DropBasisPoints, a.ObservedAt)
	}
	if err := t.tx.SendBatch(ctx, batch).Close(); err != nil {
		return fmt.Errorf("insertar alertas: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Suscripciones (por ahora solo para las semillas de demo; más adelante las
// gestionará el auth-gateway en nombre del usuario autenticado).
// ---------------------------------------------------------------------------

// UpsertSubscription crea o actualiza una suscripción.
func (p *Postgres) UpsertSubscription(ctx context.Context, s domain.Subscription) error {
	if err := s.Validate(); err != nil {
		return err
	}
	var (
		amount   *int64
		currency *string
	)
	if s.Target != nil {
		amount, currency = &s.Target.AmountMinor, &s.Target.Currency
	}
	_, err := p.pool.Exec(ctx, `
		INSERT INTO flights.fare_subscriptions (user_id, route_key, target_amount_minor, target_currency)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (route_key, user_id) DO UPDATE
		SET target_amount_minor = EXCLUDED.target_amount_minor, target_currency = EXCLUDED.target_currency`,
		s.UserID, s.RouteKey, amount, currency)
	if err != nil {
		return fmt.Errorf("guardar suscripción: %w", classify(err))
	}
	return nil
}

// ---------------------------------------------------------------------------
// Bandeja de salida (outbox)
// ---------------------------------------------------------------------------

// ClaimPending reserva hasta limit alertas sin publicar y llama a publish con
// ellas. Si publish termina bien, las marca como publicadas; si falla, no
// cambia nada y se reintentarán en la siguiente pasada.
//
// FOR UPDATE SKIP LOCKED: si hay varias copias del servicio, cada una se
// queda con alertas distintas en lugar de esperar o duplicar trabajo.
func (p *Postgres) ClaimPending(ctx context.Context, limit int, publish func([]domain.PendingAlert) error) (int, error) {
	claimed := 0
	err := pgx.BeginTxFunc(ctx, p.pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT a.alert_id, a.event_id, a.user_id, a.route_key, a.alert_type, a.currency,
			       a.reference_amount_minor, a.current_amount_minor, a.drop_basis_points, a.observed_at,
			       o.watch_id, o.origin_iata, o.destination_iata, o.departure_date, o.cabin,
			       o.booking_deep_link, o.correlation_id
			FROM flights.fare_alerts a
			JOIN flights.price_observations o ON o.event_id = a.event_id
			WHERE a.published_at IS NULL
			ORDER BY a.created_at
			LIMIT $1
			FOR UPDATE OF a SKIP LOCKED`, limit)
		if err != nil {
			return fmt.Errorf("leer alertas pendientes: %w", err)
		}
		pending, err := pgx.CollectRows(rows, scanPending)
		if err != nil {
			return fmt.Errorf("leer alertas pendientes: %w", err)
		}
		if len(pending) == 0 {
			return nil
		}
		if err := publish(pending); err != nil {
			return err
		}
		ids := make([]string, len(pending))
		for i, a := range pending {
			ids[i] = a.ID
		}
		if _, err := tx.Exec(ctx, `UPDATE flights.fare_alerts SET published_at = now() WHERE alert_id = ANY($1::uuid[])`, ids); err != nil {
			return fmt.Errorf("marcar alertas publicadas: %w", err)
		}
		claimed = len(pending)
		return nil
	})
	if err != nil {
		return 0, err
	}
	return claimed, nil
}

func scanPending(row pgx.CollectableRow) (domain.PendingAlert, error) {
	var (
		a         domain.PendingAlert
		alertType string
		currency  string
		cabin     string
		departure time.Time
	)
	err := row.Scan(&a.ID, &a.EventID, &a.UserID, &a.RouteKey, &alertType, &currency,
		&a.Reference.AmountMinor, &a.Current.AmountMinor, &a.DropBasisPoints, &a.ObservedAt,
		&a.WatchID, &a.Origin, &a.Destination, &departure, &cabin, &a.DeepLink, &a.CorrelationID)
	if err != nil {
		return a, err
	}
	a.Type = domain.AlertType(alertType)
	a.Reference.Currency, a.Current.Currency = currency, currency
	a.Cabin = domain.Cabin(cabin)
	a.Departure = domain.Date{Year: departure.Year(), Month: departure.Month(), Day: departure.Day()}
	a.ObservedAt = a.ObservedAt.UTC()
	return a, nil
}
