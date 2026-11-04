"""Los viajes compartidos en PostgreSQL (ver migrations/0010_shared_trips.sql).

Reglas que se comprueban aquí:
    - Como mucho 20 viajes compartidos por persona (dentro de la transacción,
      con un bloqueo por persona para que dos envíos a la vez no se cuelen).
    - Solo quien lo compartió puede dejar de compartirlo.
    - "Copiado N veces" cuenta personas distintas, no pulsaciones.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

import asyncpg

from ai_orchestrator.negotiation.store import new_invite_code
from ai_orchestrator.shared_trips.domain import MAX_PER_OWNER, ShareTrip, TripItem
from ai_orchestrator.store import Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)
_CODE_ATTEMPTS = 5


class TooManySharedError(Exception):
    """Ya tiene 20 viajes compartidos."""


@dataclass(frozen=True, slots=True)
class TripRecord:
    code: str
    owner_id: str
    author: str
    title: str
    destination: str
    days: int
    currency: str
    items: tuple[TripItem, ...]
    copies: int
    created_at: datetime
    public: bool = False
    note: str = ""
    rating_sum: int = 0
    rating_count: int = 0


class SharedTripStore(Protocol):
    async def share(self, owner_id: str, trip: ShareTrip) -> TripRecord: ...

    async def get(self, code: str) -> TripRecord | None: ...

    async def mine(self, owner_id: str) -> list[TripRecord]: ...

    async def copy(self, code: str, user_id: str) -> TripRecord | None: ...

    async def unshare(self, code: str, owner_id: str) -> bool: ...

    async def feed(self, limit: int) -> list[TripRecord]: ...

    async def rate(self, code: str, user_id: str, stars: int) -> TripRecord | None: ...

    async def my_ratings(self, user_id: str, codes: list[str]) -> dict[str, int]: ...


_INSERT = (
    "INSERT INTO ai.shared_trips "
    "(code, owner_id, author, title, destination, days, currency, items, public, note) "
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10) "
    "RETURNING code, owner_id, author, title, destination, days, currency, items, copies, created_at, "
    "public, note, rating_sum, rating_count"
)
_GET = (
    "SELECT code, owner_id, author, title, destination, days, currency, items, copies, created_at, "
    "public, note, rating_sum, rating_count "
    "FROM ai.shared_trips WHERE code = $1"
)
_FEED = (
    "SELECT code, owner_id, author, title, destination, days, currency, items, copies, created_at, "
    "public, note, rating_sum, rating_count "
    "FROM ai.shared_trips WHERE public ORDER BY created_at DESC LIMIT $1"
)
_MINE = (
    "SELECT code, owner_id, author, title, destination, days, currency, items, copies, created_at, "
    "public, note, rating_sum, rating_count "
    "FROM ai.shared_trips WHERE owner_id = $1 ORDER BY created_at DESC LIMIT $2"
)


def _record(row: asyncpg.Record) -> TripRecord:
    raw = row["items"]
    items = json.loads(raw) if isinstance(raw, str) else raw
    return TripRecord(
        code=row["code"],
        owner_id=row["owner_id"],
        author=row["author"],
        title=row["title"],
        destination=row["destination"],
        days=row["days"],
        currency=row["currency"],
        items=tuple(TripItem.model_validate(i) for i in items),
        copies=row["copies"],
        created_at=row["created_at"],
        public=row["public"],
        note=row["note"],
        rating_sum=row["rating_sum"],
        rating_count=row["rating_count"],
    )


class PostgresSharedTrips:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def share(self, owner_id: str, trip: ShareTrip) -> TripRecord:
        items = json.dumps([i.model_dump() for i in trip.items])
        for attempt in range(1, _CODE_ATTEMPTS + 1):
            try:
                async with self._pool.acquire() as conn, conn.transaction():
                    # Un candado por persona mientras dura la transacción: así
                    # el "¿cuántos llevas?" y el INSERT van juntos.
                    await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", "shared:" + owner_id)
                    count = await conn.fetchval(
                        "SELECT count(*) FROM ai.shared_trips WHERE owner_id = $1", owner_id
                    )
                    if count >= MAX_PER_OWNER:
                        raise TooManySharedError
                    row = await conn.fetchrow(
                        _INSERT,
                        new_invite_code(),
                        owner_id,
                        trip.author,
                        trip.title,
                        trip.destination,
                        trip.days,
                        trip.currency,
                        items,
                        trip.public,
                        trip.note,
                    )
            except asyncpg.UniqueViolationError as exc:
                # Solo puede chocar el código: se prueba otro.
                if attempt == _CODE_ATTEMPTS:
                    raise StoreError(f"compartir viaje: código repetido: {exc}") from exc
                continue
            except _DB_ERRORS as exc:
                raise StoreError(f"compartir viaje: {exc}") from exc
            assert row is not None  # noqa: S101
            return _record(row)
        raise AssertionError("inalcanzable")  # pragma: no cover

    async def get(self, code: str) -> TripRecord | None:
        try:
            row = await self._pool.fetchrow(
                _GET,
                code,
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"leer viaje: {exc}") from exc
        return None if row is None else _record(row)

    async def mine(self, owner_id: str) -> list[TripRecord]:
        try:
            rows = await self._pool.fetch(
                _MINE,
                owner_id,
                MAX_PER_OWNER,
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"mis viajes: {exc}") from exc
        return [_record(r) for r in rows]

    async def copy(self, code: str, user_id: str) -> TripRecord | None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                added = await conn.execute(
                    "INSERT INTO ai.shared_trip_copies (code, user_id) "
                    "SELECT code, $2 FROM ai.shared_trips WHERE code = $1 AND owner_id <> $2 "
                    "ON CONFLICT DO NOTHING",
                    code,
                    user_id,
                )
                # Solo suma si esta persona no lo había copiado antes (y no es suyo).
                if added.endswith(" 1"):
                    await conn.execute("UPDATE ai.shared_trips SET copies = copies + 1 WHERE code = $1", code)
                row = await conn.fetchrow(
                    _GET,
                    code,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"copiar viaje: {exc}") from exc
        return None if row is None else _record(row)

    async def unshare(self, code: str, owner_id: str) -> bool:
        try:
            status = await self._pool.execute(
                "DELETE FROM ai.shared_trips WHERE code = $1 AND owner_id = $2", code, owner_id
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"dejar de compartir: {exc}") from exc
        return status.endswith(" 1")

    async def feed(self, limit: int) -> list[TripRecord]:
        try:
            rows = await self._pool.fetch(_FEED, limit)
        except _DB_ERRORS as exc:
            raise StoreError(f"muro de viajes: {exc}") from exc
        return [_record(r) for r in rows]

    async def rate(self, code: str, user_id: str, stars: int) -> TripRecord | None:
        """Tus estrellas (1-5). Volver a votar cambia tu voto, no suma otro.

        Tu propio viaje no lo puedes votar (None, como si no existiera)."""
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                owner = await conn.fetchval(
                    "SELECT owner_id FROM ai.shared_trips WHERE code = $1 FOR UPDATE", code
                )
                if owner is None or owner == user_id:
                    return None
                old = await conn.fetchval(
                    "SELECT stars FROM ai.shared_trip_ratings WHERE code = $1 AND user_id = $2", code, user_id
                )
                await conn.execute(
                    "INSERT INTO ai.shared_trip_ratings (code, user_id, stars) VALUES ($1, $2, $3) "
                    "ON CONFLICT (code, user_id) DO UPDATE SET stars = EXCLUDED.stars, rated_at = now()",
                    code,
                    user_id,
                    stars,
                )
                await conn.execute(
                    "UPDATE ai.shared_trips SET rating_sum = rating_sum + $2 - $3, "
                    "rating_count = rating_count + $4 WHERE code = $1",
                    code,
                    stars,
                    old or 0,
                    0 if old else 1,
                )
                row = await conn.fetchrow(_GET, code)
        except _DB_ERRORS as exc:
            raise StoreError(f"votar viaje: {exc}") from exc
        return None if row is None else _record(row)

    async def my_ratings(self, user_id: str, codes: list[str]) -> dict[str, int]:
        if not codes:
            return {}
        try:
            rows = await self._pool.fetch(
                "SELECT code, stars FROM ai.shared_trip_ratings "
                "WHERE user_id = $1 AND code = ANY($2::text[])",
                user_id,
                codes,
            )
        except _DB_ERRORS as exc:
            raise StoreError(f"mis votos: {exc}") from exc
        return {r["code"]: r["stars"] for r in rows}
