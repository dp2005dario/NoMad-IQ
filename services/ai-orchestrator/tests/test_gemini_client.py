"""Tests del cliente de Gemini con un servidor HTTP simulado (sin Google real)."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx
import pytest

from ai_orchestrator.llm.client import ChatMessage, LLMResponseError, LLMUnavailableError
from ai_orchestrator.llm.gemini import THINKING_ALLOWANCE, GeminiClient

Handler = Callable[[httpx.Request], httpx.Response]
KEY = "AIzaSyA-clave-de-prueba-0123456789"


def client(handler: Handler) -> GeminiClient:
    # MockTransport: httpx no sale a la red, llama a nuestra función.
    http = httpx.AsyncClient(base_url="https://gemini.test", transport=httpx.MockTransport(handler))
    return GeminiClient(http, api_key=KEY, model="gemini-flash-latest", max_concurrency=2)


def answer(*parts: dict[str, object]) -> httpx.Response:
    return httpx.Response(200, json={"candidates": [{"content": {"role": "model", "parts": list(parts)}}]})


CHAT = [
    ChatMessage("system", "Eres Flyra."),
    ChatMessage("user", "hola"),
    ChatMessage("assistant", "¡Hola!"),
    ChatMessage("user", "¿qué ver en Lisboa?"),
]


async def test_sends_system_roles_and_key_only_in_header() -> None:
    seen: dict[str, object] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["path"] = req.url.path
        seen["query"] = str(req.url.query)
        seen["key"] = req.headers.get("x-goog-api-key")
        seen["body"] = json.loads(req.content)
        return answer({"text": "Alfama y Belém."})

    text = await client(handler).chat(CHAT, json_schema=None, temperature=0.6, max_tokens=450)
    assert text == "Alfama y Belém."
    assert seen["path"] == "/v1beta/models/gemini-flash-latest:generateContent"
    # La clave va en la cabecera, nunca en la URL (las URLs acaban en logs).
    assert seen["key"] == KEY
    assert KEY not in str(seen["query"])
    body = seen["body"]
    assert isinstance(body, dict)
    assert body["systemInstruction"] == {"parts": [{"text": "Eres Flyra."}]}
    assert [c["role"] for c in body["contents"]] == ["user", "model", "user"]
    assert body["generationConfig"] == {"temperature": 0.6, "maxOutputTokens": 450 + THINKING_ALLOWANCE}


async def test_json_schema_asks_for_json() -> None:
    seen: dict[str, object] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen.update(json.loads(req.content))
        return answer({"text": "{}"})

    schema = {"type": "object"}
    out = await client(handler).chat(CHAT, json_schema=schema, temperature=0.1, max_tokens=200)
    assert out == "{}"
    config = seen["generationConfig"]
    assert isinstance(config, dict)
    assert config["responseMimeType"] == "application/json"
    system = seen["systemInstruction"]
    assert isinstance(system, dict)
    assert '{"type": "object"}' in system["parts"][0]["text"]


async def test_thoughts_are_not_shown() -> None:
    reply = answer({"text": "pensando...", "thought": True}, {"text": "Ve a Sintra."})
    out = await client(lambda _: reply).chat(CHAT, json_schema=None, temperature=0.6, max_tokens=450)
    assert out == "Ve a Sintra."


async def test_same_side_messages_are_joined() -> None:
    seen: dict[str, object] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen.update(json.loads(req.content))
        return answer({"text": "ok"})

    msgs = [ChatMessage("user", "uno"), ChatMessage("user", "dos")]
    await client(handler).chat(msgs, json_schema=None, temperature=0.6, max_tokens=100)
    assert seen["contents"] == [{"role": "user", "parts": [{"text": "uno"}, {"text": "dos"}]}]
    assert "systemInstruction" not in seen


@pytest.mark.parametrize("status", [429, 500, 503])
async def test_server_errors_are_unavailable(status: int) -> None:
    with pytest.raises(LLMUnavailableError):
        await client(lambda _: httpx.Response(status)).chat(
            CHAT, json_schema=None, temperature=0.6, max_tokens=9
        )


async def test_bad_key_is_response_error_without_echoing_body() -> None:
    reply = httpx.Response(400, text="API key not valid " + KEY)
    with pytest.raises(LLMResponseError) as info:
        await client(lambda _: reply).chat(CHAT, json_schema=None, temperature=0.6, max_tokens=9)
    assert "400" in str(info.value)
    assert KEY not in str(info.value)


@pytest.mark.parametrize(
    "body",
    [
        {"candidates": []},
        {"promptFeedback": {"blockReason": "SAFETY"}},
        {"candidates": [{"content": {"parts": []}}]},
    ],
)
async def test_no_answer_is_response_error(body: dict[str, object]) -> None:
    with pytest.raises(LLMResponseError):
        await client(lambda _: httpx.Response(200, json=body)).chat(
            CHAT, json_schema=None, temperature=0.6, max_tokens=9
        )


async def test_timeout_is_unavailable() -> None:
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("lento", request=req)

    with pytest.raises(LLMUnavailableError, match="a tiempo"):
        await client(handler).chat(CHAT, json_schema=None, temperature=0.6, max_tokens=9)
