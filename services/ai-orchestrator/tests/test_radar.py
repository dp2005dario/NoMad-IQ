"""Tests del radar local: lluvia (MET de mentira) y la API de avisos/precios."""

from __future__ import annotations

import asyncio
from decimal import Decimal
from typing import Any

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.radar.api import radar_router
from ai_orchestrator.radar.domain import (
    CityRadar,
    PriceItem,
    PriceRange,
    RadarLimitError,
    ScamCategory,
    ScamCount,
)
from ai_orchestrator.radar.rain import MetClient, RainHour, RainService, cell_of, parse_forecast

AIRPORTS = Airports.parse("NRT|35.76|140.39|Tokyo|Japan|Asia/Tokyo\n")


def hour(time: str, rain: float, temp: float = 18.0) -> dict[str, Any]:
    return {
        "time": time,
        "data": {
            "instant": {"details": {"air_temperature": temp}},
            "next_1_hours": {"summary": {"symbol_code": "rain"}, "details": {"precipitation_amount": rain}},
        },
    }


MET = {
    "properties": {
        "timeseries": [
            hour("2026-10-25T10:00:00Z", 0.0),
            hour("2026-10-25T11:00:00Z", 2.4),
            {"time": "2026-10-25T12:00:00Z", "data": {}},  # sin next_1_hours: fuera
            *[hour(f"2026-10-25T{h}:00:00Z", 0.1) for h in range(13, 20)],
        ]
    }
}


class MemoryRain:
    def __init__(self) -> None:
        self.items: dict[tuple[float, float], list[RainHour]] = {}

    async def get(self, lat: float, lon: float) -> list[RainHour] | None:
        return self.items.get((lat, lon))

    async def put(self, lat: float, lon: float, hours: list[RainHour], *, ttl_seconds: int) -> None:
        self.items[(lat, lon)] = hours


def test_parse_keeps_six_real_hours() -> None:
    hours = parse_forecast(MET)
    assert len(hours) == 6
    assert hours[1].rain_mm == 2.4 and hours[1].symbol == "rain" and hours[1].temp_c == 18.0
    assert cell_of(35.6895, 139.6917) == (35.7, 139.7)


async def test_one_call_per_cell_and_user_agent() -> None:
    requests: list[httpx.Request] = []

    def handler(r: httpx.Request) -> httpx.Response:
        requests.append(r)
        return httpx.Response(200, json=MET)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    svc = RainService(
        source=MetClient(http, limiter=RateLimiter(1000, 1000), url="https://met.test/compact"),
        cache=MemoryRain(),
    )
    results = await asyncio.gather(*(svc.at(35.6895, 139.6917) for _ in range(5)))
    await svc.at(35.70, 139.71)
    assert len(requests) == 1
    assert requests[0].url.params["lat"] == "35.70"
    assert "NomadIQ" in requests[0].headers["User-Agent"]
    assert results[0].attribution.startswith("Data from MET Norway")


class MemoryRadar:
    def __init__(self) -> None:
        self.scams: dict[tuple[str, str], set[str]] = {}
        self.prices: list[tuple[str, str, str, str, Decimal]] = []
        self.limit = False

    async def city(self, city: str, user_id: str) -> CityRadar:
        counts = [
            ScamCount(category=c, reporters=len(u))  # type: ignore[arg-type]
            for (ci, c), u in self.scams.items()
            if ci == city and len(u) >= 3
        ]
        mine: list[ScamCategory] = [c for (ci, c), u in self.scams.items() if ci == city and user_id in u]  # type: ignore[misc]
        return CityRadar(
            city=city,
            scams=counts,
            prices=[PriceRange(item="coffee", currency="JPY", reporters=5, low=400, median=500, high=650)],
            my_scams=mine,
        )

    async def report_scam(self, city: str, user_id: str, category: ScamCategory) -> None:
        if self.limit:
            raise RadarLimitError(user_id)
        self.scams.setdefault((city, category), set()).add(user_id)

    async def withdraw_scam(self, city: str, user_id: str, category: ScamCategory) -> None:
        self.scams.get((city, category), set()).discard(user_id)

    async def add_price(
        self, city: str, user_id: str, item: PriceItem, currency: str, amount: Decimal
    ) -> None:
        self.prices.append((city, user_id, item, currency, amount))


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


async def test_radar_api_needs_three_people_and_never_says_who() -> None:
    store = MemoryRadar()
    app = create_api(InMemoryStore(), radar=radar_router(store, AIRPORTS))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        for user in ("a", "b"):
            r = await c.post("/v1/radar/NRT/scams", json={"category": "street_touts"}, headers=h(user))
            assert r.status_code == 204
        body = (await c.get("/v1/radar/NRT", headers=h("a"))).json()
        assert body["scams"] == []
        assert body["my_scams"] == ["street_touts"]
        await c.post("/v1/radar/NRT/scams", json={"category": "street_touts"}, headers=h("c"))
        body = (await c.get("/v1/radar/NRT", headers=h("z"))).json()
        assert body["scams"] == [{"category": "street_touts", "reporters": 3}]
        assert "user" not in str(body)
        # Quitar mi aviso.
        assert (await c.delete("/v1/radar/NRT/scams/street_touts", headers=h("c"))).status_code == 204
        assert (await c.get("/v1/radar/NRT", headers=h("z"))).json()["scams"] == []

        ok = await c.post(
            "/v1/radar/NRT/prices",
            json={"item": "coffee", "currency": "JPY", "amount": "480"},
            headers=h("a"),
        )
        assert ok.status_code == 204
        assert store.prices[0][4] == Decimal("480")
        # Validación: cosas desconocidas, importes raros, ciudades inventadas.
        for bad in (
            {"item": "sushi", "currency": "JPY", "amount": "1"},
            {"item": "coffee", "currency": "yen", "amount": "1"},
            {"item": "coffee", "currency": "JPY", "amount": "-3"},
        ):
            assert (await c.post("/v1/radar/NRT/prices", json=bad, headers=h("a"))).status_code in (400, 422)
        assert (await c.get("/v1/radar/ZZZ", headers=h("a"))).status_code == 404
        assert (await c.get("/v1/radar/NRT")).status_code == 401
        store.limit = True
        r = await c.post("/v1/radar/NRT/scams", json={"category": "taxi"}, headers=h("a"))
        assert r.status_code == 429


async def test_rain_api_is_public() -> None:
    http = httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=MET)))
    svc = RainService(source=MetClient(http, limiter=RateLimiter(1000, 1000)), cache=MemoryRain())
    app = create_api(InMemoryStore(), rain=svc)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/v1/rain", params={"lat": 35.69, "lon": 139.69})
        assert r.status_code == 200
        assert r.headers["Cache-Control"] == "public, max-age=600"
        assert len(r.json()["hours"]) == 6
