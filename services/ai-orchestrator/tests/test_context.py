"""Tests del control de la ventana de contexto."""

from __future__ import annotations

from collections.abc import Sequence

import pytest

from ai_orchestrator.context import (
    ContextOverflowError,
    estimate_tokens,
    fit_messages,
    fit_messages_with_summary,
    message_tokens,
    truncate_text,
)
from ai_orchestrator.llm.client import ChatMessage


def chat(n: int, size: int = 300) -> list[ChatMessage]:
    msgs = [ChatMessage("system", "Eres un negociador.")]
    for i in range(n):
        role = "user" if i % 2 == 0 else "assistant"
        msgs.append(ChatMessage(role, f"mensaje {i} " + "x" * size))
    return msgs


def total(messages: Sequence[ChatMessage]) -> int:
    return sum(message_tokens(m) for m in messages)


def test_everything_fits_unchanged() -> None:
    msgs = chat(3)
    assert fit_messages(msgs, budget_tokens=10_000) == msgs


def test_old_messages_are_dropped_and_newest_kept() -> None:
    msgs = chat(50)
    fitted = fit_messages(msgs, budget_tokens=1000)
    assert fitted[0] == msgs[0]  # instrucciones intactas
    assert fitted[-1] == msgs[-1]  # lo más reciente intacto
    assert "Se omitieron" in fitted[1].content
    assert total(fitted) <= 1000


def test_system_prompt_too_big_is_an_error() -> None:
    with pytest.raises(ContextOverflowError):
        fit_messages([ChatMessage("system", "x" * 10_000)], budget_tokens=100)


class FakeSummarizer:
    def __init__(self) -> None:
        self.seen = 0

    async def summarize(self, messages: Sequence[ChatMessage], *, max_tokens: int) -> str:
        self.seen = len(messages)
        return "resumen " * 1000  # se pasa de largo a propósito


async def test_dropped_messages_are_summarised_and_bounded() -> None:
    msgs = chat(50)
    summarizer = FakeSummarizer()
    fitted = await fit_messages_with_summary(
        msgs, budget_tokens=1500, summarizer=summarizer, summary_tokens=100
    )
    assert summarizer.seen > 0
    assert fitted[1].content.startswith("Resumen de la conversación anterior")
    assert total(fitted) <= 1500
    assert fitted[-1] == msgs[-1]


def test_truncate_text() -> None:
    text = "palabra " * 500
    cut = truncate_text(text, 50)
    assert estimate_tokens(cut) <= 50
    assert cut.endswith("[recortado]")
    assert truncate_text("corto", 50) == "corto"
    assert truncate_text("algo", 0) == ""
