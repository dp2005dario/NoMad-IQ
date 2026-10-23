"""Los botes de gastos en PostgreSQL (ver migrations/0008_expenses.sql).

Reglas que se comprueban aquí, dentro de la transacción (con FOR UPDATE
cuando dos personas pueden tocar lo mismo a la vez):
    - Solo los miembros de un bote lo ven. A quien no lo es, "no existe".
    - Como mucho 20 personas por bote y 1.000 gastos.
    - Un gasto lo borra quien lo apuntó o quien lo pagó.
    - "Me lo pedí yo" en una línea del ticket solo lo marca cada uno para sí.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Protocol

import asyncpg

from ai_orchestrator.expenses.domain import (
    MAX_EXPENSES,
    MAX_MEMBERS,
    Expense,
    Item,
    Payment,
    Split,
    check_expense,
)
from ai_orchestrator.negotiation.store import new_invite_code
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)
_INVITE_ATTEMPTS = 5


class GroupNotFoundError(Exception):
    """No existe, o no eres miembro (para fuera es lo mismo)."""


class GroupFullError(Exception):
    pass


class ExpenseNotFoundError(Exception):
    pass


class NotAllowedError(Exception):
    """No puedes hacer eso con este gasto (no lo apuntaste ni lo pagaste)."""


class TooManyExpensesError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class Member:
    seat: int
    user_id: str
    name: str


@dataclass(frozen=True, slots=True)
class ExpenseRecord:
    expense_id: str
    title: str
    amount_minor: int
    payer_seat: int
    split: Split
    participants: tuple[int, ...]
    items: tuple[Item, ...]
    spent_on: date
    created_by: int
    created_at: datetime
    original_minor: int | None = None
    original_currency: str | None = None

    def as_expense(self) -> Expense:
        return Expense(
            amount_minor=self.amount_minor,
            payer_seat=self.payer_seat,
            split=self.split,
            participants=self.participants,
            items=self.items,
        )


@dataclass(frozen=True, slots=True)
class PaymentRecord:
    payment_id: str
    from_seat: int
    to_seat: int
    amount_minor: int
    created_at: datetime

    def as_payment(self) -> Payment:
        return Payment(self.from_seat, self.to_seat, self.amount_minor)


@dataclass(frozen=True, slots=True)
class GroupRecord:
    group_id: str
    title: str
    currency: str
    invite_code: str
    created_at: datetime
    members: tuple[Member, ...]
    expenses: tuple[ExpenseRecord, ...] = ()
    payments: tuple[PaymentRecord, ...] = ()

    def seat_of(self, user_id: str) -> int | None:
        return next((m.seat for m in self.members if m.user_id == user_id), None)


@dataclass(frozen=True, slots=True)
class NewExpense:
    title: str
    amount_minor: int
    payer_seat: int
    split: Split
    participants: tuple[int, ...]
    spent_on: date
    items: tuple[Item, ...] = field(default=())
    original_minor: int | None = None
    original_currency: str | None = None


class ExpenseStore(Protocol):
    async def create(self, user_id: str, name: str, title: str, currency: str) -> GroupRecord: ...

    async def join(self, code: str, user_id: str, name: str) -> GroupRecord: ...

    async def list_for_member(self, user_id: str, *, limit: int) -> list[GroupRecord]: ...

    async def get_for_member(self, group_id: str, user_id: str) -> GroupRecord | None: ...

    async def add_expense(self, group_id: str, user_id: str, new: NewExpense) -> ExpenseRecord: ...

    async def claim(
        self, group_id: str, expense_id: str, user_id: str, index: int, claimed: bool
    ) -> ExpenseRecord: ...

    async def delete_expense(self, group_id: str, expense_id: str, user_id: str) -> None: ...

    async def add_payment(
        self, group_id: str, user_id: str, to_seat: int, amount_minor: int
    ) -> PaymentRecord: ...


class PostgresExpenses:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def create(self, user_id: str, name: str, title: str, currency: str) -> GroupRecord:
        for attempt in range(1, _INVITE_ATTEMPTS + 1):
            group_id = str(uuid.uuid4())
            try:
                async with self._pool.acquire() as conn, conn.transaction():
                    await conn.execute(
                        "INSERT INTO ai.expense_groups (group_id, title, currency, invite_code) "
                        "VALUES ($1::uuid, $2, $3, $4)",
                        group_id,
                        title,
                        currency,
                        new_invite_code(),
                    )
                    await conn.execute(
                        "INSERT INTO ai.expense_members (group_id, seat, user_id, display_name) "
                        "VALUES ($1::uuid, 1, $2, $3)",
                        group_id,
                        user_id,
                        name,
                    )
                    record = await self._load(conn, group_id)
            except asyncpg.UniqueViolationError as exc:
                # Solo puede chocar el código de invitación: se prueba otro.
                if attempt == _INVITE_ATTEMPTS:
                    raise StoreError(f"crear bote: código repetido: {exc}") from exc
                continue
            except _DB_ERRORS as exc:
                raise StoreError(f"crear bote: {exc}") from exc
            assert record is not None  # noqa: S101
            return record
        raise AssertionError("inalcanzable")  # pragma: no cover

    async def join(self, code: str, user_id: str, name: str) -> GroupRecord:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                row = await conn.fetchrow(
                    "SELECT group_id FROM ai.expense_groups WHERE invite_code = $1 FOR UPDATE", code
                )
                if row is None:
                    raise GroupNotFoundError(code)
                group_id = str(row["group_id"])
                seats = await conn.fetch(
                    "SELECT seat, user_id FROM ai.expense_members WHERE group_id = $1::uuid", group_id
                )
                if all(s["user_id"] != user_id for s in seats):
                    if len(seats) >= MAX_MEMBERS:
                        raise GroupFullError(group_id)
                    await conn.execute(
                        "INSERT INTO ai.expense_members (group_id, seat, user_id, display_name) "
                        "VALUES ($1::uuid, $2, $3, $4)",
                        group_id,
                        max(s["seat"] for s in seats) + 1,
                        user_id,
                        name,
                    )
                record = await self._load(conn, group_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"entrar en el bote: {exc}") from exc
        assert record is not None  # noqa: S101
        return record

    async def list_for_member(self, user_id: str, *, limit: int) -> list[GroupRecord]:
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    "SELECT g.group_id FROM ai.expense_groups g "
                    "JOIN ai.expense_members m ON m.group_id = g.group_id "
                    "WHERE m.user_id = $1 ORDER BY g.updated_at DESC LIMIT $2",
                    user_id,
                    limit,
                )
                out = [await self._load(conn, str(r["group_id"])) for r in rows]
        except _DB_ERRORS as exc:
            raise StoreError(f"listar botes: {exc}") from exc
        return [g for g in out if g is not None]

    async def get_for_member(self, group_id: str, user_id: str) -> GroupRecord | None:
        try:
            async with self._pool.acquire() as conn:
                record = await self._load(conn, group_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"leer bote: {exc}") from exc
        if record is None or record.seat_of(user_id) is None:
            return None
        return record

    async def add_expense(self, group_id: str, user_id: str, new: NewExpense) -> ExpenseRecord:
        expense_id = str(uuid.uuid4())
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seats = await self._lock_seats(conn, group_id, user_id)
                me = seats[user_id]
                check_expense(
                    Expense(new.amount_minor, new.payer_seat, new.split, new.participants, new.items),
                    list(seats.values()),
                )
                count = await conn.fetchval(
                    "SELECT count(*) FROM ai.expenses WHERE group_id = $1::uuid", group_id
                )
                if count >= MAX_EXPENSES:
                    raise TooManyExpensesError(group_id)
                await conn.execute(
                    """
                    INSERT INTO ai.expenses
                        (expense_id, group_id, title, amount_minor, payer_seat, split, participants,
                         original_minor, original_currency, spent_on, created_by)
                    VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7::smallint[], $8, $9, $10, $11)
                    """,
                    expense_id,
                    group_id,
                    new.title,
                    new.amount_minor,
                    new.payer_seat,
                    new.split,
                    list(new.participants),
                    new.original_minor,
                    new.original_currency,
                    new.spent_on,
                    me,
                )
                await conn.executemany(
                    "INSERT INTO ai.expense_items (expense_id, idx, name, qty, price_minor, claimed_by) "
                    "VALUES ($1::uuid, $2, $3, $4, $5, $6::smallint[])",
                    [
                        (expense_id, i, it.name, it.qty, it.price_minor, list(it.claimed_by))
                        for i, it in enumerate(new.items)
                    ],
                )
                await self._touch(conn, group_id)
                found = await self._expenses(conn, group_id, expense_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"apuntar gasto: {exc}") from exc
        return found[0]

    async def claim(
        self, group_id: str, expense_id: str, user_id: str, index: int, claimed: bool
    ) -> ExpenseRecord:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seats = await self._lock_seats(conn, group_id, user_id)
                me = seats[user_id]
                row = await conn.fetchrow(
                    "SELECT participants FROM ai.expenses "
                    "WHERE expense_id = $1::uuid AND group_id = $2::uuid FOR UPDATE",
                    expense_id,
                    group_id,
                )
                if row is None:
                    raise ExpenseNotFoundError(expense_id)
                if me not in row["participants"]:
                    raise NotAllowedError("no participas en este gasto")
                sql = (
                    "UPDATE ai.expense_items SET claimed_by = array_append(array_remove(claimed_by, $3), $3) "
                    if claimed
                    else "UPDATE ai.expense_items SET claimed_by = array_remove(claimed_by, $3) "
                )
                done = await conn.execute(
                    sql + "WHERE expense_id = $1::uuid AND idx = $2", expense_id, index, me
                )
                if done.endswith(" 0"):
                    raise ExpenseNotFoundError(f"{expense_id}#{index}")
                await self._touch(conn, group_id)
                found = await self._expenses(conn, group_id, expense_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"marcar línea: {exc}") from exc
        return found[0]

    async def delete_expense(self, group_id: str, expense_id: str, user_id: str) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seats = await self._lock_seats(conn, group_id, user_id)
                me = seats[user_id]
                row = await conn.fetchrow(
                    "SELECT created_by, payer_seat FROM ai.expenses "
                    "WHERE expense_id = $1::uuid AND group_id = $2::uuid FOR UPDATE",
                    expense_id,
                    group_id,
                )
                if row is None:
                    raise ExpenseNotFoundError(expense_id)
                if me not in (row["created_by"], row["payer_seat"]):
                    raise NotAllowedError("solo quien lo apuntó o quien lo pagó puede borrarlo")
                await conn.execute("DELETE FROM ai.expenses WHERE expense_id = $1::uuid", expense_id)
                await self._touch(conn, group_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"borrar gasto: {exc}") from exc

    async def add_payment(
        self, group_id: str, user_id: str, to_seat: int, amount_minor: int
    ) -> PaymentRecord:
        payment_id = str(uuid.uuid4())
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seats = await self._lock_seats(conn, group_id, user_id)
                me = seats[user_id]
                if to_seat not in seats.values() or to_seat == me:
                    raise ValueError("a quién pagas no está en el bote")
                created_at = await conn.fetchval(
                    "INSERT INTO ai.expense_payments "
                    "(payment_id, group_id, from_seat, to_seat, amount_minor) "
                    "VALUES ($1::uuid, $2::uuid, $3, $4, $5) RETURNING created_at",
                    payment_id,
                    group_id,
                    me,
                    to_seat,
                    amount_minor,
                )
                await self._touch(conn, group_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"apuntar pago: {exc}") from exc
        return PaymentRecord(payment_id, me, to_seat, amount_minor, created_at)

    # --- Ayudantes ---------------------------------------------------------------------

    async def _lock_seats(self, conn: Conn, group_id: str, user_id: str) -> dict[str, int]:
        """user_id -> asiento, bloqueando el bote (los cambios van en fila)."""
        exists = await conn.fetchval(
            "SELECT 1 FROM ai.expense_groups WHERE group_id = $1::uuid FOR UPDATE", group_id
        )
        rows = await conn.fetch(
            "SELECT user_id, seat FROM ai.expense_members WHERE group_id = $1::uuid", group_id
        )
        seats = {r["user_id"]: r["seat"] for r in rows}
        if exists is None or user_id not in seats:
            raise GroupNotFoundError(group_id)
        return seats

    @staticmethod
    async def _touch(conn: Conn, group_id: str) -> None:
        await conn.execute(
            "UPDATE ai.expense_groups SET updated_at = now() WHERE group_id = $1::uuid", group_id
        )

    async def _load(self, conn: Conn, group_id: str) -> GroupRecord | None:
        row = await conn.fetchrow(
            "SELECT group_id, title, currency, invite_code, created_at FROM ai.expense_groups "
            "WHERE group_id = $1::uuid",
            group_id,
        )
        if row is None:
            return None
        members = await conn.fetch(
            "SELECT seat, user_id, display_name FROM ai.expense_members "
            "WHERE group_id = $1::uuid ORDER BY seat",
            group_id,
        )
        payments = await conn.fetch(
            "SELECT payment_id, from_seat, to_seat, amount_minor, created_at FROM ai.expense_payments "
            "WHERE group_id = $1::uuid ORDER BY created_at DESC",
            group_id,
        )
        return GroupRecord(
            group_id=str(row["group_id"]),
            title=row["title"],
            currency=row["currency"],
            invite_code=row["invite_code"],
            created_at=row["created_at"],
            members=tuple(Member(m["seat"], m["user_id"], m["display_name"]) for m in members),
            expenses=tuple(await self._expenses(conn, group_id)),
            payments=tuple(
                PaymentRecord(
                    str(p["payment_id"]), p["from_seat"], p["to_seat"], p["amount_minor"], p["created_at"]
                )
                for p in payments
            ),
        )

    async def _expenses(
        self, conn: Conn, group_id: str, expense_id: str | None = None
    ) -> list[ExpenseRecord]:
        rows = await conn.fetch(
            "SELECT expense_id, title, amount_minor, payer_seat, split, participants, original_minor, "
            "original_currency, spent_on, created_by, created_at FROM ai.expenses "
            "WHERE group_id = $1::uuid AND ($2::uuid IS NULL OR expense_id = $2::uuid) "
            "ORDER BY spent_on DESC, created_at DESC",
            group_id,
            expense_id,
        )
        ids = [r["expense_id"] for r in rows]
        items: dict[str, list[Item]] = {}
        if ids:
            for it in await conn.fetch(
                "SELECT expense_id, name, qty, price_minor, claimed_by FROM ai.expense_items "
                "WHERE expense_id = ANY($1::uuid[]) ORDER BY expense_id, idx",
                ids,
            ):
                items.setdefault(str(it["expense_id"]), []).append(
                    Item(it["name"], it["qty"], it["price_minor"], tuple(it["claimed_by"]))
                )
        return [_expense(r, tuple(items.get(str(r["expense_id"]), ()))) for r in rows]


def _expense(r: asyncpg.Record, items: Sequence[Item]) -> ExpenseRecord:
    return ExpenseRecord(
        expense_id=str(r["expense_id"]),
        title=r["title"],
        amount_minor=r["amount_minor"],
        payer_seat=r["payer_seat"],
        split=r["split"],
        participants=tuple(r["participants"]),
        items=tuple(items),
        spent_on=r["spent_on"],
        created_by=r["created_by"],
        created_at=r["created_at"],
        original_minor=r["original_minor"],
        original_currency=r["original_currency"],
    )
