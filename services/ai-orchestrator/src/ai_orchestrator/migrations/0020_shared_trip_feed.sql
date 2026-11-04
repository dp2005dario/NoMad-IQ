-- "Copia este viaje" como en la maqueta: un muro con los viajes que la gente
-- PUBLICA a propósito (casilla "Publicar en el muro" al compartir; por
-- defecto no) y estrellas de 1 a 5 que pone cada persona una vez.
--
-- Un viaje que no es público sigue igual que antes: solo se abre con su código.

ALTER TABLE ai.shared_trips
    ADD COLUMN public       boolean NOT NULL DEFAULT false,
    ADD COLUMN rating_sum   integer NOT NULL DEFAULT 0 CHECK (rating_sum >= 0),
    ADD COLUMN rating_count integer NOT NULL DEFAULT 0 CHECK (rating_count >= 0);

-- El muro: los públicos, del más nuevo al más viejo.
CREATE INDEX shared_trips_feed ON ai.shared_trips (created_at DESC) WHERE public;

-- Las estrellas de cada persona (cambiar tu voto lo sustituye, no suma otro).
-- Se borran con el viaje.
CREATE TABLE ai.shared_trip_ratings (
    code      text        NOT NULL REFERENCES ai.shared_trips (code) ON DELETE CASCADE,
    user_id   text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    stars     smallint    NOT NULL CHECK (stars BETWEEN 1 AND 5),
    rated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (code, user_id)
);

CREATE INDEX shared_trip_ratings_user ON ai.shared_trip_ratings (user_id);
