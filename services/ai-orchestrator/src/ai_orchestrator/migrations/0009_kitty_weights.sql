-- Bote común y modo pareja (maqueta "Bote común y modo pareja").
--
-- 1. El BOTE COMÚN es un asiento especial, el 0: "la hucha".
--    - Poner dinero en el bote = un pago de tu asiento al 0.
--    - Pagar con el bote = un gasto cuyo pagador es el 0.
--    - Lo que queda en la hucha sale de las mismas cuentas de siempre
--      (saldo del asiento 0), sin tablas nuevas.
--    Como el 0 no es una persona, ya no puede exigirse que el pagador sea un
--    miembro con una clave foránea: lo comprueba el código (expenses/domain.py).
--
-- 2. El MODO PAREJA reparte con pesos ("según sueldo": 60 % y 40 %).
--    - Un gasto puede repartirse 'weights': un peso por participante.
--    - El bote guarda el reparto habitual para no tener que elegirlo siempre.

ALTER TABLE ai.expenses DROP CONSTRAINT expenses_group_id_payer_seat_fkey;
ALTER TABLE ai.expenses ADD CONSTRAINT expenses_payer_seat_range CHECK (payer_seat BETWEEN 0 AND 20);

ALTER TABLE ai.expense_payments DROP CONSTRAINT expense_payments_group_id_from_seat_fkey;
ALTER TABLE ai.expense_payments DROP CONSTRAINT expense_payments_group_id_to_seat_fkey;
ALTER TABLE ai.expense_payments ADD CONSTRAINT expense_payments_seat_range
    CHECK (from_seat BETWEEN 0 AND 20 AND to_seat BETWEEN 0 AND 20);

ALTER TABLE ai.expenses DROP CONSTRAINT expenses_split_check;
ALTER TABLE ai.expenses ADD CONSTRAINT expenses_split_check CHECK (split IN ('equal', 'items', 'weights'));
-- Un peso (1..100) por participante, en el mismo orden. Solo con 'weights'.
ALTER TABLE ai.expenses ADD COLUMN weights smallint[]
    CHECK (weights IS NULL OR cardinality(weights) BETWEEN 1 AND 20);

-- Cuánto se pide a cada uno para el bote común ("20 € más cada uno").
ALTER TABLE ai.expense_groups ADD COLUMN kitty_ask_minor bigint
    CHECK (kitty_ask_minor BETWEEN 1 AND 100000000000);
-- El reparto habitual del bote: posición i = peso del asiento i+1.
ALTER TABLE ai.expense_groups ADD COLUMN default_weights smallint[]
    CHECK (default_weights IS NULL OR cardinality(default_weights) BETWEEN 1 AND 20);
