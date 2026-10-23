"""Tests de los cajeros: Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.atms.domain import Atms, cell_of
from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassClient, build_query, parse_atm
from ai_orchestrator.atms.service import AtmService
from ai_orchestrator.places.wikimedia import RateLimiter


def node(oid: int, lat: float, lon: float, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": lat, "lon": lon, "tags": {"amenity": "atm", **tags}}


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            node(
                1,
                35.6595,
                139.7005,
                name="Seven Bank",
                opening_hours="24/7",
                fee="no",
                **{"currency:JPY": "yes"},
            ),
            node(1, 35.6595, 139.7005),  # repetido: se queda uno
            {
                "type": "way",
                "id": 7,
                "center": {"lat": 35.661, "lon": 139.703},
                "tags": {"amenity": "bank", "atm": "yes", "operator": "Japan Post Bank", "fee": "yes"},
            },
            {"type": "way", "id": 8, "tags": {"amenity": "atm"}},  # sin centro: fuera
            {"type": "node", "id": -1, "lat": 1, "lon": 1},  # id raro: fuera
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"elements": self.rows})


class MemoryAtmCache:
    def __init__(self) -> None:
        self.items: dict[str, Atms] = {}

    async def get(self, lat: float, lon: float) -> Atms | None:
        return self.items.get(f"{lat:.2f}:{lon:.2f}")

    async def put(self, atms: Atms, *, ttl_seconds: int) -> None:
        self.items[f"{atms.lat:.2f}:{atms.lon:.2f}"] = atms


def service(fake: FakeOverpass) -> tuple[AtmService, MemoryAtmCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    client = OverpassClient(http, limiter=RateLimiter(1000, 1000))
    cache = MemoryAtmCache()
    return AtmService(overpass=client, cache=cache), cache


def test_cell_rounds_to_about_1_km() -> None:
    assert cell_of(35.65949, 139.70051) == (35.66, 139.7)


def test_query_only_has_fixed_numbers() -> None:
    q = build_query(35.645, 139.685, 35.675, 139.715)
    assert "(35.64500,139.68500,35.67500,139.71500)" in q
    assert q.startswith("[out:json]")
    assert "out center 80;" in q


def test_parse_atm_reads_useful_tags() -> None:
    a = parse_atm(
        node(
            1, 35.0, 139.0, name="  Seven   Bank ", opening_hours="24/7", fee="no", **{"currency:USD": "yes"}
        )
    )
    assert a is not None
    assert a.id == "n1"
    assert a.name == "Seven Bank"
    assert a.open_24h is True
    assert a.fee is False
    assert a.currencies == ["USD"]
    assert parse_atm({"type": "node", "id": 2, "lat": 200, "lon": 0}) is None
    assert parse_atm("nada") is None
    bank = parse_atm({"type": "way", "id": 3, "center": {"lat": 1, "lon": 2}, "tags": {"amenity": "bank"}})
    assert bank is not None and bank.in_bank and bank.fee is None and bank.id == "w3"


async def test_asks_by_cell_and_dedupes() -> None:
    fake = FakeOverpass()
    svc, _ = service(fake)
    result = await svc.near(35.65949, 139.70051)
    assert (result.lat, result.lon) == (35.66, 139.7)
    assert [a.id for a in result.atms] == ["n1", "w7"]
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    # Se pregunta por la casilla y sus vecinas, nunca por el punto exacto.
    assert "35.64500,139.68500,35.67500,139.71500" in sent
    assert "35.65949" not in sent
    assert fake.requests[0].headers["User-Agent"].startswith("NomadIQ/")


async def test_same_cell_is_served_from_cache_and_shared() -> None:
    fake = FakeOverpass()
    svc, _ = service(fake)
    await asyncio.gather(*(svc.near(35.6595, 139.7005) for _ in range(5)))
    await svc.near(35.6601, 139.6999)
    assert len(fake.requests) == 1


def api(svc: AtmService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), atms=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_validates_coordinates() -> None:
    svc, _ = service(FakeOverpass())
    async with api(svc) as client:
        ok = await client.get("/v1/atms", params={"lat": 35.6595, "lon": 139.7005})
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=21600"
        body = ok.json()
        assert body["attribution"].startswith("©")
        assert body["atms"][0]["name"] == "Seven Bank"
        bad = await client.get("/v1/atms", params={"lat": 95, "lon": 0})
        assert bad.status_code == 400


@pytest.mark.parametrize("status", [429, 504])
async def test_api_says_busy_when_overpass_pushes_back(status: int) -> None:
    fake = FakeOverpass()
    fake.status = status
    svc, _ = service(fake)
    async with api(svc) as client:
        resp = await client.get("/v1/atms", params={"lat": 35.6, "lon": 139.7})
    assert resp.status_code == 503
    assert resp.headers["Retry-After"] == "60"


async def test_limiter_uses_overpass_busy_error() -> None:
    limiter = RateLimiter(0.001, 1, busy=lambda: OverpassBusyError("x"))
    await limiter.acquire(0)
    with pytest.raises(OverpassBusyError):
        await limiter.acquire(0)
