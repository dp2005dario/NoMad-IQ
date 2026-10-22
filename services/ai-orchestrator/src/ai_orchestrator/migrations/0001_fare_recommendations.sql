-- Migración 0001: recomendaciones generadas a partir de las alertas de precio.
--
-- Recordatorio: una migración publicada NUNCA se edita (el servicio guarda su
-- huella SHA-256 y se negaría a arrancar). Para cambiar algo, crea la 0002.
--
-- Esquema propio "ai": cada servicio es dueño de sus tablas. Este servicio solo
-- LEE flights.price_observations (del price-consumer), nunca la modifica.

CREATE SCHEMA IF NOT EXISTS ai;

CREATE TABLE ai.fare_recommendations (
    -- Una recomendación por alerta: si Kafka entrega la misma alerta dos
    -- veces, el segundo INSERT no hace nada (idempotencia).
    alert_id          uuid        PRIMARY KEY,
    user_id           text        NOT NULL CHECK (length(user_id) BETWEEN 1 AND 128),
    verdict           text        NOT NULL CHECK (verdict IN ('BUY_NOW', 'CONSIDER', 'WAIT')),
    headline          text        NOT NULL CHECK (length(headline) BETWEEN 1 AND 300),
    body              text        NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    -- 'llm' = redactada por el modelo; 'rules' = plan B sin IA.
    source            text        NOT NULL CHECK (source IN ('llm', 'rules')),
    model             text        NOT NULL DEFAULT '',
    -- Los datos reales que respaldan el texto, para auditar qué se dijo y por qué.
    facts             jsonb       NOT NULL CHECK (jsonb_typeof(facts) = 'object'),
    booking_deep_link text        NOT NULL DEFAULT '' CHECK (booking_deep_link = '' OR booking_deep_link LIKE 'https://%'),
    correlation_id    text        NOT NULL DEFAULT '',
    alert_occurred_at timestamptz NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- La consulta de la API: "las últimas recomendaciones de este usuario".
CREATE INDEX fare_recommendations_user_idx
    ON ai.fare_recommendations (user_id, created_at DESC);
