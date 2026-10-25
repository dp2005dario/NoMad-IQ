"""¿Va a llover? La previsión de MET Norway (el servicio meteorológico de
Noruega), gratis para todo el mundo y también para apps comerciales, con
atribución (licencia CC BY 4.0).

    GET https://api.met.no/weatherapi/locationforecast/2.0/compact?lat&lon

Sus normas de uso, que cumplimos:
    - Identificarse con un User-Agent con contacto.
    - Como mucho 4 decimales en las coordenadas (nosotros mandamos 2: la
      casilla de ~5 km) y guardar la respuesta en caché.
    - No pasar de ~20 peticiones por segundo (nuestro límite es menor).

Se guarda en Redis por casilla 15 minutos: da igual cuánta gente mire la
misma zona, es una sola pregunta cada cuarto de hora.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Protocol

import httpx
from pydantic import BaseModel, ConfigDict, TypeAdapter, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.places.wikimedia import RateLimiter

log = logging.getLogger(__name__)

MET_URL = "https://api.met.no/weatherapi/locationforecast/2.0/compact"
USER_AGENT = "NomadIQ/1.0 https://github.com/dp2005dario/NoMad-IQ"
ATTRIBUTION = "Data from MET Norway (CC BY 4.0)"
CELL = 0.05
HOURS = 6
KEY_PREFIX = "ai:rain:v1"


class RainHour(BaseModel):
    model_config = ConfigDict(frozen=True)

    time: datetime
    # Lluvia prevista en esa hora (mm) y temperatura (°C).
    rain_mm: float
    temp_c: float | None = None
    # El icono de MET ("rain", "partlycloudy_day"...).
    symbol: str | None = None


class RainForecast(BaseModel):
    model_config = ConfigDict(frozen=True)

    lat: float
    lon: float
    hours: list[RainHour]
    attribution: str = ATTRIBUTION


_HOURS = TypeAdapter(list[RainHour])


class RainBusyError(Exception):
    pass


class RainError(Exception):
    pass


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    return round(round(lat / CELL) * CELL, 2), round(round(lon / CELL) * CELL, 2)


def _num(value: Any) -> float | None:
    return float(value) if isinstance(value, int | float) and not isinstance(value, bool) else None


def parse_forecast(data: Any) -> list[RainHour]:
    props = data.get("properties") if isinstance(data, dict) else None
    series = props.get("timeseries") if isinstance(props, dict) else None
    if not isinstance(series, list):
        raise RainError("respuesta de MET sin timeseries")
    out: list[RainHour] = []
    for row in series:
        if len(out) >= HOURS:
            break
        if not isinstance(row, dict) or not isinstance(row.get("time"), str):
            continue
        d = row.get("data")
        nxt = d.get("next_1_hours") if isinstance(d, dict) else None
        if not isinstance(nxt, dict):
            continue
        details = nxt.get("details")
        rain = _num(details.get("precipitation_amount")) if isinstance(details, dict) else None
        if rain is None or not 0 <= rain < 500:
            continue
        instant = d.get("instant") if isinstance(d, dict) else None
        inst = instant.get("details") if isinstance(instant, dict) else None
        summary = nxt.get("summary")
        symbol = summary.get("symbol_code") if isinstance(summary, dict) else None
        try:
            when = datetime.fromisoformat(row["time"].replace("Z", "+00:00"))
        except ValueError:
            continue
        out.append(
            RainHour(
                time=when,
                rain_mm=rain,
                temp_c=_num(inst.get("air_temperature")) if isinstance(inst, dict) else None,
                symbol=symbol if isinstance(symbol, str) and len(symbol) < 40 else None,
            )
        )
    return out


class MetClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str = MET_URL,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._url = url
        self._max_wait = max_wait_seconds

    async def forecast(self, lat: float, lon: float) -> list[RainHour]:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.get(
                self._url,
                params={"lat": f"{lat:.2f}", "lon": f"{lon:.2f}"},
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
        except httpx.HTTPError as exc:
            raise RainError(f"{type(exc).__name__} al llamar a MET") from exc
        if resp.status_code in (429, 503, 504):
            raise RainBusyError(f"MET respondió {resp.status_code}")
        if resp.status_code != 200:
            raise RainError(f"MET respondió {resp.status_code}")
        try:
            return parse_forecast(resp.json())
        except ValueError as exc:
            raise RainError("respuesta de MET que no es JSON") from exc


class RainSource(Protocol):
    async def forecast(self, lat: float, lon: float) -> list[RainHour]: ...


class RainCache(Protocol):
    async def get(self, lat: float, lon: float) -> list[RainHour] | None: ...

    async def put(self, lat: float, lon: float, hours: list[RainHour], *, ttl_seconds: int) -> None: ...


class RedisRainCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @staticmethod
    def _key(lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{lat:.2f}:{lon:.2f}"

    async def get(self, lat: float, lon: float) -> list[RainHour] | None:
        try:
            raw = await self._redis.get(self._key(lat, lon))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer lluvia de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return _HOURS.validate_json(raw)
        except ValidationError:
            return None

    async def put(self, lat: float, lon: float, hours: list[RainHour], *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(self._key(lat, lon), _HOURS.dump_json(hours), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar lluvia en Redis: {exc}") from exc


class RainService:
    def __init__(self, *, source: RainSource, cache: RainCache, ttl_seconds: int = 15 * 60) -> None:
        self._source = source
        self._cache = cache
        self._ttl = ttl_seconds
        self._flight: SingleFlight[list[RainHour]] = SingleFlight()

    async def at(self, lat: float, lon: float) -> RainForecast:
        c_lat, c_lon = cell_of(lat, lon)
        hours = await self._cache.get(c_lat, c_lon)
        if hours is None:

            async def load() -> list[RainHour]:
                fresh = await self._source.forecast(c_lat, c_lon)
                await self._cache.put(c_lat, c_lon, fresh, ttl_seconds=self._ttl)
                return fresh

            hours, _ = await self._flight.do(f"{c_lat:.2f}:{c_lon:.2f}", load)
        return RainForecast(lat=c_lat, lon=c_lon, hours=hours)
