"""Tests de la guía del aeropuerto: Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.airport_guide.domain import AirportGuide
from ai_orchestrator.airport_guide.overpass import AirportOverpass, build_query, parse_spot
from ai_orchestrator.airport_guide.service import AirportGuideService, UnknownAirportError
from ai_orchestrator.api import create_api
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.places.wikimedia import RateLimiter

AIRPORTS = Airports.parse("MAD|40.472|-3.563|Madrid|Spain|Europe/Madrid\n")


def node(oid: int, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": 40.49, "lon": -3.59, "tags": tags}


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            node(1, aeroway="gate", ref="K42", level="1"),
            node(2, aeroway="gate"),  # puerta sin número: fuera
            node(3, amenity="toilets"),
            node(4, amenity="cafe", name="Café  del  Sol"),
            node(5, amenity="restaurant"),
            node(6, tourism="information"),
            node(7, shop="clothes"),  # no es de los nuestros: fuera
            {"type": "way", "id": 8, "center": {"lat": 40.5, "lon": -3.6}, "tags": {"aeroway": "lounge"}},
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"elements": self.rows})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, AirportGuide] = {}
        self.ttls: list[int] = []

    async def get(self, iata: str) -> AirportGuide | None:
        return self.items.get(iata)

    async def put(self, guide: AirportGuide, *, ttl_seconds: int) -> None:
        self.items[guide.iata] = guide
        self.ttls.append(ttl_seconds)


def service(fake: FakeOverpass) -> tuple[AirportGuideService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    source = AirportOverpass(http, limiter=RateLimiter(1000, 1000), url="https://overpass.test/api")
    cache = MemoryCache()
    return AirportGuideService(source=source, cache=cache, airports=AIRPORTS), cache


def test_query_uses_the_airport_area_and_rejects_odd_codes() -> None:
    q = build_query("MAD")
    assert '["iata"="MAD"]' in q
    assert "map_to_area" in q
    assert "toilets" in q and "gate" in q
    with pytest.raises(ValueError):
        build_query('MAD"];out;')


def test_parse_spot_kinds() -> None:
    gate = parse_spot(node(1, aeroway="gate", ref="K42", level="1"))
    assert gate is not None and gate.kind == "gate" and gate.ref == "K42" and gate.level == "1"
    assert parse_spot(node(2, aeroway="gate")) is None
    food = parse_spot(node(5, amenity="fast_food", brand="Burger"))
    assert food is not None and food.kind == "food" and food.name == "Burger"
    assert parse_spot(node(7, shop="clothes")) is None


async def test_one_request_per_airport_and_cached_for_a_month() -> None:
    fake = FakeOverpass()
    svc, cache = service(fake)
    results = await asyncio.gather(*(svc.guide("mad") for _ in range(5)))
    await svc.guide("MAD")
    assert len(fake.requests) == 1
    kinds = [s.kind for s in results[0].spots]
    assert kinds == ["gate", "toilets", "cafe", "food", "info", "lounge"]
    assert results[0].spots[2].name == "Café del Sol"
    assert cache.ttls == [30 * 24 * 3600]
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    assert '"iata"="MAD"' in sent


async def test_empty_airport_is_cached_less_and_unknown_is_refused() -> None:
    fake = FakeOverpass()
    fake.rows = []
    svc, cache = service(fake)
    guide = await svc.guide("MAD")
    assert guide.spots == []
    assert cache.ttls == [7 * 24 * 3600]
    with pytest.raises(UnknownAirportError):
        await svc.guide("ZZZ")


def api(svc: AirportGuideService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), airport_guide=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_validates_the_code() -> None:
    svc, _ = service(FakeOverpass())
    async with api(svc) as client:
        ok = await client.get("/v1/airports/MAD/spots")
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=86400"
        body = ok.json()
        assert body["iata"] == "MAD"
        assert body["attribution"].startswith("©")
        assert (await client.get("/v1/airports/ZZZ/spots")).status_code == 404
        assert (await client.get("/v1/airports/MADRID/spots")).status_code in (400, 404, 422)


@pytest.mark.parametrize("status", [429, 504])
async def test_api_says_busy_when_overpass_pushes_back(status: int) -> None:
    fake = FakeOverpass()
    fake.status = status
    svc, _ = service(fake)
    async with api(svc) as client:
        resp = await client.get("/v1/airports/MAD/spots")
    assert resp.status_code == 503
    assert resp.headers["Retry-After"] == "60"
