package store

// Consultas de la API de vuelos (lo que pide la app). Solo LEEN el historial
// que guarda el consumidor, más las suscripciones de cada usuario.

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// ErrNotFound: lo pedido no existe (o no es de este usuario).
var ErrNotFound = errors.New("store: no encontrado")

// Deals devuelve el último precio de cada ruta que sale de origin, visto
// desde since, junto con su mediana de los últimos historyWindow. Como mucho
// scan rutas: el orden final (por chollo) lo decide quien llama.
func (p *Postgres) Deals(ctx context.Context, origin string, since time.Time, historyWindow time.Duration, scan int) ([]domain.Deal, error) {
	rows, err := p.pool.Query(ctx, `
		WITH latest AS (
			-- DISTINCT ON: de cada ruta y divisa, solo la fila más reciente.
			SELECT DISTINCT ON (route_key, currency)
			       route_key, currency, amount_minor, carrier_iata, booking_deep_link, observed_at
			FROM flights.price_observations
			WHERE origin_iata = $1 AND observed_at >= $2 AND departure_date >= current_date
			ORDER BY route_key, currency, observed_at DESC
			LIMIT $4
		)
		SELECT l.route_key, l.currency, l.amount_minor, l.carrier_iata, l.booking_deep_link, l.observed_at,
		       COALESCE((
		           SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY h.amount_minor)
		           FROM flights.price_observations h
		           WHERE h.route_key = l.route_key AND h.currency = l.currency AND h.observed_at >= $3
		       ), 0)::bigint
		FROM latest l`,
		origin, since, time.Now().Add(-historyWindow), scan)
	if err != nil {
		return nil, fmt.Errorf("leer chollos: %w", err)
	}
	deals, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Deal, error) {
		var (
			d   domain.Deal
			key string
		)
		if err := row.Scan(&key, &d.Price.Currency, &d.Price.AmountMinor, &d.CarrierIATA, &d.DeepLink,
			&d.ObservedAt, &d.UsualMinor); err != nil {
			return d, err
		}
		spec, err := domain.ParseRouteKey(key)
		if err != nil {
			return d, err
		}
		d.Spec = spec
		d.ObservedAt = d.ObservedAt.UTC()
		return d, nil
	})
	if err != nil {
		return nil, fmt.Errorf("leer chollos: %w", err)
	}
	return deals, nil
}

// Watches devuelve las rutas que vigila userID, con su último precio.
func (p *Postgres) Watches(ctx context.Context, userID string) ([]domain.Watch, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT s.route_key, s.target_amount_minor, s.target_currency, s.created_at,
		       o.currency, o.amount_minor, o.carrier_iata, o.booking_deep_link, o.observed_at
		FROM flights.fare_subscriptions s
		-- LEFT JOIN LATERAL: el último precio de esa ruta, o nada si aún no hay.
		LEFT JOIN LATERAL (
			SELECT currency, amount_minor, carrier_iata, booking_deep_link, observed_at
			FROM flights.price_observations
			WHERE route_key = s.route_key
			ORDER BY observed_at DESC
			LIMIT 1
		) o ON true
		WHERE s.user_id = $1
		ORDER BY s.created_at DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("leer seguimientos: %w", err)
	}
	watches, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.Watch, error) {
		var (
			w              domain.Watch
			key            string
			targetAmount   *int64
			targetCurrency *string
			currency       *string
			amount         *int64
			carrier        *string
			link           *string
			observed       *time.Time
		)
		if err := row.Scan(&key, &targetAmount, &targetCurrency, &w.CreatedAt,
			&currency, &amount, &carrier, &link, &observed); err != nil {
			return w, err
		}
		spec, err := domain.ParseRouteKey(key)
		if err != nil {
			return w, err
		}
		w.Spec = spec
		w.CreatedAt = w.CreatedAt.UTC()
		if targetAmount != nil && targetCurrency != nil {
			w.Target = &domain.Money{Currency: *targetCurrency, AmountMinor: *targetAmount}
		}
		if amount != nil && currency != nil && observed != nil {
			w.Latest = &domain.Fare{
				Spec:        spec,
				Price:       domain.Money{Currency: *currency, AmountMinor: *amount},
				CarrierIATA: deref(carrier),
				DeepLink:    deref(link),
				ObservedAt:  observed.UTC(),
			}
		}
		return w, nil
	})
	if err != nil {
		return nil, fmt.Errorf("leer seguimientos: %w", err)
	}
	return watches, nil
}

// DeleteSubscription deja de vigilar una ruta. Devuelve ErrNotFound si el
// usuario no la vigilaba.
func (p *Postgres) DeleteSubscription(ctx context.Context, userID, routeKey string) error {
	tag, err := p.pool.Exec(ctx,
		`DELETE FROM flights.fare_subscriptions WHERE user_id = $1 AND route_key = $2`, userID, routeKey)
	if err != nil {
		return fmt.Errorf("borrar seguimiento: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// EraseUser borra todo lo de una persona: las rutas que vigilaba y sus avisos
// (también los que aún no se habían enviado). Es "Borrar mi cuenta". Los
// precios en sí no son de nadie: se quedan. Devuelve cuántas filas se fueron.
func (p *Postgres) EraseUser(ctx context.Context, userID string) (int64, error) {
	// Una sola transacción: o se borra todo o nada.
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("borrar usuario: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }() // no hace nada si ya se confirmó
	subs, err := tx.Exec(ctx, `DELETE FROM flights.fare_subscriptions WHERE user_id = $1`, userID)
	if err != nil {
		return 0, fmt.Errorf("borrar seguimientos: %w", err)
	}
	alerts, err := tx.Exec(ctx, `DELETE FROM flights.fare_alerts WHERE user_id = $1`, userID)
	if err != nil {
		return 0, fmt.Errorf("borrar avisos: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("borrar usuario: %w", err)
	}
	return subs.RowsAffected() + alerts.RowsAffected(), nil
}

// History devuelve el precio más bajo de cada día desde since (para la
// gráfica). Si la ruta tiene precios en varias divisas, solo la más usada.
func (p *Postgres) History(ctx context.Context, routeKey string, since time.Time) (string, []domain.PricePoint, error) {
	var currency string
	err := p.pool.QueryRow(ctx, `
		SELECT currency FROM flights.price_observations
		WHERE route_key = $1 AND observed_at >= $2
		GROUP BY currency ORDER BY count(*) DESC, currency LIMIT 1`, routeKey, since).Scan(&currency)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, nil
	}
	if err != nil {
		return "", nil, fmt.Errorf("leer historial: %w", err)
	}
	rows, err := p.pool.Query(ctx, `
		SELECT (observed_at AT TIME ZONE 'UTC')::date AS day, min(amount_minor)
		FROM flights.price_observations
		WHERE route_key = $1 AND currency = $2 AND observed_at >= $3
		GROUP BY day ORDER BY day`, routeKey, currency, since)
	if err != nil {
		return "", nil, fmt.Errorf("leer historial: %w", err)
	}
	points, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.PricePoint, error) {
		var (
			pt  domain.PricePoint
			day time.Time
		)
		if err := row.Scan(&day, &pt.MinMinor); err != nil {
			return pt, err
		}
		pt.Day = domain.Date{Year: day.Year(), Month: day.Month(), Day: day.Day()}
		return pt, nil
	})
	if err != nil {
		return "", nil, fmt.Errorf("leer historial: %w", err)
	}
	return currency, points, nil
}

// Alerts devuelve las últimas alertas de userID (ya publicadas o no).
func (p *Postgres) Alerts(ctx context.Context, userID string, limit int) ([]domain.AlertView, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT a.alert_id, a.route_key, a.alert_type, a.currency, a.reference_amount_minor,
		       a.current_amount_minor, a.drop_basis_points, o.booking_deep_link, a.observed_at
		FROM flights.fare_alerts a
		JOIN flights.price_observations o ON o.event_id = a.event_id
		WHERE a.user_id = $1
		ORDER BY a.observed_at DESC
		LIMIT $2`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("leer alertas: %w", err)
	}
	alerts, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (domain.AlertView, error) {
		var (
			a         domain.AlertView
			key       string
			alertType string
			currency  string
		)
		if err := row.Scan(&a.ID, &key, &alertType, &currency, &a.Reference.AmountMinor,
			&a.Current.AmountMinor, &a.DropBasisPoints, &a.DeepLink, &a.ObservedAt); err != nil {
			return a, err
		}
		spec, err := domain.ParseRouteKey(key)
		if err != nil {
			return a, err
		}
		a.Spec = spec
		a.Type = domain.AlertType(alertType)
		a.Reference.Currency, a.Current.Currency = currency, currency
		a.ObservedAt = a.ObservedAt.UTC()
		return a, nil
	})
	if err != nil {
		return nil, fmt.Errorf("leer alertas: %w", err)
	}
	return alerts, nil
}

// SubscribedRouteKeys devuelve las rutas que alguien vigila y aún no han
// salido (para decirle al flight-ingestor qué tiene que consultar).
func (p *Postgres) SubscribedRouteKeys(ctx context.Context, today time.Time) ([]string, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT DISTINCT route_key FROM flights.fare_subscriptions
		WHERE split_part(route_key, ':', 2)::date >= $1::date
		ORDER BY route_key`, today)
	if err != nil {
		return nil, fmt.Errorf("leer rutas vigiladas: %w", err)
	}
	keys, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("leer rutas vigiladas: %w", err)
	}
	return keys, nil
}

// DeleteExpiredSubscriptions borra las suscripciones de vuelos que ya
// salieron: nadie puede comprar un vuelo de ayer.
func (p *Postgres) DeleteExpiredSubscriptions(ctx context.Context, today time.Time) (int64, error) {
	tag, err := p.pool.Exec(ctx, `
		DELETE FROM flights.fare_subscriptions
		WHERE split_part(route_key, ':', 2)::date < $1::date`, today)
	if err != nil {
		return 0, fmt.Errorf("borrar seguimientos caducados: %w", err)
	}
	return tag.RowsAffected(), nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
