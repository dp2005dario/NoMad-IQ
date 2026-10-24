"""El servicio de clima: caché primero, la NASA solo si hace falta.

Orden de cada petición (de lo más barato a lo más caro):
    1. Redis (``ai:climate:v1:<lat>:<lon>`` de la casilla): ~1 ms.
    2. Single flight: si ya hay alguien pidiendo ESA casilla, se espera.
    3. NASA POWER (1 petición), y se guarda 30 días.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.climate.domain import Climate, cell_of
from ai_orchestrator.climate.nasa import NasaBusyError, NasaClient, NasaError

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:climate:v1"


class ClimateCache(Protocol):
    async def get(self, lat: float, lon: float) -> Climate | None: ...

    async def put(self, climate: Climate, *, ttl_seconds: int) -> None: ...


class RedisClimateCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.1f}:{lon:.1f}"

    async def get(self, lat: float, lon: float) -> Climate | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer clima de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return Climate.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, climate: Climate, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(
                self._key(climate.lat, climate.lon), climate.model_dump_json(), ex=ttl_seconds
            )
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar clima en Redis: {exc}") from exc


class ClimateBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará más tarde."""


class ClimateUnavailableError(Exception):
    """La NASA no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class ClimateSettings:
    # Medias de 30 años: un mes de caché es de sobra.
    ttl_seconds: int = 30 * 24 * 3600


class ClimateService:
    def __init__(
        self, *, nasa: NasaClient, cache: ClimateCache, settings: ClimateSettings | None = None
    ) -> None:
        self._nasa = nasa
        self._cache = cache
        self._settings = settings or ClimateSettings()
        self._flight: SingleFlight[Climate] = SingleFlight()

    async def at(self, lat: float, lon: float) -> Climate:
        """El clima medio de cada mes alrededor de un punto."""
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.1f}:{c_lon:.1f}", lambda: self._build(c_lat, c_lon))
        except NasaBusyError as exc:
            raise ClimateBusyError(str(exc)) from exc
        except NasaError as exc:
            log.warning("NASA POWER no disponible", extra={"error": str(exc)})
            raise ClimateUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> Climate:
        months = await self._nasa.climate_at(lat, lon)
        result = Climate(lat=lat, lon=lon, months=months)
        # Una respuesta incompleta no se guarda tanto tiempo: un día.
        ttl = self._settings.ttl_seconds if len(months) == 12 else 24 * 3600
        await self._cache.put(result, ttl_seconds=ttl)
        return result
