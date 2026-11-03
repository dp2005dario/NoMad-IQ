-- Pantalla "Grupo" (maqueta 7), dos cosas nuevas:
--
-- 1. "Gustos de cada uno": cada miembro marca sus gustos (tapas, museos,
--    sin madrugar...) y TODO el grupo los ve. No son las preferencias
--    privadas de la negociación (esas siguen siendo secretas): estos gustos
--    se enseñan a propósito para que Flyra y el grupo los crucen.
--    Se guardan como identificadores fijos ("tapas", "views"): la app los
--    traduce al idioma de cada uno.
--
-- 2. Los votos de "¿Qué os apetece?" (Me apetece / Paso sobre un sitio
--    cercano) y de "Votad dónde dormir" usan el mismo tablero de planes
--    (group_plans + group_plan_votes). La columna "kind" dice de qué es cada
--    uno: así "Elegid planes" solo enseña los planes de siempre.
--      plan  = un plan normal (lo de antes)
--      crave = un sitio de "¿Qué os apetece?"
--      sleep = una zona para dormir
--    Un sitio o una zona no se repite en el mismo viaje (por su nombre).

ALTER TABLE ai.group_negotiation_members
    ADD COLUMN tastes text[] NOT NULL DEFAULT '{}' CHECK (cardinality(tastes) <= 12);

ALTER TABLE ai.group_plans
    ADD COLUMN kind text NOT NULL DEFAULT 'plan' CHECK (kind IN ('plan', 'crave', 'sleep'));

CREATE UNIQUE INDEX group_plans_kind_title
    ON ai.group_plans (negotiation_id, kind, lower(title)) WHERE kind <> 'plan';
