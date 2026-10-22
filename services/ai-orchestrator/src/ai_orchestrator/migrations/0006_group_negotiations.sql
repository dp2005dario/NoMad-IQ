-- Negociación de grupo con agentes de IA (ver el paquete negotiation/).
--
-- Tres tablas:
--   ai.group_negotiations         -> una fila por negociación (opciones, estado, resultado).
--   ai.group_negotiation_members  -> quién participa y sus preferencias PRIVADAS.
--   ai.outbox                     -> mensajes para Kafka pendientes de enviar.
--
-- ¿Qué es el "outbox" (buzón de salida)?
--   Problema: queremos cambiar el estado en PostgreSQL Y avisar por Kafka. Si
--   hacemos las dos cosas por separado, un corte justo en medio deja una sin
--   la otra (una negociación "lista" que nadie arranca, o un aviso de algo
--   que no se guardó). Solución: escribir el mensaje en esta tabla en la
--   MISMA transacción que el cambio de estado (o se guardan los dos, o
--   ninguno). Después, un "relé" lee lo pendiente y lo manda a Kafka.
--   Analogía: dejas la carta en la bandeja de "correo saliente" de la
--   oficina en el mismo momento en que archivas el expediente; el cartero
--   pasa cada poco y se lleva lo que haya.

CREATE TABLE ai.group_negotiations (
    negotiation_id uuid        PRIMARY KEY,
    -- Quién la creó (user_id verificado por el auth-gateway).
    organizer_id   text        NOT NULL CHECK (char_length(organizer_id) BETWEEN 1 AND 128),
    title          text        NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
    currency       char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    language       text        NOT NULL CHECK (language ~ '^[a-z]{2}$'),
    -- Las opciones (ids, nombres, precios por persona y etiquetas) en JSON.
    options        jsonb       NOT NULL CHECK (jsonb_typeof(options) = 'array'),
    max_rounds     smallint    NOT NULL CHECK (max_rounds BETWEEN 1 AND 10),
    status         text        NOT NULL CHECK (status IN ('collecting', 'queued', 'running', 'concluded', 'expired')),
    -- Hasta cuándo se esperan las preferencias de todos.
    deadline       timestamptz NOT NULL,
    -- Mientras está "running", hasta cuándo es de quien la está negociando.
    -- Si el proceso muere, al caducar otro la vuelve a poner en cola.
    lease_until    timestamptz,
    result         jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    concluded_at   timestamptz,
    -- Coherencia: hay resultado si y solo si está concluida.
    CONSTRAINT group_negotiations_result_iff_concluded CHECK ((status = 'concluded') = (result IS NOT NULL)),
    CONSTRAINT group_negotiations_lease_iff_running CHECK ((status = 'running') = (lease_until IS NOT NULL))
);

-- Índices parciales: solo contienen las filas que el barrido revisa
-- (pocas), no el histórico entero.
CREATE INDEX group_negotiations_collecting ON ai.group_negotiations (deadline) WHERE status = 'collecting';
CREATE INDEX group_negotiations_running ON ai.group_negotiations (lease_until) WHERE status = 'running';
CREATE INDEX group_negotiations_finished ON ai.group_negotiations (updated_at) WHERE status IN ('concluded', 'expired');

CREATE TABLE ai.group_negotiation_members (
    negotiation_id uuid        NOT NULL REFERENCES ai.group_negotiations (negotiation_id) ON DELETE CASCADE,
    user_id        text        NOT NULL CHECK (char_length(user_id) BETWEEN 1 AND 128),
    -- Asiento 1, 2, 3... y su alias ("Viajero 2"): es lo único que ven el
    -- LLM y los demás miembros. El organizador es siempre el asiento 1.
    seat           smallint    NOT NULL CHECK (seat BETWEEN 1 AND 8),
    alias          text        NOT NULL,
    -- Presupuesto, gustos y notas. PRIVADO: solo lo ve su dueño y solo lo
    -- usa su agente. Se BORRA (NULL) al terminar la negociación: ya no hace
    -- falta y lo que no se guarda no se puede filtrar (minimización, RGPD).
    preferences    jsonb,
    submitted_at   timestamptz,
    PRIMARY KEY (negotiation_id, user_id),
    UNIQUE (negotiation_id, seat)
);

-- "Mis negociaciones": busca por persona sin recorrer toda la tabla.
CREATE INDEX group_negotiation_members_user ON ai.group_negotiation_members (user_id, negotiation_id);

CREATE TABLE ai.outbox (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic        text        NOT NULL,
    msg_key      bytea,
    -- El mensaje protobuf ya codificado, listo para Kafka.
    payload      bytea       NOT NULL,
    -- Cabeceras estilo CloudEvents: [["ce_type", "..."], ...].
    headers      jsonb       NOT NULL DEFAULT '[]'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);

-- Lo pendiente de enviar, en orden de llegada.
CREATE INDEX outbox_pending ON ai.outbox (id) WHERE published_at IS NULL;
