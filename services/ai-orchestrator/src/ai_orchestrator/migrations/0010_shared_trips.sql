-- "Copia este viaje": viajes que alguien comparte para que otros los copien
-- (y Flyra los adapte a su presupuesto). Ver el paquete shared_trips/.
--
-- Solo se comparte lo que la persona escribe a propósito: título, destino,
-- días y una lista corta de cosas con su precio. Nunca fechas exactas, ni
-- quién más iba, ni su cuenta: los demás ven el nombre que eligió ("@laura").
--
-- El dinero en céntimos enteros (bigint), como en los gastos.

CREATE TABLE ai.shared_trips (
    -- Código para abrirlo (alfabeto Crockford, como los de Grupo y Gastos).
    code         text        PRIMARY KEY CHECK (code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
    owner_id     text        NOT NULL CHECK (char_length(owner_id) BETWEEN 1 AND 128),
    author       text        NOT NULL CHECK (char_length(author) BETWEEN 1 AND 30),
    title        text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 60),
    destination  text        NOT NULL CHECK (char_length(destination) BETWEEN 1 AND 60),
    days         smallint    NOT NULL CHECK (days BETWEEN 1 AND 60),
    currency     char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    -- [{"kind": "flight", "title": "...", "price_minor": 98000}, ...] (máx. 30).
    items        jsonb       NOT NULL CHECK (jsonb_typeof(items) = 'array'),
    copies       integer     NOT NULL DEFAULT 0 CHECK (copies >= 0),
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- "Mis viajes compartidos" y el tope por persona.
CREATE INDEX shared_trips_owner ON ai.shared_trips (owner_id);

-- Quién lo ha copiado: para contar cada persona UNA vez (copiarlo diez veces
-- no lo hace diez veces más popular). Se borra con el viaje.
CREATE TABLE ai.shared_trip_copies (
    code       text        NOT NULL REFERENCES ai.shared_trips (code) ON DELETE CASCADE,
    user_id    text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    copied_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (code, user_id)
);

CREATE INDEX shared_trip_copies_user ON ai.shared_trip_copies (user_id);
