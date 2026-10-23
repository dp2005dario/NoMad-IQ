"""PostgreSQL de la negociación: negociaciones, miembros y transiciones de estado.

Todas las transiciones de estado (collecting -> queued -> running ->
concluded) se hacen con UPDATE ... WHERE status = 'lo_esperado'. Así, si dos
procesos intentan lo mismo a la vez, solo a uno le "cuadra" la condición: el
otro no cambia nada. Es la forma más simple de evitar carreras sin cerrojos
globales.

Y cada vez que un cambio de estado debe anunciarse por Kafka, el mensaje se
guarda en ai.outbox en la MISMA transacción (ver outbox.py).
"""

from __future__ import annotations

import secrets
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

import asyncpg
from pydantic import TypeAdapter

from ai_orchestrator.negotiation.domain import (
    MAX_MEMBERS,
    MIN_MEMBERS,
    GroupOption,
    MemberPreferences,
    NegotiationResult,
    Status,
)
from ai_orchestrator.negotiation.events import request_message
from ai_orchestrator.outbox import OutboxMessage, enqueue
from ai_orchestrator.store import Conn, Pool, StoreError

_OPTIONS = TypeAdapter(tuple[GroupOption, ...])
# Errores que significan "la base de datos no está disponible ahora mismo".
_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class NegotiationNotFoundError(Exception):
    """No existe, o existe pero quien pregunta no es miembro (misma respuesta)."""


class NegotiationClosedError(Exception):
    """Ya no admite preferencias: está en marcha, terminada o fuera de plazo."""


class NegotiationFullError(Exception):
    """El grupo ya tiene el máximo de miembros (MAX_MEMBERS)."""


class NotOrganizerError(Exception):
    """Solo el organizador puede hacer esto (por ejemplo, "Empezar")."""


class NotEnoughReadyError(Exception):
    """Para negociar hacen falta al menos dos personas con sus preferencias enviadas."""


# Alfabeto de Crockford: 32 símbolos sin O, I, L ni U. Al dictar un código
# por teléfono nadie duda entre "0" y "O" o entre "1" e "I".
INVITE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
INVITE_LENGTH = 8


def new_invite_code() -> str:
    """8 símbolos al azar = 32^8 ≈ 1 billón de combinaciones (40 bits).

    ``secrets`` usa el generador del sistema operativo (impredecible), no
    ``random`` (que sirve para juegos, no para secretos). Con un billón de
    combinaciones y un código que caduca en horas, adivinar uno a ciegas
    llevaría siglos aunque se probaran mil por segundo.
    """
    return "".join(secrets.choice(INVITE_ALPHABET) for _ in range(INVITE_LENGTH))


def normalize_invite_code(raw: str) -> str | None:
    """Lo que escribe la persona -> el código guardado, o None si no puede serlo.

    Perdona lo típico: minúsculas, espacios y guiones ("7k2m-9qxd"), y las
    letras que se confunden con números (O -> 0, I y L -> 1).
    """
    text = "".join(c for c in raw.upper() if c not in " -")
    text = text.translate(str.maketrans("OIL", "011"))
    if len(text) != INVITE_LENGTH or any(c not in INVITE_ALPHABET for c in text):
        return None
    return text


@dataclass(frozen=True, slots=True)
class NewNegotiation:
    organizer_id: str
    title: str
    currency: str
    language: str
    options: tuple[GroupOption, ...]
    # Todos los miembros, con el organizador el primero.
    member_ids: tuple[str, ...]
    max_rounds: int
    deadline: datetime
    # Abierta a invitaciones con código: entonces no arranca sola (ver 0007).
    invites_open: bool = False
    # Nombre del organizador para su grupo (None = solo su alias).
    organizer_name: str | None = None


@dataclass(frozen=True, slots=True)
class MemberRecord:
    user_id: str
    seat: int
    alias: str
    preferences: MemberPreferences | None
    submitted_at: datetime | None
    display_name: str | None = None


@dataclass(frozen=True, slots=True)
class NegotiationRecord:
    negotiation_id: str
    organizer_id: str
    title: str
    currency: str
    language: str
    options: tuple[GroupOption, ...]
    max_rounds: int
    status: Status
    deadline: datetime
    created_at: datetime
    concluded_at: datetime | None
    result: NegotiationResult | None
    members: tuple[MemberRecord, ...]
    invites_open: bool = False
    invite_code: str | None = None


@dataclass(frozen=True, slots=True)
class SweepReport:
    queued: int = 0
    expired: int = 0
    requeued: int = 0
    deleted: int = 0


class NegotiationStore(Protocol):
    """Lo que usan la API y el servicio. En los tests hay una versión en memoria."""

    async def create(self, draft: NewNegotiation) -> NegotiationRecord: ...

    async def get_for_member(self, negotiation_id: str, user_id: str) -> NegotiationRecord | None: ...

    async def list_for_member(self, user_id: str, *, limit: int) -> list[NegotiationRecord]: ...

    async def submit_preferences(
        self, negotiation_id: str, user_id: str, preferences: MemberPreferences
    ) -> NegotiationRecord: ...

    async def join(self, code: str, user_id: str, display_name: str | None) -> NegotiationRecord: ...

    async def start(self, negotiation_id: str, user_id: str) -> NegotiationRecord: ...

    async def claim(self, negotiation_id: str, *, lease_seconds: int) -> NegotiationRecord | None: ...

    async def conclude(
        self, negotiation_id: str, result: NegotiationResult, message: OutboxMessage
    ) -> bool: ...

    async def expire(self, negotiation_id: str) -> bool: ...


def alias_for(seat: int) -> str:
    return f"Viajero {seat}"


_NEGOTIATION_COLUMNS = (
    "negotiation_id, organizer_id, title, currency, language, options, max_rounds, status, "
    "deadline, created_at, concluded_at, result, invites_open, invite_code"
)

# Si el código al azar ya lo tiene otro grupo vivo (rarísimo), se prueba otro.
_INVITE_ATTEMPTS = 5


class PostgresNegotiations:
    def __init__(self, pool: Pool, *, requests_topic: str, retention_days: int = 90) -> None:
        self._pool = pool
        self._requests_topic = requests_topic
        self._retention_days = retention_days

    async def create(self, draft: NewNegotiation) -> NegotiationRecord:
        for attempt in range(1, _INVITE_ATTEMPTS + 1):
            try:
                return await self._insert(draft, new_invite_code() if draft.invites_open else None)
            except asyncpg.UniqueViolationError as exc:
                # Solo puede chocar el código de invitación (el id es un UUID nuevo).
                if attempt == _INVITE_ATTEMPTS:
                    raise StoreError(f"crear negociación: código de invitación repetido: {exc}") from exc
            except _DB_ERRORS as exc:
                raise StoreError(f"crear negociación: {exc}") from exc
        raise AssertionError("inalcanzable")  # pragma: no cover

    async def _insert(self, draft: NewNegotiation, invite_code: str | None) -> NegotiationRecord:
        negotiation_id = str(uuid.uuid4())
        async with self._pool.acquire() as conn, conn.transaction():
            await conn.execute(
                """
                INSERT INTO ai.group_negotiations
                    (negotiation_id, organizer_id, title, currency, language, options, max_rounds,
                     status, deadline, invites_open, invite_code)
                VALUES ($1::uuid, $2, $3, $4, $5, $6::jsonb, $7, 'collecting', $8, $9, $10)
                """,
                negotiation_id,
                draft.organizer_id,
                draft.title,
                draft.currency,
                draft.language,
                _OPTIONS.dump_json(draft.options).decode(),
                draft.max_rounds,
                draft.deadline,
                draft.invites_open,
                invite_code,
            )
            await conn.executemany(
                "INSERT INTO ai.group_negotiation_members "
                "(negotiation_id, user_id, seat, alias, display_name) VALUES ($1::uuid, $2, $3, $4, $5)",
                [
                    # Solo el organizador (asiento 1) trae nombre al crear.
                    (negotiation_id, uid, seat, alias_for(seat), draft.organizer_name if seat == 1 else None)
                    for seat, uid in enumerate(draft.member_ids, start=1)
                ],
            )
            record = await self._load(conn, negotiation_id)
        assert record is not None  # noqa: S101 (la acabamos de crear en esta transacción)
        return record

    async def join(self, code: str, user_id: str, display_name: str | None) -> NegotiationRecord:
        """Entra en un grupo con su código de invitación.

        Si ya era miembro, no pasa nada (puede haber pulsado dos veces):
        devuelve el grupo tal cual. Así reintentar es inofensivo.
        """
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                # FOR UPDATE: dos personas entrando a la vez van en fila y no
                # se quedan con el mismo asiento ni pasan del máximo.
                row = await conn.fetchrow(
                    """
                    SELECT negotiation_id, status, deadline < now() AS late
                      FROM ai.group_negotiations
                     WHERE invite_code = $1 AND invites_open
                       FOR UPDATE
                    """,
                    code,
                )
                if row is None:
                    raise NegotiationNotFoundError(code)
                negotiation_id = str(row["negotiation_id"])
                seats = await conn.fetch(
                    "SELECT user_id, seat FROM ai.group_negotiation_members WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                )
                if all(s["user_id"] != user_id for s in seats):
                    if row["status"] != Status.COLLECTING or row["late"]:
                        raise NegotiationClosedError(negotiation_id)
                    if len(seats) >= MAX_MEMBERS:
                        raise NegotiationFullError(negotiation_id)
                    seat = max(s["seat"] for s in seats) + 1
                    await conn.execute(
                        "INSERT INTO ai.group_negotiation_members "
                        "(negotiation_id, user_id, seat, alias, display_name) "
                        "VALUES ($1::uuid, $2, $3, $4, $5)",
                        negotiation_id,
                        user_id,
                        seat,
                        alias_for(seat),
                        display_name,
                    )
                record = await self._load(conn, negotiation_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"entrar en el grupo: {exc}") from exc
        assert record is not None  # noqa: S101
        return record

    async def start(self, negotiation_id: str, user_id: str) -> NegotiationRecord:
        """El organizador pulsa "Empezar": se cierra el grupo y se pone en cola.

        Negocian quienes ya enviaron sus preferencias (mínimo dos). Quien no
        las envió se queda sin agente, igual que si venciera el plazo.
        """
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                row = await conn.fetchrow(
                    """
                    SELECT n.organizer_id, n.status, n.deadline < now() AS late,
                           (SELECT count(*) FROM ai.group_negotiation_members m
                             WHERE m.negotiation_id = n.negotiation_id
                               AND m.submitted_at IS NOT NULL) AS ready
                      FROM ai.group_negotiations n
                     WHERE n.negotiation_id = $1::uuid
                       AND EXISTS (SELECT 1 FROM ai.group_negotiation_members m
                                    WHERE m.negotiation_id = n.negotiation_id AND m.user_id = $2)
                       FOR UPDATE OF n
                    """,
                    negotiation_id,
                    user_id,
                )
                if row is None:
                    raise NegotiationNotFoundError(negotiation_id)
                if row["organizer_id"] != user_id:
                    raise NotOrganizerError(negotiation_id)
                if row["status"] != Status.COLLECTING or row["late"]:
                    raise NegotiationClosedError(negotiation_id)
                if row["ready"] < MIN_MEMBERS:
                    raise NotEnoughReadyError(negotiation_id)
                await self._queue(conn, negotiation_id)
                record = await self._load(conn, negotiation_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"empezar negociación: {exc}") from exc
        assert record is not None  # noqa: S101
        return record

    async def get_for_member(self, negotiation_id: str, user_id: str) -> NegotiationRecord | None:
        try:
            async with self._pool.acquire() as conn:
                # El filtro "es miembro" va EN LA CONSULTA: quien no lo es
                # recibe lo mismo que si no existiera.
                member = await conn.fetchval(
                    "SELECT EXISTS (SELECT 1 FROM ai.group_negotiation_members "
                    "WHERE negotiation_id = $1::uuid AND user_id = $2)",
                    negotiation_id,
                    user_id,
                )
                return await self._load(conn, negotiation_id) if member else None
        except _DB_ERRORS as exc:
            raise StoreError(f"leer negociación: {exc}") from exc

    async def list_for_member(self, user_id: str, *, limit: int) -> list[NegotiationRecord]:
        try:
            async with self._pool.acquire() as conn:
                rows = await conn.fetch(
                    f"""
                    SELECT {_prefixed("n")}
                      FROM ai.group_negotiations n
                      JOIN ai.group_negotiation_members m USING (negotiation_id)
                     WHERE m.user_id = $1
                     ORDER BY n.created_at DESC
                     LIMIT $2
                    """,  # noqa: S608 (columnas constantes nuestras)
                    user_id,
                    limit,
                )
                members = await self._members(conn, [str(r["negotiation_id"]) for r in rows])
        except _DB_ERRORS as exc:
            raise StoreError(f"listar negociaciones: {exc}") from exc
        return [_record(r, members.get(str(r["negotiation_id"]), ())) for r in rows]

    async def submit_preferences(
        self, negotiation_id: str, user_id: str, preferences: MemberPreferences
    ) -> NegotiationRecord:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                # FOR UPDATE: si dos miembros envían a la vez, van en fila. Así
                # solo el ÚLTIMO de verdad ve "ya estamos todos" y pone la
                # negociación en cola (una sola orden de trabajo, nunca dos).
                row = await conn.fetchrow(
                    """
                    SELECT n.status, n.deadline < now() AS late, n.invites_open
                      FROM ai.group_negotiations n
                     WHERE n.negotiation_id = $1::uuid
                       AND EXISTS (SELECT 1 FROM ai.group_negotiation_members m
                                    WHERE m.negotiation_id = n.negotiation_id AND m.user_id = $2)
                       FOR UPDATE
                    """,
                    negotiation_id,
                    user_id,
                )
                if row is None:
                    raise NegotiationNotFoundError(negotiation_id)
                if row["status"] != Status.COLLECTING or row["late"]:
                    raise NegotiationClosedError(negotiation_id)
                await conn.execute(
                    "UPDATE ai.group_negotiation_members SET preferences = $3::jsonb, submitted_at = now() "
                    "WHERE negotiation_id = $1::uuid AND user_id = $2",
                    negotiation_id,
                    user_id,
                    preferences.model_dump_json(),
                )
                pending = await conn.fetchval(
                    "SELECT count(*) FROM ai.group_negotiation_members "
                    "WHERE negotiation_id = $1::uuid AND submitted_at IS NULL",
                    negotiation_id,
                )
                # Con el grupo abierto a invitaciones podría faltar alguien por
                # llegar: entonces no arranca sola (la arranca "Empezar" o el plazo).
                if pending == 0 and not row["invites_open"]:
                    await self._queue(conn, negotiation_id)
                record = await self._load(conn, negotiation_id)
        except _DB_ERRORS as exc:
            raise StoreError(f"guardar preferencias: {exc}") from exc
        assert record is not None  # noqa: S101
        return record

    async def claim(self, negotiation_id: str, *, lease_seconds: int) -> NegotiationRecord | None:
        """queued -> running. None si no estaba en cola (duplicado, ya hecha...)."""
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                claimed = await conn.fetchval(
                    """
                    UPDATE ai.group_negotiations
                       SET status = 'running', lease_until = now() + make_interval(secs => $2),
                           updated_at = now()
                     WHERE negotiation_id = $1::uuid AND status = 'queued'
                    RETURNING true
                    """,
                    negotiation_id,
                    float(lease_seconds),
                )
                return await self._load(conn, negotiation_id) if claimed else None
        except _DB_ERRORS as exc:
            raise StoreError(f"reclamar negociación: {exc}") from exc

    async def conclude(self, negotiation_id: str, result: NegotiationResult, message: OutboxMessage) -> bool:
        """running -> concluded + borra las preferencias + deja el anuncio en el outbox."""
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                done = await conn.fetchval(
                    """
                    UPDATE ai.group_negotiations
                       SET status = 'concluded', result = $2::jsonb, lease_until = NULL,
                           concluded_at = now(), updated_at = now()
                     WHERE negotiation_id = $1::uuid AND status = 'running'
                    RETURNING true
                    """,
                    negotiation_id,
                    result.model_dump_json(),
                )
                if not done:
                    return False
                # Minimización (RGPD): presupuestos, gustos y notas ya no hacen falta.
                await conn.execute(
                    "UPDATE ai.group_negotiation_members SET preferences = NULL "
                    "WHERE negotiation_id = $1::uuid",
                    negotiation_id,
                )
                await enqueue(conn, message)
                return True
        except _DB_ERRORS as exc:
            raise StoreError(f"guardar resultado de negociación: {exc}") from exc

    async def expire(self, negotiation_id: str) -> bool:
        """running -> expired (no hay suficientes participantes) + borra las preferencias."""
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                done = await conn.fetchval(
                    """
                    UPDATE ai.group_negotiations
                       SET status = 'expired', lease_until = NULL, updated_at = now()
                     WHERE negotiation_id = $1::uuid AND status = 'running'
                    RETURNING true
                    """,
                    negotiation_id,
                )
                if done:
                    await conn.execute(
                        "UPDATE ai.group_negotiation_members SET preferences = NULL "
                        "WHERE negotiation_id = $1::uuid",
                        negotiation_id,
                    )
                return bool(done)
        except _DB_ERRORS as exc:
            raise StoreError(f"caducar negociación: {exc}") from exc

    async def sweep(self) -> SweepReport:
        """Barrido periódico (lo llama el relé del outbox en cada vuelta):

        1. Negociaciones "running" cuyo préstamo caducó (el proceso murió):
           vuelven a la cola con una orden nueva.
        2. Plazo vencido: con al menos dos miembros listos, se negocia con
           ellos; si no, caduca ("expired") y se borran sus preferencias.
        3. Las terminadas hace más de retention_days se borran.
        """
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                stale = await conn.fetch(
                    """
                    UPDATE ai.group_negotiations
                       SET status = 'queued', lease_until = NULL, updated_at = now()
                     WHERE negotiation_id IN (
                           SELECT negotiation_id FROM ai.group_negotiations
                            WHERE status = 'running' AND lease_until < now()
                            LIMIT 100 FOR UPDATE SKIP LOCKED)
                    RETURNING negotiation_id
                    """
                )
                for row in stale:
                    await enqueue(
                        conn, request_message(self._requests_topic, str(row["negotiation_id"]), _now())
                    )

                due = await conn.fetch(
                    """
                    WITH due AS (
                        SELECT n.negotiation_id,
                               (SELECT count(*) FROM ai.group_negotiation_members m
                                 WHERE m.negotiation_id = n.negotiation_id
                                   AND m.submitted_at IS NOT NULL) AS ready
                          FROM ai.group_negotiations n
                         WHERE n.status = 'collecting' AND n.deadline < now()
                         ORDER BY n.deadline
                         LIMIT 100
                           FOR UPDATE SKIP LOCKED)
                    UPDATE ai.group_negotiations n
                       SET status = CASE WHEN due.ready >= 2 THEN 'queued' ELSE 'expired' END,
                           invites_open = false, invite_code = NULL, updated_at = now()
                      FROM due
                     WHERE n.negotiation_id = due.negotiation_id
                    RETURNING n.negotiation_id, n.status
                    """
                )
                queued = [str(r["negotiation_id"]) for r in due if r["status"] == Status.QUEUED]
                expired = [str(r["negotiation_id"]) for r in due if r["status"] == Status.EXPIRED]
                for negotiation_id in queued:
                    await enqueue(conn, request_message(self._requests_topic, negotiation_id, _now()))
                if expired:
                    await conn.execute(
                        "UPDATE ai.group_negotiation_members SET preferences = NULL "
                        "WHERE negotiation_id = ANY($1::uuid[])",
                        expired,
                    )

                deleted = await conn.execute(
                    """
                    DELETE FROM ai.group_negotiations
                     WHERE status IN ('concluded', 'expired')
                       AND updated_at < now() - make_interval(days => $1)
                    """,
                    self._retention_days,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"barrido de negociaciones: {exc}") from exc
        return SweepReport(
            queued=len(queued), expired=len(expired), requeued=len(stale), deleted=int(deleted.split()[-1])
        )

    # --- Ayudantes ------------------------------------------------------------------

    async def _queue(self, conn: Conn, negotiation_id: str) -> None:
        # Al ponerse en cola el grupo se cierra: el código deja de valer.
        await conn.execute(
            "UPDATE ai.group_negotiations SET status = 'queued', invites_open = false, invite_code = NULL, "
            "updated_at = now() WHERE negotiation_id = $1::uuid",
            negotiation_id,
        )
        await enqueue(conn, request_message(self._requests_topic, negotiation_id, _now()))

    async def _load(self, conn: Conn, negotiation_id: str) -> NegotiationRecord | None:
        row = await conn.fetchrow(
            f"SELECT {_NEGOTIATION_COLUMNS} FROM ai.group_negotiations WHERE negotiation_id = $1::uuid",  # noqa: S608
            negotiation_id,
        )
        if row is None:
            return None
        members = await self._members(conn, [negotiation_id])
        return _record(row, members.get(negotiation_id, ()))

    async def _members(
        self, conn: Conn, negotiation_ids: Sequence[str]
    ) -> dict[str, tuple[MemberRecord, ...]]:
        if not negotiation_ids:
            return {}
        rows = await conn.fetch(
            "SELECT negotiation_id, user_id, seat, alias, preferences, submitted_at, display_name "
            "FROM ai.group_negotiation_members WHERE negotiation_id = ANY($1::uuid[]) "
            "ORDER BY negotiation_id, seat",
            list(negotiation_ids),
        )
        out: dict[str, list[MemberRecord]] = {}
        for r in rows:
            out.setdefault(str(r["negotiation_id"]), []).append(
                MemberRecord(
                    user_id=r["user_id"],
                    seat=r["seat"],
                    alias=r["alias"],
                    preferences=(
                        MemberPreferences.model_validate_json(r["preferences"]) if r["preferences"] else None
                    ),
                    submitted_at=r["submitted_at"],
                    display_name=r["display_name"],
                )
            )
        return {k: tuple(v) for k, v in out.items()}


def _prefixed(alias: str) -> str:
    return ", ".join(f"{alias}.{c.strip()}" for c in _NEGOTIATION_COLUMNS.split(","))


def _record(row: asyncpg.Record, members: tuple[MemberRecord, ...]) -> NegotiationRecord:
    data: dict[str, Any] = dict(row)
    return NegotiationRecord(
        negotiation_id=str(data["negotiation_id"]),
        organizer_id=data["organizer_id"],
        title=data["title"],
        currency=data["currency"],
        language=data["language"],
        # jsonb llega como texto: lo validamos al leerlo (confiar, pero verificar).
        options=_OPTIONS.validate_json(data["options"]),
        max_rounds=data["max_rounds"],
        status=Status(data["status"]),
        deadline=data["deadline"],
        created_at=data["created_at"],
        concluded_at=data["concluded_at"],
        result=NegotiationResult.model_validate_json(data["result"]) if data["result"] else None,
        members=members,
        invites_open=data["invites_open"],
        invite_code=data["invite_code"],
    )


def _now() -> datetime:
    return datetime.now(UTC)


def deadline_after(now: datetime, hours: float) -> datetime:
    return now + timedelta(hours=hours)
