"""El chat del viaje en PostgreSQL (ver migrations/0014_group_chat.sql).

El orden de los mensajes: la app pide "lo que haya después del número N".
Para que nunca se salte uno, cada mensaje nuevo se escribe con el viaje
BLOQUEADO (FOR UPDATE): dentro de un mismo viaje, los mensajes se guardan
de uno en uno y sus números salen siempre en orden. Entre viajes distintos
no hay espera (cada uno tiene su candado).

A quien no es miembro del viaje, el viaje "no existe" (igual que en los
planes y la negociación).
"""

from __future__ import annotations

from typing import Protocol

import asyncpg

from ai_orchestrator.erasure import ERASED_PREFIX
from ai_orchestrator.group_chat.domain import (
    KEEP_FOR,
    MAX_PER_DAY,
    PAGE,
    ChatLimitError,
    ChatPage,
    Member,
    Message,
    TripKind,
)
from ai_orchestrator.plans.store import TripNotFoundError
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)

__all__ = ["ChatStore", "PostgresChat", "TripNotFoundError"]


class ChatStore(Protocol):
    async def page(
        self, negotiation_id: str, user_id: str, *, after: int | None, limit: int = PAGE
    ) -> ChatPage: ...

    async def post(self, negotiation_id: str, user_id: str, text: str) -> Message: ...

    async def post_flyra(self, negotiation_id: str, text: str) -> Message: ...

    async def set_kind(self, negotiation_id: str, user_id: str, kind: TripKind) -> None: ...

    async def set_name(self, negotiation_id: str, user_id: str, name: str | None) -> None: ...

    async def others(self, negotiation_id: str, user_id: str) -> list[str]: ...


def _message(r: asyncpg.Record) -> Message:
    return Message(
        message_id=int(r["message_id"]),
        seat=r["seat"],
        text=r["body"],
        created_at=r["created_at"],
    )


class PostgresChat:
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

    async def page(
        self, negotiation_id: str, user_id: str, *, after: int | None, limit: int = PAGE
    ) -> ChatPage:
        try:
            async with self._pool.acquire() as conn:
                seat = await self._seat(conn, negotiation_id, user_id)
                trip = await conn.fetchrow(
                    "SELECT title, trip_kind FROM ai.group_negotiations WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                )
                if trip is None:
                    raise TripNotFoundError(negotiation_id)
                members = await conn.fetch(
                    "SELECT seat, coalesce(chat_name, alias) AS name, user_id NOT LIKE $2 AS active"
                    " FROM ai.group_negotiation_members WHERE negotiation_id = $1::uuid ORDER BY seat",
                    negotiation_id,
                    ERASED_PREFIX + "%",
                )
                if after is None:
                    # La primera vez: los últimos [limit], en orden.
                    rows = await conn.fetch(
                        "SELECT * FROM (SELECT message_id, seat, body, created_at"
                        " FROM ai.group_chat_messages WHERE negotiation_id = $1::uuid"
                        " ORDER BY message_id DESC LIMIT $2) last ORDER BY message_id",
                        negotiation_id,
                        limit,
                    )
                else:
                    rows = await conn.fetch(
                        "SELECT message_id, seat, body, created_at FROM ai.group_chat_messages"
                        " WHERE negotiation_id = $1::uuid AND message_id > $2 ORDER BY message_id LIMIT $3",
                        negotiation_id,
                        after,
                        limit,
                    )
                return ChatPage(
                    negotiation_id=negotiation_id,
                    title=trip["title"],
                    kind=TripKind(trip["trip_kind"]),
                    my_seat=seat,
                    members=tuple(
                        Member(seat=int(m["seat"]), name=m["name"], active=bool(m["active"])) for m in members
                    ),
                    messages=tuple(_message(r) for r in rows),
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"leer chat: {exc}") from exc

    async def _insert(self, conn: Conn, negotiation_id: str, seat: int | None, text: str) -> Message:
        # De paso, se limpia lo viejo de este viaje (barato: va por índice).
        await conn.execute(
            "DELETE FROM ai.group_chat_messages"
            " WHERE negotiation_id = $1::uuid AND created_at < now() - $2::interval",
            negotiation_id,
            KEEP_FOR,
        )
        row = await conn.fetchrow(
            "INSERT INTO ai.group_chat_messages (negotiation_id, seat, body) VALUES ($1::uuid, $2, $3)"
            " RETURNING message_id, seat, body, created_at",
            negotiation_id,
            seat,
            text,
        )
        if row is None:  # pragma: no cover - INSERT ... RETURNING siempre devuelve fila
            raise StoreError("el mensaje no se guardó")
        return _message(row)

    async def _lock(self, conn: Conn, negotiation_id: str) -> None:
        found = await conn.fetchval(
            "SELECT 1 FROM ai.group_negotiations WHERE negotiation_id = $1::uuid FOR UPDATE",
            negotiation_id,
        )
        if found is None:
            raise TripNotFoundError(negotiation_id)

    async def post(self, negotiation_id: str, user_id: str, text: str) -> Message:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                await self._lock(conn, negotiation_id)
                seat = await self._seat(conn, negotiation_id, user_id)
                today = await conn.fetchval(
                    "SELECT count(*) FROM ai.group_chat_messages"
                    " WHERE negotiation_id = $1::uuid AND seat = $2"
                    " AND created_at > now() - interval '1 day'",
                    negotiation_id,
                    seat,
                )
                if int(today or 0) >= MAX_PER_DAY:
                    raise ChatLimitError(negotiation_id)
                return await self._insert(conn, negotiation_id, seat, text)
        except _DB_ERRORS as exc:
            raise StoreError(f"escribir en el chat: {exc}") from exc

    async def post_flyra(self, negotiation_id: str, text: str) -> Message:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                await self._lock(conn, negotiation_id)
                return await self._insert(conn, negotiation_id, None, text)
        except _DB_ERRORS as exc:
            raise StoreError(f"respuesta de Flyra: {exc}") from exc

    async def set_kind(self, negotiation_id: str, user_id: str, kind: TripKind) -> None:
        try:
            async with self._pool.acquire() as conn:
                await self._seat(conn, negotiation_id, user_id)
                await conn.execute(
                    "UPDATE ai.group_negotiations SET trip_kind = $2 WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                    kind.value,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"tipo de viaje: {exc}") from exc

    async def set_name(self, negotiation_id: str, user_id: str, name: str | None) -> None:
        try:
            async with self._pool.acquire() as conn:
                await self._seat(conn, negotiation_id, user_id)
                await conn.execute(
                    "UPDATE ai.group_negotiation_members SET chat_name = $3"
                    " WHERE negotiation_id = $1::uuid AND user_id = $2",
                    negotiation_id,
                    user_id,
                    name,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"nombre en el chat: {exc}") from exc

    async def others(self, negotiation_id: str, user_id: str) -> list[str]:
        """Los user_id de los DEMÁS miembros (para avisarles en el móvil)."""
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    "SELECT user_id FROM ai.group_negotiation_members"
                    " WHERE negotiation_id = $1::uuid AND user_id <> $2 AND user_id NOT LIKE $3",
                    negotiation_id,
                    user_id,
                    ERASED_PREFIX + "%",
                )
                return [r["user_id"] for r in rows]
        except _DB_ERRORS as exc:
            raise StoreError(f"miembros del chat: {exc}") from exc
