-- Migración 2: foto de perfil y enlace con la cuenta de Google.
-- (Una migración ya aplicada nunca se edita: por eso es un archivo nuevo.)

-- Dirección https de la foto de perfil (la de Google). Puede no haber.
ALTER TABLE users ADD COLUMN photo_url text CHECK (photo_url IS NULL OR length(photo_url) <= 500);

-- El identificador estable de Google ("sub") de quien entró con Google.
-- Es único: una cuenta de Google solo puede estar enlazada a un usuario.
ALTER TABLE users ADD COLUMN google_sub text;
CREATE UNIQUE INDEX users_google_sub_key ON users (google_sub) WHERE google_sub IS NOT NULL;
