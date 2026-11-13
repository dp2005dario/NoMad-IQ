-- Viajes en grupo: "Reparto de tareas" (quién reserva el hotel, quién
-- compra las entradas, quién lleva el cargador...).
--
-- Cualquiera del viaje añade tareas; cada uno puede quedarse con una ("me
-- encargo yo") y marcarla como hecha. Se guarda el ASIENTO, no la persona:
-- los demás solo ven el nombre que cada uno eligió para el grupo.

CREATE TABLE ai.group_tasks (
    task_id        uuid        PRIMARY KEY,
    negotiation_id uuid        NOT NULL REFERENCES ai.group_negotiations (negotiation_id) ON DELETE CASCADE,
    label          text        NOT NULL CHECK (char_length(label) BETWEEN 1 AND 80),
    added_by_seat  smallint    NOT NULL CHECK (added_by_seat BETWEEN 1 AND 8),
    owner_seat     smallint    CHECK (owner_seat BETWEEN 1 AND 8),
    done           boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX group_tasks_trip ON ai.group_tasks (negotiation_id, created_at);
