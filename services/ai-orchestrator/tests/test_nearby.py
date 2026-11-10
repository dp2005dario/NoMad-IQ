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
from ai_orchestrator.nearby.overpass import MAX_SHOPS, NearbyOverpass, build_query, parse_place, parse_spot
from ai_orchestrator.nearby.service import NearbyService, NearbyUnavailableError
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
        self.expired = False  # True = lo guardado ya no es "fresco"

    async def get(self, lat: float, lon: float) -> Nearby | None:
        return None if self.expired else await self.get_stale(lat, lon)

    async def get_stale(self, lat: float, lon: float) -> Nearby | None:
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


def test_query_and_parse_dog_kinds() -> None:
    q = build_query(40.4, -3.71, 40.43, -3.69)
    for tag in ("veterinary", "dog_park", '["dog"~"^(yes|leashed)$"]'):
        assert tag in q
    vet = parse_spot(node(11, amenity="veterinary", name="Clínica", phone="+34 911 22 33 44"))
    assert vet is not None and vet.kind == "vet" and vet.phone == "+34 911 22 33 44"
    park = parse_spot(node(12, leisure="dog_park"))
    assert park is not None and park.kind == "dog_park"
    hotel = parse_spot(node(13, tourism="hotel", dog="yes", name="Hotel Can", website="https://can.es"))
    assert hotel is not None and hotel.kind == "pet_stay" and hotel.website == "https://can.es"
    # Sin nombre o sin permitir perros: fuera.
    assert parse_spot(node(14, tourism="hotel", dog="yes")) is None
    assert parse_spot(node(15, tourism="hotel", dog="no", name="Sin perros")) is None


def test_parse_restaurant_with_reservation() -> None:
    table = parse_spot(
        node(
            7,
            amenity="restaurant",
            reservation="required",
            name="Casa Lucio",
            website="https://casalucio.es",
            phone="+34 913 65 32 52;+34 600 000 000",
            cuisine="spanish",
        )
    )
    assert table is not None and table.kind == "table"
    assert (table.website, table.phone, table.reservation) == (
        "https://casalucio.es",
        "+34 913 65 32 52",
        "required",
    )
    # Sin reserva, sin forma de reservar o con enlaces raros: fuera.
    # Sin reserva ya no es "mesa", pero sí sale como sitio para comer.
    plain = parse_spot(node(8, amenity="restaurant", name="X", website="https://x.es"))
    assert plain is not None and (plain.kind, plain.sub) == ("shop", "food")
    no_book = parse_spot(node(8, amenity="restaurant", reservation="no", name="X", phone="+3491"))
    assert no_book is not None and no_book.kind == "shop"
    assert (
        parse_spot(node(8, amenity="restaurant", reservation="yes", name="X", website="javascript:1")) is None
    )
    weird = parse_spot(
        node(8, amenity="restaurant", reservation="yes", name="X", website="http://x.es", phone="9 1 2 3 4 5")
    )
    assert weird is not None and weird.website is None and weird.phone == "9 1 2 3 4 5"


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


async def test_serves_stale_copy_when_overpass_fails() -> None:
    fake = FakeOverpass()
    svc, cache = service(fake)
    first = await svc.near(40.4168, -3.7038)
    cache.expired = True  # pasó el tiempo: ya no es fresca
    fake.status = 502  # y Overpass se cae
    assert await svc.near(40.4168, -3.7038) == first
    # Y si nunca se guardó esa casilla, sí hay error.
    with pytest.raises(NearbyUnavailableError):
        await svc.near(48.85, 2.35)


def test_sight_types_and_place_names() -> None:
    q = build_query(40.4, -3.71, 40.43, -3.69)
    assert '["leisure"="park"]' in q and "place_of_worship" in q
    assert "is_in(40.41500,-3.70000)" in q
    view = parse_spot(node(21, tourism="viewpoint", name="Mirador", wikidata="Q1", fee="no"))
    assert view is not None and (view.sub, view.fee) == ("viewpoint", False)
    park = parse_spot(node(22, leisure="park", name="Retiro", wikidata="Q2"))
    assert park is not None and (park.kind, park.sub) == ("sight", "park")
    church = parse_spot(node(23, amenity="place_of_worship", name="San Isidro", wikidata="Q3"))
    assert church is not None and church.sub == "worship"
    # Un parque sin Wikidata no es "conocido": fuera.
    assert parse_spot(node(24, leisure="park", name="Parquecito")) is None
    city = parse_place(
        {"type": "area", "id": 3_600_005_326, "tags": {"name": "Madrid", "admin_level": "8"}}, 40.4, -3.7
    )
    assert city is not None and (city.id, city.kind, city.name, city.sub) == ("r5326", "place", "Madrid", "8")
    assert (
        parse_place(
            {"type": "area", "id": 3_600_000_001, "tags": {"name": "España", "admin_level": "2"}}, 0, 0
        )
        is None
    )
    assert parse_place(node(1, name="x"), 0, 0) is None


def test_parse_shops_like_a_normal_map() -> None:
    """Tiendas, súper, farmacias y cajeros salen como "shop" con su grupo."""
    assert parse_spot(node(20, shop="clothes", name="Zara")).sub == "shop"
    assert parse_spot(node(21, shop="supermarket", name="Día")).sub == "grocery"
    assert parse_spot(node(22, amenity="pharmacy", name="Farmacia Sol")).sub == "pharmacy"
    assert parse_spot(node(23, amenity="cafe", name="Café Central")).sub == "food"
    # Un cajero sin nombre vale (se ve el banco si lo pone); una tienda no.
    assert parse_spot(node(24, amenity="atm", operator="Santander")).name == "Santander"
    assert parse_spot(node(25, shop="clothes")) is None


def test_query_asks_for_shops_nearby() -> None:
    q = build_query(40.40, -3.72, 40.44, -3.68)
    assert 'nwr["shop"]["name"]' in q
    assert f"out center {MAX_SHOPS}" in q
