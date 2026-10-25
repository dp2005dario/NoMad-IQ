"""El servicio de "Cerca de ti": caché primero, Overpass solo si hace falta.

Igual que los cajeros (atms/service.py): Redis → single flight → Overpass.
Lo gratis de una ciudad cambia muy poco: una semana de caché por casilla.
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
from ai_orchestrator.nearby.domain import CELL_DEGREES, Nearby, NearbySpot, cell_of

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:nearby:v1"


class NearbySource(Protocol):
    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[NearbySpot]: ...


class NearbyCache(Protocol):
    async def get(self, lat: float, lon: float) -> Nearby | None: ...

    async def put(self, nearby: Nearby, *, ttl_seconds: int) -> None: ...


class RedisNearbyCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def get(self, lat: float, lon: float) -> Nearby | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer 'cerca de ti' de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return Nearby.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, nearby: Nearby, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(nearby.lat, nearby.lon), nearby.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar 'cerca de ti' en Redis: {exc}") from exc


class NearbyBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará."""


class NearbyUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class NearbySettings:
    ttl_seconds: int = 7 * 24 * 3600
    # 1 = la casilla y sus 8 vecinas: un cuadrado de ~3 km (un paseo largo).
    ring: int = 1


class NearbyService:
    def __init__(
        self, *, source: NearbySource, cache: NearbyCache, settings: NearbySettings | None = None
    ) -> None:
        self._source = source
        self._cache = cache
        self._settings = settings or NearbySettings()
        self._flight: SingleFlight[Nearby] = SingleFlight()

    async def near(self, lat: float, lon: float) -> Nearby:
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.2f}:{c_lon:.2f}", lambda: self._build(c_lat, c_lon))
        except OverpassBusyError as exc:
            raise NearbyBusyError(str(exc)) from exc
        except OverpassError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            raise NearbyUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> Nearby:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._source.spots_in(lat - half, lon - half, lat + half, lon + half)
        result = Nearby(lat=lat, lon=lon, spots=found)
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
