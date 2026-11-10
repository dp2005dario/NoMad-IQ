"""Tests de las fotos de Google Maps de las tiendas: Google de mentira."""

from __future__ import annotations

import json
from typing import Any

import httpx
from conftest import InMemoryStore
from pydantic import SecretStr

from ai_orchestrator.api import create_api
from ai_orchestrator.geocode.api import GoogleFirstGeocoder, Place
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.shop_photos.domain import ShopPhoto
from ai_orchestrator.shop_photos.google import FIND_FIELDS, GooglePlacesClient, first_photo
from ai_orchestrator.shop_photos.service import ShopPhotoService, ShopPhotoSettings

KEY = "AIzaSyTEST_key-0123456789abcdef"
PHOTO = "places/ChIJabc/photos/AUc7xyz"
CDN = "https://lh3.googleusercontent.com/place-photos/abc=s480"


class FakeGoogle:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.places: list[dict[str, Any]] = [
            {
                "id": "ChIJabc",
                "photos": [
                    {
                        "name": PHOTO,
                        "authorAttributions": [
                            {"displayName": "Ana  G.", "uri": "https://maps.google.com/u/1"}
                        ],
                    }
                ],
            }
        ]
        self.photo_uri = CDN

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        if request.url.path.endswith(":searchText"):
            return httpx.Response(200, json={"places": self.places})
        return httpx.Response(200, json={"name": PHOTO, "photoUri": self.photo_uri})


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, ShopPhoto] = {}
        self.ttls: dict[str, int] = {}

    async def get(self, osm_id: str) -> ShopPhoto | None:
        return self.items.get(osm_id)

    async def put(self, photo: ShopPhoto, *, ttl_seconds: int) -> None:
        self.items[photo.id], self.ttls[photo.id] = photo, ttl_seconds


class MemoryQuota:
    def __init__(self) -> None:
        self.used = 0

    async def take(self, user_id: str, day: str, limit: int) -> int | None:
        self.used += 1
        return None if self.used > limit else limit - self.used


def service(fake: FakeGoogle, limit: int = 100) -> tuple[ShopPhotoService, MemoryCache, MemoryQuota]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    client = GooglePlacesClient(http, key=SecretStr(KEY), limiter=RateLimiter(1000, 1000))
    cache, quota = MemoryCache(), MemoryQuota()
    svc = ShopPhotoService(
        google=client, cache=cache, quota=quota, settings=ShopPhotoSettings(daily_limit=limit)
    )
    return svc, cache, quota


def test_first_photo_keeps_only_safe_names() -> None:
    assert first_photo({"places": [{"photos": [{"name": "../../x"}]}]}) is None
    assert first_photo({"places": []}) is None
    assert first_photo({"places": [{"photos": [{"name": PHOTO}]}]}) == (PHOTO, None, None)


async def test_finds_the_photo_with_the_key_in_a_header_only() -> None:
    fake = FakeGoogle()
    svc, cache, _ = service(fake)
    photo = await svc.photo("n12", "Café de Oriente", 40.4183, -3.7126)
    assert (photo.photo_url, photo.author, photo.author_url) == (CDN, "Ana G.", "https://maps.google.com/u/1")
    search, media = fake.requests
    assert search.headers["X-Goog-Api-Key"] == KEY and KEY not in str(search.url)
    assert search.headers["X-Goog-FieldMask"] == "places.id,places.photos"
    body = json.loads(search.content)
    assert body["textQuery"] == "Café de Oriente"
    assert body["locationBias"]["circle"]["center"] == {"latitude": 40.4183, "longitude": -3.7126}
    assert media.url.path == f"/v1/{PHOTO}/media" and KEY not in str(media.url)
    assert media.url.params["skipHttpRedirect"] == "true"
    assert cache.ttls["n12"] == 12 * 3600


async def test_second_time_comes_from_cache() -> None:
    fake = FakeGoogle()
    svc, _, quota = service(fake)
    await svc.photo("n12", "Café", 40.0, -3.0)
    await svc.photo("n12", "Café", 40.0, -3.0)
    assert len(fake.requests) == 2 and quota.used == 1


async def test_no_photo_or_foreign_image_is_remembered_longer() -> None:
    fake = FakeGoogle()
    fake.photo_uri = "https://evil.example/x.jpg"
    svc, cache, _ = service(fake)
    photo = await svc.photo("n13", "X", 40.0, -3.0)
    assert photo.photo_url is None and cache.ttls["n13"] == 3 * 24 * 3600


async def test_daily_limit_stops_calling_google() -> None:
    fake = FakeGoogle()
    svc, cache, _ = service(fake, limit=1)
    assert (await svc.photo("n1", "A", 40.0, -3.0)).photo_url == CDN
    assert (await svc.photo("n2", "B", 40.0, -3.0)).photo_url is None
    assert len(fake.requests) == 2 and "n2" not in cache.items  # mañana se vuelve a buscar


def api(svc: ShopPhotoService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), shop_photos=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_validates_and_says_busy() -> None:
    fake = FakeGoogle()
    svc, _, _ = service(fake)
    ok = {"id": "n12", "name": "Café", "lat": "40.4", "lon": "-3.7"}
    async with api(svc) as c:
        resp = await c.get("/v1/nearby/photo", params=ok)
        assert resp.status_code == 200 and resp.json()["attribution"] == "Google Maps"
        assert resp.headers["cache-control"] == "public, max-age=21600"
        assert (await c.get("/v1/nearby/photo", params={**ok, "id": "x1"})).status_code == 400
        assert (await c.get("/v1/nearby/photo", params={**ok, "name": "a" * 81})).status_code == 400
        fake.status = 429
        busy = await c.get("/v1/nearby/photo", params={**ok, "id": "n99"})
    assert busy.status_code == 503 and busy.headers["retry-after"] == "60"


class FakeNominatim:
    def __init__(self) -> None:
        self.calls = 0

    async def search(self, query: str, near: tuple[float, float] | None) -> list[Place]:
        self.calls += 1
        return [Place(name="OSM", address="OSM, Madrid", lat=40.0, lon=-3.0)]


def google_finder(handler: Any) -> GooglePlacesClient:
    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return GooglePlacesClient(http, key=SecretStr(KEY), limiter=RateLimiter(1000, 1000))


async def test_map_search_uses_google_then_cache_then_osm_when_out_of_quota() -> None:
    seen: list[dict[str, Any]] = []

    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(json.loads(req.content))
        assert req.headers["X-Goog-FieldMask"] == FIND_FIELDS
        return httpx.Response(
            200,
            json={
                "places": [
                    {
                        "displayName": {"text": "Mercado de San Miguel"},
                        "formattedAddress": "Plaza de San Miguel, Madrid",
                        "location": {"latitude": 40.4154, "longitude": -3.7090},
                    },
                    {"displayName": {"text": "Sin sitio"}},
                ]
            },
        )

    osm = FakeNominatim()
    geo = GoogleFirstGeocoder(google_finder(handler), osm, quota=MemoryQuota(), daily_limit=1)
    found = await geo.search("mercado", (40.4, -3.7))
    assert [(p.name, p.source) for p in found] == [("Mercado de San Miguel", "Google Maps")]
    assert seen[0]["locationBias"]["circle"]["center"] == {"latitude": 40.4, "longitude": -3.7}
    assert await geo.search("Mercado ", (40.4, -3.7)) == found  # caché
    assert len(seen) == 1
    # Cupo del día gastado: OpenStreetMap.
    assert (await geo.search("otra cosa", None))[0].name == "OSM"
    assert osm.calls == 1


async def test_map_search_falls_back_when_google_fails() -> None:
    osm = FakeNominatim()
    geo = GoogleFirstGeocoder(
        google_finder(lambda r: httpx.Response(500)), osm, quota=MemoryQuota(), daily_limit=10
    )
    assert (await geo.search("algo", None))[0].name == "OSM"
