"""El servicio de vídeos de planes.

Vídeos cortos de YouTube de cada sitio (si hay clave): caché de 7 días en
Redis (``ai:planvideos:v1:<idioma>:<sitio>``), single flight y tope diario
de búsquedas nuevas. Y la foto de Wikipedia de un sitio.
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
from ai_orchestrator.plan_videos.domain import PlanVideo, PlanVideos
from ai_orchestrator.plan_videos.youtube import YouTubeBusyError, YouTubeClient, YouTubeError
from ai_orchestrator.quota import QuotaUnavailableError, day_key

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:planvideos:v1"
QUOTA_PREFIX = "ai:planvideos:quota"


def place_key(place: str) -> str:
    """ "Lisboa", " lisboa " y "LISBOA" son el mismo sitio."""
    norm = " ".join(place.lower().split())
    return hashlib.sha256(norm.encode()).hexdigest()[:32]


def cache_key(place: str, language: str) -> str:
    return f"{language}:{place_key(place)}"


class PlanVideoCache(Protocol):
    async def get(self, key: str) -> PlanVideos | None: ...

    async def put(self, key: str, videos: PlanVideos, *, ttl_seconds: int) -> None: ...


class PhotoCache(Protocol):
    async def get(self, key: str) -> tuple[bool, str | None]: ...

    async def put(self, key: str, url: str | None, *, ttl_seconds: int) -> None: ...


class PhotoSource(Protocol):
    async def photo_of(self, place: str, language: str) -> str | None: ...


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
    """YouTube o Redis no responden ahora mismo."""


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
        youtube: YouTubeClient | None,
        cache: PlanVideoCache,
        quota: DailyQuota,
        photos: PhotoSource,
        photo_cache: PhotoCache,
        settings: PlanVideoSettings | None = None,
    ) -> None:
        self._photos = photos
        self._photo_cache = photo_cache
        self._photo_flight: SingleFlight[str | None] = SingleFlight()
        self._youtube = youtube
        self._cache = cache
        self._quota = quota
        self._settings = settings or PlanVideoSettings()
        self._flight: SingleFlight[list[PlanVideo]] = SingleFlight()

    async def videos(self, place: str, query: str, language: str) -> PlanVideos:
        """Vídeos de ``place``; ``query`` es la búsqueda ya en su idioma
        ("qué hacer en Lisboa")."""
        found: list[PlanVideo] = []
        if self._youtube is not None:
            found = await self._youtube_videos(place, query, language)
        return PlanVideos(place=place, videos=found, youtube=self._youtube is not None)

    async def photo(self, place: str, language: str) -> str | None:
        """La foto de Wikipedia de un sitio (o None), guardada 30 días."""
        key = cache_key(place, language)
        try:
            known, url = await self._photo_cache.get(key)
        except CacheError as exc:
            raise PlanVideosUnavailableError(str(exc)) from exc
        if known:
            return url
        result, _ = await self._photo_flight.do(key, lambda: self._find_photo(key, place, language))
        return result

    async def _find_photo(self, key: str, place: str, language: str) -> str | None:
        url = await self._photos.photo_of(place, language)
        ttl = 30 * 24 * 3600 if url else 3 * 24 * 3600
        try:
            await self._photo_cache.put(key, url, ttl_seconds=ttl)
        except CacheError:
            log.warning("no se pudo guardar la foto del sitio")
        return url

    async def _youtube_videos(self, place: str, query: str, language: str) -> list[PlanVideo]:
        key = cache_key(place, language)
        cached = await self._cache.get(key)
        if cached is not None:
            return list(cached.videos)
        try:
            result, _ = await self._flight.do(key, lambda: self._search(key, place, query, language))
        except YouTubeBusyError as exc:
            raise PlanVideosBusyError(str(exc)) from exc
        except YouTubeError as exc:
            log.warning("YouTube no disponible", extra={"error": str(exc)})
            raise PlanVideosUnavailableError(str(exc)) from exc
        return result

    async def _search(self, key: str, place: str, query: str, language: str) -> list[PlanVideo]:
        youtube = self._youtube
        if youtube is None:
            return []
        try:
            left = await self._quota.take("all", day_key(datetime.now(UTC)), self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise PlanVideosUnavailableError(str(exc)) from exc
        if left is None:
            return []
        found = await youtube.shorts(query, language)
        ttl = self._settings.ttl_seconds if found else self._settings.empty_ttl_seconds
        await self._cache.put(key, PlanVideos(place=place, videos=found), ttl_seconds=ttl)
        return found
