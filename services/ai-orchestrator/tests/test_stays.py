"""Tests de "Dormir barato": Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.stays.domain import (
    Lodging,
    Station,
    StayArea,
    build_zones,
    cell_of,
    km_between,
    minutes_for,
)
from ai_orchestrator.stays.overpass import StayOverpass, build_query, parse
from ai_orchestrator.stays.service import StayService

# Disneyland París (más o menos) y estaciones del RER A hacia París.
PARK = (48.8722, 2.7758)
VAL = (48.8530, 2.7830)  # Val d'Europe, ~2,2 km
BUSSY = (48.8370, 2.7040)  # Bussy-Saint-Georges, ~6 km
TORCY = (48.8500, 2.6500)  # Torcy, ~9,5 km
NATION = (48.8484, 2.3958)  # París Nation, ~28 km


def lodging(i: int, at: tuple[float, float], kind: str = "hotel", name: str | None = None) -> Lodging:
    return Lodging(id=f"n{i}", lat=at[0] + i * 1e-4, lon=at[1], name=name or f"Hotel {i}", kind=kind)


def test_distances_and_minutes() -> None:
    assert 27 < km_between(*PARK, *NATION) < 30
    assert minutes_for(1.0, "walk") == 12
    assert minutes_for(10.0, "train") == 22
    assert cell_of(48.8722, 2.7758) == (48.88, 2.78)


def test_zones_by_ring_without_repeating_the_same_area() -> None:
    stations = [
        Station(id="n100", lat=VAL[0], lon=VAL[1], name="Val d'Europe"),
        # A 300 m de Val d'Europe: es el mismo barrio, no sale dos veces.
        Station(id="n101", lat=VAL[0] + 0.003, lon=VAL[1], name="Serris-Montévrain"),
        Station(id="n102", lat=BUSSY[0], lon=BUSSY[1], name="Bussy-Saint-Georges"),
        Station(id="n103", lat=TORCY[0], lon=TORCY[1], name="Torcy"),
        Station(id="n104", lat=NATION[0], lon=NATION[1], name="Nation"),
        Station(id="n105", lat=48.95, lon=2.9, name="Sin hoteles"),
    ]
    lodgings = (
        [lodging(i, PARK) for i in range(3)]
        + [lodging(10 + i, VAL) for i in range(4)]
        + [lodging(20 + i, BUSSY, kind="guest_house") for i in range(2)]
        + [lodging(30, TORCY)]  # solo uno: no es zona
        + [lodging(40 + i, NATION, kind="hostel") for i in range(6)]
    )
    zones = build_zones(*PARK, stations, lodgings)
    # Val d'Europe y Serris están a 300 m: sale una sola (con el mismo empate
    # de alojamientos, la más cercana al sitio).
    assert [z.id for z in zones] == ["walk", "n101", "n102", "n104"]
    walk, val, bussy, nation = zones
    assert walk.by == "walk" and walk.lodgings == 3 and walk.name is None
    assert val.by == "train" and val.lodgings == 4 and val.name == "Serris-Montévrain"
    assert bussy.budget == 2
    assert nation.km > 25 and nation.budget == 6 and len(nation.examples) == 3


def row(oid: int, lat: float, lon: float, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": lat, "lon": lon, "tags": tags}


def test_parse_keeps_only_ours() -> None:
    stations, lodgings = parse(
        [
            row(1, *VAL, railway="station", name="Val d'Europe"),
            row(2, *VAL, railway="station"),  # sin nombre: fuera
            row(3, *VAL, tourism="hostel", name="  Hostal\nNation ", stars="3S"),
            row(3, *VAL, tourism="hostel"),  # repetido
            row(4, *VAL, tourism="museum", name="Museo"),
            {"type": "way", "id": 5, "center": {"lat": 48.0, "lon": 2.0}, "tags": {"tourism": "hotel"}},
            {"type": "node", "id": -1, "lat": 0, "lon": 0, "tags": {"tourism": "hotel"}},
            "basura",
        ]
    )
    assert [s.name for s in stations] == ["Val d'Europe"]
    assert {x.id for x in lodgings} == {"n3", "w5"}
    hostel = next(x for x in lodgings if x.id == "n3")
    assert hostel.name == "Hostal Nation" and hostel.stars == 3 and hostel.kind == "hostel"


def test_query_has_fixed_numbers() -> None:
    q = build_query(48.88, 2.78)
    assert "around:35000,48.88000,2.78000" in q
    assert "around.st:600" in q
    assert q.count("out center") == 2


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        rows = [row(100, *VAL, railway="station", name="Val d'Europe")] + [
            row(10 + i, VAL[0] + i * 1e-4, VAL[1], tourism="hotel", name=f"H{i}") for i in range(3)
        ]
        return httpx.Response(200, json={"elements": rows})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, StayArea] = {}

    async def get(self, lat: float, lon: float) -> StayArea | None:
        return self.items.get(f"{lat:.2f}:{lon:.2f}")

    async def put(self, area: StayArea, *, ttl_seconds: int) -> None:
        self.items[f"{area.lat:.2f}:{area.lon:.2f}"] = area


def service(fake: FakeOverpass) -> StayService:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    source = StayOverpass(http, limiter=RateLimiter(1000, 1000), url="https://overpass.test/api")
    return StayService(source=source, cache=MemoryCache())


async def test_one_overpass_call_per_cell_and_public_api() -> None:
    fake = FakeOverpass()
    svc = service(fake)
    await asyncio.gather(*(svc.around(*PARK) for _ in range(5)))
    assert len(fake.requests) == 1
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    assert "48.8722" not in sent  # la casilla, no el punto exacto
    app = create_api(InMemoryStore(), stays=svc)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        ok = await client.get("/v1/stays", params={"lat": PARK[0], "lon": PARK[1]})
        assert ok.status_code == 200 and ok.headers["Cache-Control"] == "public, max-age=86400"
        body = ok.json()
        assert [z["name"] for z in body["zones"]] == ["Val d'Europe"]
        assert "OpenStreetMap" in body["attribution"]
        assert (await client.get("/v1/stays", params={"lat": 99, "lon": 0})).status_code == 400


@pytest.mark.parametrize("status", [429, 504, 500])
async def test_busy_when_overpass_fails(status: int) -> None:
    fake = FakeOverpass()
    fake.status = status
    app = create_api(InMemoryStore(), stays=service(fake))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        resp = await client.get("/v1/stays", params={"lat": 40.4, "lon": -3.7})
    assert resp.status_code == 503 and resp.headers["Retry-After"] == "60"
