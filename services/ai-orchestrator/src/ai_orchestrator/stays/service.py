"""El servicio de "Dormir barato": caché primero, Overpass solo si hace falta.

Igual que el modo coche (drive/service.py): Redis → single flight →
Overpass. Los hoteles y las estaciones cambian poco: un mes de caché.
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
from ai_orchestrator.stays.domain import Lodging, Station, StayArea, build_zones, cell_of

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:stays:v1"


class StaySource(Protocol):
    async def around(self, lat: float, lon: float) -> tuple[list[Station], list[Lodging]]: ...


class StayCache(Protocol):
    async def get(self, lat: float, lon: float) -> StayArea | None: ...

    async def put(self, area: StayArea, *, ttl_seconds: int) -> None: ...


class RedisStayCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def get(self, lat: float, lon: float) -> StayArea | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer dormir barato de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return StayArea.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, area: StayArea, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(area.lat, area.lon), area.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar dormir barato en Redis: {exc}") from exc


class StayBusyError(Exception):
    """Demasiadas zonas nuevas a la vez: la app lo reintentará."""


class StayUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class StaySettings:
    ttl_seconds: int = 30 * 24 * 3600


class StayService:
    def __init__(self, *, source: StaySource, cache: StayCache, settings: StaySettings | None = None) -> None:
        self._source = source
        self._cache = cache
        self._settings = settings or StaySettings()
        self._flight: SingleFlight[StayArea] = SingleFlight()

    async def around(self, lat: float, lon: float) -> StayArea:
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.2f}:{c_lon:.2f}", lambda: self._build(c_lat, c_lon))
        except OverpassBusyError as exc:
            raise StayBusyError(str(exc)) from exc
        except OverpassError as exc:
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            raise StayUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> StayArea:
        stations, lodgings = await self._source.around(lat, lon)
        result = StayArea(lat=lat, lon=lon, zones=build_zones(lat, lon, stations, lodgings))
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
