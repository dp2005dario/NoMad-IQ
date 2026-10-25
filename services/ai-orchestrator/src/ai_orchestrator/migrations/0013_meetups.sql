-- Quedadas de viajeros (pantalla "Quedadas" de la app): gente que viaja sola
-- propone planes en sitios públicos de una ciudad y otros se apuntan.
-- Ver el paquete meetups/.
--
-- Seguridad y privacidad:
--   - Las quedadas van por CIUDAD (código del aeropuerto), nunca por
--     coordenadas: nadie sabe dónde estás.
--   - De cada persona solo se guarda el nombre que elige y su país, y puede
--     apuntarse "oculta" (los demás ven "Alguien").
--   - Con 3 denuncias de personas distintas, la quedada deja de verse.
--   - Una semana después de la hora, se borra (no hace falta guardarla).

CREATE TABLE ai.meetups (
    meetup_id       uuid        PRIMARY KEY,
    city            char(3)     NOT NULL CHECK (city ~ '^[A-Z]{3}$'),
    kind            text        NOT NULL CHECK (kind IN ('food', 'walk', 'drinks', 'culture', 'other')),
    title           text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
    place           text        NOT NULL CHECK (char_length(place) BETWEEN 1 AND 80),
    starts_at       timestamptz NOT NULL,
    capacity        smallint    NOT NULL CHECK (capacity BETWEEN 2 AND 12),
    creator_id      text        NOT NULL CHECK (char_length(creator_id) BETWEEN 1 AND 128),
    reports         smallint    NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX meetups_city ON ai.meetups (city, starts_at);
CREATE INDEX meetups_creator ON ai.meetups (creator_id);

CREATE TABLE ai.meetup_members (
    meetup_id  uuid        NOT NULL REFERENCES ai.meetups (meetup_id) ON DELETE CASCADE,
    user_id    text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    name       text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 40),
    country    char(2)     CHECK (country ~ '^[A-Z]{2}$'),
    visible    boolean     NOT NULL DEFAULT true,
    joined_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (meetup_id, user_id)
);

CREATE INDEX meetup_members_user ON ai.meetup_members (user_id);

CREATE TABLE ai.meetup_reports (
    meetup_id  uuid NOT NULL REFERENCES ai.meetups (meetup_id) ON DELETE CASCADE,
    user_id    text NOT NULL,
    PRIMARY KEY (meetup_id, user_id)
);
