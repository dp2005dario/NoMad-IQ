"""La cola de trabajos de audio (outbox) y el índice del audio grabado, en PostgreSQL.

Ver la migración 0004 para el porqué de cada tabla. Aquí está el "cómo":

- :class:`PostgresAudioJobs`: coger un trabajo (``claim``), darlo por hecho,
  aplazarlo o rendirse. Varios workers pueden trabajar a la vez: cada uno
  coge un trabajo distinto gracias a ``FOR UPDATE SKIP LOCKED`` ("si esta fila
  la está mirando otro, sáltatela y dame la siguiente").
- :class:`PostgresAudioManifests`: guardar y buscar "qué archivos forman el
  audio de esta zona en este idioma" (el manifiesto).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Protocol

import asyncpg
from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.audioguides.domain import NARRATED_KINDS, LanguageCode, ZoneKind
from ai_orchestrator.store import Pool, StoreError

log = logging.getLogger(__name__)

# Canal de pg_notify del trigger (migración 0004).
NOTIFY_CHANNEL = "ai_audio_jobs"


@dataclass(frozen=True, slots=True)
class AudioJob:
    zone_slug: str
    content_version: int
    # Número de este intento (1 = primera vez).
    attempt: int
    # Datos actuales de la zona en geo.zones (None si ya no existe).
    zone_id: str | None
    zone_kind: ZoneKind | None
    zone_active: bool
    # Versión ACTUAL de la zona: si es mayor que la del trabajo, el trabajo
    # está superado (ya hay otro más nuevo apuntado).
    current_version: int


class AudioPart(BaseModel):
    """Un párrafo grabado: un archivo .opus."""

    model_config = ConfigDict(frozen=True)

    index: int = Field(ge=1, le=99)
    key: str
    duration_seconds: float = Field(ge=0)
    # El texto que se oye en ESTE archivo: si la app tiene que tirar del audio
    # de una versión anterior, puede mostrar exactamente lo que suena.
    text: str


class AudioManifest(BaseModel):
    """La lista de archivos que forman el audio de una zona en un idioma."""

    model_config = ConfigDict(frozen=True)

    zone_slug: str
    language: LanguageCode
    content_language: LanguageCode
    content_version: int = Field(ge=0)
    script_digest: str = Field(pattern=r"^[0-9a-f]{16}$")
    source: Literal["llm", "rules"]
    voice: str
    parts: tuple[AudioPart, ...] = Field(min_length=1)
    created_at: datetime | None = None


class AudioJobQueue(Protocol):
    async def claim(self, *, lease_seconds: int) -> AudioJob | None: ...

    async def complete(self, job: AudioJob) -> None: ...

    async def retry(self, job: AudioJob, *, delay_seconds: float, error: str) -> None: ...

    async def reschedule(self, job: AudioJob, *, delay_seconds: float) -> None: ...

    async def give_up(self, job: AudioJob, *, error: str) -> None: ...

    async def enqueue_missing(self) -> int: ...


class AudioManifests(Protocol):
    async def exists(self, slug: str, language: str, version: int, digest: str) -> bool: ...

    async def save(self, manifest: AudioManifest) -> None: ...

    async def latest(self, zone_id: str, language: str, max_version: int) -> AudioManifest | None: ...


def _store_error(what: str, exc: BaseException) -> StoreError:
    return StoreError(f"{what}: {exc}")


_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class PostgresAudioJobs:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def claim(self, *, lease_seconds: int) -> AudioJob | None:
        """Coge el trabajo pendiente más antiguo y lo "presta" durante lease_seconds."""
        try:
            row = await self._pool.fetchrow(
                """
                WITH next AS (
                    SELECT zone_slug, content_version FROM ai.audio_jobs
                    WHERE done_at IS NULL AND available_at <= now()
                      AND (locked_until IS NULL OR locked_until < now())
                    ORDER BY available_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                ), taken AS (
                    UPDATE ai.audio_jobs j
                    SET locked_until = now() + make_interval(secs => $1), attempts = j.attempts + 1
                    FROM next
                    WHERE j.zone_slug = next.zone_slug AND j.content_version = next.content_version
                    RETURNING j.zone_slug, j.content_version, j.attempts
                )
                SELECT t.zone_slug, t.content_version, t.attempts,
                       z.zone_id, z.kind, COALESCE(z.active, false) AS active,
                       COALESCE(c.content_version, 0) AS current_version
                FROM taken t
                LEFT JOIN geo.zones z ON z.slug = t.zone_slug
                LEFT JOIN ai.zone_content c ON c.zone_slug = t.zone_slug
                """,
                float(lease_seconds),
            )
        except asyncpg.UndefinedTableError:
            # geo.zones aún no existe (el geo-engine no ha arrancado nunca).
            return None
        except _DB_ERRORS as exc:
            raise _store_error("coger trabajo de audio", exc) from exc
        if row is None:
            return None
        kind = row["kind"]
        return AudioJob(
            zone_slug=row["zone_slug"],
            content_version=int(row["content_version"]),
            attempt=int(row["attempts"]),
            zone_id=str(row["zone_id"]) if row["zone_id"] is not None else None,
            zone_kind=ZoneKind(kind) if kind in ZoneKind.__members__ else None,
            zone_active=bool(row["active"]),
            current_version=int(row["current_version"]),
        )

    async def complete(self, job: AudioJob) -> None:
        await self._update(
            "UPDATE ai.audio_jobs SET done_at = now(), locked_until = NULL, last_error = NULL "
            "WHERE zone_slug = $1 AND content_version = $2",
            job,
            what="cerrar trabajo de audio",
        )

    async def retry(self, job: AudioJob, *, delay_seconds: float, error: str) -> None:
        """Falló: se devuelve a la cola para dentro de un rato (cada vez más largo)."""
        await self._update(
            "UPDATE ai.audio_jobs SET locked_until = NULL, last_error = left($3, 500), "
            "available_at = now() + make_interval(secs => $4) "
            "WHERE zone_slug = $1 AND content_version = $2",
            job,
            error,
            float(delay_seconds),
            what="aplazar trabajo de audio",
        )

    async def reschedule(self, job: AudioJob, *, delay_seconds: float) -> None:
        """Salió bien, pero hay que volver más tarde (el plan B pide repetir con el LLM).

        No cuenta como fallo: el contador de intentos vuelve a cero.
        """
        await self._update(
            "UPDATE ai.audio_jobs SET locked_until = NULL, last_error = NULL, attempts = 0, "
            "available_at = now() + make_interval(secs => $3) "
            "WHERE zone_slug = $1 AND content_version = $2",
            job,
            float(delay_seconds),
            what="reprogramar trabajo de audio",
        )

    async def give_up(self, job: AudioJob, *, error: str) -> None:
        """Demasiados fallos seguidos: se cierra con el error apuntado para revisarlo."""
        await self._update(
            "UPDATE ai.audio_jobs SET done_at = now(), locked_until = NULL, last_error = left($3, 500) "
            "WHERE zone_slug = $1 AND content_version = $2",
            job,
            error,
            what="abandonar trabajo de audio",
        )

    async def enqueue_missing(self) -> int:
        """Apunta un trabajo para cada zona narrable cuya versión actual aún no tiene ninguno.

        Es la red de seguridad del outbox: cubre las zonas que existían antes
        de esta migración, las que se dan de alta sin hechos (versión 0) y
        cualquier trabajo que se hubiera borrado a mano.
        """
        try:
            status = await self._pool.execute(
                """
                INSERT INTO ai.audio_jobs (zone_slug, content_version)
                SELECT z.slug, COALESCE(c.content_version, 0)
                FROM geo.zones z LEFT JOIN ai.zone_content c ON c.zone_slug = z.slug
                WHERE z.active AND z.kind = ANY($1::text[])
                ON CONFLICT DO NOTHING
                """,
                [k.value for k in NARRATED_KINDS],
            )
        except asyncpg.UndefinedTableError:
            return 0
        except _DB_ERRORS as exc:
            raise _store_error("apuntar trabajos de audio", exc) from exc
        # asyncpg devuelve "INSERT 0 <filas>".
        return int(status.rsplit(" ", 1)[-1])

    async def _update(self, sql: str, job: AudioJob, *args: object, what: str) -> None:
        try:
            await self._pool.execute(sql, job.zone_slug, job.content_version, *args)
        except _DB_ERRORS as exc:
            raise _store_error(what, exc) from exc


class PostgresAudioManifests:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def exists(self, slug: str, language: str, version: int, digest: str) -> bool:
        try:
            found = await self._pool.fetchval(
                "SELECT EXISTS (SELECT 1 FROM ai.zone_audio WHERE zone_slug = $1 AND language = $2 "
                "AND content_version = $3 AND script_digest = $4)",
                slug,
                language,
                version,
                digest,
            )
        except _DB_ERRORS as exc:
            raise _store_error("buscar audio", exc) from exc
        return bool(found)

    async def save(self, manifest: AudioManifest) -> None:
        parts = json.dumps([p.model_dump() for p in manifest.parts], ensure_ascii=False)
        try:
            await self._pool.execute(
                "INSERT INTO ai.zone_audio (zone_slug, language, content_language, content_version, "
                "script_digest, source, voice, parts) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb) "
                "ON CONFLICT DO NOTHING",
                manifest.zone_slug,
                manifest.language,
                manifest.content_language,
                manifest.content_version,
                manifest.script_digest,
                manifest.source,
                manifest.voice,
                parts,
            )
        except _DB_ERRORS as exc:
            raise _store_error("guardar manifiesto de audio", exc) from exc

    async def latest(self, zone_id: str, language: str, max_version: int) -> AudioManifest | None:
        """El audio más reciente de la zona hasta ``max_version`` (incluida).

        Si la versión actual todavía se está grabando, sale el de la anterior:
        mejor oír la versión de ayer unos minutos que no oír nada.
        """
        try:
            row = await self._pool.fetchrow(
                "SELECT a.zone_slug, a.language, a.content_language, a.content_version, a.script_digest, "
                "a.source, a.voice, a.parts, a.created_at "
                "FROM ai.zone_audio a JOIN geo.zones z ON z.slug = a.zone_slug "
                "WHERE z.zone_id = $1::uuid AND z.active AND a.language = $2 AND a.content_version <= $3 "
                "ORDER BY a.content_version DESC, a.created_at DESC LIMIT 1",
                zone_id,
                language,
                max_version,
            )
        except asyncpg.UndefinedTableError:
            return None
        except _DB_ERRORS as exc:
            raise _store_error("leer manifiesto de audio", exc) from exc
        if row is None:
            return None
        return AudioManifest(
            zone_slug=row["zone_slug"],
            language=row["language"],
            content_language=row["content_language"],
            content_version=int(row["content_version"]),
            script_digest=row["script_digest"],
            source=row["source"],
            voice=row["voice"],
            parts=tuple(AudioPart(**p) for p in json.loads(row["parts"])),
            created_at=row["created_at"],
        )
