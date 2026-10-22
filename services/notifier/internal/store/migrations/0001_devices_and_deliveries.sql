-- Esquema propio del notifier. Ningún otro servicio lo lee ni lo escribe.
--
-- Lo que NO hay aquí, a propósito: user_id, nombres, coordenadas, zonas ni
-- historial de avisos enviados. Solo "taquillas" (seudónimos) con sus
-- teléfonos, y una cola de envíos pendientes que se vacía en minutos.
CREATE SCHEMA IF NOT EXISTS notify;

-- Teléfonos registrados para recibir avisos.
CREATE TABLE notify.devices (
    -- Lo genera la app al instalarse (UUID aleatorio).
    device_id        uuid        PRIMARY KEY,
    -- HMAC-SHA256 del user_id (ver internal/pseudonym). Nunca el user_id.
    recipient        text        NOT NULL CHECK (recipient ~ '^[A-Za-z0-9_-]{43}$'),
    platform         text        NOT NULL CHECK (platform IN ('android')),
    -- Token de FCM cifrado con AES-256-GCM (nonce + texto cifrado).
    token_ciphertext bytea       NOT NULL,
    -- "Índice ciego": HMAC del token. Permite detectar el mismo teléfono
    -- registrado dos veces sin guardar el token en claro.
    token_index      bytea       NOT NULL UNIQUE CHECK (octet_length(token_index) = 32),
    -- Clave pública X25519 del teléfono: los avisos se cifran para ella.
    public_key       bytea       NOT NULL CHECK (octet_length(public_key) = 32),
    created_at       timestamptz NOT NULL DEFAULT now(),
    -- La app se vuelve a registrar al abrirse: un teléfono que no da
    -- señales en NOTIFY_DEVICE_INACTIVITY_DAYS se borra solo.
    last_seen_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX devices_by_recipient ON notify.devices (recipient, last_seen_at DESC);
CREATE INDEX devices_by_last_seen ON notify.devices (last_seen_at);

-- Cola de envíos pendientes (bandeja de salida). Cada fila es UN aviso ya
-- cifrado para UN teléfono. Se borra en cuanto Google lo acepta, caduca o
-- se abandona: no queda historial.
CREATE TABLE notify.deliveries (
    delivery_id  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id    uuid        NOT NULL REFERENCES notify.devices (device_id) ON DELETE CASCADE,
    -- Aviso cifrado con HPKE para la clave pública del teléfono.
    envelope     bytea       NOT NULL,
    attempts     integer     NOT NULL DEFAULT 0,
    -- No se envía antes de esta hora (reintentos con espera).
    available_at timestamptz NOT NULL DEFAULT now(),
    -- "Préstamo": mientras no caduque, ninguna otra copia lo coge.
    locked_until timestamptz,
    -- Pasada esta hora el aviso ya no sirve y se tira sin enviarlo.
    expires_at   timestamptz NOT NULL,
    last_error   text,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX deliveries_ready ON notify.deliveries (available_at);
CREATE INDEX deliveries_by_device ON notify.deliveries (device_id);
CREATE INDEX deliveries_by_expiry ON notify.deliveries (expires_at);
