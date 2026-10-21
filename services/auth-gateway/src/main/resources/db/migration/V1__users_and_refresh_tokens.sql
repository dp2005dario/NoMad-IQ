-- Migración 1 del auth-gateway (la aplica Flyway automáticamente al arrancar).
--
-- Regla de Flyway: una migración ya aplicada NUNCA se edita. Si hay que
-- cambiar algo, se crea V2__..., V3__... Flyway guarda en la tabla
-- identity.flyway_schema_history cuáles se han aplicado ya.
--
-- Todo vive en el esquema "identity": este servicio no toca tablas de otros
-- (mínimo privilegio y fronteras claras entre microservicios).

-- ---------------------------------------------------------------------------
-- Usuarios
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    -- UUID en vez de 1, 2, 3...: no revela cuántos usuarios hay ni permite
    -- adivinar el id de otra persona.
    id            uuid        PRIMARY KEY,
    -- Siempre en minúsculas (lo normaliza el código); el CHECK lo garantiza
    -- aunque alguien inserte a mano.
    email         text        NOT NULL CHECK (email = lower(email) AND length(email) <= 254),
    -- Nunca la contraseña: solo su "huella" Argon2id, imposible de revertir.
    password_hash text        NOT NULL,
    -- Roles para el control de acceso (RBAC). Todo usuario empieza como USER.
    roles         text[]      NOT NULL DEFAULT ARRAY['USER'] CHECK (cardinality(roles) > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- Si tiene fecha, la cuenta está desactivada (baneo): no puede entrar ni refrescar.
    disabled_at   timestamptz
);

-- Un email solo puede registrarse una vez.
CREATE UNIQUE INDEX users_email_key ON users (email);

-- ---------------------------------------------------------------------------
-- Tokens de refresco
-- ---------------------------------------------------------------------------
-- Cada token es de UN SOLO USO: al usarlo se marca y se entrega otro nuevo
-- de la misma "familia" (rotación). Si alguien presenta un token ya usado, es
-- señal de robo (lo usó el ladrón o la víctima, uno de los dos es un
-- impostor) y se revoca la familia entera: los dos tienen que volver a hacer login.
CREATE TABLE refresh_tokens (
    -- Huella SHA-256 del token: si alguien roba esta tabla, no obtiene
    -- tokens utilizables.
    token_hash  bytea       PRIMARY KEY CHECK (length(token_hash) = 32),
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- Todos los tokens nacidos de un mismo login comparten familia.
    family_id   uuid        NOT NULL,
    issued_at   timestamptz NOT NULL,
    expires_at  timestamptz NOT NULL CHECK (expires_at > issued_at),
    -- Cuándo se canjeó por uno nuevo (NULL = aún no usado).
    used_at     timestamptz,
    -- Cuándo se anuló (logout, robo detectado, baneo).
    revoked_at  timestamptz
);

-- Para revocar rápido "toda la familia" o "todo lo del usuario".
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id);
-- Para la limpieza periódica de tokens caducados.
CREATE INDEX refresh_tokens_expires_idx ON refresh_tokens (expires_at);
