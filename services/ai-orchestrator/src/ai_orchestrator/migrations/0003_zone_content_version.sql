-- Migración 0003: número de versión del contenido de cada zona.
--
-- El problema: el guion de una zona se guarda en Redis por zona+idioma. Si
-- alguien corrige un hecho en ai.zone_facts (un horario, una fecha mal
-- puesta), el guion viejo seguía sonando hasta que caducase.
--
-- La solución: cada zona tiene un número, content_version, que SUBE SOLO
-- (con un trigger) cada vez que se añade, cambia o borra uno de sus hechos.
-- Ese número forma parte de la clave de caché
-- (ai:audioguide:v2:<zona>:<idioma>:<versión>): al subir, la clave nueva
-- está vacía, se genera un guion nuevo y el viejo caduca solo.
--
-- ¿Por qué un trigger y no "acuérdate de subir la versión"? Porque las
-- personas se olvidan; la base de datos no. Da igual quién cambie los hechos
-- (una migración, un panel de administración, un psql a mano): la versión sube.
--
-- ¿Por qué un entero y no una huella (hash) de todos los hechos? Calcular la
-- huella obliga a leer todos los hechos; leer un entero por clave primaria es
-- lo más barato que existe. Y el servicio además lo guarda en memoria unos
-- segundos, así que PostgreSQL no se entera de cuánta gente entra en una zona.

CREATE TABLE ai.zone_content (
    zone_slug       text        PRIMARY KEY CHECK (zone_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(zone_slug) <= 100),
    content_version bigint      NOT NULL DEFAULT 1 CHECK (content_version >= 1),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Las zonas que ya tienen hechos (migración 0002) empiezan en la versión 1.
INSERT INTO ai.zone_content (zone_slug)
SELECT DISTINCT zone_slug FROM ai.zone_facts
ON CONFLICT DO NOTHING;

-- Sube (o crea a 1) la versión de una zona.
CREATE FUNCTION ai.bump_zone_content_version(slug text) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO ai.zone_content AS c (zone_slug) VALUES (slug)
    ON CONFLICT (zone_slug) DO UPDATE
        SET content_version = c.content_version + 1, updated_at = now();
$$;

CREATE FUNCTION ai.zone_facts_changed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- OLD existe en UPDATE/DELETE; NEW en INSERT/UPDATE. Si un UPDATE mueve
    -- un hecho de una zona a otra, cambian las DOS.
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM ai.bump_zone_content_version(OLD.zone_slug);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') AND (TG_OP = 'INSERT' OR NEW.zone_slug <> OLD.zone_slug) THEN
        PERFORM ai.bump_zone_content_version(NEW.zone_slug);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER zone_facts_bump_version
    AFTER INSERT OR UPDATE OR DELETE ON ai.zone_facts
    FOR EACH ROW EXECUTE FUNCTION ai.zone_facts_changed();
