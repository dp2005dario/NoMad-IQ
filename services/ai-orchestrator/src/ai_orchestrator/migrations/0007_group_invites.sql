-- Invitaciones a un viaje en grupo (la pantalla Grupo de la app).
--
-- Hasta ahora el organizador tenía que saber el user_id de cada amigo. En la
-- app eso no existe: el organizador crea el viaje y comparte un CÓDIGO de
-- invitación ("7K2M-9QXD") por WhatsApp o en persona. Quien lo escribe en su
-- móvil entra en el grupo.
--
--   invite_code   -> 8 letras/números al azar (alfabeto Crockford: sin O, I,
--                    L ni U, para que no se confundan al dictarlo). Único
--                    mientras está vivo. Se BORRA (NULL) al cerrar el grupo:
--                    un código viejo no sirve para nada y deja el hueco libre.
--   invites_open  -> el grupo admite gente nueva. Mientras está abierto, la
--                    negociación NO arranca sola cuando todos han enviado sus
--                    preferencias (podría faltar alguien por llegar): la
--                    arranca el organizador con "Empezar" o el plazo.
--   display_name  -> el nombre que cada uno quiere que vea SU grupo ("Noelia").
--                    Nunca llega al LLM: los agentes solo ven "Viajero 2".

ALTER TABLE ai.group_negotiations
    ADD COLUMN invite_code  text    UNIQUE CHECK (invite_code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
    ADD COLUMN invites_open boolean NOT NULL DEFAULT false,
    -- Un código solo existe con el grupo abierto (y no al revés: se puede
    -- abrir sin código si algún día queremos invitar de otra forma).
    ADD CONSTRAINT group_negotiations_code_needs_open CHECK (invite_code IS NULL OR invites_open);

ALTER TABLE ai.group_negotiation_members
    ADD COLUMN display_name text CHECK (char_length(display_name) BETWEEN 1 AND 40);
