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

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.nearby.domain import CELL_DEGREES, Nearby, NearbySpot, cell_of
from ai_orchestrator.stale_cache import DEFAULT_STALE_SECONDS, read, write

log = logging.getLogger(__name__)

# v2: ahora también trae restaurantes con reserva (las fichas v1 no).
KEY_PREFIX = "ai:nearby:v2"


class NearbySource(Protocol):
    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[NearbySpot]: ...


class NearbyCache(Protocol):
    async def get(self, lat: float, lon: float) -> Nearby | None:
        """Solo si es fresco."""
        ...

    async def get_stale(self, lat: float, lon: float) -> Nearby | None:
        """Aunque esté pasado de fecha (para cuando Overpass falla)."""
        ...

    async def put(self, nearby: Nearby, *, ttl_seconds: int) -> None: ...


class RedisNearbyCache:
    def __init__(self, redis: Redis, *, stale_seconds: int = DEFAULT_STALE_SECONDS) -> None:
        self._redis = redis
        self._stale = stale_seconds

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def _read(self, lat: float, lon: float, *, fresh_only: bool) -> Nearby | None:
        raw = await read(self._redis, self._key(lat, lon), fresh_only=fresh_only, what="'cerca de ti'")
        if raw is None:
            return None
        try:
            return Nearby.model_validate_json(raw)
        except ValidationError:
            return None

    async def get(self, lat: float, lon: float) -> Nearby | None:
        return await self._read(lat, lon, fresh_only=True)

    async def get_stale(self, lat: float, lon: float) -> Nearby | None:
        return await self._read(lat, lon, fresh_only=False)

    async def put(self, nearby: Nearby, *, ttl_seconds: int) -> None:
        await write(
            self._redis,
            self._key(nearby.lat, nearby.lon),
            nearby.model_dump_json(),
            ttl_seconds=ttl_seconds,
            stale_seconds=self._stale,
            what="'cerca de ti'",
        )


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
            stale = await self._stale(c_lat, c_lon)
            if stale is not None:
                return stale
            raise NearbyBusyError(str(exc)) from exc
        except OverpassError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            stale = await self._stale(c_lat, c_lon)
            if stale is not None:
                return stale
            raise NearbyUnavailableError(str(exc)) from exc
        return result

    async def _stale(self, lat: float, lon: float) -> Nearby | None:
        """La copia vieja de la casilla, si existe: mejor algo antiguo que un error."""
        try:
            stale = await self._cache.get_stale(lat, lon)
        except CacheError:
            return None  # si Redis también falla, se da el error original
        if stale is not None:
            log.info("sirviendo 'cerca de ti' de la caché obsoleta")
        return stale

    async def _build(self, lat: float, lon: float) -> Nearby:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._source.spots_in(lat - half, lon - half, lat + half, lon + half)
        result = Nearby(lat=lat, lon=lon, spots=found)
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
