"""El servicio de la guía del aeropuerto: caché primero, Overpass si hace falta.

    1. Redis (``ai:airport:v1:<IATA>``): ~1 ms.
    2. Single flight: si alguien ya está pidiendo ESE aeropuerto, se espera.
    3. Overpass (1 petición) y se guarda 30 días (7 si salió vacío: quizá
       alguien lo dibuja pronto en OpenStreetMap).
Solo se aceptan aeropuertos de nuestra lista: nadie puede llenar la caché con
códigos inventados.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.airport_guide.domain import AirportGuide, AirportSpot
from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.places.airports import Airports

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:airport:v1"


class SpotSource(Protocol):
    async def spots(self, iata: str) -> list[AirportSpot]: ...


class GuideCache(Protocol):
    async def get(self, iata: str) -> AirportGuide | None: ...

    async def put(self, guide: AirportGuide, *, ttl_seconds: int) -> None: ...


class RedisGuideCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, iata: str) -> AirportGuide | None:
        try:
            raw = await self._redis.get(f"{KEY_PREFIX}:{iata}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer aeropuerto de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return AirportGuide.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, guide: AirportGuide, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(f"{KEY_PREFIX}:{guide.iata}", guide.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar aeropuerto en Redis: {exc}") from exc


class UnknownAirportError(Exception):
    """Ese código no está en nuestra lista de aeropuertos."""


class GuideBusyError(Exception):
    """Overpass está ocupado: la app lo reintentará más tarde."""


class GuideUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class GuideSettings:
    ttl_seconds: int = 30 * 24 * 3600
    empty_ttl_seconds: int = 7 * 24 * 3600


class AirportGuideService:
    def __init__(
        self,
        *,
        source: SpotSource,
        cache: GuideCache,
        airports: Airports,
        settings: GuideSettings | None = None,
    ) -> None:
        self._source = source
        self._cache = cache
        self._airports = airports
        self._settings = settings or GuideSettings()
        self._flight: SingleFlight[AirportGuide] = SingleFlight()

    async def guide(self, iata: str) -> AirportGuide:
        code = iata.upper()
        airport = self._airports.get(code)
        if airport is None:
            raise UnknownAirportError(code)
        cached = await self._cache.get(code)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(code, lambda: self._build(code, airport.lat, airport.lon))
        except OverpassBusyError as exc:
            raise GuideBusyError(str(exc)) from exc
        except OverpassError as exc:
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            raise GuideUnavailableError(str(exc)) from exc
        return result

    async def _build(self, iata: str, lat: float, lon: float) -> AirportGuide:
        spots = await self._source.spots(iata)
        guide = AirportGuide(iata=iata, lat=lat, lon=lon, spots=spots)
        ttl = self._settings.ttl_seconds if spots else self._settings.empty_ttl_seconds
        await self._cache.put(guide, ttl_seconds=ttl)
        return guide
