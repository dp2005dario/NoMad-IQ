"""Dónde se guardan las tareas (PostgreSQL) y la vista de la lista."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Protocol

import asyncpg

from ai_orchestrator.erasure import ERASED_PREFIX
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)
MAX_TASKS = 40
ORGANIZER_SEAT = 1


class TripNotFoundError(Exception):
    """No existe el viaje o no eres de él (se responde igual: 404)."""


class TaskNotFoundError(Exception):
    """Esa tarea no es de este viaje."""


class TaskLimitError(Exception):
    """Ya hay demasiadas tareas en este viaje."""


class NotAllowedError(Exception):
    """Solo quien la puso (o el organizador) puede quitarla."""


@dataclass(frozen=True, slots=True)
class Task:
    task_id: str
    label: str
    added_by_seat: int
    owner_seat: int | None
    done: bool


@dataclass(frozen=True, slots=True)
class TaskList:
    negotiation_id: str
    my_seat: int
    names: dict[int, str]
    tasks: tuple[Task, ...]


class TaskStore(Protocol):
    async def list(self, negotiation_id: str, user_id: str) -> TaskList: ...

    async def add(self, negotiation_id: str, user_id: str, label: str) -> TaskList: ...

    async def take(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList: ...

    async def done(self, negotiation_id: str, user_id: str, task_id: str, *, done: bool) -> TaskList: ...

    async def delete(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList: ...


class PostgresTasks:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def _seat(self, conn: Conn, negotiation_id: str, user_id: str) -> int:
        seat = await conn.fetchval(
            "SELECT seat FROM ai.group_negotiation_members WHERE negotiation_id = $1::uuid AND user_id = $2",
            negotiation_id,
            user_id,
        )
        if seat is None:
            raise TripNotFoundError(negotiation_id)
        return int(seat)

    async def _list(self, conn: Conn, negotiation_id: str, seat: int) -> TaskList:
        people = await conn.fetch(
            "SELECT seat, coalesce(display_name, alias) AS name FROM ai.group_negotiation_members"
            " WHERE negotiation_id = $1::uuid AND user_id NOT LIKE $2",
            negotiation_id,
            ERASED_PREFIX + "%",
        )
        rows = await conn.fetch(
            "SELECT task_id, label, added_by_seat, owner_seat, done FROM ai.group_tasks"
            " WHERE negotiation_id = $1::uuid ORDER BY created_at, task_id",
            negotiation_id,
        )
        return TaskList(
            negotiation_id=negotiation_id,
            my_seat=seat,
            names={int(p["seat"]): str(p["name"]) for p in people},
            tasks=tuple(
                Task(
                    task_id=str(r["task_id"]),
                    label=r["label"],
                    added_by_seat=int(r["added_by_seat"]),
                    owner_seat=r["owner_seat"],
                    done=bool(r["done"]),
                )
                for r in rows
            ),
        )

    async def list(self, negotiation_id: str, user_id: str) -> TaskList:
        try:
            async with self._pool.acquire() as conn:
                return await self._list(conn, negotiation_id, await self._seat(conn, negotiation_id, user_id))
        except _DB_ERRORS as exc:
            raise StoreError(f"leer tareas: {exc}") from exc

    async def add(self, negotiation_id: str, user_id: str, label: str) -> TaskList:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                # Candado sobre el viaje: así el tope se cuenta bien.
                await conn.execute(
                    "SELECT 1 FROM ai.group_negotiations WHERE negotiation_id = $1::uuid FOR UPDATE",
                    negotiation_id,
                )
                count = await conn.fetchval(
                    "SELECT count(*) FROM ai.group_tasks WHERE negotiation_id = $1::uuid", negotiation_id
                )
                if int(count) >= MAX_TASKS:
                    raise TaskLimitError(negotiation_id)
                await conn.execute(
                    "INSERT INTO ai.group_tasks (task_id, negotiation_id, label, added_by_seat)"
                    " VALUES ($1::uuid, $2::uuid, $3, $4)",
                    str(uuid.uuid4()),
                    negotiation_id,
                    label,
                    seat,
                )
                return await self._list(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"añadir tarea: {exc}") from exc

    async def _change(
        self, negotiation_id: str, user_id: str, task_id: str, sql: str, *args: object
    ) -> TaskList:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                status = await conn.execute(sql, task_id, negotiation_id, seat, *args)
                if status.endswith(" 0"):
                    raise TaskNotFoundError(task_id)
                return await self._list(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"cambiar tarea: {exc}") from exc

    async def take(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList:
        # Si ya era tuya, la sueltas; si no, te la quedas.
        return await self._change(
            negotiation_id,
            user_id,
            task_id,
            "UPDATE ai.group_tasks SET owner_seat = CASE WHEN owner_seat = $3 THEN NULL ELSE $3 END"
            " WHERE task_id = $1::uuid AND negotiation_id = $2::uuid",
        )

    async def done(self, negotiation_id: str, user_id: str, task_id: str, *, done: bool) -> TaskList:
        return await self._change(
            negotiation_id,
            user_id,
            task_id,
            "UPDATE ai.group_tasks SET done = $4 WHERE task_id = $1::uuid AND negotiation_id = $2::uuid"
            " AND $3::smallint > 0",
            done,
        )

    async def delete(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                seat = await self._seat(conn, negotiation_id, user_id)
                added_by = await conn.fetchval(
                    "SELECT added_by_seat FROM ai.group_tasks"
                    " WHERE task_id = $1::uuid AND negotiation_id = $2::uuid",
                    task_id,
                    negotiation_id,
                )
                if added_by is None:
                    raise TaskNotFoundError(task_id)
                if seat not in (int(added_by), ORGANIZER_SEAT):
                    raise NotAllowedError(task_id)
                await conn.execute("DELETE FROM ai.group_tasks WHERE task_id = $1::uuid", task_id)
                return await self._list(conn, negotiation_id, seat)
        except _DB_ERRORS as exc:
            raise StoreError(f"quitar tarea: {exc}") from exc
