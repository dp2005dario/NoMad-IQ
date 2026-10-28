"""Tests de los espejos de Overpass, la caché obsoleta (stale) y su configuración."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import httpx
import pytest
from test_config import DEV, clean_env, settings  # noqa: F401  (clean_env es un fixture autouse)

from ai_orchestrator.atms.overpass import OverpassError, post_query
from ai_orchestrator.nearby.domain import Nearby
from ai_orchestrator.nearby.service import RedisNearbyCache

A, B = "https://a.test/api", "https://b.test/api"
OK = {"elements": []}


def client(handler: Callable[[httpx.Request], httpx.Response]) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_falls_back_to_next_server_on_502() -> None:
    hosts: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        hosts.append(req.url.host)
        return httpx.Response(502) if req.url.host == "a.test" else httpx.Response(200, json=OK)

    resp = await post_query(client(handler), [A, B], "q", retry_pause=0)
    assert resp.status_code == 200 and hosts == ["a.test", "b.test"]


async def test_falls_back_on_timeout_and_does_not_repeat_slow_server() -> None:
    hosts: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        hosts.append(req.url.host)
        if req.url.host == "a.test":
            raise httpx.ReadTimeout("lento")
        return httpx.Response(200, json=OK)

    resp = await post_query(client(handler), [A, B], "q", retry_pause=0)
    assert resp.status_code == 200 and hosts == ["a.test", "b.test"]


async def test_retries_fast_failures_once() -> None:
    calls: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        calls.append(req.url.host)
        return httpx.Response(503) if len(calls) < 3 else httpx.Response(200, json=OK)

    resp = await post_query(client(handler), [A, B], "q", retry_pause=0)
    assert resp.status_code == 200 and calls == ["a.test", "b.test", "a.test"]


async def test_returns_last_response_when_all_fail() -> None:
    resp = await post_query(client(lambda r: httpx.Response(502)), [A, B], "q", retry_pause=0)
    assert resp.status_code == 502


async def test_does_not_try_other_servers_for_client_errors() -> None:
    calls: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        calls.append(req.url.host)
        return httpx.Response(400)

    resp = await post_query(client(handler), [A, B], "q", retry_pause=0)
    assert resp.status_code == 400 and calls == ["a.test"]


async def test_error_message_has_only_the_error_type() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("40.41,-3.70")

    with pytest.raises(OverpassError) as info:
        await post_query(client(handler), [A], "q", retry_pause=0)
    assert "40.41" not in str(info.value) and "ReadTimeout" in str(info.value)


def test_config_lists_primary_then_known_mirror_without_duplicates() -> None:
    s = settings(**DEV)
    assert s.overpass_servers == [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]
    custom = settings(
        **DEV,
        overpass_fallback_urls=" https://x.test/i , https://overpass-api.de/api/interpreter ,",
    )
    assert custom.overpass_servers == ["https://overpass-api.de/api/interpreter", "https://x.test/i"]
    assert settings(**DEV, overpass_fallback_urls="").overpass_servers == [s.overpass_url]


def test_config_rejects_plain_http_mirrors() -> None:
    with pytest.raises(ValueError, match="https"):
        settings(**DEV, overpass_fallback_urls="http://x.test/i")


class FakeRedis:
    """Un Redis de mentira con caducidad a mano (solo get, mget y set)."""

    def __init__(self) -> None:
        self.data: dict[str, str] = {}
        self.ttl: dict[str, int] = {}

    async def set(self, key: str, value: str, ex: int) -> None:
        self.data[key], self.ttl[key] = value, ex

    async def get(self, key: str) -> str | None:
        return self.data.get(key)

    async def mget(self, keys: list[str]) -> list[str | None]:
        return [self.data.get(k) for k in keys]


async def test_redis_cache_keeps_stale_copy_after_fresh_mark_expires() -> None:
    redis: Any = FakeRedis()
    cache = RedisNearbyCache(redis, stale_seconds=1000)
    await cache.put(Nearby(lat=40.4, lon=-3.7, spots=[]), ttl_seconds=100)
    key = "ai:nearby:v2:40.40:-3.70"
    assert redis.ttl[key] == 1100 and redis.ttl[f"{key}:fresh"] == 100
    assert await cache.get(40.4, -3.7) is not None
    del redis.data[f"{key}:fresh"]  # la marca caduca
    assert await cache.get(40.4, -3.7) is None  # ya no es fresco
    assert await cache.get_stale(40.4, -3.7) is not None  # pero sigue ahí
