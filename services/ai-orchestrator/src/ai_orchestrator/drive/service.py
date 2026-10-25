"""El servicio del modo coche: caché primero, Overpass solo si hace falta.

Igual que "Cerca de ti" (nearby/service.py): Redis → single flight →
Overpass. Gasolineras y aparcamientos cambian poco: una semana de caché.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.drive.domain import CELL_DEGREES, DriveArea, DriveSpot, cell_of

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:drive:v1"


class DriveSource(Protocol):
    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[DriveSpot]: ...


class DriveCache(Protocol):
    async def get(self, lat: float, lon: float) -> DriveArea | None: ...

    async def put(self, area: DriveArea, *, ttl_seconds: int) -> None: ...


class RedisDriveCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def get(self, lat: float, lon: float) -> DriveArea | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer el modo coche de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return DriveArea.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, area: DriveArea, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(area.lat, area.lon), area.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar el modo coche en Redis: {exc}") from exc


class DriveBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará."""


class DriveUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class DriveSettings:
    ttl_seconds: int = 7 * 24 * 3600
    # 1 = la casilla y sus 8 vecinas: un cuadrado de ~16 km.
    ring: int = 1


class DriveService:
    def __init__(
        self, *, source: DriveSource, cache: DriveCache, settings: DriveSettings | None = None
    ) -> None:
        self._source = source
        self._cache = cache
        self._settings = settings or DriveSettings()
        self._flight: SingleFlight[DriveArea] = SingleFlight()

    async def around(self, lat: float, lon: float) -> DriveArea:
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.2f}:{c_lon:.2f}", lambda: self._build(c_lat, c_lon))
        except OverpassBusyError as exc:
            raise DriveBusyError(str(exc)) from exc
        except OverpassError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            raise DriveUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> DriveArea:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._source.spots_in(lat - half, lon - half, lat + half, lon + half)
        result = DriveArea(lat=lat, lon=lon, spots=found)
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
