"""El servicio de cajeros: caché primero, Overpass solo si hace falta.

Orden de cada petición (de lo más barato a lo más caro):
    1. Redis (``ai:atms:v1:<lat>:<lon>`` de la casilla): ~1 ms.
    2. Single flight: si ya hay alguien pidiendo ESA casilla, se espera.
    3. Overpass (1 petición), y se guarda un día.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.atms.domain import CELL_DEGREES, Atms, cell_of
from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassClient, OverpassError
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:atms:v1"


class AtmCache(Protocol):
    async def get(self, lat: float, lon: float) -> Atms | None: ...

    async def put(self, atms: Atms, *, ttl_seconds: int) -> None: ...


class RedisAtmCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def get(self, lat: float, lon: float) -> Atms | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer cajeros de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return Atms.model_validate_json(raw)
        except ValidationError:
            return None  # algo viejo o roto: se vuelve a pedir

    async def put(self, atms: Atms, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(atms.lat, atms.lon), atms.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar cajeros en Redis: {exc}") from exc


class AtmBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará más tarde."""


class AtmUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class AtmSettings:
    # Los cajeros casi nunca cambian: un día de caché.
    ttl_seconds: int = 24 * 3600
    # 1 = la casilla y sus 8 vecinas: un cuadrado de ~3 km.
    ring: int = 1


class AtmService:
    def __init__(
        self, *, overpass: OverpassClient, cache: AtmCache, settings: AtmSettings | None = None
    ) -> None:
        self._overpass = overpass
        self._cache = cache
        self._settings = settings or AtmSettings()
        self._flight: SingleFlight[Atms] = SingleFlight()

    async def near(self, lat: float, lon: float) -> Atms:
        """Cajeros alrededor de un punto (se redondea a su casilla)."""
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(f"{c_lat:.2f}:{c_lon:.2f}", lambda: self._build(c_lat, c_lon))
        except OverpassBusyError as exc:
            raise AtmBusyError(str(exc)) from exc
        except OverpassError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            raise AtmUnavailableError(str(exc)) from exc
        return result

    async def _build(self, lat: float, lon: float) -> Atms:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._overpass.atms_in(lat - half, lon - half, lat + half, lon + half)
        result = Atms(lat=lat, lon=lon, atms=found)
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
