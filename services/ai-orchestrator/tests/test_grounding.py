"""Tests del anclaje a datos reales: el LLM no puede escribir cifras."""

from __future__ import annotations

from conftest import make_alert, make_stats

from ai_orchestrator.domain import Money
from ai_orchestrator.grounding import build_facts, grounding_problems, render


def test_facts_come_from_alert_and_history() -> None:
    facts = build_facts(make_alert(), make_stats())
    assert facts["precio_actual"] == "520,00 EUR"
    assert facts["precio_referencia"] == "800,00 EUR"
    assert facts["bajada_porcentaje"] == "35,00 %"
    assert facts["fecha_salida"] == "1 de diciembre de 2026"
    assert facts["precio_mediano_historial"] == "780,00 EUR"
    assert facts["cabina"] == "turista"


def test_history_in_other_currency_is_ignored() -> None:
    stats = make_stats().model_copy(update={"median": Money(currency="USD", amount_minor=1)})
    assert "precio_mediano_historial" not in build_facts(make_alert(), stats)
    assert "precio_mediano_historial" not in build_facts(make_alert(), None)


def test_valid_text_passes() -> None:
    facts = build_facts(make_alert(), None)
    assert grounding_problems(["Ahora {precio_actual}, antes {precio_referencia}."], facts) == []


def test_handwritten_numbers_are_rejected() -> None:
    facts = build_facts(make_alert(), None)
    for text in ["Cuesta 389 €", "Sale el 1 de diciembre", "Baja un 35%"]:
        assert grounding_problems([text], facts), text


def test_unknown_placeholders_are_rejected() -> None:
    facts = build_facts(make_alert(), None)
    problems = grounding_problems(["Hora de salida: {hora_salida}"], facts)
    assert any("{hora_salida}" in p for p in problems)


def test_loose_braces_are_rejected() -> None:
    facts = build_facts(make_alert(), None)
    assert grounding_problems(["Precio {precio actual}"], facts)


def test_render_fills_real_values() -> None:
    facts = build_facts(make_alert(), None)
    assert render("De {origen} a {destino} por {precio_actual}", facts) == "De MAD a NRT por 520,00 EUR"
