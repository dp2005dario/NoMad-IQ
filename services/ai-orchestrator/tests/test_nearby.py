"""Tests de "Cerca de ti": Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.nearby.domain import Nearby
from ai_orchestrator.nearby.overpass import NearbyOverpass, build_query, parse_spot
from ai_orchestrator.nearby.service import NearbyService
from ai_orchestrator.places.wikimedia import RateLimiter


def node(oid: int, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": 40.4168, "lon": -3.7038, "tags": tags}


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            node(1, amenity="drinking_water"),
            node(2, amenity="toilets", fee="yes", opening_hours="Mo-Su 08:00-22:00"),
            node(3, internet_access="wlan", **{"internet_access:fee": "no"}, name="Wifi de la plaza"),
            node(4, amenity="device_charging_station"),
            node(5, tourism="viewpoint", name="Mirador", wikidata="Q123"),
            node(6, tourism="attraction"),  # sin nombre ni Wikidata: fuera
            node(7, shop="bakery"),  # no es de los nuestros: fuera
            node(1, amenity="drinking_water"),  # repetido
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"elements": self.rows})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, Nearby] = {}
        self.ttls: list[int] = []

    async def get(self, lat: float, lon: float) -> Nearby | None:
        return self.items.get(f"{lat:.2f}:{lon:.2f}")

    async def put(self, nearby: Nearby, *, ttl_seconds: int) -> None:
        self.items[f"{nearby.lat:.2f}:{nearby.lon:.2f}"] = nearby
        self.ttls.append(ttl_seconds)


def service(fake: FakeOverpass) -> tuple[NearbyService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    source = NearbyOverpass(http, limiter=RateLimiter(1000, 1000), url="https://overpass.test/api")
    cache = MemoryCache()
    return NearbyService(source=source, cache=cache), cache


def test_query_has_fixed_numbers_and_all_kinds() -> None:
    q = build_query(40.4, -3.71, 40.43, -3.69)
    assert "40.40000,-3.71000,40.43000,-3.69000" in q
    for kind in ("drinking_water", "toilets", "wlan", "device_charging_station", "viewpoint"):
        assert kind in q


def test_parse_spot_kinds() -> None:
    wifi = parse_spot(node(3, internet_access="wlan", **{"internet_access:fee": "no"}))
    assert wifi is not None and wifi.kind == "wifi"
    paid_wifi = parse_spot(node(3, internet_access="wlan", **{"internet_access:fee": "yes"}))
    assert paid_wifi is None
    sight = parse_spot(node(5, historic="castle", name="Castillo", wikidata="Q9"))
    assert sight is not None and sight.kind == "sight" and sight.wikidata_id == "Q9"
    assert parse_spot(node(5, historic="castle", name="Castillo", wikidata="nope")) is None


async def test_one_overpass_call_per_cell_for_a_week() -> None:
    fake = FakeOverpass()
    svc, cache = service(fake)
    # Varios turistas a la vez en la misma casilla: UNA pregunta.
    results = await asyncio.gather(*(svc.near(40.4168, -3.7038) for _ in range(5)))
    await svc.near(40.4171, -3.7041)
    assert len(fake.requests) == 1
    kinds = [s.kind for s in results[0].spots]
    assert kinds == ["water", "toilets", "wifi", "charging", "sight"]
    assert results[0].spots[1].fee is True
    assert cache.ttls == [7 * 24 * 3600]
    # Se manda la casilla, no el punto exacto.
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    assert "40.4168" not in sent


def api(svc: NearbyService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), nearby=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_cached() -> None:
    svc, _ = service(FakeOverpass())
    async with api(svc) as client:
        ok = await client.get("/v1/nearby", params={"lat": 40.4168, "lon": -3.7038})
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=86400"
        body = ok.json()
        assert body["lat"] == 40.42 and body["attribution"].startswith("©")
        assert (await client.get("/v1/nearby", params={"lat": 99, "lon": 0})).status_code == 400


@pytest.mark.parametrize("status", [429, 504, 500])
async def test_api_says_busy_when_overpass_fails(status: int) -> None:
    fake = FakeOverpass()
    fake.status = status
    svc, _ = service(fake)
    async with api(svc) as client:
        resp = await client.get("/v1/nearby", params={"lat": 40.4, "lon": -3.7})
    assert resp.status_code == 503
    assert resp.headers["Retry-After"] == "60"
