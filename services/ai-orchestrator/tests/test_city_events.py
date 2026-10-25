"""Tests de "Qué pasa en tus fechas": Nager.Date y Ticketmaster de mentira."""

from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime, timedelta
from typing import Any

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.city_events.domain import CityEvent
from ai_orchestrator.city_events.service import (
    BadDatesError,
    CityEventService,
    EventSettings,
    UnknownAirportError,
)
from ai_orchestrator.city_events.sources import (
    NagerClient,
    TicketmasterClient,
    parse_holidays,
    parse_ticketmaster,
)
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.places.countries import bundled_countries, parse_countries
from ai_orchestrator.places.wikimedia import RateLimiter

AIRPORTS = Airports.parse("LIS|38.774|-9.134|Lisbon|Portugal|Europe/Lisbon\nXXX|1|1|Nowhere|Atlantis|UTC\n")
COUNTRIES = parse_countries("Portugal|PT\n")
TODAY = date(2026, 6, 1)

HOLIDAYS = [
    {"date": "2026-06-10", "localName": "Dia de Portugal", "name": "Portugal Day", "global": True},
    {"date": "2026-06-13", "localName": "Santo António", "name": "St Anthony", "global": False},
    {"date": "2026-12-25", "localName": "Natal", "name": "Christmas", "global": True},
    {"date": "mal", "localName": "x"},
]


def tm_event(eid: str, day: str, **extra: Any) -> dict[str, Any]:
    return {
        "id": eid,
        "name": f"Concierto {eid}",
        "url": f"https://www.ticketmaster.pt/event/{eid}",
        "dates": {"start": {"localDate": day, "localTime": "21:00:00"}},
        "classifications": [{"segment": {"name": "Music"}}],
        "_embedded": {"venues": [{"name": "Altice Arena"}]},
        **extra,
    }


class Fake:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.tm_status = 200
        self.tm_events = [
            tm_event("a", "2026-06-11", priceRanges=[{"min": 45, "max": 90, "currency": "EUR"}]),
            tm_event("b", "2026-06-20"),
            tm_event("a", "2026-06-11"),  # repetido: fuera
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.host == "nager.test":
            return httpx.Response(200, json=HOLIDAYS)
        if self.tm_status != 200:
            return httpx.Response(self.tm_status)
        return httpx.Response(200, json={"_embedded": {"events": self.tm_events}})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, list[CityEvent]] = {}
        self.ttls: dict[str, int] = {}
        self.counts: dict[str, int] = {}

    async def get(self, key: str) -> list[CityEvent] | None:
        return self.items.get(key)

    async def put(self, key: str, events: list[CityEvent], *, ttl_seconds: int) -> None:
        self.items[key] = events
        self.ttls[key] = ttl_seconds

    async def count_today(self, key: str, today: date) -> int:
        name = f"{key}:{today}"
        self.counts[name] = self.counts.get(name, 0) + 1
        return self.counts[name]


def service(fake: Fake, *, with_key: bool = True, limit: int = 4000) -> tuple[CityEventService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    cache = MemoryCache()
    svc = CityEventService(
        airports=AIRPORTS,
        countries=COUNTRIES,
        holidays=NagerClient(
            http, limiter=RateLimiter(1000, 1000), url="https://nager.test/api/v3/PublicHolidays"
        ),
        tickets=TicketmasterClient(
            http, api_key="SECRETO", limiter=RateLimiter(1000, 1000), url="https://tm.test/events.json"
        )
        if with_key
        else None,
        cache=cache,
        settings=EventSettings(ticketmaster_daily_limit=limit),
    )
    return svc, cache


def test_parsers_keep_only_real_fields() -> None:
    hol = parse_holidays(HOLIDAYS)
    assert [h.name for h in hol] == ["Dia de Portugal", "Santo António", "Natal"]
    assert hol[1].regional and not hol[0].regional
    ev = parse_ticketmaster({"_embedded": {"events": Fake().tm_events}})
    assert [e.id for e in ev] == ["t-a", "t-b"]
    assert ev[0].kind == "music" and ev[0].time == "21:00" and ev[0].venue == "Altice Arena"
    assert (ev[0].price_min, ev[0].price_max, ev[0].currency) == (45, 90, "EUR")
    # Sin precio publicado: sin precio (nunca uno estimado).
    assert ev[1].price_min is None and ev[1].currency is None
    bad = parse_ticketmaster(
        {"_embedded": {"events": [tm_event("c", "2026-06-12", url="javascript:alert(1)")]}}
    )
    assert bad[0].url is None
    assert parse_ticketmaster({}) == []


def test_bundled_countries_has_the_airport_names() -> None:
    codes = bundled_countries()
    assert codes["Portugal"] == "PT"
    assert codes["Spain"] == "ES"


async def test_holidays_and_events_in_your_dates_with_one_call_each() -> None:
    fake = Fake()
    svc, cache = service(fake)
    results = await asyncio.gather(
        *(svc.between("LIS", date(2026, 6, 10), date(2026, 6, 14), today=TODAY) for _ in range(4))
    )
    again = await svc.between("LIS", date(2026, 6, 9), date(2026, 6, 13), today=TODAY)
    found = results[0]
    assert found.country == "PT" and found.city == "Lisbon"
    assert [e.name for e in found.events] == ["Dia de Portugal", "Concierto a", "Santo António"]
    assert found.sources == ["Nager.Date", "Ticketmaster"]
    assert [e.name for e in again.events] == ["Dia de Portugal", "Concierto a", "Santo António"]
    # Una pregunta a cada fuente: festivos del año y eventos del MES.
    assert len(fake.requests) == 2
    assert cache.ttls == {"hol:PT:2026": 30 * 24 * 3600, "tm:LIS:2026-06": 12 * 3600}
    tm = next(r for r in fake.requests if r.url.host == "tm.test")
    assert tm.url.params["latlong"] == "38.77,-9.13"
    assert tm.url.params["startDateTime"] == "2026-06-01T00:00:00Z"
    assert tm.url.params["endDateTime"] == "2026-07-01T00:00:00Z"


async def test_no_key_or_failures_still_answer_with_what_there_is() -> None:
    fake = Fake()
    svc, _ = service(fake, with_key=False)
    found = await svc.between("LIS", date(2026, 6, 10), date(2026, 6, 14), today=TODAY)
    assert found.sources == ["Nager.Date"]
    assert all(e.kind == "holiday" for e in found.events)

    fake = Fake()
    fake.tm_status = 429
    svc, _ = service(fake)
    found = await svc.between("LIS", date(2026, 6, 10), date(2026, 6, 14), today=TODAY)
    assert found.sources == ["Nager.Date"]


async def test_daily_ticketmaster_budget() -> None:
    fake = Fake()
    svc, _ = service(fake, limit=1)
    await svc.between("LIS", date(2026, 6, 10), date(2026, 6, 14), today=TODAY)
    found = await svc.between("LIS", date(2026, 7, 10), date(2026, 7, 14), today=TODAY)
    # El segundo mes ya no se pregunta: el cupo de hoy está gastado.
    assert found.sources == ["Nager.Date"]
    assert sum(1 for r in fake.requests if r.url.host == "tm.test") == 1


async def test_dates_are_checked() -> None:
    svc, _ = service(Fake())
    with pytest.raises(BadDatesError):
        await svc.between("LIS", date(2026, 6, 14), date(2026, 6, 10), today=TODAY)
    with pytest.raises(BadDatesError):
        await svc.between("LIS", date(2026, 6, 1), date(2026, 7, 15), today=TODAY)
    with pytest.raises(BadDatesError):
        await svc.between("LIS", date(2028, 6, 1), date(2028, 6, 5), today=TODAY)
    with pytest.raises(UnknownAirportError):
        await svc.between("ZZZ", date(2026, 6, 10), date(2026, 6, 14), today=TODAY)
    # Un país que no está en la tabla: sin festivos, pero sin error.
    found = await svc.between("XXX", date(2026, 6, 10), date(2026, 6, 14), today=TODAY)
    assert "Nager.Date" not in found.sources


async def test_api_is_public() -> None:
    svc, _ = service(Fake())
    app = create_api(InMemoryStore(), city_events=svc)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        soon = datetime.now(UTC).date() + timedelta(days=10)
        ok = await client.get(
            "/v1/events",
            params={"iata": "lis", "from": soon.isoformat(), "to": (soon + timedelta(days=3)).isoformat()},
        )
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=3600"
        assert ok.json()["iata"] == "LIS"
        bad = await client.get("/v1/events", params={"iata": "LIS", "from": "2026-06-14", "to": "2026-06-10"})
        assert bad.status_code == 400
        assert (
            await client.get("/v1/events", params={"iata": "ZZZ", "from": "2026-06-10", "to": "2026-06-14"})
        ).status_code in (400, 404)
        assert (
            await client.get(
                "/v1/events", params={"iata": "LISBOA", "from": "2026-06-10", "to": "2026-06-14"}
            )
        ).status_code in (400, 422)
