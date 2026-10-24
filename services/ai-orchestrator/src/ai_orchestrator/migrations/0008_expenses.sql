-- Gastos compartidos (la pantalla Gastos de la app: "Cena en La Latina, pagó
-- Álex, ¿cuánto le debe cada uno?"). Ver el paquete expenses/.
--
-- Cuatro tablas:
--   ai.expense_groups    -> un "bote" (un viaje, un piso compartido...).
--   ai.expense_members   -> quién está en el bote y con qué nombre.
--   ai.expenses          -> cada gasto: quién pagó, cuánto y entre quiénes.
--   ai.expense_items     -> las líneas del ticket (si se reparte por platos),
--                           con quién se ha "pedido" cada una.
--   ai.expense_payments  -> "Saldar": un pago de una persona a otra.
--
-- El dinero SIEMPRE en céntimos enteros (bigint), nunca con decimales:
-- 0,1 + 0,2 no da 0,3 exacto en un ordenador, y con dinero no vale "casi".
--
-- Cada persona es un ASIENTO (1, 2, 3...). Los demás ven el asiento y el
-- nombre que cada uno eligió, nunca su user_id.

CREATE TABLE ai.expense_groups (
    group_id     uuid        PRIMARY KEY,
    title        text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 60),
    -- La moneda del bote: todas las cuentas se hacen en ella.
    currency     char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    -- Código para unirse (alfabeto Crockford, como en Grupo). Siempre vivo:
    -- en un piso compartido puede llegar alguien nuevo en cualquier momento.
    invite_code  text        NOT NULL UNIQUE CHECK (invite_code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ai.expense_members (
    group_id     uuid        NOT NULL REFERENCES ai.expense_groups (group_id) ON DELETE CASCADE,
    seat         smallint    NOT NULL CHECK (seat BETWEEN 1 AND 20),
    user_id      text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    display_name text        NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 40),
    joined_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, seat),
    UNIQUE (group_id, user_id)
);

-- "Mis botes": busca por persona sin recorrer toda la tabla.
CREATE INDEX expense_members_user ON ai.expense_members (user_id, group_id);

CREATE TABLE ai.expenses (
    expense_id    uuid        PRIMARY KEY,
    group_id      uuid        NOT NULL REFERENCES ai.expense_groups (group_id) ON DELETE CASCADE,
    title         text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
    -- Lo que pagó, en la moneda del bote.
    amount_minor  bigint      NOT NULL CHECK (amount_minor BETWEEN 1 AND 100000000000),
    payer_seat    smallint    NOT NULL,
    -- 'equal' = a partes iguales entre participants; 'items' = cada uno lo suyo.
    split         text        NOT NULL CHECK (split IN ('equal', 'items')),
    participants  smallint[]  NOT NULL CHECK (cardinality(participants) BETWEEN 1 AND 20),
    -- Lo que marcaba el ticket si era en otra moneda (solo para enseñarlo).
    original_minor    bigint  CHECK (original_minor > 0),
    original_currency char(3) CHECK (original_currency ~ '^[A-Z]{3}$'),
    spent_on      date        NOT NULL,
    created_by    smallint    NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT expenses_original_pair CHECK ((original_minor IS NULL) = (original_currency IS NULL)),
    FOREIGN KEY (group_id, payer_seat) REFERENCES ai.expense_members (group_id, seat)
);

CREATE INDEX expenses_group ON ai.expenses (group_id, spent_on DESC, created_at DESC);

CREATE TABLE ai.expense_items (
    expense_id   uuid        NOT NULL REFERENCES ai.expenses (expense_id) ON DELETE CASCADE,
    idx          smallint    NOT NULL CHECK (idx BETWEEN 0 AND 99),
    name         text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
    qty          smallint    NOT NULL CHECK (qty BETWEEN 1 AND 999),
    price_minor  bigint      NOT NULL CHECK (price_minor BETWEEN 0 AND 100000000000),
    -- Quién se ha pedido esta línea. Vacío = "de todos" (se reparte entre
    -- todos los participantes).
    claimed_by   smallint[]  NOT NULL DEFAULT '{}',
    PRIMARY KEY (expense_id, idx)
);

CREATE TABLE ai.expense_payments (
    payment_id   uuid        PRIMARY KEY,
    group_id     uuid        NOT NULL REFERENCES ai.expense_groups (group_id) ON DELETE CASCADE,
    from_seat    smallint    NOT NULL,
    to_seat      smallint    NOT NULL,
    amount_minor bigint      NOT NULL CHECK (amount_minor BETWEEN 1 AND 100000000000),
    created_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (from_seat <> to_seat),
    FOREIGN KEY (group_id, from_seat) REFERENCES ai.expense_members (group_id, seat),
    FOREIGN KEY (group_id, to_seat) REFERENCES ai.expense_members (group_id, seat)
);

CREATE INDEX expense_payments_group ON ai.expense_payments (group_id, created_at DESC);
