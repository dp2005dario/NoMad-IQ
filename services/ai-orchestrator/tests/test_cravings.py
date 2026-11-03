"""Tests de «¿Qué os apetece?» (Grupo): Overpass de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any
from urllib.parse import parse_qs

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.nearby.cravings import (
    Cravings,
    CravingService,
    CravingsOverpass,
    CravingsUnavailableError,
    build_query,
    parse_spot,
)
from ai_orchestrator.places.wikimedia import RateLimiter


def node(oid: int, **tags: str) -> dict[str, Any]:
    return {"type": "node", "id": oid, "lat": 38.7110, "lon": -9.1300, "tags": tags}


class FakeOverpass:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            node(
                1, amenity="restaurant", name="Taberna do Largo", cuisine="tapas", opening_hours="18:00-24:00"
            ),
            node(2, amenity="restaurant", cuisine="tapas"),  # sin nombre: fuera
            node(1, amenity="restaurant", name="Taberna do Largo", cuisine="tapas"),  # repetido
            {"type": "way", "id": 3, "center": {"lat": 38.712, "lon": -9.131}, "tags": {"name": "Petiscos"}},
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"elements": self.rows})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, Cravings] = {}
        self.expired = False

    async def get(self, kind: str, lat: float, lon: float) -> Cravings | None:
        return None if self.expired else await self.get_stale(kind, lat, lon)

    async def get_stale(self, kind: str, lat: float, lon: float) -> Cravings | None:
        return self.items.get(f"{kind}:{lat:.2f}:{lon:.2f}")

    async def put(self, found: Cravings, *, ttl_seconds: int) -> None:
        self.items[f"{found.kind}:{found.lat:.2f}:{found.lon:.2f}"] = found


def service(fake: FakeOverpass) -> tuple[CravingService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    source = CravingsOverpass(http, limiter=RateLimiter(1000, 1000), url="https://overpass.test/api")
    cache = MemoryCache()
    return CravingService(source=source, cache=cache), cache


@pytest.mark.parametrize(
    ("kind", "needle"),
    [
        ("tapas", "tapas"),
        ("fish", "seafood"),
        ("veggie", "diet:vegetarian"),
        ("cafe", '"amenity"="cafe"'),
        ("views", "viewpoint"),
    ],
)
def test_one_query_per_craving(kind: str, needle: str) -> None:
    q = build_query(kind, 38.7, -9.14, 38.72, -9.12)
    assert needle in q
    assert "38.70000,-9.14000,38.72000,-9.12000" in q


def test_parse_needs_a_name() -> None:
    assert parse_spot(node(9, amenity="cafe")) is None
    spot = parse_spot(node(9, amenity="cafe", name="Café do Miradouro"))
    assert spot is not None and spot.id == "n9" and spot.name == "Café do Miradouro"


async def test_one_call_per_cell_and_craving() -> None:
    fake = FakeOverpass()
    svc, _ = service(fake)
    results = await asyncio.gather(*(svc.near(38.7110, -9.1300, "tapas") for _ in range(4)))
    assert len(fake.requests) == 1
    assert [s.name for s in results[0].spots] == ["Taberna do Largo", "Petiscos"]
    assert results[0].spots[0].opening_hours == "18:00-24:00"
    # Otro antojo en la misma casilla es otra pregunta.
    await svc.near(38.7110, -9.1300, "cafe")
    assert len(fake.requests) == 2
    # Se manda la casilla, no el punto exacto.
    sent = parse_qs(fake.requests[0].content.decode())["data"][0]
    assert "38.711" not in sent
    with pytest.raises(ValueError, match="antojo"):
        await svc.near(38.7, -9.1, "pizza")


async def test_stale_copy_when_overpass_fails() -> None:
    fake = FakeOverpass()
    svc, cache = service(fake)
    first = await svc.near(38.7110, -9.1300, "views")
    cache.expired = True
    fake.status = 502
    assert await svc.near(38.7110, -9.1300, "views") == first
    with pytest.raises(CravingsUnavailableError):
        await svc.near(48.85, 2.35, "views")


async def test_api_is_public_and_checks_the_craving() -> None:
    fake = FakeOverpass()
    svc, _ = service(fake)
    app = create_api(InMemoryStore(), cravings=svc)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        ok = await client.get("/v1/cravings", params={"lat": 38.711, "lon": -9.13, "kind": "tapas"})
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=86400"
        assert ok.json()["kind"] == "tapas" and ok.json()["lat"] == 38.71
        bad = await client.get("/v1/cravings", params={"lat": 38.7, "lon": -9.1, "kind": "pizza"})
        assert bad.status_code in (400, 422)
        fake.status = 429
        busy = await client.get("/v1/cravings", params={"lat": 1.0, "lon": 1.0, "kind": "fish"})
        assert busy.status_code == 503 and busy.headers["Retry-After"] == "60"
