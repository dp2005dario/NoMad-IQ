"""Buscar tu hotel en OpenStreetMap (Nominatim), sin tocar Internet."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.geocode.api import (
    GeocodeBusyError,
    NominatimGeocoder,
    Place,
    geocode_router,
    parse_nominatim,
)
from ai_orchestrator.places.wikimedia import RateLimiter

DARIO = "11111111-1111-4111-8111-111111111111"

AVENIDA = {
    "lat": "38.7157",
    "lon": "-9.1418",
    "name": "Avenida Palace",
    "display_name": "Avenida Palace, Rua 1º de Dezembro, Lisboa, Portugal",
}


H = {"X-User-ID": DARIO, "X-User-Roles": "USER"}


def test_parse_keeps_good_places_only() -> None:
    raw: list[Any] = [
        AVENIDA,
        {"lat": "x", "lon": "1"},
        {"lat": "100", "lon": "1", "display_name": "a"},
        "raro",
    ]
    assert parse_nominatim(raw) == [
        Place(
            name="Avenida Palace",
            address="Avenida Palace, Rua 1º de Dezembro, Lisboa, Portugal",
            lat=38.7157,
            lon=-9.1418,
        )
    ]


async def test_asks_nominatim_once_and_remembers() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=[AVENIDA])

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
        geo = NominatimGeocoder(http)
        first = await geo.search("Avenida Palace", (38.71, -9.14))
        again = await geo.search("  avenida   PALACE ", (38.712, -9.141))
    assert first == again and first[0].lat == 38.7157
    assert len(seen) == 1
    assert seen[0].headers["User-Agent"].startswith("NomadIQ/")
    assert seen[0].url.params["viewbox"] == "-9.64,39.21,-8.64,38.21"


async def test_busy_when_nominatim_says_wait() -> None:
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(429))) as http:
        geo = NominatimGeocoder(http, limiter=RateLimiter(100, 10))
        with pytest.raises(GeocodeBusyError):
            await geo.search("Hotel", None)


class FakeGeocoder:
    async def search(self, query: str, near: tuple[float, float] | None) -> list[Place]:
        return [
            Place(
                name=query, address=f"{query}, Lisboa", lat=near[0] if near else 0, lon=near[1] if near else 0
            )
        ]


async def test_api_needs_an_account() -> None:
    app = create_api(InMemoryStore(), geocode=geocode_router(FakeGeocoder()))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get("/v1/geocode", params={"q": "Avenida"})).status_code == 401
        ok = await c.get("/v1/geocode", params={"q": "Avenida", "lat": 38.7, "lon": -9.1}, headers=H)
        assert ok.status_code == 200
        assert ok.json()["items"][0]["lat"] == 38.7
        assert ok.json()["source"] == "OpenStreetMap (Nominatim)"
        # Muy corto: no se busca.
        assert (await c.get("/v1/geocode", params={"q": "a"}, headers=H)).status_code == 400
