"""Las dos fuentes de eventos, las dos gratis:

- Nager.Date (https://date.nager.at): festivos oficiales de ~100 países.
  Sin clave. Se pregunta UNA vez por país y año (un mes de caché).
- Ticketmaster Discovery API: conciertos, partidos, teatro... con fecha,
  sitio, web de entradas y el precio que publica el organizador. Clave
  gratis (TICKETMASTER_API_KEY) con un cupo diario: si no hay clave, esta
  parte se apaga y la app enseña solo los festivos.

La clave de Ticketmaster va en la URL porque así lo exige su API. Por eso
NUNCA se escribe la URL en los logs ni en los errores (solo el tipo de
error).
"""

from __future__ import annotations

import re
from datetime import date, datetime, time, timedelta
from typing import Any

import httpx

from ai_orchestrator.city_events.domain import CityEvent, EventKind
from ai_orchestrator.places.wikimedia import RateLimiter

NAGER_URL = "https://date.nager.at/api/v3/PublicHolidays"
TICKETMASTER_URL = "https://app.ticketmaster.com/discovery/v2/events.json"
USER_AGENT = "NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)"
# Radio alrededor del aeropuerto: suele estar a pocos km de la ciudad, y
# 30 km cubren la ciudad y sus alrededores.
RADIUS_KM = 30
MAX_EVENTS = 100

_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d")
_CURRENCY = re.compile(r"^[A-Z]{3}$")


class SourceBusyError(Exception):
    """La fuente pide que esperemos (o hemos llegado a nuestro límite)."""


class SourceError(Exception):
    """La fuente no responde o responde algo raro."""


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    clean = " ".join(value.split())
    return clean[:limit] or None


def _day(value: Any) -> date | None:
    if not isinstance(value, str):
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


def parse_holidays(rows: Any) -> list[CityEvent]:
    """La respuesta de Nager.Date: una lista de festivos."""
    if not isinstance(rows, list):
        raise SourceError("respuesta de Nager.Date que no es una lista")
    out: list[CityEvent] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        day = _day(row.get("date"))
        # El nombre en el idioma del país ("Dia de Portugal") y, si no, en inglés.
        name = _text(row.get("localName"), 120) or _text(row.get("name"), 120)
        if day is None or name is None:
            continue
        out.append(
            CityEvent(
                id=f"h-{day.isoformat()}-{len(out)}",
                kind="holiday",
                name=name,
                date=day,
                regional=row.get("global") is False,
            )
        )
    return out


_SEGMENTS: dict[str, EventKind] = {
    "Music": "music",
    "Sports": "sports",
    "Arts & Theatre": "arts",
    "Family": "family",
}


def _first(items: Any) -> dict[str, Any]:
    if isinstance(items, list) and items and isinstance(items[0], dict):
        return items[0]
    return {}


def parse_ticketmaster(data: Any) -> list[CityEvent]:
    """La respuesta de Ticketmaster (``_embedded.events``)."""
    if not isinstance(data, dict):
        raise SourceError("respuesta de Ticketmaster que no es un objeto")
    embedded = data.get("_embedded")
    # Sin "_embedded" = no hay eventos (no es un error).
    rows = embedded.get("events") if isinstance(embedded, dict) else []
    if not isinstance(rows, list):
        return []
    out: list[CityEvent] = []
    seen: set[str] = set()
    for row in rows[:MAX_EVENTS]:
        if not isinstance(row, dict):
            continue
        eid, name = _text(row.get("id"), 40), _text(row.get("name"), 120)
        dates = row.get("dates")
        start = dates.get("start") if isinstance(dates, dict) else None
        day = _day(start.get("localDate")) if isinstance(start, dict) else None
        if eid is None or name is None or day is None or eid in seen:
            continue
        seen.add(eid)
        raw_time = start.get("localTime") if isinstance(start, dict) else None
        hhmm = raw_time[:5] if isinstance(raw_time, str) and _TIME.match(raw_time) else None
        segment = _first(row.get("classifications")).get("segment")
        kind = _SEGMENTS.get(segment.get("name", "") if isinstance(segment, dict) else "", "other")
        venues = row.get("_embedded")
        venue = _text(_first(venues.get("venues") if isinstance(venues, dict) else None).get("name"), 80)
        url = row.get("url")
        price = _first(row.get("priceRanges"))
        lo, hi, cur = price.get("min"), price.get("max"), price.get("currency")
        low = float(lo) if isinstance(lo, int | float) and not isinstance(lo, bool) and lo >= 0 else None
        high = float(hi) if isinstance(hi, int | float) and not isinstance(hi, bool) and hi >= 0 else None
        has_price = low is not None and isinstance(cur, str) and _CURRENCY.match(cur) is not None
        out.append(
            CityEvent(
                id=f"t-{eid}",
                kind=kind,
                name=name,
                date=day,
                time=hhmm,
                venue=venue,
                url=url if isinstance(url, str) and url.startswith("https://") and len(url) < 500 else None,
                price_min=low if has_price else None,
                price_max=high if has_price else None,
                currency=cur if has_price else None,
            )
        )
    return out


async def _get_json(http: httpx.AsyncClient, url: str, params: dict[str, str] | None, who: str) -> Any:
    try:
        resp = await http.get(
            url, params=params, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}
        )
    except httpx.HTTPError as exc:
        # Solo el tipo: el mensaje llevaría la URL (con la clave de Ticketmaster).
        raise SourceError(f"{type(exc).__name__} al llamar a {who}") from exc
    if resp.status_code in (429, 503, 504):
        raise SourceBusyError(f"{who} respondió {resp.status_code}")
    if resp.status_code in (204, 404):
        # Nager.Date: país sin datos. Se guarda como "sin festivos".
        return []
    if resp.status_code != 200:
        raise SourceError(f"{who} respondió {resp.status_code}")
    try:
        return resp.json()
    except ValueError as exc:
        raise SourceError(f"respuesta de {who} que no es JSON") from exc


class NagerClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str = NAGER_URL,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._url = url.rstrip("/")
        self._max_wait = max_wait_seconds

    async def holidays(self, year: int, country: str) -> list[CityEvent]:
        if not (2000 <= year <= 2100) or not re.fullmatch(r"[A-Z]{2}", country):
            raise ValueError("año o país no válido")
        await self._limiter.acquire(self._max_wait)
        return parse_holidays(
            await _get_json(self._http, f"{self._url}/{year}/{country}", None, "Nager.Date")
        )


class TicketmasterClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        api_key: str,
        limiter: RateLimiter,
        url: str = TICKETMASTER_URL,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._key = api_key
        self._limiter = limiter
        self._url = url
        self._max_wait = max_wait_seconds

    async def events(self, lat: float, lon: float, start: date, end: date) -> list[CityEvent]:
        await self._limiter.acquire(self._max_wait)
        begin = datetime.combine(start, time(0, 0))
        finish = datetime.combine(end + timedelta(days=1), time(0, 0))
        data = await _get_json(
            self._http,
            self._url,
            {
                "apikey": self._key,
                "latlong": f"{lat:.2f},{lon:.2f}",
                "radius": str(RADIUS_KM),
                "unit": "km",
                "startDateTime": begin.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "endDateTime": finish.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "size": str(MAX_EVENTS),
                "sort": "date,asc",
                "locale": "*",
            },
            "Ticketmaster",
        )
        return parse_ticketmaster(data)
