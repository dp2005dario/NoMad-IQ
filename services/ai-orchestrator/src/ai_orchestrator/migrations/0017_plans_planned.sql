-- "Añadir al plan" en Elegid planes: cuando un match viajero (dos o más del
-- grupo dijeron que sí) se mete en el plan del grupo, se apunta cuándo.
-- NULL = aún no está en el plan. Ver plans/.
ALTER TABLE ai.group_plans
    ADD COLUMN planned_at timestamptz;
