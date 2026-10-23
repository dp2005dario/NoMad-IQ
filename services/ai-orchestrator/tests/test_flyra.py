"""Pruebas del chat libre con Flyra (sin Ollama ni Redis de verdad)."""

from __future__ import annotations

import asyncio
from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from conftest import FakeLLM, InMemoryStore
from pydantic import ValidationError

from ai_orchestrator.api import create_api
from ai_orchestrator.flyra.domain import MAX_REPLY_CHARS, ChatRequest
from ai_orchestrator.flyra.service import (
    FlyraBusyError,
    FlyraService,
    FlyraSettings,
    QuotaExceededError,
    build_messages,
)
from ai_orchestrator.llm.client import ChatMessage, LLMUnavailableError

USER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 10, 23, 22, 0, tzinfo=UTC)


class MemoryQuota:
    """El contador de Redis, pero en un diccionario."""

    def __init__(self) -> None:
        self.used: dict[tuple[str, str], int] = {}

    async def take(self, user_id: str, day: str, limit: int) -> int | None:
        key = (user_id, day)
        self.used[key] = self.used.get(key, 0) + 1
        if self.used[key] > limit:
            return None
        return limit - self.used[key]

    async def give_back(self, user_id: str, day: str) -> None:
        self.used[(user_id, day)] -= 1


class SlowLLM:
    model = "slow"

    async def chat(
        self,
        messages: Sequence[ChatMessage],
        *,
        json_schema: dict[str, Any] | None,
        temperature: float,
        max_tokens: int,
    ) -> str:
        await asyncio.sleep(5)
        return "tarde"


def service(llm: Any, quota: MemoryQuota | None = None, limit: int = 3, timeout: float = 5) -> FlyraService:
    return FlyraService(
        llm=llm,
        quota=quota or MemoryQuota(),
        settings=FlyraSettings(daily_limit=limit, timeout_seconds=timeout),
        clock=lambda: NOW,
    )


def ask(text: str = "¿Qué ver en Lisboa?", **extra: Any) -> ChatRequest:
    return ChatRequest.model_validate({"messages": [{"role": "user", "text": text}], **extra})


def headers(user_id: str = USER) -> dict[str, str]:
    return {"X-User-ID": user_id, "X-User-Roles": "USER"}


def client(svc: FlyraService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), flyra=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


# --- Validación de la petición ---------------------------------------------------------


def test_last_message_must_be_the_person() -> None:
    with pytest.raises(ValidationError):
        ChatRequest.model_validate({"messages": [{"role": "flyra", "text": "Hola"}]})


def test_rejects_blank_long_and_odd_languages() -> None:
    with pytest.raises(ValidationError):
        ask("   ")
    with pytest.raises(ValidationError):
        ask("x" * 2001)
    with pytest.raises(ValidationError):
        ask(language="español")
    with pytest.raises(ValidationError):
        ChatRequest.model_validate({"messages": [{"role": "user", "text": "hola"}] * 21})
    assert ask(language="pt-BR").language == "pt-BR"


def test_messages_have_system_prompt_language_and_place() -> None:
    req = ChatRequest.model_validate(
        {
            "messages": [
                {"role": "user", "text": "Hola"},
                {"role": "flyra", "text": "¡Hola! ¿A dónde vas?"},
                {"role": "user", "text": "A Lisboa"},
            ],
            "language": "es",
            "place": "Lisboa",
        }
    )
    msgs = build_messages(req, NOW)
    assert [m.role for m in msgs] == ["system", "user", "assistant", "user"]
    assert "Flyra" in msgs[0].content
    assert "Spanish" in msgs[0].content
    assert "Lisboa" in msgs[0].content
    assert "2026-10-23" in msgs[0].content


# --- Servicio ----------------------------------------------------------------------------


async def test_answers_and_counts_down() -> None:
    llm = FakeLLM(["  Lisboa: Alfama y pasteles de Belém.  ", "Otra"])
    svc = service(llm)
    first = await svc.answer(USER, ask())
    assert first.reply == "Lisboa: Alfama y pasteles de Belém."
    assert first.remaining_today == 2
    assert (await svc.answer(USER, ask())).remaining_today == 1
    # Texto libre: sin esquema JSON.
    assert llm.calls[0]["json_schema"] is None


async def test_daily_quota_is_per_person() -> None:
    svc = service(FakeLLM(["a", "b", "c"]), limit=1)
    await svc.answer(USER, ask())
    with pytest.raises(QuotaExceededError) as err:
        await svc.answer(USER, ask())
    # Quedan 2 horas para medianoche (UTC).
    assert err.value.retry_after == 7200
    assert (await svc.answer(OTHER, ask())).remaining_today == 0


async def test_failures_do_not_spend_the_quota() -> None:
    quota = MemoryQuota()
    svc = service(FakeLLM([LLMUnavailableError("caído"), ""]), quota=quota)
    with pytest.raises(FlyraBusyError):
        await svc.answer(USER, ask())
    with pytest.raises(FlyraBusyError):
        await svc.answer(USER, ask())
    assert quota.used[(USER, "20261023")] == 0


async def test_slow_model_times_out() -> None:
    quota = MemoryQuota()
    with pytest.raises(FlyraBusyError):
        await service(SlowLLM(), quota=quota, timeout=0.05).answer(USER, ask())
    assert quota.used[(USER, "20261023")] == 0


async def test_long_replies_are_cut() -> None:
    reply = await service(FakeLLM(["x" * 5000])).answer(USER, ask())
    assert len(reply.reply) == MAX_REPLY_CHARS


# --- API -----------------------------------------------------------------------------------


async def test_api_needs_a_session() -> None:
    async with client(service(FakeLLM(["hola"]))) as c:
        resp = await c.post("/v1/flyra/chat", json={"messages": [{"role": "user", "text": "hola"}]})
        assert resp.status_code == 401


async def test_api_answers_without_caching() -> None:
    async with client(service(FakeLLM(["¡Buen viaje!"]))) as c:
        resp = await c.post(
            "/v1/flyra/chat",
            json={"messages": [{"role": "user", "text": "hola"}], "language": "es"},
            headers=headers(),
        )
        assert resp.status_code == 200
        assert resp.json() == {"reply": "¡Buen viaje!", "remaining_today": 2}
        assert resp.headers["cache-control"] == "no-store"


async def test_api_maps_quota_busy_and_bad_input() -> None:
    async with client(service(FakeLLM(["a", LLMUnavailableError("x")]), limit=1)) as c:
        ok = {"messages": [{"role": "user", "text": "hola"}]}
        assert (await c.post("/v1/flyra/chat", json=ok, headers=headers())).status_code == 200
        limited = await c.post("/v1/flyra/chat", json=ok, headers=headers())
        assert limited.status_code == 429
        assert limited.headers["retry-after"] == "7200"
        busy = await c.post("/v1/flyra/chat", json=ok, headers=headers(OTHER))
        assert busy.status_code == 503
        assert busy.headers["retry-after"] == "30"
        bad = await c.post("/v1/flyra/chat", json={"messages": []}, headers=headers())
        assert bad.status_code == 400
