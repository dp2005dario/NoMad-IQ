-- Planes del grupo (pantalla "Elegid planes" de la app): cada miembro de un
-- viaje en grupo desliza tarjetas de planes (derecha = sí, izquierda = no) y
-- los que gustan a todos son un "match". Ver el paquete plans/.
--
-- Los planes cuelgan del viaje en grupo (group_negotiations): si el viaje se
-- borra, se van con él. Los votos van por ASIENTO, no por user_id: así nadie
-- ve quién votó qué y, al borrar una cuenta, el voto queda anónimo.

CREATE TABLE ai.group_plans (
    plan_id        uuid        PRIMARY KEY,
    negotiation_id uuid        NOT NULL REFERENCES ai.group_negotiations (negotiation_id) ON DELETE CASCADE,
    -- Quién lo propuso (su asiento en el grupo).
    added_by_seat  smallint    NOT NULL CHECK (added_by_seat BETWEEN 1 AND 8),
    title          text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
    -- "Esta noche · 21:30 · ≈ 25 €/persona" (lo escribe quien lo propone).
    note           text        CHECK (char_length(note) BETWEEN 1 AND 140),
    -- Si viene de las atracciones de la ciudad (Wikidata): su id, para no
    -- repetirla, y la foto y el artículo (solo de Wikimedia).
    wikidata_id    text        CHECK (wikidata_id ~ '^Q[1-9][0-9]{0,11}$'),
    photo_url      text        CHECK (char_length(photo_url) <= 500),
    article_url    text        CHECK (char_length(article_url) <= 500),
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (negotiation_id, wikidata_id)
);

CREATE INDEX group_plans_trip ON ai.group_plans (negotiation_id, created_at);

CREATE TABLE ai.group_plan_votes (
    plan_id  uuid     NOT NULL REFERENCES ai.group_plans (plan_id) ON DELETE CASCADE,
    seat     smallint NOT NULL CHECK (seat BETWEEN 1 AND 8),
    yes      boolean  NOT NULL,
    voted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_id, seat)
);
