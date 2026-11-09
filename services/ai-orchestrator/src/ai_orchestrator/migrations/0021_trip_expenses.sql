-- Pantalla "Grupo": los gastos van unidos al viaje en grupo.
--
-- Cada viaje en grupo (negociación) tiene, como mucho, UN bote de gastos.
-- Lo crea el primero que toca "Gastos del grupo" y los demás del viaje
-- entran solos (sin código): así "Lo que debes" sale en Grupo.
-- Aquí no se guarda nada de nadie: solo qué bote es de qué viaje.

CREATE TABLE ai.trip_expense_groups (
    negotiation_id uuid PRIMARY KEY REFERENCES ai.group_negotiations (negotiation_id) ON DELETE CASCADE,
    group_id       uuid NOT NULL UNIQUE REFERENCES ai.expense_groups (group_id) ON DELETE CASCADE
);
