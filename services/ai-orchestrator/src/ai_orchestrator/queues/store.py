"""Sin colas en PostgreSQL (ver migrations/0016_queues.sql)."""

from __future__ import annotations

from typing import Protocol

import asyncpg

from ai_orchestrator.queues.domain import (
    HOURS_DAYS,
    MAX_REPORTS_PER_DAY,
    MIN_HOUR_REPORTERS,
    MIN_NOW_REPORTERS,
    NOW_MINUTES,
    PlaceQueue,
    QueueLimitError,
    WaitHour,
    WaitNow,
)
from ai_orchestrator.store import Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class QueueStore(Protocol):
    async def place(self, place: str, user_id: str, local_hour: int) -> PlaceQueue: ...

    async def report(self, place: str, user_id: str, local_hour: int, wait: int) -> None: ...


class PostgresQueues:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def place(self, place: str, user_id: str, local_hour: int) -> PlaceQueue:
        try:
            async with self._pool.acquire() as conn:
                now = await conn.fetchrow(
                    "SELECT count(*) AS n,"
                    " percentile_disc(0.5) WITHIN GROUP (ORDER BY wait) AS wait,"
                    " extract(epoch FROM now() - max(reported_at))::int / 60 AS ago"
                    " FROM ai.queue_reports"
                    " WHERE place = $1 AND reported_at >= now() - make_interval(mins => $2)",
                    place,
                    NOW_MINUTES,
                )
                hours = await conn.fetch(
                    "SELECT local_hour, count(*) AS n,"
                    " percentile_disc(0.5) WITHIN GROUP (ORDER BY wait) AS wait"
                    " FROM ai.queue_reports"
                    " WHERE place = $1 AND reported_on >= current_date - $2::int"
                    " GROUP BY local_hour HAVING count(*) >= $3 ORDER BY local_hour",
                    place,
                    HOURS_DAYS,
                    MIN_HOUR_REPORTERS,
                )
                mine = await conn.fetchval(
                    "SELECT EXISTS (SELECT 1 FROM ai.queue_reports WHERE place = $1"
                    " AND user_id = $2 AND reported_on = current_date AND local_hour = $3)",
                    place,
                    user_id,
                    local_hour,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"leer colas: {exc}") from exc
        reporters = int(now["n"]) if now is not None else 0
        return PlaceQueue(
            place=place,
            now=WaitNow(wait=int(now["wait"]), reporters=reporters, minutes_ago=int(now["ago"]))
            if now is not None and reporters >= MIN_NOW_REPORTERS
            else None,
            hours=[
                WaitHour(hour=int(r["local_hour"]), wait=int(r["wait"]), reporters=int(r["n"])) for r in hours
            ],
            reported_this_hour=bool(mine),
        )

    async def report(self, place: str, user_id: str, local_hour: int, wait: int) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                # Bloqueo por persona (dentro de la transacción) para contar bien.
                await conn.execute("SELECT pg_advisory_xact_lock(hashtext('queues:' || $1))", user_id)
                today = await conn.fetchval(
                    "SELECT count(*) FROM ai.queue_reports WHERE user_id = $1 AND reported_on = current_date",
                    user_id,
                )
                if int(today or 0) >= MAX_REPORTS_PER_DAY:
                    raise QueueLimitError(user_id)
                await conn.execute(
                    "INSERT INTO ai.queue_reports (place, user_id, local_hour, wait) VALUES ($1, $2, $3, $4)"
                    " ON CONFLICT (place, user_id, reported_on, local_hour)"
                    " DO UPDATE SET wait = EXCLUDED.wait, reported_at = now()",
                    place,
                    user_id,
                    local_hour,
                    wait,
                )
                # Barrido de lo caducado de ese sitio (con índice: barato).
                await conn.execute(
                    "DELETE FROM ai.queue_reports WHERE place = $1 AND reported_on < current_date - $2::int",
                    place,
                    HOURS_DAYS,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"avisar cola: {exc}") from exc
