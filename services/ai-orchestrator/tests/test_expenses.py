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
    kitty,
    settle,
    shares,
    with_extras,
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
    Rework,
)

NOW = datetime(2026, 10, 23, 20, 0, tzinfo=UTC)
DARIO = "11111111-1111-4111-8111-111111111111"
ALEX = "22222222-2222-4222-8222-222222222222"
MARTA = "33333333-3333-4333-8333-333333333333"
STRANGER = "44444444-4444-4444-8444-444444444444"
ANA = MARTA
BASE = "/v1/expense-groups"

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


def test_extras_of_the_ticket() -> None:
    # El ejemplo de la maqueta: 86 + 6 de pan - 5 de descuento, 10 % de propina.
    assert with_extras(8600, 600, 500, 10) == (9570, 870)
    assert with_extras(8600, 0, 0, 0) == (8600, 0)
    assert with_extras(8600, 0, 0, 5) == (9030, 430)
    with pytest.raises(ValueError):
        with_extras(8600, 0, 0, 15)
    with pytest.raises(ValueError):
        with_extras(500, 0, 600, 0)


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
        # Viajes en grupo: quién va en cada uno y su bote.
        self.trips: dict[str, tuple[str, ...]] = {}
        self.trip_groups: dict[str, str] = {}

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

    async def for_trip(self, negotiation_id: str, user_id: str) -> GroupRecord:
        if user_id not in self.trips.get(negotiation_id, ()):
            raise GroupNotFoundError(negotiation_id)
        gid = self.trip_groups.get(negotiation_id)
        if gid is None:
            g = await self.create(user_id, user_id.title(), "Viaje", "EUR")
            self.trip_groups[negotiation_id] = g.group_id
            return g
        return await self.join(self.groups[gid].invite_code, user_id, user_id.title())

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
            Expense(new.amount_minor, new.payer_seat, new.split, new.participants, new.items, new.weights),
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
            new.weights,
            new.cover_minor,
            new.discount_minor,
            new.tip_pct,
            new.tip_minor,
        )
        self.groups[group_id] = replace(g, expenses=(rec, *g.expenses))
        return rec

    async def rework(self, group_id: str, expense_id: str, user_id: str, change: Rework) -> ExpenseRecord:
        g = self._find(group_id, user_id)
        me = g.seat_of(user_id) or 0
        e = next((e for e in g.expenses if e.expense_id == expense_id), None)
        if e is None:
            raise ExpenseNotFoundError(expense_id)
        if me not in e.participants:
            raise NotAllowedError("no participas")
        if change.owners is not None and len(change.owners) != len(e.items):
            raise ValueError("hace falta quién tomó cada línea")
        amount, tip = with_extras(e.ticket_minor, change.cover_minor, change.discount_minor, change.tip_pct)
        items = e.items
        if change.owners is not None:
            items = tuple(
                replace(i, claimed_by=tuple(dict.fromkeys(o)))
                for i, o in zip(e.items, change.owners, strict=True)
            )
        check_expense(
            Expense(amount, e.payer_seat, change.split, e.participants, items), [m.seat for m in g.members]
        )
        new = replace(
            e,
            split=change.split,
            amount_minor=amount,
            items=items,
            weights=(),
            cover_minor=change.cover_minor,
            discount_minor=change.discount_minor,
            tip_pct=change.tip_pct,
            tip_minor=tip,
        )
        self.groups[group_id] = replace(g, expenses=tuple(new if x is e else x for x in g.expenses))
        return new

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
        self, group_id: str, user_id: str, to_seat: int, amount_minor: int, *, from_kitty: bool = False
    ) -> PaymentRecord:
        g = self._find(group_id, user_id)
        me = g.seat_of(user_id) or 0
        payer = 0 if from_kitty else me
        if from_kitty:
            to_seat = me
        elif to_seat == me or (to_seat != 0 and to_seat not in [m.seat for m in g.members]):
            raise ValueError("a quién pagas no está en el bote")
        p = PaymentRecord(str(uuid.uuid4()), payer, to_seat, amount_minor, NOW)
        self.groups[group_id] = replace(g, payments=(p, *g.payments))
        return p

    async def set_kitty_ask(self, group_id: str, user_id: str, ask_minor: int | None) -> None:
        g = self._find(group_id, user_id)
        self.groups[group_id] = replace(g, kitty_ask_minor=ask_minor)

    async def set_default_weights(self, group_id: str, user_id: str, weights: dict[int, int]) -> None:
        g = self._find(group_id, user_id)
        if any(s not in [m.seat for m in g.members] for s in weights):
            raise ValueError("pesos de asientos que no están en el bote")
        self.groups[group_id] = replace(g, default_weights=tuple(sorted(weights.items())))


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

        tipped = await c.post(
            f"/v1/expense-groups/{gid}/expenses",
            json={**DINNER, "tip_pct": 10, "discount_minor": 500},
            headers=h(DARIO),
        )
        # El ticket dice 86,00 (ya con el descuento): con la propina, 94,60.
        assert (tipped.json()["amount_minor"], tipped.json()["tip_minor"]) == (9460, 860)
        await c.delete(f"/v1/expense-groups/{gid}/expenses/{tipped.json()['expense_id']}", headers=h(DARIO))

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

        # "Repartir" desde la pantalla del gasto (maqueta 8): Marta (no lo
        # pagó) pone quién tomó cada línea, el pan, un descuento y un 10 %.
        rw = await c.put(
            f"/v1/expense-groups/{gid}/expenses/{eid}/split",
            json={
                "split": "items",
                "owners": [[1, 2, 3], [1], [2]],
                "cover_minor": 600,
                "discount_minor": 500,
                "tip_pct": 10,
            },
            headers=h(MARTA),
        )
        assert rw.status_code == 200, rw.text
        body = rw.json()
        # Ticket 86,00 + 6 de pan - 5 de descuento = 87,00; +10 % = 8,70 → 95,70.
        assert (body["tip_minor"], body["amount_minor"]) == (870, 9570)
        assert [i["claimed_by"] for i in body["items"]] == [[1, 2, 3], [1], [2]]
        assert sum(s["amount_minor"] for s in body["shares"]) == 9570
        # Volver a "a partes iguales" y sin extras: vuelve el ticket solo.
        back = await c.put(
            f"/v1/expense-groups/{gid}/expenses/{eid}/split", json={"split": "equal"}, headers=h(DARIO)
        )
        assert back.json()["amount_minor"] == 8600 and back.json()["split"] == "equal"
        # Las líneas tienen que ir todas, y nadie de fuera.
        bad = await c.put(
            f"/v1/expense-groups/{gid}/expenses/{eid}/split",
            json={"split": "items", "owners": [[1]]},
            headers=h(DARIO),
        )
        assert bad.status_code == 400
        assert (
            await c.put(
                f"/v1/expense-groups/{gid}/expenses/{eid}/split", json={"split": "equal"}, headers=h(STRANGER)
            )
        ).status_code == 404

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


def test_weights_and_kitty_domain() -> None:
    # Modo pareja "según sueldo": 60 % y 40 %.
    couple = Expense(10001, 1, "weights", (1, 2), weights=(60, 40))
    assert shares(couple) == {1: 6001, 2: 4000}
    with pytest.raises(ValueError):
        check_expense(Expense(100, 1, "weights", (1, 2), weights=(60,)), [1, 2])
    with pytest.raises(ValueError):
        check_expense(Expense(100, 1, "equal", (1, 2), weights=(1, 1)), [1, 2])
    # Bote común: cada uno pone 100 y el bote paga una cena de 150 entre 3.
    pays = [Payment(s, 0, 10000) for s in (1, 2, 3)]
    dinner = Expense(15000, 0, "equal", (1, 2, 3))
    check_expense(dinner, [1, 2, 3])
    put, spent = kitty([dinner], pays)
    assert put == {1: 10000, 2: 10000, 3: 10000} and spent == 15000
    bal = balances((1, 2, 3), [dinner], pays)
    assert bal[0] == -15000  # quedan 150 en la hucha
    assert bal[1] == bal[2] == bal[3] == 5000
    # Al cerrar, el bote devuelve a cada uno lo suyo.
    assert sorted((t.from_seat, t.to_seat, t.amount_minor) for t in settle(bal)) == [
        (0, 1, 5000),
        (0, 2, 5000),
        (0, 3, 5000),
    ]


async def test_kitty_and_couple_api() -> None:
    store = MemoryExpenses()
    async with client(store) as c:
        gid = (
            await c.post(BASE, json={"title": "Lisboa", "currency": "EUR", "my_name": "Ana"}, headers=h(ANA))
        ).json()["group_id"]
        await c.post(f"{BASE}/join", json={"code": "7K2M9QXD", "my_name": "Darío"}, headers=h(DARIO))
        assert (await c.get(f"{BASE}/{gid}", headers=h(ANA))).json()["kitty"] is None
        assert (
            await c.put(f"{BASE}/{gid}/kitty", json={"ask_minor": 10000}, headers=h(ANA))
        ).status_code == 204
        for who in (ANA, DARIO):
            ok = await c.post(f"{BASE}/{gid}/payments", json={"amount_minor": 10000}, headers=h(who))
            assert ok.status_code == 201 and ok.json()["to_seat"] == 0
        spend = {**DINNER, "payer_seat": 0, "participants": [1, 2], "split": "equal", "items": []}
        assert (await c.post(f"{BASE}/{gid}/expenses", json=spend, headers=h(DARIO))).status_code == 201
        view = (await c.get(f"{BASE}/{gid}", headers=h(ANA))).json()
        assert view["kitty"]["left_minor"] == 20000 - 8600
        assert view["kitty"]["ask_minor"] == 10000
        assert [b["seat"] for b in view["balances"]] == [1, 2]
        # El bote me devuelve lo que sobra.
        back = await c.post(
            f"{BASE}/{gid}/payments", json={"amount_minor": 5700, "from_kitty": True}, headers=h(ANA)
        )
        assert back.json()["from_seat"] == 0 and back.json()["to_seat"] == 1
        # Modo pareja: reparto habitual 60/40 y un gasto con pesos.
        w = {"weights": [{"seat": 1, "weight": 60}, {"seat": 2, "weight": 40}]}
        assert (await c.put(f"{BASE}/{gid}/weights", json=w, headers=h(ANA))).status_code == 204
        couple = {**spend, "payer_seat": 1, "split": "weights", "weights": [60, 40], "amount_minor": 10000}
        made = (await c.post(f"{BASE}/{gid}/expenses", json=couple, headers=h(ANA))).json()
        assert made["shares"] == [{"seat": 1, "amount_minor": 6000}, {"seat": 2, "amount_minor": 4000}]
        view = (await c.get(f"{BASE}/{gid}", headers=h(DARIO))).json()
        assert view["default_weights"] == [{"seat": 1, "weight": 60}, {"seat": 2, "weight": 40}]
        bad = {**couple, "weights": [60]}
        assert (await c.post(f"{BASE}/{gid}/expenses", json=bad, headers=h(ANA))).status_code == 400


async def test_trip_group_api() -> None:
    """Grupo: POST /trip da el bote del viaje (el mismo para todos los del viaje)."""
    store = MemoryExpenses()
    trip = str(uuid.uuid4())
    store.trips[trip] = ("ana", "beto")
    async with client(store) as c:
        ana = await c.post("/v1/expense-groups/trip", json={"trip_id": trip}, headers=h("ana"))
        assert ana.status_code == 200
        beto = await c.post("/v1/expense-groups/trip", json={"trip_id": trip}, headers=h("beto"))
        assert beto.json()["group_id"] == ana.json()["group_id"]
        assert len(beto.json()["members"]) == 2
        # Quien no va en el viaje: 404. Un id que no es uuid: 400.
        out = await c.post("/v1/expense-groups/trip", json={"trip_id": trip}, headers=h("eve"))
        assert out.status_code == 404
        bad = await c.post("/v1/expense-groups/trip", json={"trip_id": "x"}, headers=h("ana"))
        assert bad.status_code == 400
