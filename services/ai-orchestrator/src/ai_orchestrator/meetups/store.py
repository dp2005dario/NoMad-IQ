"""Las quedadas en PostgreSQL (ver migrations/0013_meetups.sql).

Los topes (plazas, quedadas por persona) se comprueban dentro de una
transacción con FOR UPDATE sobre la quedada: dos personas que pulsan
"Unirme" a la vez por la última plaza no pueden entrar las dos.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Protocol

import asyncpg

from ai_orchestrator.meetups.domain import (
    KEEP_AFTER_START,
    MAX_ACTIVE_CREATED,
    MAX_ACTIVE_JOINED,
    REPORTS_TO_HIDE,
    SHOWN_AFTER_START,
    Meetup,
    MeetupFullError,
    MeetupKind,
    MeetupLimitError,
    MeetupNotFoundError,
    Member,
)
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class NewMeetup(Protocol):
    @property
    def city(self) -> str: ...

    @property
    def kind(self) -> MeetupKind: ...

    @property
    def title(self) -> str: ...

    @property
    def place(self) -> str: ...

    @property
    def starts_at(self) -> datetime: ...

    @property
    def capacity(self) -> int: ...


class MeetupStore(Protocol):
    async def list_city(self, city: str, now: datetime) -> list[Meetup]: ...

    async def mine(self, user_id: str, now: datetime) -> list[Meetup]: ...

    async def create(self, user_id: str, me: Member, draft: NewMeetup, now: datetime) -> Meetup: ...

    async def join(self, meetup_id: str, me: Member, now: datetime) -> Meetup: ...

    async def leave(self, meetup_id: str, user_id: str, now: datetime) -> Meetup: ...

    async def cancel(self, meetup_id: str, user_id: str) -> None: ...

    async def report(self, meetup_id: str, user_id: str) -> None: ...

    async def sweep(self, now: datetime) -> int: ...


_COLUMNS = "meetup_id, city, kind, title, place, starts_at, capacity, creator_id, reports"


class PostgresMeetups:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def _with_members(self, conn: Conn, rows: list[asyncpg.Record]) -> list[Meetup]:
        if not rows:
            return []
        ids = [r["meetup_id"] for r in rows]
        members = await conn.fetch(
            "SELECT meetup_id, user_id, name, country, visible FROM ai.meetup_members"
            " WHERE meetup_id = ANY($1::uuid[]) ORDER BY joined_at",
            ids,
        )
        by_id: dict[str, list[Member]] = {}
        for m in members:
            by_id.setdefault(str(m["meetup_id"]), []).append(
                Member(user_id=m["user_id"], name=m["name"], country=m["country"], visible=m["visible"])
            )
        return [
            Meetup(
                meetup_id=str(r["meetup_id"]),
                city=r["city"],
                kind=r["kind"],
                title=r["title"],
                place=r["place"],
                starts_at=r["starts_at"],
                capacity=r["capacity"],
                creator_id=r["creator_id"],
                reports=r["reports"],
                members=tuple(by_id.get(str(r["meetup_id"]), [])),
            )
            for r in rows
        ]

    async def _one(self, conn: Conn, meetup_id: str, now: datetime, *, lock: bool = False) -> Meetup:
        row = await conn.fetchrow(
            f"SELECT {_COLUMNS} FROM ai.meetups WHERE meetup_id = $1::uuid"  # noqa: S608
            + (" FOR UPDATE" if lock else ""),
            meetup_id,
        )
        found = await self._with_members(conn, [row] if row else [])
        if not found or not found[0].shown(now):
            raise MeetupNotFoundError(meetup_id)
        return found[0]

    async def list_city(self, city: str, now: datetime) -> list[Meetup]:
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    f"SELECT {_COLUMNS} FROM ai.meetups"  # noqa: S608
                    " WHERE city = $1 AND starts_at > $2 AND reports < $3"
                    " ORDER BY starts_at LIMIT 100",
                    city,
                    now - SHOWN_AFTER_START,
                    REPORTS_TO_HIDE,
                )
                return await self._with_members(conn, list(rows))
        except _DB_ERRORS as exc:
            raise StoreError(f"leer quedadas: {exc}") from exc

    async def mine(self, user_id: str, now: datetime) -> list[Meetup]:
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    f"SELECT {_COLUMNS} FROM ai.meetups m"  # noqa: S608
                    " WHERE m.starts_at > $2 AND m.reports < $3 AND EXISTS"
                    " (SELECT 1 FROM ai.meetup_members x WHERE x.meetup_id = m.meetup_id AND x.user_id = $1)"
                    " ORDER BY m.starts_at LIMIT 50",
                    user_id,
                    now - SHOWN_AFTER_START,
                    REPORTS_TO_HIDE,
                )
                return await self._with_members(conn, list(rows))
        except _DB_ERRORS as exc:
            raise StoreError(f"leer mis quedadas: {exc}") from exc

    async def _active_joined(self, conn: Conn, user_id: str, now: datetime) -> int:
        count = await conn.fetchval(
            "SELECT count(*) FROM ai.meetup_members x JOIN ai.meetups m USING (meetup_id)"
            " WHERE x.user_id = $1 AND m.starts_at > $2",
            user_id,
            now - SHOWN_AFTER_START,
        )
        return int(count or 0)

    async def create(self, user_id: str, me: Member, draft: NewMeetup, now: datetime) -> Meetup:
        meetup_id = str(uuid.uuid4())
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                # Un candado por persona (pg_advisory_xact_lock): dos "Proponer"
                # a la vez de la misma persona no se saltan el tope.
                await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", "meetups:" + user_id)
                created = await conn.fetchval(
                    "SELECT count(*) FROM ai.meetups WHERE creator_id = $1 AND starts_at > $2",
                    user_id,
                    now - SHOWN_AFTER_START,
                )
                if int(created or 0) >= MAX_ACTIVE_CREATED:
                    raise MeetupLimitError(user_id)
                if await self._active_joined(conn, user_id, now) >= MAX_ACTIVE_JOINED:
                    raise MeetupLimitError(user_id)
                await conn.execute(
                    "INSERT INTO ai.meetups"
                    " (meetup_id, city, kind, title, place, starts_at, capacity, creator_id)"
                    " VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8)",
                    meetup_id,
                    draft.city,
                    draft.kind,
                    draft.title,
                    draft.place,
                    draft.starts_at,
                    draft.capacity,
                    user_id,
                )
                await conn.execute(
                    "INSERT INTO ai.meetup_members (meetup_id, user_id, name, country, visible)"
                    " VALUES ($1::uuid, $2, $3, $4, $5)",
                    meetup_id,
                    user_id,
                    me.name,
                    me.country,
                    me.visible,
                )
                return await self._one(conn, meetup_id, now)
        except _DB_ERRORS as exc:
            raise StoreError(f"crear quedada: {exc}") from exc

    async def join(self, meetup_id: str, me: Member, now: datetime) -> Meetup:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                meetup = await self._one(conn, meetup_id, now, lock=True)
                if meetup.member(me.user_id) is None:
                    if meetup.full:
                        raise MeetupFullError(meetup_id)
                    if await self._active_joined(conn, me.user_id, now) >= MAX_ACTIVE_JOINED:
                        raise MeetupLimitError(me.user_id)
                await conn.execute(
                    "INSERT INTO ai.meetup_members (meetup_id, user_id, name, country, visible)"
                    " VALUES ($1::uuid, $2, $3, $4, $5) ON CONFLICT (meetup_id, user_id) DO UPDATE"
                    " SET name = EXCLUDED.name, country = EXCLUDED.country, visible = EXCLUDED.visible",
                    meetup_id,
                    me.user_id,
                    me.name,
                    me.country,
                    me.visible,
                )
                return await self._one(conn, meetup_id, now)
        except _DB_ERRORS as exc:
            raise StoreError(f"unirse a la quedada: {exc}") from exc

    async def leave(self, meetup_id: str, user_id: str, now: datetime) -> Meetup:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                meetup = await self._one(conn, meetup_id, now, lock=True)
                if meetup.creator_id == user_id:
                    # Quien la propuso no "se va": la cancela (ver cancel).
                    raise MeetupNotFoundError(meetup_id)
                await conn.execute(
                    "DELETE FROM ai.meetup_members WHERE meetup_id = $1::uuid AND user_id = $2",
                    meetup_id,
                    user_id,
                )
                return await self._one(conn, meetup_id, now)
        except _DB_ERRORS as exc:
            raise StoreError(f"salir de la quedada: {exc}") from exc

    async def cancel(self, meetup_id: str, user_id: str) -> None:
        try:
            deleted = await self._pool.execute(
                "DELETE FROM ai.meetups WHERE meetup_id = $1::uuid AND creator_id = $2", meetup_id, user_id
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"cancelar quedada: {exc}") from exc
        if deleted.endswith(" 0"):
            raise MeetupNotFoundError(meetup_id)

    async def report(self, meetup_id: str, user_id: str) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                inserted = await conn.execute(
                    "INSERT INTO ai.meetup_reports (meetup_id, user_id)"
                    " SELECT $1::uuid, $2 WHERE EXISTS (SELECT 1 FROM ai.meetups WHERE meetup_id = $1::uuid)"
                    " ON CONFLICT DO NOTHING",
                    meetup_id,
                    user_id,
                )
                # Cada persona cuenta una vez, por mucho que pulse.
                if inserted.endswith(" 1"):
                    await conn.execute(
                        "UPDATE ai.meetups SET reports = reports + 1 WHERE meetup_id = $1::uuid", meetup_id
                    )
        except _DB_ERRORS as exc:
            raise StoreError(f"denunciar quedada: {exc}") from exc

    async def sweep(self, now: datetime) -> int:
        """Borra las quedadas de hace más de una semana (las llama el barrido)."""
        try:
            deleted = await self._pool.execute(
                "DELETE FROM ai.meetups WHERE starts_at < $1", now - KEEP_AFTER_START
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"barrer quedadas: {exc}") from exc
        return int(deleted.split()[-1]) if deleted.split()[-1].isdigit() else 0
