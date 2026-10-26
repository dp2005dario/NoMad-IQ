-- Sin colas (pantalla "Colas" de la app): cuánta cola hay en un sitio, según
-- lo que AVISAN los propios viajeros que están allí. Ver queues/.
--
-- Nada inventado: no hay datos gratis y legales de afluencia en todo el
-- mundo, así que solo se enseña lo que ha dicho gente de verdad:
--   - "Ahora": avisos de la última hora y media (con 2 personas o más).
--   - "Por horas": avisos de los últimos 60 días por hora del día (con 3 o
--     más personas en esa hora).
-- Un aviso por persona, sitio, día y hora (si lo repite, se cambia).
-- El sitio va por su Wikidata (Q...): nunca la posición de nadie.
-- Nunca se devuelve quién avisó. Al borrar la cuenta se borra lo suyo.

CREATE TABLE ai.queue_reports (
    place        text        NOT NULL CHECK (place ~ '^Q[1-9][0-9]{0,11}$'),
    user_id      text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    -- La hora en el reloj del sitio (0-23): la pone el móvil del viajero.
    local_hour   smallint    NOT NULL CHECK (local_hour BETWEEN 0 AND 23),
    -- 0 sin cola · 1 menos de 15 min · 2 de 15 a 30 · 3 de 30 a 60 · 4 más.
    wait         smallint    NOT NULL CHECK (wait BETWEEN 0 AND 4),
    reported_on  date        NOT NULL DEFAULT current_date,
    reported_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (place, user_id, reported_on, local_hour)
);

CREATE INDEX queue_reports_place ON ai.queue_reports (place, reported_at);
CREATE INDEX queue_reports_user ON ai.queue_reports (user_id, reported_on);
