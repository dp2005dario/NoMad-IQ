"""Gastos compartidos contra un PostgreSQL REAL (el de docker compose).

Solo se ejecutan con:

    make up && make test-integration      # o: uv run pytest -m integration

Comprueban lo que las pruebas en memoria no pueden: que el SQL de verdad
funciona (tipos, arrays de asientos, claves foráneas, bloqueos).
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import date

import asyncpg
import pytest
from test_integration import _settings

from ai_orchestrator.expenses.domain import Item, balances
from ai_orchestrator.expenses.store import (
    GroupFullError,
    GroupNotFoundError,
    NewExpense,
    NotAllowedError,
    PostgresExpenses,
)
from ai_orchestrator.store import create_pool, migrate

pytestmark = pytest.mark.integration


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def person() -> str:
    # Un usuario inventado por test: así los datos de un test no afectan a otro.
    return f"it-{uuid.uuid4()}"


async def test_dinner_split_by_items(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresExpenses(pool)
    alex, bea = person(), person()
    group = await store.create(alex, "Álex", "Madrid", "EUR")
    joined = await store.join(group.invite_code, bea, "Bea")
    assert [m.name for m in joined.members] == ["Álex", "Bea"]
    # Volver a unirse no crea otro asiento.
    assert len((await store.join(group.invite_code, bea, "Bea")).members) == 2

    dinner = await store.add_expense(
        group.group_id,
        alex,
        NewExpense(
            title="Cena",
            amount_minor=3000,
            payer_seat=1,
            split="items",
            participants=(1, 2),
            spent_on=date(2026, 10, 23),
            items=(Item("Pizza", 1, 1800), Item("Vino", 1, 1200)),
            original_minor=3300,
            original_currency="USD",
        ),
    )
    # Bea se pide la pizza y Álex el vino.
    await store.claim(group.group_id, dinner.expense_id, bea, 0, True)
    claimed = await store.claim(group.group_id, dinner.expense_id, alex, 1, True)
    assert claimed.items[0].claimed_by == (2,) and claimed.items[1].claimed_by == (1,)
    # Desmarcar también funciona (y repetir no duplica).
    await store.claim(group.group_id, dinner.expense_id, alex, 1, False)
    again = await store.claim(group.group_id, dinner.expense_id, alex, 1, True)
    assert again.items[1].claimed_by == (1,)

    await store.add_payment(group.group_id, bea, 1, 1000)
    loaded = await store.get_for_member(group.group_id, bea)
    assert loaded is not None
    assert loaded.expenses[0].original_currency == "USD"
    bal = balances(
        tuple(m.seat for m in loaded.members),
        [e.as_expense() for e in loaded.expenses],
        [p.as_payment() for p in loaded.payments],
    )
    assert bal == {1: 1800 - 1000, 2: -1800 + 1000}

    # Un extraño no ve el bote, y Bea no puede borrar un gasto que pagó Álex.
    assert await store.get_for_member(group.group_id, person()) is None
    with pytest.raises(NotAllowedError):
        await store.delete_expense(group.group_id, dinner.expense_id, bea)
    await store.delete_expense(group.group_id, dinner.expense_id, alex)
    after = await store.get_for_member(group.group_id, alex)
    assert after is not None and not after.expenses

    mine = await store.list_for_member(bea, limit=10)
    assert [g.group_id for g in mine] == [group.group_id]


async def test_unknown_code_and_full_group(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresExpenses(pool)
    with pytest.raises(GroupNotFoundError):
        await store.join("ZZZZZZZZ", person(), "Nadie")
    group = await store.create(person(), "Org", "Piso", "EUR")
    # 19 personas a la vez: los bloqueos reparten asientos sin repetir ninguno.
    await asyncio.gather(*(store.join(group.invite_code, person(), f"P{i}") for i in range(19)))
    with pytest.raises(GroupFullError):
        await store.join(group.invite_code, person(), "Sobra")


async def test_kitty_and_weights(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresExpenses(pool)
    ana, dario = person(), person()
    group = await store.create(ana, "Ana", "Lisboa", "EUR")
    await store.join(group.invite_code, dario, "Darío")
    await store.set_kitty_ask(group.group_id, ana, 10000)
    await store.add_payment(group.group_id, ana, 0, 10000)
    await store.add_payment(group.group_id, dario, 0, 10000)
    # El bote (asiento 0) paga un tuk-tuk; luego un gasto de pareja 60/40.
    await store.add_expense(
        group.group_id,
        dario,
        NewExpense("Tuk-tuk", 4800, 0, "equal", (1, 2), date(2026, 10, 23)),
    )
    await store.add_expense(
        group.group_id,
        ana,
        NewExpense("Cena", 10000, 1, "weights", (1, 2), date(2026, 10, 23), weights=(60, 40)),
    )
    await store.set_default_weights(group.group_id, ana, {1: 60, 2: 40})
    back = await store.add_payment(group.group_id, dario, 1, 1000, from_kitty=True)
    assert (back.from_seat, back.to_seat) == (0, 2)
    loaded = await store.get_for_member(group.group_id, ana)
    assert loaded is not None
    assert loaded.kitty_ask_minor == 10000
    assert loaded.default_weights == ((1, 60), (2, 40))
    assert {e.title: e.weights for e in loaded.expenses} == {"Tuk-tuk": (), "Cena": (60, 40)}
    bal = balances(
        (1, 2), [e.as_expense() for e in loaded.expenses], [p.as_payment() for p in loaded.payments]
    )
    # Hucha: 200 puestos - 48 de tuk-tuk - 10 devueltos = 142.
    assert -bal[0] == 14200
