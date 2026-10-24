"""Las ligas de cromos en PostgreSQL (ver migrations/0011_leagues.sql).

Reglas que se comprueban aquí, dentro de la transacción (con FOR UPDATE
sobre la liga cuando dos personas pueden tocar lo mismo a la vez):
    - Solo los miembros ven una liga. A quien no lo es, "no existe".
    - Como mucho 30 personas y 20 cambios pendientes por persona.
    - Un cambio solo lo acepta o rechaza quien lo recibe, y al aceptarlo se
      vuelve a comprobar (los cromos pueden haber cambiado desde entonces).
"""

from __future__ import annotations

import json
import uuid
from typing import Protocol

import asyncpg

from ai_orchestrator.leagues.domain import (
    MAX_MEMBERS,
    MAX_PENDING,
    MAX_SWAPS_KEPT,
    Card,
    League,
    Member,
    Swap,
    SwapNotAllowedError,
    SwapStatus,
    check_swap,
)
from ai_orchestrator.negotiation.store import new_invite_code
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)
_INVITE_ATTEMPTS = 5


class LeagueNotFoundError(Exception):
    """No existe, o no eres miembro (para fuera es lo mismo)."""


class LeagueFullError(Exception):
    pass


class SwapNotFoundError(Exception):
    pass


class TooManyPendingError(Exception):
    pass


class LeagueStore(Protocol):
    async def create(self, user_id: str, name: str, title: str) -> League: ...

    async def join(self, code: str, user_id: str, name: str) -> League: ...

    async def list_for_member(self, user_id: str) -> list[League]: ...

    async def get_for_member(self, league_id: str, user_id: str) -> League | None: ...

    async def update_me(self, league_id: str, user_id: str, cards: list[Card], countries: int) -> None: ...

    async def set_city(self, league_id: str, user_id: str, city: str | None) -> None: ...

    async def propose(
        self, league_id: str, user_id: str, to_seat: int, give_qid: str, want_qid: str
    ) -> Swap: ...

    async def decide(self, league_id: str, user_id: str, swap_id: str, *, accept: bool) -> Swap: ...

    async def leave(self, league_id: str, user_id: str) -> None: ...


def _cards(raw: object) -> tuple[Card, ...]:
    items = json.loads(raw) if isinstance(raw, str) else raw
    return tuple(Card.model_validate(c) for c in items) if isinstance(items, list) else ()


def _card(raw: object) -> Card:
    return Card.model_validate(json.loads(raw) if isinstance(raw, str) else raw)


class PostgresLeagues:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def _load(self, conn: Conn, league_id: str) -> League | None:
        row = await conn.fetchrow(
            "SELECT league_id, title, invite_code FROM ai.leagues WHERE league_id = $1::uuid", league_id
        )
        if row is None:
            return None
        members = await conn.fetch(
            "SELECT seat, user_id, display_name, cards, countries, city, city_at "
            "FROM ai.league_members WHERE league_id = $1::uuid ORDER BY seat",
            league_id,
        )
        swaps = await conn.fetch(
            "SELECT swap_id, from_seat, to_seat, give, want, status, created_at "
            "FROM ai.league_swaps WHERE league_id = $1::uuid ORDER BY created_at DESC LIMIT $2",
            league_id,
            MAX_SWAPS_KEPT,
        )
        return League(
            league_id=str(row["league_id"]),
            title=row["title"],
            invite_code=row["invite_code"],
            members=tuple(
                Member(
                    seat=m["seat"],
                    user_id=m["user_id"],
                    name=m["display_name"],
                    cards=_cards(m["cards"]),
                    countries=m["countries"],
                    city=m["city"],
                    city_at=m["city_at"],
                )
                for m in members
            ),
            swaps=tuple(
                Swap(
                    swap_id=str(s["swap_id"]),
                    from_seat=s["from_seat"],
                    to_seat=s["to_seat"],
                    give=_card(s["give"]),
                    want=_card(s["want"]),
                    status=s["status"],
                    created_at=s["created_at"],
                )
                for s in swaps
            ),
        )

    async def _locked(self, conn: Conn, league_id: str, user_id: str) -> League:
        """La liga con un candado (FOR UPDATE), comprobando que eres miembro."""
        found = await conn.fetchval(
            "SELECT 1 FROM ai.leagues WHERE league_id = $1::uuid FOR UPDATE", league_id
        )
        league = await self._load(conn, league_id) if found else None
        if league is None or league.member(user_id) is None:
            raise LeagueNotFoundError(league_id)
        return league

    async def create(self, user_id: str, name: str, title: str) -> League:
        for attempt in range(1, _INVITE_ATTEMPTS + 1):
            league_id = str(uuid.uuid4())
            try:
                async with self._pool.acquire() as conn, conn.transaction():
                    await conn.execute(
                        "INSERT INTO ai.leagues (league_id, title, invite_code) VALUES ($1::uuid, $2, $3)",
                        league_id,
                        title,
                        new_invite_code(),
                    )
                    await conn.execute(
                        "INSERT INTO ai.league_members (league_id, seat, user_id, display_name) "
                        "VALUES ($1::uuid, 1, $2, $3)",
                        league_id,
                        user_id,
                        name,
                    )
                    league = await self._load(conn, league_id)
            except asyncpg.UniqueViolationError as exc:
                if attempt == _INVITE_ATTEMPTS:
                    raise StoreError(f"crear liga: código repetido: {exc}") from exc
                continue
            except _DB_ERRORS as exc:
                raise StoreError(f"crear liga: {exc}") from exc
            assert league is not None  # noqa: S101
            return league
        raise AssertionError("inalcanzable")  # pragma: no cover

    async def join(self, code: str, user_id: str, name: str) -> League:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                row = await conn.fetchrow(
                    "SELECT league_id FROM ai.leagues WHERE invite_code = $1 FOR UPDATE", code
                )
                if row is None:
                    raise LeagueNotFoundError(code)
                league_id = str(row["league_id"])
                seats = await conn.fetch(
                    "SELECT seat, user_id FROM ai.league_members WHERE league_id = $1::uuid", league_id
                )
                if all(s["user_id"] != user_id for s in seats):
                    if len(seats) >= MAX_MEMBERS:
                        raise LeagueFullError(league_id)
                    await conn.execute(
                        "INSERT INTO ai.league_members (league_id, seat, user_id, display_name) "
                        "VALUES ($1::uuid, $2, $3, $4)",
                        league_id,
                        max((s["seat"] for s in seats), default=0) + 1,
                        user_id,
                        name,
                    )
                league = await self._load(conn, league_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"entrar en la liga: {exc}") from exc
        assert league is not None  # noqa: S101
        return league

    async def list_for_member(self, user_id: str) -> list[League]:
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    "SELECT l.league_id FROM ai.leagues l "
                    "JOIN ai.league_members m ON m.league_id = l.league_id "
                    "WHERE m.user_id = $1 ORDER BY l.updated_at DESC LIMIT 20",
                    user_id,
                )
                out = [await self._load(conn, str(r["league_id"])) for r in rows]
        except _DB_ERRORS as exc:
            raise StoreError(f"listar ligas: {exc}") from exc
        return [league for league in out if league is not None]

    async def get_for_member(self, league_id: str, user_id: str) -> League | None:
        try:
            async with self._pool.acquire() as conn:
                league = await self._load(conn, league_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"leer liga: {exc}") from exc
        if league is None or league.member(user_id) is None:
            return None
        return league

    async def update_me(self, league_id: str, user_id: str, cards: list[Card], countries: int) -> None:
        payload = json.dumps([c.model_dump() for c in cards])
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                done = await conn.execute(
                    "UPDATE ai.league_members SET cards = $3::jsonb, countries = $4 "
                    "WHERE league_id = $1::uuid AND user_id = $2",
                    league_id,
                    user_id,
                    payload,
                    countries,
                )
                if done.endswith(" 0"):
                    raise LeagueNotFoundError(league_id)
                await conn.execute(
                    "UPDATE ai.leagues SET updated_at = now() WHERE league_id = $1::uuid", league_id
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"subir cromos: {exc}") from exc

    async def set_city(self, league_id: str, user_id: str, city: str | None) -> None:
        try:
            done = await self._pool.execute(
                "UPDATE ai.league_members SET city = $3, city_at = CASE WHEN $3::text IS NULL THEN NULL "
                "ELSE now() END WHERE league_id = $1::uuid AND user_id = $2",
                league_id,
                user_id,
                city,
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"ciudad: {exc}") from exc
        if done.endswith(" 0"):
            raise LeagueNotFoundError(league_id)

    async def propose(self, league_id: str, user_id: str, to_seat: int, give_qid: str, want_qid: str) -> Swap:
        swap_id = str(uuid.uuid4())
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                league = await self._locked(conn, league_id, user_id)
                me = league.member(user_id)
                them = league.seat(to_seat)
                assert me is not None  # noqa: S101
                if them is None:
                    raise SwapNotAllowedError("no está en la liga")
                give, want = check_swap(league, me, them, give_qid, want_qid)
                pending = sum(1 for s in league.swaps if s.status == "pending" and s.from_seat == me.seat)
                if pending >= MAX_PENDING:
                    raise TooManyPendingError(league_id)
                row = await conn.fetchrow(
                    "INSERT INTO ai.league_swaps (swap_id, league_id, from_seat, to_seat, give, want) "
                    "VALUES ($1::uuid, $2::uuid, $3, $4, $5::jsonb, $6::jsonb) RETURNING created_at",
                    swap_id,
                    league_id,
                    me.seat,
                    to_seat,
                    give.model_dump_json(),
                    want.model_dump_json(),
                )
                # Solo se guardan los últimos cambios: los decididos más viejos se van.
                await conn.execute(
                    "DELETE FROM ai.league_swaps WHERE swap_id IN ("
                    " SELECT swap_id FROM ai.league_swaps WHERE league_id = $1::uuid AND status <> 'pending'"
                    " ORDER BY created_at DESC OFFSET $2)",
                    league_id,
                    MAX_SWAPS_KEPT,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"proponer cambio: {exc}") from exc
        assert row is not None  # noqa: S101
        return Swap(swap_id, me.seat, to_seat, give, want, "pending", row["created_at"])

    async def decide(self, league_id: str, user_id: str, swap_id: str, *, accept: bool) -> Swap:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                league = await self._locked(conn, league_id, user_id)
                me = league.member(user_id)
                swap = next((s for s in league.swaps if s.swap_id == swap_id), None)
                assert me is not None  # noqa: S101
                if swap is None or swap.to_seat != me.seat or swap.status != "pending":
                    raise SwapNotFoundError(swap_id)
                if accept:
                    giver = league.seat(swap.from_seat)
                    if giver is None:
                        raise SwapNotAllowedError("ya no está en la liga")
                    # Se vuelve a comprobar desde el lado de quien lo propuso.
                    check_swap(league, giver, me, swap.give.qid, swap.want.qid)
                status: SwapStatus = "accepted" if accept else "declined"
                await conn.execute(
                    "UPDATE ai.league_swaps SET status = $2, decided_at = now() WHERE swap_id = $1::uuid",
                    swap_id,
                    status,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"decidir cambio: {exc}") from exc
        return Swap(swap.swap_id, swap.from_seat, swap.to_seat, swap.give, swap.want, status, swap.created_at)

    async def leave(self, league_id: str, user_id: str) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await conn.fetchval(
                    "DELETE FROM ai.league_members WHERE league_id = $1::uuid AND user_id = $2 "
                    "RETURNING seat",
                    league_id,
                    user_id,
                )
                if seat is None:
                    raise LeagueNotFoundError(league_id)
                await conn.execute(
                    "DELETE FROM ai.league_swaps WHERE league_id = $1::uuid "
                    "AND (from_seat = $2 OR to_seat = $2)",
                    league_id,
                    seat,
                )
                # Si era la última persona, la liga entera fuera.
                await conn.execute(
                    "DELETE FROM ai.leagues l WHERE league_id = $1::uuid AND NOT EXISTS "
                    "(SELECT 1 FROM ai.league_members m WHERE m.league_id = l.league_id)",
                    league_id,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"salir de la liga: {exc}") from exc
