"""Los tipos de cambio, con caché: memoria → Redis → BCE.

1. Memoria del proceso (10 min): la inmensa mayoría de peticiones acaban aquí.
2. Redis (6 h): todos los procesos del servidor comparten la misma copia.
3. El BCE: una sola petición a la vez ("single flight"), y si falla se
   sigue usando la última copia buena aunque sea vieja (mejor un cambio
   de ayer que ninguno). La app enseña la fecha.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from datetime import date
from typing import Protocol

from pydantic import BaseModel, ConfigDict, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import SingleFlight
from ai_orchestrator.fx.ecb import EcbError

log = logging.getLogger(__name__)

KEY = "ai:fx:v1:ecb"
SOURCE = "Banco Central Europeo (BCE)"


class FxRates(BaseModel):
    model_config = ConfigDict(frozen=True)

    base: str = "EUR"
    # El día de los tipos (el BCE no publica en fines de semana ni festivos).
    date: date
    # Unidades de cada moneda por 1 euro.
    rates: dict[str, float]
    source: str = SOURCE


class FxUnavailableError(Exception):
    """Ni hay copia guardada ni el BCE responde."""


class RatesSource(Protocol):
    async def latest(self) -> tuple[date, dict[str, float]]: ...


class RatesCache(Protocol):
    async def get(self) -> FxRates | None: ...

    async def put(self, rates: FxRates, *, ttl_seconds: int) -> None: ...


class RedisRatesCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self) -> FxRates | None:
        try:
            raw = await self._redis.get(KEY)
        except (RedisError, OSError):
            return None  # sin Redis seguimos con memoria y BCE
        if raw is None:
            return None
        try:
            return FxRates.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, rates: FxRates, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(KEY, rates.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            log.warning("no se pudo guardar el cambio en Redis", extra={"error": str(exc)})


class FxService:
    def __init__(
        self,
        *,
        source: RatesSource,
        cache: RatesCache,
        ttl_seconds: int = 6 * 3600,
        memory_seconds: float = 600,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._source = source
        self._cache = cache
        self._ttl = ttl_seconds
        self._memory_seconds = memory_seconds
        self._clock = clock
        self._memory: FxRates | None = None
        self._memory_at = 0.0
        self._flight: SingleFlight[FxRates] = SingleFlight()

    async def rates(self) -> FxRates:
        fresh = self._memory is not None and self._clock() - self._memory_at < self._memory_seconds
        if fresh and self._memory is not None:
            return self._memory
        cached = await self._cache.get()
        if cached is not None:
            return self._remember(cached)
        try:
            result, _ = await self._flight.do("ecb", self._fetch)
        except EcbError as exc:
            log.warning("BCE no disponible", extra={"error": str(exc)})
            if self._memory is not None:
                return self._memory  # la última buena, aunque sea vieja
            raise FxUnavailableError(str(exc)) from exc
        return self._remember(result)

    async def _fetch(self) -> FxRates:
        day, values = await self._source.latest()
        rates = FxRates(date=day, rates=dict(sorted(values.items())))
        await self._cache.put(rates, ttl_seconds=self._ttl)
        return rates

    def _remember(self, rates: FxRates) -> FxRates:
        self._memory = rates
        self._memory_at = self._clock()
        return rates
