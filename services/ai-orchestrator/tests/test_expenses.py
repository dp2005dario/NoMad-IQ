"""Pruebas de los gastos compartidos: las cuentas y la API (store en memoria)."""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, date, datetime
from typing import Any

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.expenses.api import expense_router
from ai_orchestrator.expenses.domain import (
    MAX_MEMBERS,
    Expense,
    Item,
    Payment,
    balances,
    check_expense,
    divide,
    settle,
    shares,
)
from ai_orchestrator.expenses.store import (
    ExpenseNotFoundError,
    ExpenseRecord,
    GroupFullError,
    GroupNotFoundError,
    GroupRecord,
    Member,
    NewExpense,
    NotAllowedError,
    PaymentRecord,
)

NOW = datetime(2026, 10, 23, 20, 0, tzinfo=UTC)
DARIO = "11111111-1111-4111-8111-111111111111"
ALEX = "22222222-2222-4222-8222-222222222222"
MARTA = "33333333-3333-4333-8333-333333333333"
STRANGER = "44444444-4444-4444-8444-444444444444"

# --- Las cuentas -------------------------------------------------------------------------


def test_divide_never_loses_a_cent() -> None:
    assert divide(100, {1: 1, 2: 1, 3: 1}) == {1: 34, 2: 33, 3: 33}
    assert divide(8600, {1: 1, 2: 1, 3: 1, 4: 1}) == dict.fromkeys((1, 2, 3, 4), 2150)
    parts = divide(1001, {1: 3, 2: 2, 3: 2})
    assert sum(parts.values()) == 1001
    with pytest.raises(ValueError):
        divide(10, {1: 0})


def test_equal_split() -> None:
    e = Expense(8600, payer_seat=3, split="equal", participants=(1, 2, 3, 4))
    assert shares(e) == dict.fromkeys((1, 2, 3, 4), 2150)


def test_split_by_items_like_the_mockup() -> None:
    # Cena en La Latina (86 €): croquetas y tortilla para todos, el resto de cada uno.
    items = (
        Item("Croquetas", 2, 1200),
        Item("Tortilla", 1, 1200),
        Item("Secreto ibérico", 1, 1775, (1,)),
        Item("Vino tinto copa", 4, 1400, (2,)),
        Item("Pulpo a feira", 1, 1850, (3,)),
        Item("Caña", 4, 1175, (4,)),
    )
    e = Expense(8600, payer_seat=3, split="items", participants=(1, 2, 3, 4), items=items)
    s = shares(e)
    assert s == {1: 2375, 2: 2000, 3: 2450, 4: 1775}
    assert sum(s.values()) == 8600


def test_items_scale_to_the_total_with_tip() -> None:
    # Ticket de 20 € y se pagaron 22 € (propina): cada uno pone en proporción.
    e = Expense(2200, 1, "items", (1, 2), (Item("A", 1, 1500, (1,)), Item("B", 1, 500, (2,))))
    assert shares(e) == {1: 1650, 2: 550}


def test_shared_item_and_unclaimed_lines() -> None:
    e = Expense(900, 1, "items", (1, 2, 3), (Item("Pizza", 1, 600, (1, 2)), Item("Agua", 1, 300)))
    assert shares(e) == {1: 400, 2: 400, 3: 100}


def test_balances_and_settle() -> None:
    expenses = [
        Expense(8600, 3, "equal", (1, 2, 3, 4)),  # Álex paga la cena
        Expense(4000, 1, "equal", (1, 2)),  # Darío paga un taxi para 2
    ]
    bal = balances((1, 2, 3, 4), expenses, [Payment(4, 3, 2150)])  # Noelia ya pagó a Álex
    assert sum(bal.values()) == 0
    assert bal == {1: -2150 + 2000, 2: -2150 - 2000, 3: 8600 - 2150 - 2150, 4: 0}
    transfers = settle(bal)
    # Bea debe 41,50 y Darío 1,50: los dos pagan a Álex (dos transferencias, 43,00 en total).
    assert sorted((t.from_seat, t.to_seat, t.amount_minor) for t in transfers) == [(1, 3, 150), (2, 3, 4150)]
    for t in transfers:
        bal[t.from_seat] += t.amount_minor
        bal[t.to_seat] -= t.amount_minor
    assert set(bal.values()) == {0}


def test_check_expense() -> None:
    check_expense(Expense(100, 1, "equal", (1, 2)), [1, 2])
    with pytest.raises(ValueError):
        check_expense(Expense(100, 9, "equal", (1, 2)), [1, 2])
    with pytest.raises(ValueError):
        check_expense(Expense(100, 1, "items", (1, 2)), [1, 2])
    with pytest.raises(ValueError):
        check_expense(Expense(100, 1, "items", (1,), (Item("x", 1, 100, (2,)),)), [1, 2])


# --- Store en memoria (mismas reglas que PostgresExpenses) --------------------------------


class MemoryExpenses:
    def __init__(self) -> None:
        self.groups: dict[str, GroupRecord] = {}

    def _find(self, group_id: str, user_id: str) -> GroupRecord:
        g = self.groups.get(group_id)
        if g is None or g.seat_of(user_id) is None:
            raise GroupNotFoundError(group_id)
        return g

    async def create(self, user_id: str, name: str, title: str, currency: str) -> GroupRecord:
        gid = str(uuid.uuid4())
        self.groups[gid] = GroupRecord(gid, title, currency, "7K2M9QXD", NOW, (Member(1, user_id, name),))
        return self.groups[gid]

    async def join(self, code: str, user_id: str, name: str) -> GroupRecord:
        g = next((g for g in self.groups.values() if g.invite_code == code), None)
        if g is None:
            raise GroupNotFoundError(code)
        if g.seat_of(user_id) is None:
            if len(g.members) >= MAX_MEMBERS:
                raise GroupFullError(code)
            g = replace(g, members=(*g.members, Member(len(g.members) + 1, user_id, name)))
            self.groups[g.group_id] = g
        return g

    async def list_for_member(self, user_id: str, *, limit: int) -> list[GroupRecord]:
        return [g for g in self.groups.values() if g.seat_of(user_id) is not None][:limit]

    async def get_for_member(self, group_id: str, user_id: str) -> GroupRecord | None:
        try:
            return self._find(group_id, user_id)
        except GroupNotFoundError:
            return None

    async def add_expense(self, group_id: str, user_id: str, new: NewExpense) -> ExpenseRecord:
        g = self._find(group_id, user_id)
        check_expense(
            Expense(new.amount_minor, new.payer_seat, new.split, new.participants, new.items),
            [m.seat for m in g.members],
        )
        rec = ExpenseRecord(
            str(uuid.uuid4()),
            new.title,
            new.amount_minor,
            new.payer_seat,
            new.split,
            new.participants,
            new.items,
            new.spent_on,
            g.seat_of(user_id) or 0,
            NOW,
            new.original_minor,
            new.original_currency,
        )
        self.groups[group_id] = replace(g, expenses=(rec, *g.expenses))
        return rec

    async def claim(
        self, group_id: str, expense_id: str, user_id: str, index: int, claimed: bool
    ) -> ExpenseRecord:
        g = self._find(group_id, user_id)
        me = g.seat_of(user_id) or 0
        e = next((e for e in g.expenses if e.expense_id == expense_id), None)
        if e is None or index >= len(e.items):
            raise ExpenseNotFoundError(expense_id)
        if me not in e.participants:
            raise NotAllowedError("no participas")
        items = list(e.items)
        who = tuple(s for s in items[index].claimed_by if s != me) + ((me,) if claimed else ())
        items[index] = replace(items[index], claimed_by=who)
        new = replace(e, items=tuple(items))
        self.groups[group_id] = replace(g, expenses=tuple(new if x is e else x for x in g.expenses))
        return new

    async def delete_expense(self, group_id: str, expense_id: str, user_id: str) -> None:
        g = self._find(group_id, user_id)
        me = g.seat_of(user_id)
        e = next((e for e in g.expenses if e.expense_id == expense_id), None)
        if e is None:
            raise ExpenseNotFoundError(expense_id)
        if me not in (e.created_by, e.payer_seat):
            raise NotAllowedError("no")
        self.groups[group_id] = replace(g, expenses=tuple(x for x in g.expenses if x is not e))

    async def add_payment(
        self, group_id: str, user_id: str, to_seat: int, amount_minor: int
    ) -> PaymentRecord:
        g = self._find(group_id, user_id)
        me = g.seat_of(user_id) or 0
        if to_seat == me or to_seat not in [m.seat for m in g.members]:
            raise ValueError("a quién pagas no está en el bote")
        p = PaymentRecord(str(uuid.uuid4()), me, to_seat, amount_minor, NOW)
        self.groups[group_id] = replace(g, payments=(p, *g.payments))
        return p


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def client(store: MemoryExpenses) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), expenses=expense_router(store))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


DINNER: dict[str, Any] = {
    "title": "Cena en La Latina",
    "amount_minor": 8600,
    "payer_seat": 2,
    "split": "items",
    "participants": [1, 2, 3],
    "spent_on": date(2026, 10, 22).isoformat(),
    "items": [
        {"name": "Croquetas", "qty": 2, "price_minor": 1200},
        {"name": "Secreto ibérico", "price_minor": 1775},
        {"name": "Pulpo a feira", "price_minor": 1850, "claimed_by": [2]},
    ],
}


async def test_full_flow() -> None:
    store = MemoryExpenses()
    async with client(store) as c:
        created = await c.post(
            "/v1/expense-groups",
            json={"title": "Madrid", "currency": "EUR", "my_name": "Darío"},
            headers=h(DARIO),
        )
        assert created.status_code == 201
        gid = created.json()["group_id"]
        code = created.json()["invite_code"]
        # Se perdona escribirlo en minúsculas y con guion.
        joined = await c.post(
            "/v1/expense-groups/join", json={"code": "7k2m-9qxd", "my_name": "Álex"}, headers=h(ALEX)
        )
        assert joined.status_code == 200 and joined.json()["my_seat"] == 2
        await c.post("/v1/expense-groups/join", json={"code": code, "my_name": "Marta"}, headers=h(MARTA))
        assert (await c.get(f"/v1/expense-groups/{gid}", headers=h(STRANGER))).status_code == 404

        e = await c.post(f"/v1/expense-groups/{gid}/expenses", json=DINNER, headers=h(DARIO))
        assert e.status_code == 201, e.text
        eid = e.json()["expense_id"]
        # "El secreto me lo pedí yo".
        claim = await c.put(
            f"/v1/expense-groups/{gid}/expenses/{eid}/items/1/claim", json={"claimed": True}, headers=h(DARIO)
        )
        assert claim.json()["items"][1]["claimed_by"] == [1]
        assert sum(s["amount_minor"] for s in claim.json()["shares"]) == 8600

        view = (await c.get(f"/v1/expense-groups/{gid}", headers=h(MARTA))).json()
        assert view["my_seat"] == 3 and [m["name"] for m in view["members"]] == ["Darío", "Álex", "Marta"]
        assert "user_id" not in str(view)
        assert sum(b["balance_minor"] for b in view["balances"]) == 0
        assert all(t["to_seat"] == 2 for t in view["transfers"])

        # Marta salda lo suyo con Álex.
        owed = next(t["amount_minor"] for t in view["transfers"] if t["from_seat"] == 3)
        paid = await c.post(
            f"/v1/expense-groups/{gid}/payments", json={"to_seat": 2, "amount_minor": owed}, headers=h(MARTA)
        )
        assert paid.status_code == 201
        listed = (await c.get("/v1/expense-groups", headers=h(MARTA))).json()["items"]
        assert listed[0]["my_balance_minor"] == 0 and listed[0]["total_minor"] == 8600

        # Marta no lo apuntó ni lo pagó: no puede borrarlo. Álex (pagó) sí.
        assert (
            await c.delete(f"/v1/expense-groups/{gid}/expenses/{eid}", headers=h(MARTA))
        ).status_code == 403
        assert (
            await c.delete(f"/v1/expense-groups/{gid}/expenses/{eid}", headers=h(ALEX))
        ).status_code == 204


async def test_bad_input() -> None:
    store = MemoryExpenses()
    async with client(store) as c:
        gid = (
            await c.post(
                "/v1/expense-groups", json={"title": "X", "currency": "EUR", "my_name": "D"}, headers=h(DARIO)
            )
        ).json()["group_id"]
        bad = await c.post(f"/v1/expense-groups/{gid}/expenses", json=DINNER, headers=h(DARIO))
        assert bad.status_code == 400  # Álex (asiento 2) no está en el bote
        assert (
            await c.post(
                f"/v1/expense-groups/{gid}/expenses",
                json={**DINNER, "payer_seat": 1, "participants": [1], "items": [], "amount_minor": 0},
                headers=h(DARIO),
            )
        ).status_code == 400
        assert (
            await c.post("/v1/expense-groups/join", json={"code": "nope", "my_name": "A"}, headers=h(ALEX))
        ).status_code == 404
        assert (
            await c.post(
                f"/v1/expense-groups/{gid}/payments", json={"to_seat": 1, "amount_minor": 5}, headers=h(DARIO)
            )
        ).status_code == 400
        assert (await c.get("/v1/expense-groups")).status_code == 401
