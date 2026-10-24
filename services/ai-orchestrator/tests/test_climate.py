"""Tests del clima medio: NASA POWER de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
from typing import Any

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.climate.domain import Climate, cell_of
from ai_orchestrator.climate.nasa import MONTHS, NasaClient, NasaError, parse_months
from ai_orchestrator.climate.service import ClimateService
from ai_orchestrator.places.wikimedia import RateLimiter


def nasa_body(**override: dict[str, float]) -> dict[str, Any]:
    temp = {m: 5.0 + i * 2 for i, m in enumerate(MONTHS)}
    top = {m: v + 6 for m, v in temp.items()}
    rain = {m: 2.0 for m in MONTHS}
    params = {"T2M": temp, "T2M_MAX": top, "PRECTOTCORR": rain, **override}
    return {"properties": {"parameter": params}}


class FakeNasa:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.body: dict[str, Any] = nasa_body()

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json=self.body)


class MemoryClimateCache:
    def __init__(self) -> None:
        self.items: dict[str, tuple[Climate, int]] = {}

    async def get(self, lat: float, lon: float) -> Climate | None:
        found = self.items.get(f"{lat:.1f}:{lon:.1f}")
        return found[0] if found else None

    async def put(self, climate: Climate, *, ttl_seconds: int) -> None:
        self.items[f"{climate.lat:.1f}:{climate.lon:.1f}"] = (climate, ttl_seconds)


def service(fake: FakeNasa) -> tuple[ClimateService, MemoryClimateCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    cache = MemoryClimateCache()
    return ClimateService(nasa=NasaClient(http, limiter=RateLimiter(1000, 1000)), cache=cache), cache


def test_cell_rounds_to_half_a_degree() -> None:
    assert cell_of(35.68, 139.76) == (35.5, 140.0)
    assert cell_of(-33.87, 151.21) == (-34.0, 151.0)


def test_parse_months_turns_daily_rain_into_monthly_and_skips_gaps() -> None:
    body = nasa_body(T2M={**{m: 5.0 for m in MONTHS}, "FEB": -999.0})
    months = parse_months(body)
    assert [m.month for m in months] == [1, *range(3, 13)]  # febrero sin dato
    assert months[0].rain_mm == 62  # 2 mm al día x 31 días
    with pytest.raises(NasaError):
        parse_months({"nada": 1})


async def test_asks_by_cell_caches_and_shares() -> None:
    fake = FakeNasa()
    svc, cache = service(fake)
    results = await asyncio.gather(*(svc.at(35.68, 139.76) for _ in range(5)))
    await svc.at(35.6, 139.9)  # misma casilla
    assert len(fake.requests) == 1
    assert (results[0].lat, results[0].lon) == (35.5, 140.0)
    assert len(results[0].months) == 12
    params = fake.requests[0].url.params
    # Se pregunta por la casilla, nunca por el punto exacto.
    assert params["latitude"] == "35.50" and params["longitude"] == "140.00"
    assert fake.requests[0].headers["User-Agent"].startswith("NomadIQ/")
    assert next(iter(cache.items.values()))[1] == 30 * 24 * 3600


async def test_incomplete_answer_is_cached_only_a_day() -> None:
    fake = FakeNasa()
    fake.body = nasa_body(T2M={m: 5.0 for m in MONTHS[:6]})
    svc, cache = service(fake)
    found = await svc.at(40.4, -3.7)
    assert len(found.months) == 6
    assert next(iter(cache.items.values()))[1] == 24 * 3600


def api(svc: ClimateService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), climate=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_validates() -> None:
    svc, _ = service(FakeNasa())
    async with api(svc) as client:
        ok = await client.get("/v1/climate", params={"lat": 35.68, "lon": 139.76})
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "public, max-age=604800"
        body = ok.json()
        assert body["months"][0] == {"month": 1, "temp_c": 5.0, "temp_max_c": 11.0, "rain_mm": 62.0}
        assert "NASA" in body["attribution"]
        assert (await client.get("/v1/climate", params={"lat": 95, "lon": 0})).status_code == 400


@pytest.mark.parametrize("status", [429, 500])
async def test_api_degrades_when_nasa_fails(status: int) -> None:
    fake = FakeNasa()
    fake.status = status
    svc, _ = service(fake)
    async with api(svc) as client:
        resp = await client.get("/v1/climate", params={"lat": 1, "lon": 1})
    assert resp.status_code == 503
    assert resp.headers["Retry-After"] == "60"
