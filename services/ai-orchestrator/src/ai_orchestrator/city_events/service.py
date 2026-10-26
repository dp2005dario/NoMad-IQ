"""Qué pasa en tus fechas: festivos + eventos, con caché para miles de usuarios.

1. Festivos: Redis por país y año (``ai:events:v1:hol:ES:2026``), un mes.
   Un país tiene los mismos festivos para todos: ~100 países x 2 años =
   unas 200 preguntas a Nager.Date al mes, como mucho.
2. Eventos: Redis por aeropuerto y MES (``ai:events:v1:tm:LIS:2026-06``),
   12 horas. Se pide el mes entero y se recorta a tus fechas: así las
   claves posibles son pocas (aeropuertos x 13 meses), no una por cada
   combinación de fechas que alguien pueda inventar.
3. Un tope diario de preguntas a Ticketmaster (su cupo gratis): si se
   acaba, la respuesta sale solo con festivos (y lo dice en ``sources``).
4. Si una fuente falla, se devuelve lo de la otra: nunca un error por
   culpa de un festivo.
"""

from __future__ import annotations

import functools
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Protocol

from pydantic import TypeAdapter, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.city_events.domain import HORIZON_DAYS, MAX_DAYS, CityEvent, CityEvents
from ai_orchestrator.city_events.sources import SourceBusyError, SourceError
from ai_orchestrator.places.airports import Airports

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:events:v1"
_LIST = TypeAdapter(list[CityEvent])

SOURCE_HOLIDAYS = "Nager.Date"
SOURCE_TICKETMASTER = "Ticketmaster"


class HolidaySource(Protocol):
    async def holidays(self, year: int, country: str) -> list[CityEvent]: ...


class EventSource(Protocol):
    async def events(self, lat: float, lon: float, start: date, end: date) -> list[CityEvent]: ...


class EventCache(Protocol):
    async def get(self, key: str) -> list[CityEvent] | None: ...

    async def put(self, key: str, events: list[CityEvent], *, ttl_seconds: int) -> None: ...

    async def count_today(self, key: str, today: date) -> int:
        """Suma 1 al contador de hoy y devuelve el total."""
        ...


class RedisEventCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, key: str) -> list[CityEvent] | None:
        try:
            raw = await self._redis.get(f"{KEY_PREFIX}:{key}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer eventos de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return _LIST.validate_json(raw)
        except ValidationError:
            return None

    async def put(self, key: str, events: list[CityEvent], *, ttl_seconds: int) -> None:
        payload = json.dumps([e.model_dump(mode="json") for e in events])
        try:
            await self._redis.set(f"{KEY_PREFIX}:{key}", payload, ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar eventos en Redis: {exc}") from exc

    async def count_today(self, key: str, today: date) -> int:
        name = f"{KEY_PREFIX}:{key}:{today.isoformat()}"
        try:
            pipe = self._redis.pipeline()
            pipe.incr(name)
            pipe.expire(name, 2 * 24 * 3600)
            value, _ = await pipe.execute()
        except (RedisError, OSError) as exc:
            raise CacheError(f"contar eventos en Redis: {exc}") from exc
        return int(value)


class UnknownAirportError(Exception):
    """Ese código no está en nuestra lista de aeropuertos."""


class BadDatesError(Exception):
    """Fechas al revés, más de un mes o demasiado lejos."""


@dataclass(frozen=True, slots=True)
class EventSettings:
    holidays_ttl_seconds: int = 30 * 24 * 3600
    events_ttl_seconds: int = 12 * 3600
    # El cupo gratis de Ticketmaster es mayor; se deja margen.
    ticketmaster_daily_limit: int = 4000


def _months(start: date, end: date) -> list[date]:
    """El primer día de cada mes que toca el rango (como mucho dos)."""
    out: list[date] = []
    cur = start.replace(day=1)
    while cur <= end:
        out.append(cur)
        cur = (cur + timedelta(days=32)).replace(day=1)
    return out


def _month_end(first: date) -> date:
    return (first + timedelta(days=32)).replace(day=1) - timedelta(days=1)


class CityEventService:
    def __init__(
        self,
        *,
        airports: Airports,
        countries: dict[str, str],
        holidays: HolidaySource,
        cache: EventCache,
        tickets: EventSource | None = None,
        settings: EventSettings | None = None,
    ) -> None:
        self._airports = airports
        self._countries = countries
        self._holidays = holidays
        self._tickets = tickets
        self._cache = cache
        self._settings = settings or EventSettings()
        self._flight: SingleFlight[list[CityEvent]] = SingleFlight()

    async def between(self, iata: str, start: date, end: date, *, today: date) -> CityEvents:
        airport = self._airports.get(iata)
        if airport is None:
            raise UnknownAirportError(iata)
        if end < start or (end - start).days >= MAX_DAYS:
            raise BadDatesError("como mucho un mes")
        if end < today - timedelta(days=1) or start > today + timedelta(days=HORIZON_DAYS):
            raise BadDatesError("fuera del año que viene")
        country = self._countries.get(airport.country)
        events: list[CityEvent] = []
        sources: list[str] = []
        if country is not None:
            got = await self._safe(lambda: self._holidays_between(country, start, end))
            if got is not None:
                events += got
                sources.append(SOURCE_HOLIDAYS)
        tickets = self._tickets
        if tickets is not None:
            got = await self._safe(
                lambda: self._tickets_between(
                    tickets, airport.iata, airport.lat, airport.lon, start, end, today
                )
            )
            if got is not None:
                events += got
                sources.append(SOURCE_TICKETMASTER)
        events.sort(key=lambda e: (e.date, e.kind != "holiday", e.time or "99:99", e.name))
        return CityEvents(
            iata=airport.iata,
            city=airport.city,
            country=country,
            start=start,
            end=end,
            events=events,
            sources=sources,
        )

    async def _safe(self, fn: Callable[[], Awaitable[list[CityEvent]]]) -> list[CityEvent] | None:
        """Una fuente que falla no tumba la respuesta: se registra y sigue."""
        try:
            return await fn()
        except (SourceError, SourceBusyError, CacheError, _OverBudgetError) as exc:
            log.warning("fuente de eventos no disponible", extra={"error": str(exc)})
            return None

    async def _cached(
        self, key: str, ttl: int, build: Callable[[], Awaitable[list[CityEvent]]]
    ) -> list[CityEvent]:
        found = await self._cache.get(key)
        if found is not None:
            return found

        async def load() -> list[CityEvent]:
            fresh = await build()
            await self._cache.put(key, fresh, ttl_seconds=ttl)
            return fresh

        result, _ = await self._flight.do(key, load)
        return result

    async def _holidays_between(self, country: str, start: date, end: date) -> list[CityEvent]:
        out: list[CityEvent] = []
        for year in sorted({start.year, end.year}):
            rows = await self._cached(
                f"hol:{country}:{year}",
                self._settings.holidays_ttl_seconds,
                functools.partial(self._holidays.holidays, year, country),
            )
            out += [e for e in rows if start <= e.date <= end]
        return out

    async def _tickets_between(
        self, tickets: EventSource, iata: str, lat: float, lon: float, start: date, end: date, today: date
    ) -> list[CityEvent]:
        out: list[CityEvent] = []
        for first in _months(start, end):
            # Del mes, solo lo que queda desde hoy (lo pasado ya no se vende).
            begin = max(first, today)
            finish = _month_end(first)
            if finish < begin:
                continue

            async def fetch(b: date = begin, f: date = finish) -> list[CityEvent]:
                if await self._cache.count_today("tmday", today) > self._settings.ticketmaster_daily_limit:
                    raise _OverBudgetError("cupo diario de Ticketmaster agotado")
                return await tickets.events(lat, lon, b, f)

            rows = await self._cached(f"tm:{iata}:{first:%Y-%m}", self._settings.events_ttl_seconds, fetch)
            out += [e for e in rows if start <= e.date <= end]
        return out


class _OverBudgetError(Exception):
    pass
