"""El servicio de vídeos de planes: caché primero, YouTube solo si hace falta.

1. Redis (``ai:planvideos:v1:<idioma>:<sitio>``), 7 días.
2. Single flight: si alguien ya está buscando ESE sitio, se espera.
3. Tope del día: gastado → lista vacía (y la app ofrece TikTok/Instagram).
4. YouTube, y se guarda.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.plan_videos.domain import PlanVideos
from ai_orchestrator.plan_videos.youtube import YouTubeBusyError, YouTubeClient, YouTubeError
from ai_orchestrator.quota import QuotaUnavailableError, day_key

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:planvideos:v1"
QUOTA_PREFIX = "ai:planvideos:quota"


def cache_key(place: str, language: str) -> str:
    """ "Lisboa", " lisboa " y "LISBOA" son el mismo sitio."""
    norm = " ".join(place.lower().split())
    digest = hashlib.sha256(norm.encode()).hexdigest()[:32]
    return f"{language}:{digest}"


class PlanVideoCache(Protocol):
    async def get(self, key: str) -> PlanVideos | None: ...

    async def put(self, key: str, videos: PlanVideos, *, ttl_seconds: int) -> None: ...


class DailyQuota(Protocol):
    async def take(self, user_id: str, day: str, limit: int) -> int | None: ...


class RedisPlanVideoCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, key: str) -> PlanVideos | None:
        try:
            raw = await self._redis.get(f"{KEY_PREFIX}:{key}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer vídeos de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return PlanVideos.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, key: str, videos: PlanVideos, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(f"{KEY_PREFIX}:{key}", videos.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar vídeos en Redis: {exc}") from exc


class PlanVideosBusyError(Exception):
    """YouTube está saturado: la app lo reintentará."""


class PlanVideosUnavailableError(Exception):
    """YouTube no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class PlanVideoSettings:
    ttl_seconds: int = 7 * 24 * 3600
    # Sin resultados se recuerda menos (puede ser una errata pasajera).
    empty_ttl_seconds: int = 24 * 3600
    # Búsquedas nuevas al día (cada una gasta 100 de las 10 000 unidades gratis).
    daily_limit: int = 80


class PlanVideoService:
    def __init__(
        self,
        *,
        youtube: YouTubeClient,
        cache: PlanVideoCache,
        quota: DailyQuota,
        settings: PlanVideoSettings | None = None,
    ) -> None:
        self._youtube = youtube
        self._cache = cache
        self._quota = quota
        self._settings = settings or PlanVideoSettings()
        self._flight: SingleFlight[PlanVideos] = SingleFlight()

    async def videos(self, place: str, query: str, language: str) -> PlanVideos:
        """Vídeos de ``place``; ``query`` es la búsqueda ya en su idioma
        ("qué hacer en Lisboa")."""
        key = cache_key(place, language)
        cached = await self._cache.get(key)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(key, lambda: self._build(key, place, query, language))
        except YouTubeBusyError as exc:
            raise PlanVideosBusyError(str(exc)) from exc
        except YouTubeError as exc:
            log.warning("YouTube no disponible", extra={"error": str(exc)})
            raise PlanVideosUnavailableError(str(exc)) from exc
        return result

    async def _build(self, key: str, place: str, query: str, language: str) -> PlanVideos:
        try:
            left = await self._quota.take("all", day_key(datetime.now(UTC)), self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise PlanVideosUnavailableError(str(exc)) from exc
        if left is None:
            return PlanVideos(place=place)
        found = await self._youtube.shorts(query, language)
        result = PlanVideos(place=place, videos=found)
        ttl = self._settings.ttl_seconds if found else self._settings.empty_ttl_seconds
        await self._cache.put(key, result, ttl_seconds=ttl)
        return result
