"""Tests de las fotos de calle: Mapillary de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
import json
from typing import Any
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from conftest import InMemoryStore
from pydantic import SecretStr

from ai_orchestrator.api import create_api
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.streetview.domain import StreetPhotos, cell_of
from ai_orchestrator.streetview.mapillary import MapillaryBusyError, MapillaryClient, parse_photo
from ai_orchestrator.streetview.service import StreetSettings, StreetViewService, pick

TOKEN = "MLY|123456|abcdef0123456789"
CDN = "https://scontent-mad1-1.xx.fbcdn.net/m1/v/t6/abc.jpg?oe=1"


def row(pid: str, lat: float, lon: float, **extra: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": pid,
        "captured_at": 1_690_000_000_000,
        "compass_angle": 370.0,
        "computed_geometry": {"type": "Point", "coordinates": [lon, lat]},
        "is_pano": False,
        "thumb_256_url": CDN,
        "thumb_1024_url": CDN,
        "creator": {"username": "ana", "id": "9"},
    }
    base.update(extra)
    return base


class FakeMapillary:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            row("1", 40.4168, -3.7038),
            row("2", 40.41679, -3.70379),  # casi la misma que la 1
            row("3", 40.4172, -3.7030, is_pano=True),
            row("4", 40.4160, -3.7045, thumb_256_url="https://evil.example/x.jpg"),
        ]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"data": self.rows})


class MemoryStreetCache:
    def __init__(self) -> None:
        self.items: dict[str, StreetPhotos] = {}
        self.ttls: dict[str, int] = {}

    async def get(self, lat: float, lon: float) -> StreetPhotos | None:
        return self.items.get(f"{lat:.3f}:{lon:.3f}")

    async def put(self, photos: StreetPhotos, *, ttl_seconds: int) -> None:
        key = f"{photos.lat:.3f}:{photos.lon:.3f}"
        self.items[key] = photos
        self.ttls[key] = ttl_seconds


def service(fake: FakeMapillary) -> tuple[StreetViewService, MemoryStreetCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    client = MapillaryClient(http, token=SecretStr(TOKEN), limiter=RateLimiter(1000, 1000))
    cache = MemoryStreetCache()
    return StreetViewService(mapillary=client, cache=cache), cache


def test_cell_rounds_to_about_100_m() -> None:
    assert cell_of(40.41684, -3.70379) == (40.417, -3.704)
    assert cell_of(-33.44949, 151.0) == (-33.449, 151.0)


def test_parse_photo_keeps_only_trusted_images() -> None:
    photo = parse_photo(row("42", 40.0, -3.0))
    assert photo is not None
    assert photo.compass_angle == 10.0
    assert photo.creator == "ana"
    assert photo.page_url.endswith("pKey=42&focus=photo")
    assert photo.captured_at is not None and photo.captured_at.year == 2023
    # Nada de imágenes de otros sitios, ids raros ni posiciones imposibles.
    assert parse_photo(row("43", 40.0, -3.0, thumb_1024_url="http://scontent.xx.fbcdn.net/a.jpg")) is None
    assert parse_photo(row("../x", 40.0, -3.0)) is None
    assert parse_photo(row("44", 95.0, -3.0, geometry=None)) is None
    assert parse_photo("no soy una foto") is None


def test_pick_skips_near_duplicates() -> None:
    photos = [p for p in (parse_photo(r) for r in FakeMapillary().rows) if p]
    chosen = pick(photos, 40.4168, -3.7038, limit=10, spacing=6.0)
    assert [p.id for p in chosen] == ["1", "3"]


async def test_asks_by_cell_with_token_in_header_only() -> None:
    fake = FakeMapillary()
    svc, cache = service(fake)
    result = await svc.near(40.41684, -3.70379)
    assert (result.lat, result.lon) == (40.417, -3.704)
    assert [p.id for p in result.photos] == ["1", "3"]
    assert result.photos[1].is_pano
    req = fake.requests[0]
    assert req.headers["authorization"] == f"OAuth {TOKEN}"
    # La token nunca va en la URL (acabaría en registros).
    assert "MLY" not in str(req.url)
    bbox = [float(x) for x in parse_qs(urlparse(str(req.url)).query)["bbox"][0].split(",")]
    assert bbox[0] < -3.704 < bbox[2] and bbox[1] < 40.417 < bbox[3]
    assert bbox[2] - bbox[0] < 0.004  # un rectángulo pequeño (~300 m)
    assert cache.ttls["40.417:-3.704"] == StreetSettings().ttl_seconds


async def test_same_cell_is_served_from_cache_and_shared() -> None:
    fake = FakeMapillary()
    svc, _ = service(fake)
    await asyncio.gather(*(svc.near(40.4168, -3.7038) for _ in range(20)))
    await svc.near(40.41679, -3.70382)  # otro punto de la misma casilla
    assert len(fake.requests) == 1


async def test_empty_places_are_remembered_longer() -> None:
    fake = FakeMapillary()
    fake.rows = []
    svc, cache = service(fake)
    result = await svc.near(10.0, 10.0)
    assert result.photos == []
    assert cache.ttls["10.000:10.000"] == StreetSettings().empty_ttl_seconds


async def test_rate_limiter_uses_its_own_busy_error() -> None:
    limiter = RateLimiter(0.001, 1, busy=lambda: MapillaryBusyError("lleno"))
    await limiter.acquire(0.1)
    with pytest.raises(MapillaryBusyError):
        await limiter.acquire(0.1)


def api(svc: StreetViewService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), streetview=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_validates_coordinates() -> None:
    svc, _ = service(FakeMapillary())
    async with api(svc) as c:
        resp = await c.get("/v1/streetview", params={"lat": "40.4168", "lon": "-3.7038"})
        assert resp.status_code == 200
        assert resp.headers["cache-control"] == "public, max-age=3600"
        body = resp.json()
        assert body["attribution"] == "Mapillary (CC BY-SA 4.0)"
        assert len(body["photos"]) == 2
        assert (await c.get("/v1/streetview", params={"lat": "91", "lon": "0"})).status_code == 400
        assert (await c.get("/v1/streetview", params={"lat": "x", "lon": "0"})).status_code == 400
        assert (await c.get("/v1/streetview")).status_code == 400


async def test_api_says_busy_when_mapillary_pushes_back() -> None:
    fake = FakeMapillary()
    fake.status = 429
    svc, _ = service(fake)
    async with api(svc) as c:
        resp = await c.get("/v1/streetview", params={"lat": "1", "lon": "1"})
    assert resp.status_code == 503
    assert resp.headers["retry-after"] == "60"
    assert json.loads(resp.text)["status"] == 503
