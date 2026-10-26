-- Chat del viaje en grupo (pantalla "Chat del viaje" de la app): los
-- miembros de un viaje se escriben y, si alguien empieza con "@Flyra", Flyra
-- contesta en el mismo hilo. Ver el paquete group_chat/.
--
-- Los mensajes cuelgan del viaje: si el viaje se borra, se van con él. Van
-- por ASIENTO (como los votos de los planes): al borrar una cuenta, sus
-- mensajes se borran (ver erasure.py) y el asiento queda anónimo.

-- Tipo de viaje: Flyra se adapta (familia = ritmo tranquilo, pareja = planes
-- para dos...). "Solo" no existe aquí: eso es el chat privado con Flyra.
ALTER TABLE ai.group_negotiations
    ADD COLUMN trip_kind text NOT NULL DEFAULT 'friends'
        CHECK (trip_kind IN ('friends', 'couple', 'family'));

-- El nombre que cada uno quiere enseñar en el chat ("Mamá"). Si no pone
-- ninguno, se ve su alias ("Viajero 2"). Nunca su correo ni su user_id.
ALTER TABLE ai.group_negotiation_members
    ADD COLUMN chat_name text CHECK (char_length(chat_name) BETWEEN 1 AND 30);

CREATE TABLE ai.group_chat_messages (
    -- Número creciente: la app pide "lo que haya después del 1234".
    message_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negotiation_id uuid        NOT NULL REFERENCES ai.group_negotiations (negotiation_id) ON DELETE CASCADE,
    -- Quién lo escribió (su asiento). NULL = lo escribió Flyra.
    seat           smallint    CHECK (seat BETWEEN 1 AND 8),
    body           text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- "Lo nuevo de este viaje" (lo que pide la app cada pocos segundos).
CREATE INDEX group_chat_trip ON ai.group_chat_messages (negotiation_id, message_id);
-- "¿Cuántos ha escrito hoy esta persona?" (tope diario) y la limpieza.
CREATE INDEX group_chat_seat_time ON ai.group_chat_messages (negotiation_id, seat, created_at);
