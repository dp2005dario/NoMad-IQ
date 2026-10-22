-- Migración 0004: la voz de las audioguías (texto → audio con Piper).
--
-- Dos tablas:
--
-- 1. ai.audio_jobs: la "bandeja de salida" (patrón OUTBOX). Cada vez que sube
--    la versión del contenido de una zona (migración 0003), un trigger deja
--    aquí apuntado "hay que grabar el audio de la zona X, versión N".
--
--    ¿Por qué una tabla y no publicar directamente en Kafka? Porque el
--    apunte se hace en la MISMA transacción que la corrección del hecho: o
--    se guardan las dos cosas o ninguna. Si publicáramos en Kafka desde el
--    código, podría guardarse el hecho y perderse el aviso (o al revés) si
--    algo se cae justo en medio: el famoso problema de la "doble escritura".
--    Analogía: el pedido y el ticket para cocina salen de la misma impresora;
--    no hay forma de cobrar un plato sin que cocina se entere.
--
--    El worker de audio (audioguides/audio_worker.py) recoge los trabajos con
--    FOR UPDATE SKIP LOCKED: si hay varias copias del worker, cada una coge
--    uno distinto sin pisarse, sin necesitar más infraestructura.
--
-- 2. ai.zone_audio: el "índice" del audio ya grabado. Una fila por zona,
--    idioma, versión y guion, con la lista de partes (un archivo .opus por
--    párrafo). Los archivos viven fuera de la base de datos (un volumen o un
--    almacén de objetos); aquí solo se guarda dónde están.

CREATE TABLE ai.audio_jobs (
    zone_slug       text        NOT NULL CHECK (zone_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(zone_slug) <= 100),
    content_version bigint      NOT NULL CHECK (content_version >= 0),
    -- Cuántas veces se ha intentado (para rendirse tras varios fallos seguidos).
    attempts        integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    -- No antes de esta hora (sirve para esperar entre reintentos).
    available_at    timestamptz NOT NULL DEFAULT now(),
    -- "Préstamo" del trabajo: mientras no pase esta hora, es de quien lo cogió.
    -- Si ese worker se cae, el préstamo caduca y otro lo retoma. No hace falta
    -- mantener una transacción abierta durante minutos de síntesis de voz.
    locked_until    timestamptz,
    last_error      text        CHECK (length(last_error) <= 500),
    created_at      timestamptz NOT NULL DEFAULT now(),
    done_at         timestamptz,
    PRIMARY KEY (zone_slug, content_version)
);

-- Lo que consulta el worker una y otra vez: "trabajos pendientes por fecha".
-- Índice parcial: solo los pendientes, que son pocos aunque haya años de historia.
CREATE INDEX audio_jobs_pending ON ai.audio_jobs (available_at) WHERE done_at IS NULL;

CREATE TABLE ai.zone_audio (
    zone_slug        text        NOT NULL CHECK (zone_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(zone_slug) <= 100),
    -- Idioma pedido (el mismo que en la clave del guion).
    language         text        NOT NULL CHECK (language ~ '^[a-z]{2,3}$'),
    -- Idioma en el que habla la voz (el del texto real del guion).
    content_language text        NOT NULL CHECK (content_language ~ '^[a-z]{2,3}$'),
    content_version  bigint      NOT NULL CHECK (content_version >= 0),
    -- Huella del texto del guion: si el texto cambia (por ejemplo, el plan B
    -- por reglas se sustituye por el del LLM), cambia la huella y con ella la
    -- ruta de los archivos. Una ruta, una vez publicada, nunca cambia de contenido.
    script_digest    text        NOT NULL CHECK (script_digest ~ '^[0-9a-f]{16}$'),
    source           text        NOT NULL CHECK (source IN ('llm', 'rules')),
    voice            text        NOT NULL CHECK (length(voice) <= 100),
    -- [{"index": 1, "key": "...", "duration_seconds": 21.4, "text": "..."}, ...]
    parts            jsonb       NOT NULL CHECK (jsonb_typeof(parts) = 'array'),
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (zone_slug, language, content_version, script_digest)
);

-- La API busca "el audio más reciente de esta zona e idioma hasta la versión N".
CREATE INDEX zone_audio_latest ON ai.zone_audio (zone_slug, language, content_version DESC, created_at DESC);

-- Al subir la versión de una zona: apunta el trabajo y avisa al worker.
CREATE FUNCTION ai.enqueue_audio_job() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ai.audio_jobs (zone_slug, content_version)
    VALUES (NEW.zone_slug, NEW.content_version)
    ON CONFLICT DO NOTHING;
    -- pg_notify es un "timbre": despierta al worker al instante en vez de que
    -- espere a su siguiente vuelta. Si nadie lo oye no pasa nada: el trabajo
    -- ya está apuntado en la tabla y el worker lo verá en su próxima revisión.
    -- (El aviso solo se entrega si la transacción se confirma.)
    PERFORM pg_notify('ai_audio_jobs', NEW.zone_slug);
    RETURN NULL;
END;
$$;

CREATE TRIGGER zone_content_enqueue_audio
    AFTER INSERT OR UPDATE OF content_version ON ai.zone_content
    FOR EACH ROW EXECUTE FUNCTION ai.enqueue_audio_job();
