"""Acceso a PostgreSQL: migraciones, historial de precios y recomendaciones.

Usamos asyncpg, un driver ASÍNCRONO: mientras la base de datos responde, el
programa sigue atendiendo otras cosas (igual que con Ollama).

Todas las consultas usan parámetros ($1, $2...) y nunca pegan texto del
usuario dentro del SQL. Eso hace imposible la "inyección SQL" (que alguien
cuele órdenes en la base de datos escribiendo cosas raras en un campo).
"""

from __future__ import annotations

import hashlib
import json
import logging
import ssl
from dataclasses import dataclass
from importlib import resources
from typing import Any, Protocol

import asyncpg

from ai_orchestrator.config import Settings
from ai_orchestrator.domain import FareAlert, Money, PriceStats, Recommendation

log = logging.getLogger(__name__)

# "Llave" fija para que, si arrancan varias copias a la vez, solo una migre
# (pg_advisory_lock) y las demás esperen. Distinta de la del price-consumer.
MIGRATION_LOCK_ID = 0x61692D6F7263  # "ai-orc" en hexadecimal

# "type" crea un alias que solo se evalúa al comprobar tipos (asyncpg no admite [] en tiempo de ejecución).
type Pool = asyncpg.Pool[asyncpg.Record]
# Una conexión: suelta, o prestada por el pool (las dos se usan igual).
type Conn = asyncpg.Connection[asyncpg.Record] | asyncpg.pool.PoolConnectionProxy[asyncpg.Record]


class StoreError(Exception):
    """Fallo de base de datos (normalmente temporal: conexión, reinicio...)."""


async def create_pool(settings: Settings) -> Pool:
    """Abre el pool (grupo reutilizable) de conexiones a PostgreSQL."""
    tls: ssl.SSLContext | bool
    if settings.pgsslmode == "verify-full":
        # Comprueba el certificado del servidor y que su nombre coincide con
        # PGHOST. Exigimos TLS 1.3 como en el resto de la plataforma.
        tls = ssl.create_default_context(
            cafile=str(settings.pgsslrootcert) if settings.pgsslrootcert else None
        )
        tls.minimum_version = ssl.TLSVersion.TLSv1_3
    else:
        # Solo llega aquí con DB_INSECURE_DEV=true (config.py lo garantiza).
        tls = False
    pool: Pool = await asyncpg.create_pool(
        host=settings.pghost,
        port=settings.pgport,
        user=settings.pguser,
        password=settings.pgpassword.get_secret_value(),
        database=settings.pgdatabase,
        ssl=tls,
        min_size=1,
        max_size=settings.pg_max_conns,
        # Ninguna consulta de este servicio debería tardar más de 10 s.
        command_timeout=10,
        server_settings={"application_name": "ai-orchestrator"},
    )
    return pool


# ---------------------------------------------------------------------------
# Migraciones
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Migration:
    version: int
    name: str
    sql: str
    checksum: str


def load_migrations() -> list[Migration]:
    """Lee los .sql de la carpeta migrations/ (van dentro del paquete)."""
    out: list[Migration] = []
    seen: dict[int, str] = {}
    folder = resources.files("ai_orchestrator") / "migrations"
    for entry in folder.iterdir():
        if not entry.name.endswith(".sql"):
            continue
        prefix, _, _ = entry.name.partition("_")
        if not prefix.isdigit() or int(prefix) <= 0:
            raise ValueError(f"migración con nombre inválido {entry.name!r} (usa 0001_descripcion.sql)")
        version = int(prefix)
        if version in seen:
            raise ValueError(f"versión {version} repetida: {seen[version]} y {entry.name}")
        seen[version] = entry.name
        body = entry.read_bytes()
        out.append(Migration(version, entry.name, body.decode(), hashlib.sha256(body).hexdigest()))
    return sorted(out, key=lambda m: m.version)


async def migrate(pool: Pool) -> int:
    """Aplica las migraciones pendientes, cada una en su transacción.

    Si alguien edita una migración ya aplicada, su huella no coincide y se
    lanza un error: mejor no arrancar que tener bases de datos distintas en
    cada entorno sin saberlo.
    """
    migrations = load_migrations()
    applied_now = 0
    async with pool.acquire() as conn:
        await conn.execute("SELECT pg_advisory_lock($1)", MIGRATION_LOCK_ID)
        try:
            await conn.execute(
                """
                CREATE SCHEMA IF NOT EXISTS ai;
                CREATE TABLE IF NOT EXISTS ai.ai_orchestrator_migrations (
                    version    integer     PRIMARY KEY,
                    name       text        NOT NULL,
                    checksum   text        NOT NULL,
                    applied_at timestamptz NOT NULL DEFAULT now()
                )"""
            )
            rows = await conn.fetch("SELECT version, checksum FROM ai.ai_orchestrator_migrations")
            applied = {r["version"]: r["checksum"] for r in rows}
            for m in migrations:
                if m.version in applied:
                    if applied[m.version] != m.checksum:
                        raise StoreError(f"la migración {m.name} cambió después de aplicarse")
                    continue
                async with conn.transaction():
                    await conn.execute(m.sql)
                    await conn.execute(
                        "INSERT INTO ai.ai_orchestrator_migrations (version, name, checksum) "
                        "VALUES ($1, $2, $3)",
                        m.version,
                        m.name,
                        m.checksum,
                    )
                log.info("migración aplicada", extra={"migration": m.name})
                applied_now += 1
        finally:
            await conn.execute("SELECT pg_advisory_unlock($1)", MIGRATION_LOCK_ID)
    return applied_now


# ---------------------------------------------------------------------------
# Historial de precios (solo lectura de la tabla del price-consumer)
# ---------------------------------------------------------------------------


class PostgresPriceHistory:
    """Implementa retrieval.PriceHistory con los precios reales guardados."""

    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def stats(self, alert: FareAlert, *, window_days: int) -> PriceStats | None:
        # percentile_disc(0.5) = la mediana, pero eligiendo un precio que
        # EXISTE (no una media entre dos): sigue siendo un entero en céntimos.
        query = """
            SELECT count(*)                                                AS samples,
                   min(amount_minor)                                       AS minimum,
                   max(amount_minor)                                       AS maximum,
                   percentile_disc(0.5) WITHIN GROUP (ORDER BY amount_minor) AS median
              FROM flights.price_observations
             WHERE origin_iata = $1 AND destination_iata = $2 AND departure_date = $3
               AND cabin = $4 AND currency = $5
               AND observed_at >= now() - make_interval(days => $6)
        """
        currency = alert.current_price.currency
        try:
            row = await self._pool.fetchrow(
                query,
                alert.origin,
                alert.destination,
                alert.departure_date,
                alert.cabin.value,
                currency,
                window_days,
            )
        except asyncpg.UndefinedTableError:
            # El price-consumer aún no ha creado su tabla: sin historial, no es un error.
            log.warning("flights.price_observations no existe todavía: sin historial")
            return None
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"consultar historial de precios: {exc}") from exc
        if row is None or row["samples"] == 0:
            return None
        return PriceStats(
            window_days=window_days,
            samples=row["samples"],
            minimum=Money(currency=currency, amount_minor=row["minimum"]),
            maximum=Money(currency=currency, amount_minor=row["maximum"]),
            median=Money(currency=currency, amount_minor=row["median"]),
        )


# ---------------------------------------------------------------------------
# Recomendaciones
# ---------------------------------------------------------------------------


class RecommendationStore(Protocol):
    """Lo que necesitan la API y el procesador. En tests hay una versión en memoria."""

    async def exists(self, alert_id: str) -> bool: ...

    async def save(self, rec: Recommendation) -> bool: ...

    async def list_for_user(self, user_id: str, *, limit: int) -> list[Recommendation]: ...

    async def get_for_user(self, user_id: str, alert_id: str) -> Recommendation | None: ...

    async def ping(self) -> bool: ...


_COLUMNS = (
    "alert_id, user_id, verdict, headline, body, source, model, facts, "
    "booking_deep_link, correlation_id, alert_occurred_at, created_at"
)


def _from_row(row: asyncpg.Record) -> Recommendation:
    data: dict[str, Any] = dict(row)
    data["alert_id"] = str(data["alert_id"])
    # jsonb llega como texto: lo convertimos en diccionario.
    data["facts"] = json.loads(data["facts"])
    return Recommendation.model_validate(data)


class PostgresRecommendations:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def exists(self, alert_id: str) -> bool:
        try:
            found = await self._pool.fetchval(
                "SELECT EXISTS (SELECT 1 FROM ai.fare_recommendations WHERE alert_id = $1::uuid)", alert_id
            )
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"comprobar recomendación: {exc}") from exc
        return bool(found)

    async def save(self, rec: Recommendation) -> bool:
        """Guarda la recomendación. Devuelve False si ya existía (duplicado)."""
        try:
            status = await self._pool.execute(
                f"""
                INSERT INTO ai.fare_recommendations ({_COLUMNS})
                VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11, $12)
                ON CONFLICT (alert_id) DO NOTHING
                """,  # noqa: S608 (_COLUMNS es una constante nuestra, no texto del usuario)
                rec.alert_id,
                rec.user_id,
                rec.verdict.value,
                rec.headline,
                rec.body,
                rec.source,
                rec.model,
                json.dumps(rec.facts, ensure_ascii=False),
                rec.booking_deep_link,
                rec.correlation_id,
                rec.alert_occurred_at,
                rec.created_at,
            )
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"guardar recomendación: {exc}") from exc
        # asyncpg devuelve "INSERT 0 1" (insertada) o "INSERT 0 0" (ya existía).
        return bool(status.endswith(" 1"))

    async def list_for_user(self, user_id: str, *, limit: int) -> list[Recommendation]:
        try:
            rows = await self._pool.fetch(
                f"SELECT {_COLUMNS} FROM ai.fare_recommendations WHERE user_id = $1 "  # noqa: S608
                "ORDER BY created_at DESC LIMIT $2",
                user_id,
                limit,
            )
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"listar recomendaciones: {exc}") from exc
        return [_from_row(r) for r in rows]

    async def get_for_user(self, user_id: str, alert_id: str) -> Recommendation | None:
        # El filtro por user_id va EN LA CONSULTA: aunque alguien adivine el
        # alert_id de otra persona, no obtiene nada.
        try:
            row = await self._pool.fetchrow(
                f"SELECT {_COLUMNS} FROM ai.fare_recommendations WHERE alert_id = $1::uuid AND user_id = $2",  # noqa: S608
                alert_id,
                user_id,
            )
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"leer recomendación: {exc}") from exc
        return _from_row(row) if row is not None else None

    async def ping(self) -> bool:
        try:
            return bool(await self._pool.fetchval("SELECT 1"))
        except (asyncpg.PostgresError, OSError, TimeoutError):
            return False
