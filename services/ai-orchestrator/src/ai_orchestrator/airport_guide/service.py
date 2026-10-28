"""El servicio de la guía del aeropuerto: caché primero, Overpass si hace falta.

    1. Redis (``ai:airport:v2:<IATA>``): ~1 ms.
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

from ai_orchestrator.airport_guide.domain import AirportGuide, AirportSpot
from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.stale_cache import DEFAULT_STALE_SECONDS, read, write

log = logging.getLogger(__name__)

# v2: desde que también trae las estaciones (lo guardado antes no las tiene).
KEY_PREFIX = "ai:airport:v2"


class SpotSource(Protocol):
    async def spots(self, iata: str) -> list[AirportSpot]: ...


class GuideCache(Protocol):
    async def get(self, iata: str) -> AirportGuide | None:
        """Solo si es fresca."""
        ...

    async def get_stale(self, iata: str) -> AirportGuide | None:
        """Aunque esté pasada de fecha (para cuando Overpass falla)."""
        ...

    async def put(self, guide: AirportGuide, *, ttl_seconds: int) -> None: ...


class RedisGuideCache:
    def __init__(self, redis: Redis, *, stale_seconds: int = DEFAULT_STALE_SECONDS) -> None:
        self._redis = redis
        self._stale = stale_seconds

    async def _read(self, iata: str, *, fresh_only: bool) -> AirportGuide | None:
        raw = await read(self._redis, f"{KEY_PREFIX}:{iata}", fresh_only=fresh_only, what="aeropuerto")
        if raw is None:
            return None
        try:
            return AirportGuide.model_validate_json(raw)
        except ValidationError:
            return None

    async def get(self, iata: str) -> AirportGuide | None:
        return await self._read(iata, fresh_only=True)

    async def get_stale(self, iata: str) -> AirportGuide | None:
        return await self._read(iata, fresh_only=False)

    async def put(self, guide: AirportGuide, *, ttl_seconds: int) -> None:
        await write(
            self._redis,
            f"{KEY_PREFIX}:{guide.iata}",
            guide.model_dump_json(),
            ttl_seconds=ttl_seconds,
            stale_seconds=self._stale,
            what="aeropuerto",
        )


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
            stale = await self._stale(code)
            if stale is not None:
                return stale
            raise GuideBusyError(str(exc)) from exc
        except OverpassError as exc:
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            stale = await self._stale(code)
            if stale is not None:
                return stale
            raise GuideUnavailableError(str(exc)) from exc
        return result

    async def _stale(self, iata: str) -> AirportGuide | None:
        """La copia vieja del aeropuerto, si existe: mejor algo antiguo que un error."""
        try:
            stale = await self._cache.get_stale(iata)
        except CacheError:
            return None  # si Redis también falla, se da el error original
        if stale is not None:
            log.info("sirviendo la guía del aeropuerto de la caché obsoleta")
        return stale

    async def _build(self, iata: str, lat: float, lon: float) -> AirportGuide:
        spots = await self._source.spots(iata)
        guide = AirportGuide(iata=iata, lat=lat, lon=lon, spots=spots)
        ttl = self._settings.ttl_seconds if spots else self._settings.empty_ttl_seconds
        await self._cache.put(guide, ttl_seconds=ttl)
        return guide
