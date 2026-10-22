-- Esquema "geo": la FUENTE DE VERDAD de los datos geoespaciales de NomadIQ.
--
-- Reparto de trabajo (decisión de arquitectura):
--   * PostgreSQL + PostGIS guarda los datos de forma duradera, con índices
--     espaciales GiST para consultas grandes o analíticas (informes, cargas
--     masivas, "¿qué zonas se solapan?").
--   * El geo-engine (Rust) carga una COPIA en memoria y responde desde ahí las
--     preguntas de alta frecuencia (aeropuerto más cercano, ¿en qué zona
--     está este usuario?) sin una consulta SQL por petición.
-- Así ninguno de los dos hace el trabajo del otro.
--
-- La extensión PostGIS la instala la infraestructura (necesita permisos de
-- superusuario): infrastructure/postgres/init/01-extensions.sql.

CREATE SCHEMA IF NOT EXISTS geo;

-- Aeropuertos con vuelos comerciales.
-- geography (y no geometry) porque las distancias de PostGIS sobre geography
-- se calculan en metros sobre la Tierra real, no en grados sobre un plano.
CREATE TABLE IF NOT EXISTS geo.airports (
    iata_code    char(3)     PRIMARY KEY CHECK (iata_code ~ '^[A-Z]{3}$'),
    icao_code    char(4)     CHECK (icao_code ~ '^[A-Z0-9]{4}$'),
    name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    city         text        NOT NULL DEFAULT '' CHECK (length(city) <= 200),
    country_code char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    location     geography(Point, 4326) NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Índice espacial: permite a PostGIS buscar por cercanía sin recorrer la tabla.
CREATE INDEX IF NOT EXISTS airports_location_gist ON geo.airports USING gist (location);

-- Zonas de geofencing (polígonos). Se guardan siempre como MultiPolygon para
-- que todas tengan el mismo tipo (un polígono simple es un MultiPolygon de uno).
CREATE TABLE IF NOT EXISTS geo.zones (
    zone_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug       text        NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 100),
    name       text        NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
    kind       text        NOT NULL CHECK (kind IN ('CITY_CENTER', 'TOURIST_AREA', 'AIRPORT', 'RESTRICTED')),
    geom       geometry(MultiPolygon, 4326) NOT NULL,
    active     boolean     NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- La base de datos rechaza polígonos rotos (que se cruzan a sí mismos,
    -- sin cerrar...). El geo-engine vuelve a validarlos al cargarlos:
    -- defensa en profundidad.
    CONSTRAINT zones_geom_valid CHECK (ST_IsValid(geom)),
    -- Las zonas que cruzan el antimeridiano (longitud ±180°) se parten en
    -- dos polígonos al darlas de alta; así el índice en memoria es más simple.
    CONSTRAINT zones_geom_in_range CHECK (ST_XMin(geom) >= -180 AND ST_XMax(geom) <= 180
                                          AND ST_YMin(geom) >= -90 AND ST_YMax(geom) <= 90)
);

CREATE INDEX IF NOT EXISTS zones_geom_gist ON geo.zones USING gist (geom);

-- updated_at se actualiza solo en cada UPDATE. El geo-engine lo usa para saber
-- si los datos cambiaron y si merece la pena reconstruir su copia en memoria.
CREATE OR REPLACE FUNCTION geo.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS airports_touch ON geo.airports;
CREATE TRIGGER airports_touch BEFORE UPDATE ON geo.airports
    FOR EACH ROW EXECUTE FUNCTION geo.touch_updated_at();

DROP TRIGGER IF EXISTS zones_touch ON geo.zones;
CREATE TRIGGER zones_touch BEFORE UPDATE ON geo.zones
    FOR EACH ROW EXECUTE FUNCTION geo.touch_updated_at();

-- Un DELETE no deja rastro en updated_at, así que se registra aparte: el
-- geo-engine compara esta "versión" para detectar también los borrados.
CREATE TABLE IF NOT EXISTS geo.dataset_version (
    singleton  boolean     PRIMARY KEY DEFAULT true CHECK (singleton),
    version    bigint      NOT NULL DEFAULT 0,
    changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO geo.dataset_version (singleton) VALUES (true) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION geo.bump_dataset_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE geo.dataset_version SET version = version + 1, changed_at = now();
    RETURN NULL;
END;
$$;

-- "FOR EACH STATEMENT": una sola subida de versión por sentencia, aunque
-- toque miles de filas (una carga masiva no hace miles de UPDATE extra).
DROP TRIGGER IF EXISTS airports_version ON geo.airports;
CREATE TRIGGER airports_version AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON geo.airports
    FOR EACH STATEMENT EXECUTE FUNCTION geo.bump_dataset_version();

DROP TRIGGER IF EXISTS zones_version ON geo.zones;
CREATE TRIGGER zones_version AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON geo.zones
    FOR EACH STATEMENT EXECUTE FUNCTION geo.bump_dataset_version();
