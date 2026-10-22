"""Tests del cliente de Ollama con un servidor HTTP simulado (sin Ollama real)."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable

import httpx
import pytest

from ai_orchestrator.llm.client import ChatMessage, LLMResponseError, LLMUnavailableError, OllamaClient

Handler = Callable[[httpx.Request], httpx.Response]


def client(handler: Handler, max_concurrency: int = 2) -> OllamaClient:
    # MockTransport: httpx no sale a la red, llama a nuestra función.
    http = httpx.AsyncClient(base_url="http://ollama.test", transport=httpx.MockTransport(handler))
    return OllamaClient(
        http, model="llama3.1:8b", embed_model="nomic", num_ctx=4096, max_concurrency=max_concurrency
    )


async def ask(c: OllamaClient) -> str:
    return await c.chat(
        [ChatMessage("user", "hola")], json_schema={"type": "object"}, temperature=0.1, max_tokens=200
    )


async def test_sends_schema_temperature_and_limits() -> None:
    seen: dict[str, object] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen.update(json.loads(req.content))
        return httpx.Response(200, json={"message": {"role": "assistant", "content": "{}"}, "done": True})

    assert await ask(client(handler)) == "{}"
    assert seen["stream"] is False
    assert seen["format"] == {"type": "object"}
    assert seen["options"] == {"temperature": 0.1, "num_predict": 200, "num_ctx": 4096}


@pytest.mark.parametrize("status", [429, 500, 503])
async def test_server_errors_are_unavailable(status: int) -> None:
    with pytest.raises(LLMUnavailableError):
        await ask(client(lambda _: httpx.Response(status)))


async def test_client_errors_are_response_errors() -> None:
    with pytest.raises(LLMResponseError, match="404"):
        await ask(client(lambda _: httpx.Response(404, text="model not found")))


async def test_timeout_is_unavailable() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("lento", request=req)

    with pytest.raises(LLMUnavailableError, match="a tiempo"):
        await ask(client(handler))


async def test_connection_refused_is_unavailable() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("rechazada", request=req)

    with pytest.raises(LLMUnavailableError):
        await ask(client(handler))


async def test_unexpected_shape_is_response_error() -> None:
    with pytest.raises(LLMResponseError):
        await ask(client(lambda _: httpx.Response(200, json={"nada": True})))
    with pytest.raises(LLMResponseError):
        await ask(client(lambda _: httpx.Response(200, text="<html>")))


async def test_concurrency_is_limited() -> None:
    active = 0
    peak = 0

    async def slow(req: httpx.Request) -> httpx.Response:
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0.02)
        active -= 1
        return httpx.Response(200, json={"message": {"content": "{}"}})

    http = httpx.AsyncClient(base_url="http://ollama.test", transport=httpx.MockTransport(slow))
    c = OllamaClient(http, model="m", embed_model="e", num_ctx=2048, max_concurrency=2)
    await asyncio.gather(*(ask(c) for _ in range(8)))
    assert peak == 2  # nunca más de 2 peticiones a la vez contra Ollama


async def test_embed() -> None:
    c = client(lambda _: httpx.Response(200, json={"embeddings": [[0.1, 0.2]]}))
    assert await c.embed("texto") == [0.1, 0.2]
    bad = client(lambda _: httpx.Response(200, json={"embeddings": []}))
    with pytest.raises(LLMResponseError):
        await bad.embed("texto")
