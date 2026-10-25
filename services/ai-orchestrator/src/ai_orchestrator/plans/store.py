"""Los planes del grupo en PostgreSQL (ver migrations/0012_group_plans.sql).

Reglas que se comprueban aquí, dentro de la transacción:
    - Solo los miembros del viaje ven y votan sus planes. A quien no lo es,
      "no existe" (igual que en la negociación).
    - Topes: 60 planes por viaje y 15 por persona (con FOR UPDATE sobre el
      viaje, para que dos personas a la vez no se salten el tope).
    - Un plan solo lo borra quien lo propuso.
"""

from __future__ import annotations

import uuid
from typing import Protocol

import asyncpg

from ai_orchestrator.erasure import ERASED_PREFIX
from ai_orchestrator.plans.domain import MAX_PLANS, MAX_PLANS_PER_MEMBER, Board, Plan, PlanLimitError
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class TripNotFoundError(Exception):
    """No existe, o no eres miembro (para fuera es lo mismo)."""


class PlanNotFoundError(Exception):
    pass


class NewPlan(Protocol):
    """Un plan nuevo (en la API es NewPlanBody, ya validado)."""

    @property
    def title(self) -> str: ...

    @property
    def note(self) -> str | None: ...

    @property
    def wikidata_id(self) -> str | None: ...

    @property
    def photo_url(self) -> str | None: ...

    @property
    def article_url(self) -> str | None: ...


class PlanStore(Protocol):
    async def board(self, negotiation_id: str, user_id: str) -> Board: ...

    async def add(self, negotiation_id: str, user_id: str, plans: list[NewPlan]) -> Board: ...

    async def vote(self, negotiation_id: str, user_id: str, plan_id: str, *, yes: bool) -> Board: ...

    async def delete(self, negotiation_id: str, user_id: str, plan_id: str) -> Board: ...


class PostgresPlans:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def _seat(self, conn: Conn, negotiation_id: str, user_id: str, *, lock: bool = False) -> int:
        if lock:
            # El candado es sobre el viaje: así los topes se cuentan bien.
            await conn.execute(
                "SELECT 1 FROM ai.group_negotiations WHERE negotiation_id = $1::uuid FOR UPDATE",
                negotiation_id,
            )
        seat = await conn.fetchval(
            "SELECT seat FROM ai.group_negotiation_members WHERE negotiation_id = $1::uuid AND user_id = $2",
            negotiation_id,
            user_id,
        )
        if seat is None:
            raise TripNotFoundError(negotiation_id)
        return int(seat)

    async def _board(self, conn: Conn, negotiation_id: str, seat: int) -> Board:
        seats = await conn.fetch(
            "SELECT seat FROM ai.group_negotiation_members"
            " WHERE negotiation_id = $1::uuid AND user_id NOT LIKE $2",
            negotiation_id,
            ERASED_PREFIX + "%",
        )
        rows = await conn.fetch(
            "SELECT plan_id, added_by_seat, title, note, wikidata_id, photo_url, article_url, created_at"
            " FROM ai.group_plans WHERE negotiation_id = $1::uuid ORDER BY created_at, plan_id",
            negotiation_id,
        )
        votes = await conn.fetch(
            "SELECT v.plan_id, v.seat, v.yes FROM ai.group_plan_votes v"
            " JOIN ai.group_plans p ON p.plan_id = v.plan_id WHERE p.negotiation_id = $1::uuid",
            negotiation_id,
        )
        by_plan: dict[str, dict[int, bool]] = {}
        for v in votes:
            by_plan.setdefault(str(v["plan_id"]), {})[int(v["seat"])] = bool(v["yes"])
        return Board(
            negotiation_id=negotiation_id,
            my_seat=seat,
            active_seats=frozenset(int(s["seat"]) for s in seats),
            plans=tuple(
                Plan(
                    plan_id=str(r["plan_id"]),
                    added_by_seat=r["added_by_seat"],
                    title=r["title"],
                    note=r["note"],
                    wikidata_id=r["wikidata_id"],
                    photo_url=r["photo_url"],
                    article_url=r["article_url"],
                    created_at=r["created_at"],
                    votes=by_plan.get(str(r["plan_id"]), {}),
                )
                for r in rows
            ),
        )

    async def board(self, negotiation_id: str, user_id: str) -> Board:
        try:
            async with self._pool.acquire() as conn:
                seat = await self._seat(conn, negotiation_id, user_id)
                return await self._board(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"leer planes: {exc}") from exc

    async def add(self, negotiation_id: str, user_id: str, plans: list[NewPlan]) -> Board:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id, lock=True)
                counts = await conn.fetchrow(
                    "SELECT count(*) AS total, count(*) FILTER (WHERE added_by_seat = $2) AS mine"
                    " FROM ai.group_plans WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                    seat,
                )
                total = int(counts["total"]) if counts else 0
                mine = int(counts["mine"]) if counts else 0
                known = {
                    r["wikidata_id"]
                    for r in await conn.fetch(
                        "SELECT wikidata_id FROM ai.group_plans"
                        " WHERE negotiation_id = $1::uuid AND wikidata_id IS NOT NULL",
                        negotiation_id,
                    )
                }
                # Una atracción que ya está en el viaje no se repite (no es error).
                fresh = [p for p in plans if p.wikidata_id is None or p.wikidata_id not in known]
                if total + len(fresh) > MAX_PLANS or mine + len(fresh) > MAX_PLANS_PER_MEMBER:
                    raise PlanLimitError(negotiation_id)
                for p in fresh:
                    await conn.execute(
                        "INSERT INTO ai.group_plans (plan_id, negotiation_id, added_by_seat, title, note,"
                        " wikidata_id, photo_url, article_url)"
                        " VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8)",
                        str(uuid.uuid4()),
                        negotiation_id,
                        seat,
                        p.title,
                        p.note,
                        p.wikidata_id,
                        p.photo_url,
                        p.article_url,
                    )
                return await self._board(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"añadir planes: {exc}") from exc

    async def vote(self, negotiation_id: str, user_id: str, plan_id: str, *, yes: bool) -> Board:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                found = await conn.fetchval(
                    "SELECT 1 FROM ai.group_plans WHERE plan_id = $1::uuid AND negotiation_id = $2::uuid",
                    plan_id,
                    negotiation_id,
                )
                if found is None:
                    raise PlanNotFoundError(plan_id)
                # Votar otra vez cambia el voto (te arrepientes: sin problema).
                await conn.execute(
                    "INSERT INTO ai.group_plan_votes (plan_id, seat, yes) VALUES ($1::uuid, $2, $3)"
                    " ON CONFLICT (plan_id, seat) DO UPDATE SET yes = EXCLUDED.yes, voted_at = now()",
                    plan_id,
                    seat,
                    yes,
                )
                return await self._board(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"votar plan: {exc}") from exc

    async def delete(self, negotiation_id: str, user_id: str, plan_id: str) -> Board:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                deleted = await conn.execute(
                    "DELETE FROM ai.group_plans"
                    " WHERE plan_id = $1::uuid AND negotiation_id = $2::uuid AND added_by_seat = $3",
                    plan_id,
                    negotiation_id,
                    seat,
                )
                if deleted.endswith(" 0"):
                    raise PlanNotFoundError(plan_id)
                return await self._board(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"borrar plan: {exc}") from exc
