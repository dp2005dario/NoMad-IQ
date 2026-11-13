-- "Copia este viaje": la foto de perfil de quien publica (la de su cuenta
-- de Google), para que su tarjeta del muro lleve su cara y no un dibujo.
-- Solo una dirección https de Google (se comprueba antes de guardarla).
ALTER TABLE ai.shared_trips ADD COLUMN IF NOT EXISTS author_photo text;
