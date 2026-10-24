"""Pruebas del traductor de cartas (sin Ollama ni Redis de verdad)."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from conftest import FakeLLM, InMemoryStore
from pydantic import ValidationError
from test_flyra import MemoryQuota

from ai_orchestrator.api import create_api
from ai_orchestrator.llm.client import LLMUnavailableError
from ai_orchestrator.menu.domain import MenuRequest
from ai_orchestrator.menu.service import (
    MenuBusyError,
    MenuService,
    MenuSettings,
    QuotaExceededError,
    build_messages,
    parse_reply,
)

USER = "11111111-1111-4111-8111-111111111111"
NOW = datetime(2026, 10, 24, 22, 0, tzinfo=UTC)

LINES = ["お品書き", "親子丼 1.200円", "うどん 800円", "Wi-Fi: nomad2026"]


def ask(**extra: Any) -> MenuRequest:
    return MenuRequest.model_validate({"lines": LINES, "language": "es", "place_language": "ja", **extra})


def answer(*dishes: dict[str, Any]) -> str:
    return json.dumps({"dishes": list(dishes)})


OYAKODON = {
    "original": "親子丼",
    "name": "Oyakodon: pollo con huevo sobre arroz",
    "description": "Pollo y huevo cuajado con salsa dulce sobre arroz.",
    "allergens": "Lleva gluten y huevo: la salsa de soja tiene trigo.",
    "order_phrase": "親子丼をお願いします",
    "order_sounds": "Oyakodon o onegaishimasu",
    "price": "1.200円",
}


def service(llm: FakeLLM, limit: int = 3) -> tuple[MenuService, MemoryQuota]:
    quota = MemoryQuota()
    svc = MenuService(
        llm=llm,
        quota=quota,
        settings=MenuSettings(daily_limit=limit, timeout_seconds=5),
        clock=lambda: NOW,
    )
    return svc, quota


def headers(user_id: str = USER) -> dict[str, str]:
    return {"X-User-ID": user_id, "X-User-Roles": "USER"}


def client(svc: MenuService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), menu=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


# --- Validación de la petición ---------------------------------------------------------


def test_rejects_empty_huge_and_odd_languages() -> None:
    with pytest.raises(ValidationError):
        MenuRequest.model_validate({"lines": []})
    with pytest.raises(ValidationError):
        MenuRequest.model_validate({"lines": ["   "]})
    with pytest.raises(ValidationError):
        MenuRequest.model_validate({"lines": ["x" * 100] * 40})  # más de 3000 letras
    with pytest.raises(ValidationError):
        ask(language="japonés")
    with pytest.raises(ValidationError):
        ask(place_language="japonés")
    assert ask(place_language=None).place_language is None


def test_messages_carry_both_languages_and_numbered_lines() -> None:
    msgs = build_messages(ask())
    assert [m.role for m in msgs] == ["system", "user"]
    assert "Spanish" in msgs[0].content and "Japanese" in msgs[0].content
    assert "2. 親子丼 1.200円" in msgs[1].content


# --- Lo que contesta el modelo ----------------------------------------------------------


def test_invented_dishes_and_duplicates_are_dropped() -> None:
    dishes = parse_reply(
        answer(
            OYAKODON,
            {**OYAKODON, "name": "Otra vez"},  # repetido
            {"original": "Paella", "name": "Arroz"},  # no está en la carta
            {"original": "うどん", "name": ""},  # sin nombre
            {"original": "うどん", "name": "Udon: fideos gruesos", "price": "800円"},
            "nada",
        ),
        ask(),
    )
    assert [d.original for d in dishes] == ["親子丼", "うどん"]
    assert dishes[0].allergens.startswith("Lleva gluten")
    assert dishes[1].price == "800円"


def test_bad_json_or_nothing_usable_is_busy() -> None:
    with pytest.raises(MenuBusyError):
        parse_reply("no soy json", ask())
    with pytest.raises(MenuBusyError):
        parse_reply(json.dumps({"dishes": "x"}), ask())
    with pytest.raises(MenuBusyError):
        parse_reply(answer({"original": "Paella", "name": "Arroz"}), ask())


def test_long_fields_are_trimmed() -> None:
    dishes = parse_reply(answer({**OYAKODON, "description": "x" * 500}), ask())
    assert len(dishes[0].description) == 160


# --- Servicio ----------------------------------------------------------------------------


async def test_translates_and_counts_down() -> None:
    llm = FakeLLM([answer(OYAKODON)])
    svc, _ = service(llm)
    reply = await svc.translate(USER, ask())
    assert reply.dishes[0].name.startswith("Oyakodon")
    assert reply.remaining_today == 2
    # Se le pide JSON con el esquema de la carta.
    assert llm.calls[0]["json_schema"]["required"] == ["dishes"]


async def test_quota_runs_out() -> None:
    llm = FakeLLM([answer(OYAKODON)] * 3)
    svc, _ = service(llm, limit=2)
    await svc.translate(USER, ask())
    await svc.translate(USER, ask())
    with pytest.raises(QuotaExceededError) as exc:
        await svc.translate(USER, ask())
    assert exc.value.retry_after > 0


@pytest.mark.parametrize("failure", [LLMUnavailableError("no está"), None])
async def test_a_failure_does_not_spend_the_quota(failure: Exception | None) -> None:
    # Sin modelo, o con una respuesta inservible: la carta no cuenta.
    llm = FakeLLM([failure if failure is not None else "{}"])
    svc, quota = service(llm)
    with pytest.raises(MenuBusyError):
        await svc.translate(USER, ask())
    assert quota.used[(USER, "20261024")] == 0


# --- La API ------------------------------------------------------------------------------


async def test_api_needs_a_session_and_never_caches() -> None:
    llm = FakeLLM([answer(OYAKODON)])
    svc, _ = service(llm)
    async with client(svc) as http:
        anon = await http.post("/v1/menu/translate", json=ask().model_dump(mode="json"))
        assert anon.status_code == 401
        ok = await http.post("/v1/menu/translate", json=ask().model_dump(mode="json"), headers=headers())
        assert ok.status_code == 200
        assert ok.headers["Cache-Control"] == "no-store"
        body = ok.json()
        assert body["dishes"][0]["order_sounds"] == "Oyakodon o onegaishimasu"
        assert body["remaining_today"] == 2


async def test_api_says_busy_and_out_of_quota() -> None:
    svc, _ = service(FakeLLM([LLMUnavailableError("no está")]), limit=1)
    async with client(svc) as http:
        busy = await http.post("/v1/menu/translate", json=ask().model_dump(mode="json"), headers=headers())
        assert busy.status_code == 503
        assert busy.headers["Retry-After"] == "30"

    svc, _ = service(FakeLLM([answer(OYAKODON)]), limit=0)
    async with client(svc) as http:
        out = await http.post("/v1/menu/translate", json=ask().model_dump(mode="json"), headers=headers())
        assert out.status_code == 429
        assert int(out.headers["Retry-After"]) > 0
