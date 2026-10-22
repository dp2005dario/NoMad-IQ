-- Migración 0005: recolector de basura del audio (borrar versiones viejas sin romper móviles).
--
-- Cada corrección de hechos deja una versión entera de audio (a escala, unos
-- 2 GB). El recolector (audioguides/audio_gc.py) borra las viejas con una
-- política de "ventana de gracia":
--
--   - Siempre se conservan las 2 grabaciones más recientes de cada zona e
--     idioma (la actual, N, y la anterior, N-1).
--   - Una grabación sustituida no se borra hasta que lleva 30 días sustituida.
--     Mientras tanto la API ya no la anuncia (siempre da la más reciente),
--     pero sus archivos siguen ahí para el móvil que guardó el manifiesto
--     viejo o lo usa sin conexión: es la "cuarentena".
--
-- Al borrar, la fila NO desaparece: se marca con purged_at. Es una "lápida":
-- si un móvil muy atrasado pide un archivo borrado, la API sabe que existió y
-- responde 410 Gone ("ya no está, pide el manifiesto actual") con un enlace,
-- en vez de un 404 que no explica nada. Una lápida ocupa unos pocos bytes.

ALTER TABLE ai.zone_audio ADD COLUMN purged_at timestamptz;

-- La API y el worker solo miran las grabaciones vivas.
DROP INDEX ai.zone_audio_latest;
CREATE INDEX zone_audio_latest ON ai.zone_audio (zone_slug, language, content_version DESC, created_at DESC)
    WHERE purged_at IS NULL;
