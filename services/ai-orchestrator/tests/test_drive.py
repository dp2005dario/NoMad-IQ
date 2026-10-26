"""Tests del modo coche: Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.drive.domain import DriveArea, cell_of
from ai_orchestrator.drive.overpass import DriveOverpass, build_query, parse_spot
from ai_orchestrator.drive.service import DriveService
from ai_orchestrator.places.wikimedia import RateLimiter


def node(oid: int, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": 40.6281, "lon": 14.4850, "tags": tags}


def relation(oid: int, **tags: str) -> dict[str, Any]:
    return {"type": "relation", "id": oid, "center": {"lat": 40.63, "lon": 14.48}, "tags": tags}


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            node(1, amenity="fuel", brand="Esso", opening_hours="24/7"),
            node(2, amenity="parking", name="Parking Mandara", fee="yes", capacity="120"),
            node(3, amenity="charging_station", operator="Enel X", capacity="2"),
            relation(
                4,
                boundary="low_emission_zone",
                name="ZTL Positano",
                website="https://comune.positano.sa.it/ztl",
            ),
            relation(5, boundary="low_emission_zone"),  # sin nombre: fuera
            node(6, shop="bakery"),  # no es de los nuestros: fuera
            node(1, amenity="fuel"),  # repetido
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"elements": self.rows})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, DriveArea] = {}
        self.ttls: list[int] = []

    async def get(self, lat: float, lon: float) -> DriveArea | None:
        return self.items.get(f"{lat:.2f}:{lon:.2f}")

    async def put(self, area: DriveArea, *, ttl_seconds: int) -> None:
        self.items[f"{area.lat:.2f}:{area.lon:.2f}"] = area
        self.ttls.append(ttl_seconds)


def service(fake: FakeOverpass) -> DriveService:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    source = DriveOverpass(http, limiter=RateLimiter(1000, 1000), url="https://overpass.test/api")
    return DriveService(source=source, cache=MemoryCache())


def test_cells_are_five_km() -> None:
    assert cell_of(40.6281, 14.4850) == (40.65, 14.5)
    assert cell_of(40.61, 14.49) == cell_of(40.62, 14.51)


def test_query_has_each_kind_with_its_own_limit() -> None:
    q = build_query(40.55, 14.4, 40.7, 14.55)
    assert "40.55000,14.40000,40.70000,14.55000" in q
    assert q.count("out center") == 4
    for kind in ("fuel", "parking", "charging_station", "low_emission_zone"):
        assert kind in q


def test_parse_spot_details() -> None:
    fuel = parse_spot(node(1, amenity="fuel", operator="Q8"))
    assert fuel is not None and fuel.brand == "Q8" and fuel.capacity is None
    park = parse_spot(node(2, amenity="parking", capacity="lots"))
    assert park is not None and park.capacity is None
    bad_web = parse_spot(relation(4, boundary="low_emission_zone", name="ZBE", website="javascript:alert(1)"))
    assert bad_web is not None and bad_web.website is None
    http_web = parse_spot(relation(4, boundary="low_emission_zone", name="ZBE", website="http://x.example"))
    assert http_web is not None and http_web.website is None


async def test_one_overpass_call_per_cell() -> None:
    fake = FakeOverpass()
    svc = service(fake)
    results = await asyncio.gather(*(svc.around(40.6281, 14.4850) for _ in range(5)))
    # 2 km más allá, la misma casilla: sin nueva pregunta.
    await svc.around(40.64, 14.49)
    assert len(fake.requests) == 1
    spots = results[0].spots
    assert [s.kind for s in spots] == ["fuel", "parking", "ev", "lez"]
    assert spots[0].brand == "Esso"
    assert spots[1].fee is True and spots[1].capacity == 120
    assert spots[3].website == "https://comune.positano.sa.it/ztl"
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    assert "40.6281" not in sent


async def test_api_is_public_cached_and_degrades() -> None:
    fake = FakeOverpass()
    app = create_api(InMemoryStore(), drive=service(fake))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        ok = await client.get("/v1/drive", params={"lat": 40.6281, "lon": 14.4850})
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=86400"
        assert ok.json()["lat"] == 40.65
        assert (await client.get("/v1/drive", params={"lat": 99, "lon": 0})).status_code == 400


@pytest.mark.parametrize("status", [429, 504, 500])
async def test_api_says_busy_when_overpass_fails(status: int) -> None:
    fake = FakeOverpass()
    fake.status = status
    app = create_api(InMemoryStore(), drive=service(fake))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        resp = await client.get("/v1/drive", params={"lat": 40.4, "lon": -3.7})
    assert resp.status_code == 503
    assert resp.headers["Retry-After"] == "60"
