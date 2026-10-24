-- Cromos con amigos (pantalla "Cromos" de la app): una liga de amigos que
-- compiten con los sellos del Pasaporte, se cambian cromos y, si quieren,
-- se dicen en qué ciudad están. Ver el paquete leagues/.
--
-- Unirse a una liga es a propósito (con su código) y la app avisa de lo que
-- se comparte: la lista de cromos (monumento, año y mes en que lo sacaste)
-- y, solo si lo activas, la ciudad aproximada. Nunca coordenadas.

CREATE TABLE ai.leagues (
    league_id    uuid        PRIMARY KEY,
    title        text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 40),
    invite_code  text        NOT NULL UNIQUE CHECK (invite_code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ai.league_members (
    league_id    uuid        NOT NULL REFERENCES ai.leagues (league_id) ON DELETE CASCADE,
    seat         smallint    NOT NULL CHECK (seat BETWEEN 1 AND 30),
    user_id      text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    display_name text        NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 40),
    -- [{"qid": "Q243", "name": "Torre Eiffel", "year": 1889, "month": "2026-10"}, ...]
    cards        jsonb       NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(cards) = 'array'),
    countries    smallint    NOT NULL DEFAULT 0 CHECK (countries BETWEEN 0 AND 250),
    -- "Kioto" (la ciudad del aeropuerto más cercano), solo si la persona lo activa.
    city         text        CHECK (char_length(city) BETWEEN 1 AND 60),
    city_at      timestamptz,
    joined_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (league_id, seat),
    UNIQUE (league_id, user_id)
);

CREATE INDEX league_members_user ON ai.league_members (user_id, league_id);

-- Cambios de cromos: "te doy la Torre Eiffel por Fushimi Inari".
CREATE TABLE ai.league_swaps (
    swap_id      uuid        PRIMARY KEY,
    league_id    uuid        NOT NULL REFERENCES ai.leagues (league_id) ON DELETE CASCADE,
    from_seat    smallint    NOT NULL,
    to_seat      smallint    NOT NULL CHECK (to_seat <> from_seat),
    give         jsonb       NOT NULL,
    want         jsonb       NOT NULL,
    status       text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz
);

CREATE INDEX league_swaps_league ON ai.league_swaps (league_id, created_at DESC);
