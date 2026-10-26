-- Radar local (pantalla "Radar" de la app): avisos de timos y precios que
-- pagan los viajeros, por CIUDAD (código del aeropuerto). Ver radar/.
--
-- Solo datos que ponen los propios viajeros (nada inventado):
--   - Un aviso de timo por persona, ciudad y tipo (si lo repite, se renueva
--     la fecha). Se enseña cuando lo han avisado al menos 3 personas.
--   - Un precio por persona, ciudad y cosa (el último que apuntó). Se
--     enseñan cuando hay al menos 5 personas, como rango (percentiles).
-- Nunca se devuelve quién avisó. Al borrar la cuenta se borra lo suyo.

CREATE TABLE ai.radar_scam_reports (
    city         char(3) NOT NULL CHECK (city ~ '^[A-Z]{3}$'),
    category     text    NOT NULL CHECK (category IN (
                     'street_touts', 'taxi', 'fake_police', 'bracelet',
                     'atm', 'pickpockets', 'fake_tickets', 'exchange')),
    user_id      text    NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    reported_on  date    NOT NULL DEFAULT current_date,
    PRIMARY KEY (city, category, user_id)
);

CREATE INDEX radar_scam_reports_user ON ai.radar_scam_reports (user_id);

CREATE TABLE ai.radar_prices (
    city      char(3)       NOT NULL CHECK (city ~ '^[A-Z]{3}$'),
    item      text          NOT NULL CHECK (item IN (
                  'coffee', 'beer', 'water', 'simple_meal', 'taxi_short')),
    currency  char(3)       NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    amount    numeric(12,2) NOT NULL CHECK (amount > 0 AND amount < 10000000),
    user_id   text          NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    paid_on   date          NOT NULL DEFAULT current_date,
    PRIMARY KEY (city, item, user_id)
);

CREATE INDEX radar_prices_city ON ai.radar_prices (city, item, currency);
CREATE INDEX radar_prices_user ON ai.radar_prices (user_id);
