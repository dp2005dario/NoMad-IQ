-- Pantalla "Gastos" (maqueta 8): los extras del ticket y repartir después.
--
-- Un gasto con ticket puede llevar, además de sus líneas:
--   cover_minor    = pan y cubierto que viene en el ticket (no es una línea)
--   discount_minor = un descuento del ticket (se resta)
--   tip_pct        = la propina que deja el grupo (0, 5 o 10 %): no viene
--                    en el ticket, se suma encima
--   tip_minor      = esa propina ya calculada, en dinero
-- amount_minor sigue siendo lo que se reparte de verdad:
--   amount = ticket (líneas) + cubierto - descuento + propina
-- Todo se reparte según lo que tomó cada uno (ver expenses/domain.py).
--
-- Después de apuntarlo, cualquiera que participa puede cambiar cómo se
-- reparte (a partes iguales / por platos), quién tomó cada línea y los
-- extras: es la cuenta de la mesa y la arregláis entre todos.

ALTER TABLE ai.expenses
    ADD COLUMN cover_minor    bigint   NOT NULL DEFAULT 0 CHECK (cover_minor BETWEEN 0 AND 100000000000),
    ADD COLUMN discount_minor bigint   NOT NULL DEFAULT 0 CHECK (discount_minor BETWEEN 0 AND 100000000000),
    ADD COLUMN tip_pct        smallint NOT NULL DEFAULT 0 CHECK (tip_pct IN (0, 5, 10)),
    ADD COLUMN tip_minor      bigint   NOT NULL DEFAULT 0 CHECK (tip_minor BETWEEN 0 AND 100000000000);
