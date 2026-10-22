"""Tests del recomendador: LLM cuando se puede, reglas cuando no."""

from __future__ import annotations

import dataclasses

import pytest
from conftest import FIXED_NOW, FakeHistory, FakeKnowledge, FakeLLM, advice_json, make_alert, make_stats

from ai_orchestrator.domain import AlertType, KnowledgeSnippet, Money, Verdict
from ai_orchestrator.llm.client import LLMResponseError, LLMUnavailableError
from ai_orchestrator.recommender import FareRecommender, RecommenderSettings
from ai_orchestrator.retrieval import RetrievalError
from ai_orchestrator.store import StoreError


def recommender(
    settings: RecommenderSettings,
    llm: FakeLLM | None,
    history: FakeHistory | None = None,
    knowledge: FakeKnowledge | None = None,
) -> FareRecommender:
    return FareRecommender(
        llm=llm,
        history=history or FakeHistory(make_stats()),
        knowledge=knowledge or FakeKnowledge(),
        settings=settings,
        clock=lambda: FIXED_NOW,
    )


async def test_llm_text_is_filled_with_real_prices(recommender_settings: RecommenderSettings) -> None:
    llm = FakeLLM([advice_json()])
    rec = await recommender(recommender_settings, llm).recommend(make_alert())
    assert rec.source == "llm"
    assert rec.model == "fake-model"
    assert rec.verdict is Verdict.BUY_NOW
    assert rec.headline == "Chollo de MAD a NRT: 520,00 EUR"
    assert "780,00 EUR" in rec.body  # mediana real del historial
    assert rec.facts["precio_actual"] == "520,00 EUR"
    assert rec.created_at == FIXED_NOW


async def test_prompt_contains_facts_and_knowledge(recommender_settings: RecommenderSettings) -> None:
    llm = FakeLLM([advice_json()])
    knowledge = FakeKnowledge(
        [KnowledgeSnippet(text="En diciembre hace frío en Tokio.", source="guia", score=0.9)]
    )
    await recommender(recommender_settings, llm, knowledge=knowledge).recommend(make_alert())
    system, user = llm.calls[0]["messages"]
    assert "NUNCA escribas cifras" in system.content
    assert '"precio_actual": "520,00 EUR"' in user.content
    assert "hace frío en Tokio" in user.content


async def test_invented_number_is_retried_then_accepted(recommender_settings: RecommenderSettings) -> None:
    llm = FakeLLM([advice_json(headline="Vuelo a Tokio por 399 euros"), advice_json()])
    rec = await recommender(recommender_settings, llm).recommend(make_alert())
    assert rec.source == "llm"
    assert "399" not in rec.headline
    assert len(llm.calls) == 2


async def test_persistent_hallucination_falls_back_to_rules(
    recommender_settings: RecommenderSettings,
) -> None:
    llm = FakeLLM([advice_json(explanation="Sale a las {hora_salida} y cuesta poco.")] * 3)
    rec = await recommender(recommender_settings, llm).recommend(make_alert())
    assert rec.source == "rules"
    assert len(llm.calls) == recommender_settings.max_attempts


@pytest.mark.parametrize("error", [LLMUnavailableError("caído"), LLMResponseError("modelo no descargado")])
async def test_llm_errors_fall_back_to_rules(
    recommender_settings: RecommenderSettings, error: Exception
) -> None:
    rec = await recommender(recommender_settings, FakeLLM([error])).recommend(make_alert())
    assert rec.source == "rules"
    assert rec.model == ""


async def test_knowledge_failure_is_not_fatal(recommender_settings: RecommenderSettings) -> None:
    knowledge = FakeKnowledge(error=RetrievalError("qdrant caído"))
    rec = await recommender(recommender_settings, FakeLLM([advice_json()]), knowledge=knowledge).recommend(
        make_alert()
    )
    assert rec.source == "llm"


async def test_database_failure_propagates(recommender_settings: RecommenderSettings) -> None:
    # Sin historial no podemos garantizar una buena recomendación: el mensaje
    # se reintentará más tarde (el consumidor trata StoreError como temporal).
    with pytest.raises(StoreError):
        await recommender(
            recommender_settings, FakeLLM([]), history=FakeHistory(error=StoreError("x"))
        ).recommend(make_alert())


async def test_knowledge_is_trimmed_to_context_budget(recommender_settings: RecommenderSettings) -> None:
    tiny = dataclasses.replace(recommender_settings, context_tokens=1700)
    snippets = [KnowledgeSnippet(text="nota " * 400, source=f"s{i}", score=0.9) for i in range(3)]
    llm = FakeLLM([advice_json()])
    await recommender(tiny, llm, knowledge=FakeKnowledge(snippets)).recommend(make_alert())
    user = llm.calls[0]["messages"][1].content
    # Cada nota se recorta y solo entran las que caben; los hechos, siempre.
    assert "precio_actual" in user
    assert 1 <= user.count("…[recortado]") < 3


# --- Reglas (plan B), sin LLM -------------------------------------------------


@pytest.mark.parametrize(
    ("alert_kwargs", "stats", "verdict"),
    [
        ({"alert_type": AlertType.ERROR_FARE}, None, Verdict.BUY_NOW),
        ({"alert_type": AlertType.TARGET_REACHED}, None, Verdict.BUY_NOW),
        ({"drop_basis_points": 2500}, None, Verdict.BUY_NOW),
        ({"drop_basis_points": 1200}, None, Verdict.CONSIDER),
        ({"drop_basis_points": 500}, None, Verdict.WAIT),
        # Pequeña bajada, pero es el mínimo del historial: compra.
        ({"drop_basis_points": 500}, make_stats(minimum=52000), Verdict.BUY_NOW),
    ],
)
async def test_rules_are_deterministic(
    recommender_settings: RecommenderSettings,
    alert_kwargs: dict[str, object],
    stats: object,
    verdict: Verdict,
) -> None:
    alert = make_alert(**alert_kwargs)
    rec = await recommender(recommender_settings, None, history=FakeHistory(stats)).recommend(alert)  # type: ignore[arg-type]
    assert rec.source == "rules"
    assert rec.verdict is verdict
    assert "520,00 EUR" in rec.headline
    assert "{" not in rec.body


async def test_rules_mention_history_only_when_available(recommender_settings: RecommenderSettings) -> None:
    with_history = await recommender(recommender_settings, None).recommend(make_alert())
    without = await recommender(recommender_settings, None, history=FakeHistory(None)).recommend(make_alert())
    assert "780,00 EUR" in with_history.body
    assert "días" not in without.body


async def test_other_currency_history_not_used(recommender_settings: RecommenderSettings) -> None:
    alert = make_alert(
        reference_price=Money(currency="USD", amount_minor=80000),
        current_price=Money(currency="USD", amount_minor=52000),
    )
    rec = await recommender(recommender_settings, None).recommend(alert)
    assert "EUR" not in rec.body
