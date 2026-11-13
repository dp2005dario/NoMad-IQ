-- Nuevo viaje en grupo: las "reglas" que pone el organizador.
--
-- Por ejemplo "máx. 500 € por persona" o "nada de madrugones". Las reglas
-- valen para TODOS los agentes: ninguna opción por encima del máximo y lo
-- que se evita se suma a lo que evita cada uno. NULL = sin reglas.

ALTER TABLE ai.group_negotiations
    ADD COLUMN rules jsonb CHECK (rules IS NULL OR jsonb_typeof(rules) = 'object');
