-- Migración 0001: historial de precios, suscripciones y alertas del "sniper".
--
-- ¿Qué es una migración? Un fichero SQL numerado que cambia la estructura de
-- la base de datos. Se aplican en orden y UNA sola vez cada una (el servicio
-- apunta cuáles ya aplicó). Nunca se edita una migración ya publicada: si hay
-- que cambiar algo, se crea la 0002, la 0003...
--
-- Las restricciones CHECK son la última línea de defensa: aunque el código
-- tuviera un fallo, la base de datos se niega a guardar datos absurdos
-- (precios negativos, códigos de aeropuerto raros...).

CREATE SCHEMA IF NOT EXISTS flights;

-- Cada precio observado por el flight-ingestor. Es el "historial" con el que
-- el detector decide qué es barato.
CREATE TABLE flights.price_observations (
    -- El UUID del evento es la clave primaria: si el mismo mensaje llega dos
    -- veces, el segundo INSERT no hace nada (idempotencia).
    event_id          uuid        PRIMARY KEY,
    route_key         text        NOT NULL,
    watch_id          text        NOT NULL DEFAULT '',
    origin_iata       char(3)     NOT NULL CHECK (origin_iata ~ '^[A-Z]{3}$'),
    destination_iata  char(3)     NOT NULL CHECK (destination_iata ~ '^[A-Z]{3}$'),
    departure_date    date        NOT NULL,
    return_date       date,
    cabin             text        NOT NULL CHECK (cabin IN ('ECONOMY', 'PREMIUM_ECONOMY', 'BUSINESS', 'FIRST')),
    -- Dinero en céntimos (bigint), nunca en decimales de coma flotante.
    currency          char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    amount_minor      bigint      NOT NULL CHECK (amount_minor > 0),
    provider          text        NOT NULL CHECK (provider <> ''),
    carrier_iata      text        NOT NULL DEFAULT '',
    booking_deep_link text        NOT NULL DEFAULT '',
    correlation_id    text        NOT NULL DEFAULT '',
    observed_at       timestamptz NOT NULL,
    -- De dónde salió en Kafka: útil para depurar ("¿qué mensaje generó esto?").
    kafka_partition   integer     NOT NULL,
    kafka_offset      bigint      NOT NULL,
    received_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (origin_iata <> destination_iata),
    CHECK (return_date IS NULL OR return_date >= departure_date)
);

-- Índice para la consulta más frecuente: "últimos precios de esta ruta".
-- Sin él, PostgreSQL tendría que leer la tabla entera en cada mensaje.
CREATE INDEX price_observations_history_idx
    ON flights.price_observations (route_key, currency, observed_at DESC);

-- Qué usuario vigila qué ruta (y, opcionalmente, a qué precio quiere comprar).
CREATE TABLE flights.fare_subscriptions (
    user_id             text        NOT NULL CHECK (length(user_id) BETWEEN 1 AND 128),
    route_key           text        NOT NULL,
    target_amount_minor bigint      CHECK (target_amount_minor > 0),
    target_currency     char(3)     CHECK (target_currency ~ '^[A-Z]{3}$'),
    created_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (route_key, user_id),
    -- O hay objetivo completo (importe + divisa) o no hay ninguno.
    CHECK ((target_amount_minor IS NULL) = (target_currency IS NULL))
);

-- Alertas generadas. Esta tabla hace también de "outbox" (bandeja de salida):
-- published_at vacío = aún no se ha enviado a Kafka.
CREATE TABLE flights.fare_alerts (
    alert_id               uuid        PRIMARY KEY,
    event_id               uuid        NOT NULL REFERENCES flights.price_observations (event_id),
    user_id                text        NOT NULL,
    route_key              text        NOT NULL,
    alert_type             text        NOT NULL CHECK (alert_type IN ('PRICE_DROP', 'ERROR_FARE', 'TARGET_REACHED')),
    currency               char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    reference_amount_minor bigint      NOT NULL CHECK (reference_amount_minor > 0),
    current_amount_minor   bigint      NOT NULL CHECK (current_amount_minor > 0),
    drop_basis_points      integer     NOT NULL CHECK (drop_basis_points BETWEEN 0 AND 10000),
    observed_at            timestamptz NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    published_at           timestamptz,
    -- Como mucho una alerta por usuario y evento.
    UNIQUE (event_id, user_id)
);

-- Índice "parcial": solo contiene las alertas pendientes, así encontrar lo
-- que falta por publicar es instantáneo aunque haya millones ya enviadas.
CREATE INDEX fare_alerts_pending_idx
    ON flights.fare_alerts (created_at) WHERE published_at IS NULL;

-- Para el anti-spam: "¿qué le avisé a este usuario de esta ruta hace poco?".
CREATE INDEX fare_alerts_cooldown_idx
    ON flights.fare_alerts (route_key, currency, observed_at DESC);
