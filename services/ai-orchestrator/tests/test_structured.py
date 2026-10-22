"""Tests de las salidas estructuradas: JSON válido o reintento acotado."""

from __future__ import annotations

import pytest
from conftest import FakeLLM, advice_json

from ai_orchestrator.llm.client import ChatMessage, LLMUnavailableError
from ai_orchestrator.llm.structured import StructuredOutputError, extract_json_object, generate_structured
from ai_orchestrator.recommender import FareAdvice

MESSAGES = [ChatMessage("system", "instrucciones"), ChatMessage("user", "petición")]


async def run(llm: FakeLLM, **kw: object) -> FareAdvice:
    return await generate_structured(
        llm,
        MESSAGES,
        FareAdvice,
        temperature=0.1,
        max_tokens=100,
        max_attempts=3,
        **kw,  # type: ignore[arg-type]
    )


async def test_valid_json_on_first_try() -> None:
    llm = FakeLLM([advice_json()])
    result = await run(llm)
    assert result.verdict == "BUY_NOW"
    assert len(llm.calls) == 1
    # Se envía el esquema JSON y la temperatura baja a Ollama.
    assert llm.calls[0]["json_schema"]["properties"]["verdict"]
    assert llm.calls[0]["temperature"] == 0.1


async def test_chatty_wrapper_is_tolerated() -> None:
    llm = FakeLLM(["¡Claro! Aquí tienes:\n```json\n" + advice_json() + "\n```"])
    assert (await run(llm)).verdict == "BUY_NOW"


async def test_broken_json_is_retried_with_feedback() -> None:
    llm = FakeLLM(['{"verdict": "BUY_NOW", "headline": ', advice_json(verdict="WAIT")])
    result = await run(llm)
    assert result.verdict == "WAIT"
    assert len(llm.calls) == 2
    feedback = llm.calls[1]["messages"][-1]
    assert feedback.role == "user"
    assert "no es válida" in feedback.content


async def test_values_outside_schema_are_rejected() -> None:
    # "MAYBE" no es un veredicto permitido y sobra un campo.
    bad = '{"verdict": "MAYBE", "headline": "Hola hola", "explanation": "Algo largo", "extra": 1}'
    with pytest.raises(StructuredOutputError) as err:
        await run(FakeLLM([bad, bad, bad]))
    assert err.value.attempts == 3
    assert any("verdict" in p for p in err.value.problems)


async def test_custom_checks_trigger_retry() -> None:
    llm = FakeLLM([advice_json(headline="Cuesta 389 euros"), advice_json()])
    result = await run(llm, checks=lambda a: ["tiene cifras"] if any(c.isdigit() for c in a.headline) else [])
    assert "{precio_actual}" in result.headline
    assert len(llm.calls) == 2


async def test_attempts_are_bounded() -> None:
    llm = FakeLLM(["no json"] * 10)
    with pytest.raises(StructuredOutputError):
        await run(llm)
    assert len(llm.calls) == 3  # ni uno más


async def test_huge_response_is_rejected_without_parsing() -> None:
    with pytest.raises(StructuredOutputError, match="demasiado larga"):
        await run(FakeLLM(["{" + "a" * 30_000 + "}"] * 3))


async def test_unavailable_llm_propagates_without_retry() -> None:
    llm = FakeLLM([LLMUnavailableError("caído")])
    with pytest.raises(LLMUnavailableError):
        await run(llm)
    assert len(llm.calls) == 1


def test_extract_json_object() -> None:
    assert extract_json_object('bla {"a": 1} bla') == '{"a": 1}'
    assert extract_json_object("sin llaves") == "sin llaves"
