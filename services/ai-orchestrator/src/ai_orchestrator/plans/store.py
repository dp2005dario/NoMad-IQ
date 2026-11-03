"""Los planes del grupo en PostgreSQL (ver migrations/0012_group_plans.sql).

Reglas que se comprueban aquí, dentro de la transacción:
    - Solo los miembros del viaje ven y votan sus planes. A quien no lo es,
      "no existe" (igual que en la negociación).
    - Topes: 60 planes por viaje y 15 por persona; aparte, 40 sitios o zonas
      ("crave"/"sleep") por viaje (con FOR UPDATE sobre el
      viaje, para que dos personas a la vez no se salten el tope).
    - Un plan solo lo borra quien lo propuso.
"""

from __future__ import annotations

import uuid
from typing import Protocol

import asyncpg

from ai_orchestrator.erasure import ERASED_PREFIX
from ai_orchestrator.plans.domain import (
    MAX_EXTRAS,
    MAX_PLANS,
    MAX_PLANS_PER_MEMBER,
    Board,
    NotMatchError,
    Plan,
    PlanLimitError,
    is_match,
)
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
    @property
    def kind(self) -> str: ...


class PlanStore(Protocol):
    async def board(self, negotiation_id: str, user_id: str) -> Board: ...

    async def add(self, negotiation_id: str, user_id: str, plans: list[NewPlan]) -> Board: ...

    async def vote(self, negotiation_id: str, user_id: str, plan_id: str, *, yes: bool) -> Board: ...

    async def plan(self, negotiation_id: str, user_id: str, plan_id: str) -> Board: ...

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
            "SELECT seat, coalesce(display_name, alias) AS name FROM ai.group_negotiation_members"
            " WHERE negotiation_id = $1::uuid AND user_id NOT LIKE $2",
            negotiation_id,
            ERASED_PREFIX + "%",
        )
        rows = await conn.fetch(
            "SELECT plan_id, added_by_seat, title, note, wikidata_id, photo_url, article_url, created_at,"
            " planned_at IS NOT NULL AS planned, kind"
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
            names={int(s["seat"]): str(s["name"]) for s in seats},
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
                    planned=bool(r["planned"]),
                    kind=str(r["kind"]),
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
                    "SELECT count(*) FILTER (WHERE kind = 'plan') AS total,"
                    " count(*) FILTER (WHERE kind = 'plan' AND added_by_seat = $2) AS mine,"
                    " count(*) FILTER (WHERE kind <> 'plan') AS extras"
                    " FROM ai.group_plans WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                    seat,
                )
                total = int(counts["total"]) if counts else 0
                mine = int(counts["mine"]) if counts else 0
                extras = int(counts["extras"]) if counts else 0
                rows = await conn.fetch(
                    "SELECT wikidata_id, kind, lower(title) AS title FROM ai.group_plans"
                    " WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                )
                known = {r["wikidata_id"] for r in rows if r["wikidata_id"] is not None}
                named = {(r["kind"], r["title"]) for r in rows if r["kind"] != "plan"}
                # Lo que ya está en el viaje no se repite (no es error): una
                # atracción por su Wikidata; un sitio o zona por su nombre.
                fresh: list[NewPlan] = []
                for p in plans:
                    if p.wikidata_id is not None and p.wikidata_id in known:
                        continue
                    if p.kind != "plan" and (p.kind, p.title.lower()) in named:
                        continue
                    if p.kind != "plan":
                        named.add((p.kind, p.title.lower()))
                    fresh.append(p)
                new_plans = sum(1 for p in fresh if p.kind == "plan")
                new_extras = len(fresh) - new_plans
                if (
                    total + new_plans > MAX_PLANS
                    or mine + new_plans > MAX_PLANS_PER_MEMBER
                    or extras + new_extras > MAX_EXTRAS
                ):
                    raise PlanLimitError(negotiation_id)
                for p in fresh:
                    await conn.execute(
                        # clock_timestamp() y no now(): now() es la MISMA hora para
                        # toda la transacción, y los planes añadidos de golpe
                        # saldrían en orden al azar. Así salen en el orden enviado.
                        "INSERT INTO ai.group_plans (plan_id, negotiation_id, added_by_seat, title, note,"
                        " wikidata_id, photo_url, article_url, created_at, kind)"
                        " VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, clock_timestamp(), $9)"
                        # Un sitio o zona que otro añadió justo a la vez: no se repite.
                        " ON CONFLICT DO NOTHING",
                        str(uuid.uuid4()),
                        negotiation_id,
                        seat,
                        p.title,
                        p.note,
                        p.wikidata_id,
                        p.photo_url,
                        p.article_url,
                        p.kind,
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

    async def plan(self, negotiation_id: str, user_id: str, plan_id: str) -> Board:
        """ "Añadir al plan": solo un match en el que tú dijiste que sí."""
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                board = await self._board(conn, negotiation_id, seat)
                found = next((p for p in board.plans if p.plan_id == plan_id), None)
                if found is None:
                    raise PlanNotFoundError(plan_id)
                if found.votes.get(seat) is not True or not is_match(found, board.active_seats):
                    raise NotMatchError(plan_id)
                await conn.execute(
                    "UPDATE ai.group_plans SET planned_at = coalesce(planned_at, now())"
                    " WHERE plan_id = $1::uuid AND negotiation_id = $2::uuid",
                    plan_id,
                    negotiation_id,
                )
                return await self._board(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"meter plan: {exc}") from exc

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
