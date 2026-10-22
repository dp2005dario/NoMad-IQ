"""Los hechos verificados de cada zona, leídos de PostgreSQL.

¿Por qué una tabla de hechos y no "que el LLM cuente lo que sepa"?
    Un modelo de 8.000 millones de parámetros "sabe" muchas cosas del Prado,
    pero también se inventa fechas y anécdotas con total seguridad. En una
    audioguía, una fecha falsa dicha con voz de experto es peor que no decir
    nada. Así que el LLM solo REDACTA a partir de una lista corta de hechos
    escritos y revisados por personas (tabla ``ai.zone_facts``). Cada párrafo
    del guion tiene que citar de qué hechos sale (ver writer.py).

De dónde sale cada cosa:
    - ``geo.zones`` (del geo-engine): nombre y tipo de la zona. Solo la LEEMOS.
    - ``ai.zone_facts`` (nuestra): los hechos, por slug de zona e idioma.
      Usamos el slug ("madrid-centro") y no el UUID porque el UUID se genera
      al dar de alta la zona y cambia en cada entorno; el slug es estable.
"""

from __future__ import annotations

import logging
from typing import Protocol

import asyncpg

from ai_orchestrator.audioguides.domain import NARRATED_KINDS, ZoneFact, ZoneFacts, ZoneKind
from ai_orchestrator.store import Pool, StoreError

log = logging.getLogger(__name__)

# Más hechos no caben en un guion de dos minutos (y alargan el prompt).
MAX_FACTS = 8


class ZoneFactsSource(Protocol):
    async def content_version(self, zone_id: str) -> int | None:
        """Versión del contenido de la zona (0 si no tiene hechos), o None si la zona no existe."""
        ...

    async def load(self, zone_id: str, *, language: str, fallback_language: str) -> ZoneFacts | None:
        """La zona y sus hechos, o None si la zona no existe (o está desactivada)."""
        ...

    async def narrated_zone_ids(self) -> list[str]:
        """Zonas activas que merecen audioguía (para pregenerarlas)."""
        ...


class PostgresZoneFacts:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def content_version(self, zone_id: str) -> int | None:
        # Una sola consulta por clave primaria (zone_id) + otra por clave
        # primaria (slug). Microsegundos. Y además se guarda en memoria (ver
        # versions.py): se ejecuta una vez por zona y minuto, no por turista.
        try:
            row = await self._pool.fetchrow(
                "SELECT COALESCE(c.content_version, 0) AS version "
                "FROM geo.zones z LEFT JOIN ai.zone_content c ON c.zone_slug = z.slug "
                "WHERE z.zone_id = $1::uuid AND z.active",
                zone_id,
            )
        except asyncpg.UndefinedTableError:
            return None
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"leer versión de la zona: {exc}") from exc
        return None if row is None else int(row["version"])

    async def load(self, zone_id: str, *, language: str, fallback_language: str) -> ZoneFacts | None:
        try:
            # Una transacción de solo lectura "repeatable read": la versión y
            # los hechos se leen de la MISMA foto de la base de datos. Si
            # alguien corrige un hecho justo a la vez, o vemos lo viejo con su
            # versión vieja, o lo nuevo con la nueva; nunca una mezcla.
            async with (
                self._pool.acquire() as conn,
                conn.transaction(isolation="repeatable_read", readonly=True),
            ):
                zone = await conn.fetchrow(
                    "SELECT z.zone_id, z.slug, z.name, z.kind, COALESCE(c.content_version, 0) AS version "
                    "FROM geo.zones z LEFT JOIN ai.zone_content c ON c.zone_slug = z.slug "
                    "WHERE z.zone_id = $1::uuid AND z.active",
                    zone_id,
                )
                if zone is None:
                    return None
                # Pedimos los dos idiomas de una vez y elegimos después.
                rows = await conn.fetch(
                    "SELECT language, fact, source FROM ai.zone_facts "
                    "WHERE zone_slug = $1 AND language = ANY($2::text[]) "
                    "ORDER BY position LIMIT $3",
                    zone["slug"],
                    [language, fallback_language],
                    MAX_FACTS * 2,
                )
        except asyncpg.UndefinedTableError:
            # El geo-engine aún no ha creado geo.zones: no hay zonas que narrar.
            log.warning("geo.zones no existe todavía: sin audioguías")
            return None
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"leer hechos de la zona: {exc}") from exc

        chosen = language if any(r["language"] == language for r in rows) else fallback_language
        texts = [(r["fact"], r["source"]) for r in rows if r["language"] == chosen][:MAX_FACTS]
        return ZoneFacts(
            zone_id=str(zone["zone_id"]),
            slug=zone["slug"],
            name=zone["name"],
            kind=ZoneKind(zone["kind"]),
            facts_language=chosen,
            content_version=int(zone["version"]),
            facts=tuple(
                ZoneFact(fact_id=f"F{i}", text=text, source=source)
                for i, (text, source) in enumerate(texts, start=1)
            ),
        )

    async def narrated_zone_ids(self) -> list[str]:
        try:
            rows = await self._pool.fetch(
                "SELECT zone_id FROM geo.zones WHERE active AND kind = ANY($1::text[]) ORDER BY slug",
                [k.value for k in NARRATED_KINDS],
            )
        except asyncpg.UndefinedTableError:
            return []
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(f"listar zonas: {exc}") from exc
        return [str(r["zone_id"]) for r in rows]
