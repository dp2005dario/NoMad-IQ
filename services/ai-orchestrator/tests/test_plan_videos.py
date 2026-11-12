"""Tests de los vídeos de planes (YouTube Shorts): YouTube de mentira."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from conftest import InMemoryStore
from pydantic import SecretStr

from ai_orchestrator.api import create_api
from ai_orchestrator.plan_videos.domain import PlanVideo, PlanVideos
from ai_orchestrator.plan_videos.links import LinkResolver, parse_link
from ai_orchestrator.plan_videos.photos import WikipediaPhotos, lead_photo
from ai_orchestrator.plan_videos.service import (
    PlanVideoService,
    PlanVideoSettings,
    TooManyLinksError,
    cache_key,
    place_key,
)
from ai_orchestrator.plan_videos.youtube import YouTubeClient, parse_videos

KEY = "AIzaSyTEST_youtube-0123456789"


def item(vid: str, title: str = "Qué hacer en Lisboa &amp; más", thumb: str | None = None) -> dict[str, Any]:
    return {
        "id": {"kind": "youtube#video", "videoId": vid},
        "snippet": {
            "title": title,
            "channelTitle": "Viajeros",
            "thumbnails": {"high": {"url": thumb or f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"}},
        },
    }


class FakeYouTube:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.wiki: list[str] = []
        self.status = 200
        self.items: list[dict[str, Any]] = [item("abcdefghijk"), item("ABCDEFGHIJK")]

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "vm.tiktok.com":
            return httpx.Response(
                301, headers={"location": "https://www.tiktok.com/@ana/video/7301234567890123456?lang=es"}
            )
        if request.url.host.endswith("wikipedia.org"):
            self.wiki.append(str(request.url))
            if request.url.host.startswith("es.") or "Nowhere" in str(request.url):
                return httpx.Response(404)
            return httpx.Response(
                200,
                json={
                    "type": "standard",
                    "thumbnail": {
                        "source": "https://upload.wikimedia.org/wikipedia/commons/thumb/a/b/Lisboa.jpg/320px-Lisboa.jpg"
                    },
                },
            )
        if request.url.path == "/oembed":
            return httpx.Response(
                200,
                json={
                    "title": "Tranvía  28 al atardecer",
                    "author_name": "ana",
                    "thumbnail_url": "https://p16-sign.tiktokcdn.com/obj/abc.jpg",
                },
            )
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"items": self.items})


class MemoryPhotos:
    def __init__(self) -> None:
        self.items: dict[str, str | None] = {}

    async def get(self, key: str) -> tuple[bool, str | None]:
        return (key in self.items, self.items.get(key))

    async def put(self, key: str, url: str | None, *, ttl_seconds: int) -> None:
        self.items[key] = url


class MemoryLinks:
    def __init__(self) -> None:
        self.items: dict[str, list[PlanVideo]] = {}

    async def list(self, place_key: str) -> list[PlanVideo]:
        return list(self.items.get(place_key, []))

    async def add(self, place_key: str, video: PlanVideo) -> None:
        old = [v for v in self.items.get(place_key, []) if (v.source, v.id) != (video.source, video.id)]
        self.items[place_key] = [video, *old][:40]


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, PlanVideos] = {}
        self.ttls: dict[str, int] = {}

    async def get(self, key: str) -> PlanVideos | None:
        return self.items.get(key)

    async def put(self, key: str, videos: PlanVideos, *, ttl_seconds: int) -> None:
        self.items[key], self.ttls[key] = videos, ttl_seconds


class MemoryQuota:
    def __init__(self) -> None:
        self.used = 0

    async def take(self, user_id: str, day: str, limit: int) -> int | None:
        self.used += 1
        return None if self.used > limit else limit - self.used


def service(
    fake: FakeYouTube, limit: int = 80, *, youtube: bool = True
) -> tuple[PlanVideoService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    cache = MemoryCache()
    svc = PlanVideoService(
        youtube=YouTubeClient(http, SecretStr(KEY)) if youtube else None,
        resolver=LinkResolver(http),
        links=MemoryLinks(),
        cache=cache,
        quota=MemoryQuota(),
        link_quota=MemoryQuota(),
        photos=WikipediaPhotos(http),
        photo_cache=MemoryPhotos(),
        settings=PlanVideoSettings(daily_limit=limit, links_per_day=2),
    )
    return svc, cache


def test_parse_skips_the_strange() -> None:
    data = {
        "items": [
            item("abcdefghijk"),
            item("abcdefghijk"),  # repetido
            item("short"),  # id raro
            item("zzzzzzzzzzz", thumb="https://evil.example/x.jpg"),
            {"id": {"videoId": "yyyyyyyyyyy"}},  # sin snippet
            "basura",
        ]
    }
    videos = parse_videos(data)
    assert [v.id for v in videos] == ["abcdefghijk", "zzzzzzzzzzz"]
    assert videos[0].title == "Qué hacer en Lisboa & más"
    assert videos[1].thumb is None
    assert parse_videos(None) == []


async def test_searches_shorts_with_the_key_in_a_header_and_caches() -> None:
    fake = FakeYouTube()
    svc, cache = service(fake)
    found = await svc.videos("Lisboa", "qué hacer en Lisboa", "es")
    assert len(found.videos) == 2 and found.place == "Lisboa"
    req = fake.requests[0]
    assert req.headers["x-goog-api-key"] == KEY and KEY not in str(req.url)
    assert req.url.params["videoDuration"] == "short" and req.url.params["q"] == "qué hacer en Lisboa"
    assert req.url.params["relevanceLanguage"] == "es"
    # La segunda vez (aunque se escriba distinto) sale de la caché.
    await svc.videos("  LISBOA ", "qué hacer en LISBOA", "es")
    assert len(fake.requests) == 1
    assert cache.ttls[cache_key("lisboa", "es")] == 7 * 24 * 3600
    assert place_key("Lisboa") == place_key(" LISBOA ")


def test_only_real_tiktok_and_instagram_links() -> None:
    assert parse_link("https://www.tiktok.com/@ana.b/video/7301234567890123456?is_from_webapp=1") == (
        "tiktok",
        "7301234567890123456",
    )
    assert parse_link("https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=x") == ("instagram", "C1a2B3c4D5e")
    assert parse_link("https://instagram.com/p/C1a2B3c4D5e") == ("instagram", "C1a2B3c4D5e")
    for bad in (
        "https://evil.com/@a/video/7301234567890123456",
        "https://www.tiktok.com.evil.com/@a/video/7301234567890123456",
        "javascript:alert(1)",
        "https://www.tiktok.com/@ana",
        "https://www.instagram.com/ana/",
    ):
        assert parse_link(bad) is None, bad


async def test_pasted_links_come_first_and_youtube_is_optional() -> None:
    fake = FakeYouTube()
    svc, _ = service(fake, youtube=False)
    tiktok = await svc.add_link("u1", "Lisboa", "https://vm.tiktok.com/ZMabc123/")
    assert tiktok.source == "tiktok" and tiktok.id == "7301234567890123456"
    assert tiktok.title == "Tranvía 28 al atardecer" and tiktok.thumb is not None
    await svc.add_link("u1", "lisboa", "https://www.instagram.com/reel/C1a2B3c4D5e/")
    found = await svc.videos("LISBOA", "qué hacer en Lisboa", "es")
    assert [v.source for v in found.videos] == ["instagram", "tiktok"] and found.youtube is False
    assert fake.requests == []  # sin clave no se llama a YouTube
    # Tope de enlaces al día por persona.
    with pytest.raises(TooManyLinksError):
        await svc.add_link("u1", "Lisboa", "https://www.instagram.com/reel/Zzzzzzzzzzz/")


async def test_daily_limit_and_empty_results() -> None:
    fake = FakeYouTube()
    fake.items = []
    svc, cache = service(fake, limit=1)
    assert (await svc.videos("Nada", "nada", "es")).videos == []
    assert cache.ttls[cache_key("nada", "es")] == 24 * 3600
    assert (await svc.videos("Otro", "otro", "es")).videos == []
    assert len(fake.requests) == 1 and cache_key("otro", "es") not in cache.items


async def test_api_validates_and_says_busy() -> None:
    fake = FakeYouTube()
    svc, _ = service(fake)
    app = create_api(InMemoryStore(), plan_videos=svc)
    ok = {"place": "Lisboa", "q": "qué hacer en Lisboa", "lang": "es"}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        resp = await c.get("/v1/plan-videos", params=ok)
        assert resp.status_code == 200 and resp.json()["videos"][0]["id"] == "abcdefghijk"
        assert resp.headers["cache-control"] == "public, max-age=300"
        assert (await c.get("/v1/plan-videos", params={**ok, "lang": "ES!"})).status_code == 400
        assert (await c.get("/v1/plan-videos", params={**ok, "place": "a" * 61})).status_code == 400
        fake.status = 403
        busy = await c.get("/v1/plan-videos", params={**ok, "place": "Roma"})
        user = {"X-User-ID": "u-1", "X-User-Roles": "USER"}
        link = {"place": "Lisboa", "url": "https://www.instagram.com/reel/C1a2B3c4D5e/"}
        assert (await c.post("/v1/plan-videos/links", json=link)).status_code == 401
        added = await c.post("/v1/plan-videos/links", json=link, headers=user)
        assert added.status_code == 201 and added.json()["source"] == "instagram"
        bad = await c.post(
            "/v1/plan-videos/links", json={**link, "url": "https://evil.com/x/y/z"}, headers=user
        )
        assert bad.status_code == 422
    assert busy.status_code == 503 and busy.headers["retry-after"] == "60"


async def test_place_photo_from_wikipedia_with_fallback_and_cache() -> None:
    fake = FakeYouTube()
    svc, _ = service(fake)
    url = await svc.photo("Lisboa", "es")
    assert url is not None and url.startswith("https://upload.wikimedia.org/")
    assert [u.split("/")[2] for u in fake.wiki] == ["es.wikipedia.org", "en.wikipedia.org"]
    await svc.photo("lisboa", "es")
    assert len(fake.wiki) == 2  # de la caché
    assert await svc.photo("Nowhere", "en") is None
    assert (
        lead_photo({"type": "disambiguation", "thumbnail": {"source": "https://upload.wikimedia.org/x"}})
        is None
    )
    assert lead_photo({"thumbnail": {"source": "https://evil.com/x.jpg"}}) is None
