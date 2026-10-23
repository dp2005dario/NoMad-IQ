-- Migración 0002: índices para la API de vuelos que usa la app.
--
-- Cada índice responde a una pantalla concreta. Sin ellos, con millones de
-- precios guardados, cada consulta leería la tabla entera.

-- "Mis alertas": las rutas que vigila un usuario, las más nuevas primero.
CREATE INDEX fare_subscriptions_user_idx
    ON flights.fare_subscriptions (user_id, created_at DESC);

-- "Chollos de hoy desde Madrid": los últimos precios que salen de un aeropuerto.
CREATE INDEX price_observations_origin_idx
    ON flights.price_observations (origin_iata, observed_at DESC);

-- "Avisos": las alertas que recibió un usuario, las más nuevas primero.
CREATE INDEX fare_alerts_user_idx
    ON flights.fare_alerts (user_id, observed_at DESC);
