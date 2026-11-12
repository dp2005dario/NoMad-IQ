"""Tests de los vídeos de planes (YouTube Shorts): YouTube de mentira."""

from __future__ import annotations

from typing import Any

import httpx
from conftest import InMemoryStore
from pydantic import SecretStr

from ai_orchestrator.api import create_api
from ai_orchestrator.plan_videos.domain import PlanVideos
from ai_orchestrator.plan_videos.service import PlanVideoService, PlanVideoSettings, cache_key
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
        self.status = 200
        self.items: list[dict[str, Any]] = [item("abcdefghijk"), item("ABCDEFGHIJK")]

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status)
        return httpx.Response(200, json={"items": self.items})


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


def service(fake: FakeYouTube, limit: int = 80) -> tuple[PlanVideoService, MemoryCache]:
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    cache = MemoryCache()
    svc = PlanVideoService(
        youtube=YouTubeClient(http, SecretStr(KEY)),
        cache=cache,
        quota=MemoryQuota(),
        settings=PlanVideoSettings(daily_limit=limit),
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
        assert resp.headers["cache-control"] == "public, max-age=86400"
        assert (await c.get("/v1/plan-videos", params={**ok, "lang": "ES!"})).status_code == 400
        assert (await c.get("/v1/plan-videos", params={**ok, "place": "a" * 61})).status_code == 400
        fake.status = 403
        busy = await c.get("/v1/plan-videos", params={**ok, "place": "Roma"})
    assert busy.status_code == 503 and busy.headers["retry-after"] == "60"
