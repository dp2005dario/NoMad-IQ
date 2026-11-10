"""El servicio de fotos de sitios: caché primero, Google solo si hace falta.

Orden de cada petición (de lo más barato a lo más caro):
    1. Redis (``ai:shopphoto:v1:<id>``): ~1 ms y gratis.
    2. Single flight: si ya hay alguien pidiendo ESE sitio, se espera.
    3. Tope del día: si ya se gastaron las búsquedas de hoy, "sin foto".
    4. Google (2 llamadas), y se guarda unas horas.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.quota import QuotaUnavailableError, day_key
from ai_orchestrator.shop_photos.domain import ShopPhoto
from ai_orchestrator.shop_photos.google import GoogleBusyError, GoogleError, GooglePlacesClient

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:shopphoto:v1"
QUOTA_PREFIX = "ai:shopphoto:quota"


class ShopPhotoCache(Protocol):
    async def get(self, osm_id: str) -> ShopPhoto | None: ...

    async def put(self, photo: ShopPhoto, *, ttl_seconds: int) -> None: ...


class DailyQuota(Protocol):
    async def take(self, user_id: str, day: str, limit: int) -> int | None: ...


class RedisShopPhotoCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, osm_id: str) -> ShopPhoto | None:
        try:
            raw = await self._redis.get(f"{KEY_PREFIX}:{osm_id}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer foto de sitio de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return ShopPhoto.model_validate_json(raw)
        except ValidationError:
            return None  # algo viejo o roto: se vuelve a pedir

    async def put(self, photo: ShopPhoto, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(f"{KEY_PREFIX}:{photo.id}", photo.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar foto de sitio en Redis: {exc}") from exc


class ShopPhotoBusyError(Exception):
    """Google está saturado ahora: la app lo reintentará más tarde."""


class ShopPhotoUnavailableError(Exception):
    """Google no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class ShopPhotoSettings:
    # La dirección de la foto de Google caduca: se guarda medio día.
    ttl_seconds: int = 12 * 3600
    # Un sitio sin foto se recuerda más (no merece pagar otra búsqueda pronto).
    empty_ttl_seconds: int = 3 * 24 * 3600
    # Búsquedas nuevas en Google al día, para todos juntos.
    daily_limit: int = 100


class ShopPhotoService:
    def __init__(
        self,
        *,
        google: GooglePlacesClient,
        cache: ShopPhotoCache,
        quota: DailyQuota,
        settings: ShopPhotoSettings | None = None,
    ) -> None:
        self._google = google
        self._cache = cache
        self._quota = quota
        self._settings = settings or ShopPhotoSettings()
        self._flight: SingleFlight[ShopPhoto] = SingleFlight()

    async def photo(self, osm_id: str, name: str, lat: float, lon: float) -> ShopPhoto:
        """La foto de un sitio de OpenStreetMap (por su id, nombre y punto)."""
        cached = await self._cache.get(osm_id)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(osm_id, lambda: self._build(osm_id, name, lat, lon))
        except GoogleBusyError as exc:
            raise ShopPhotoBusyError(str(exc)) from exc
        except GoogleError as exc:
            # Sin el nombre ni el punto en el registro.
            log.warning("Google Places no disponible", extra={"error": str(exc)})
            raise ShopPhotoUnavailableError(str(exc)) from exc
        return result

    async def _build(self, osm_id: str, name: str, lat: float, lon: float) -> ShopPhoto:
        try:
            left = await self._quota.take("all", day_key(datetime.now(UTC)), self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise ShopPhotoUnavailableError(str(exc)) from exc
        if left is None:
            # Tope del día gastado: sin foto (y sin guardar, mañana se busca).
            return ShopPhoto(id=osm_id)
        found = await self._google.photo_of(name, lat, lon)
        if found is None:
            result = ShopPhoto(id=osm_id)
            await self._cache.put(result, ttl_seconds=self._settings.empty_ttl_seconds)
            return result
        url, author, author_url = found
        result = ShopPhoto(id=osm_id, photo_url=url, author=author, author_url=author_url)
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
