"""El servicio de fotos de calle: caché primero, Mapillary solo si hace falta.

Orden de cada petición (de lo más barato a lo más caro):
    1. Redis (``ai:street:v1:<lat>:<lon>`` de la casilla): ~1 ms.
    2. Single flight: si ya hay alguien pidiendo ESA casilla, se espera.
    3. Mapillary (1 petición), y se guarda unas horas.

Las direcciones de las fotos de Mapillary caducan a los pocos días, así que
la caché dura 6 horas (de sobra para que una plaza concurrida salga gratis).
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.streetview.domain import CELL_DEGREES, StreetPhoto, StreetPhotos, cell_of
from ai_orchestrator.streetview.mapillary import MapillaryBusyError, MapillaryClient, MapillaryError

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:street:v1"


class StreetCache(Protocol):
    async def get(self, lat: float, lon: float) -> StreetPhotos | None: ...

    async def put(self, photos: StreetPhotos, *, ttl_seconds: int) -> None: ...


class RedisStreetCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.3f}:{lon:.3f}"

    async def get(self, lat: float, lon: float) -> StreetPhotos | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer fotos de calle de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return StreetPhotos.model_validate_json(raw)
        except ValidationError:
            return None  # algo viejo o roto: se vuelve a pedir

    async def put(self, photos: StreetPhotos, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(photos.lat, photos.lon), photos.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar fotos de calle en Redis: {exc}") from exc


class StreetBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará más tarde."""


class StreetUnavailableError(Exception):
    """Mapillary no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class StreetSettings:
    ttl_seconds: int = 6 * 3600
    # Un sitio sin fotos se recuerda más (es raro que aparezcan de repente).
    empty_ttl_seconds: int = 24 * 3600
    # Cuántas fotos como mucho y de cuántas casillas alrededor se buscan
    # (1 = la casilla y sus 8 vecinas: un cuadrado de ~300 m).
    max_photos: int = 12
    ring: int = 1
    # Dos fotos a menos de estos metros son casi la misma: se deja una.
    min_spacing_m: float = 6.0


def _meters(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    # Aproximación plana: de sobra para distancias de cientos de metros.
    dy = (a_lat - b_lat) * 111_320
    dx = (a_lon - b_lon) * 111_320 * math.cos(math.radians((a_lat + b_lat) / 2))
    return math.hypot(dx, dy)


def pick(
    photos: list[StreetPhoto], lat: float, lon: float, *, limit: int, spacing: float
) -> list[StreetPhoto]:
    """Las más cercanas al centro, sin repetir casi el mismo sitio.

    Mapillary suele tener decenas de fotos seguidas de un mismo paseo (una
    cada pocos metros); enseñar 12 casi iguales no aporta nada.
    """
    chosen: list[StreetPhoto] = []
    for p in sorted(photos, key=lambda p: _meters(lat, lon, p.lat, p.lon)):
        if all(_meters(p.lat, p.lon, c.lat, c.lon) >= spacing for c in chosen):
            chosen.append(p)
            if len(chosen) >= limit:
                break
    return chosen


class StreetViewService:
    def __init__(
        self,
        *,
        mapillary: MapillaryClient,
        cache: StreetCache,
        settings: StreetSettings | None = None,
    ) -> None:
        self._mapillary = mapillary
        self._cache = cache
        self._settings = settings or StreetSettings()
        self._flight: SingleFlight[StreetPhotos] = SingleFlight()

    async def near(self, lat: float, lon: float) -> StreetPhotos:
        """Fotos de la calle alrededor de un punto (se redondea a su casilla)."""
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.3f}:{c_lon:.3f}", lambda: self._build(c_lat, c_lon))
        except MapillaryBusyError as exc:
            raise StreetBusyError(str(exc)) from exc
        except MapillaryError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Mapillary no disponible", extra={"error": str(exc)})
            raise StreetUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> StreetPhotos:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._mapillary.photos_in(lat - half, lon - half, lat + half, lon + half)
        photos = pick(found, lat, lon, limit=self._settings.max_photos, spacing=self._settings.min_spacing_m)
        result = StreetPhotos(lat=lat, lon=lon, photos=photos)
        ttl = self._settings.ttl_seconds if photos else self._settings.empty_ttl_seconds
        await self._cache.put(result, ttl_seconds=ttl)
        return result
