"""Control de la ventana de contexto (cuánto texto le pasamos al modelo).

El problema (riesgo nº 4 de la revisión):
    Un modelo solo puede "leer" una cantidad limitada de texto a la vez (su
    ventana de contexto, medida en tokens; un token ≈ ¾ de palabra). En un
    chat de grupo el historial crece sin parar. Si se lo pasamos entero cada
    vez, llega un momento en que no cabe: el modelo falla, "olvida" el
    principio, o tarda muchísimo.

La solución:
    - Calcular (aproximadamente) cuánto ocupa cada mensaje.
    - Conservar SIEMPRE las instrucciones (mensajes "system") y los mensajes
      más recientes, que son los que importan para el turno actual.
    - Lo antiguo que no cabe se descarta o, si hay un "resumidor", se
      sustituye por un resumen corto. Como las actas de una reunión: no
      relees la grabación entera, lees el resumen.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from typing import Protocol

from ai_orchestrator.llm.client import ChatMessage

# Regla práctica: en español, un token ocupa unos 3,5 caracteres de media.
# Usamos 3 para quedarnos cortos a propósito (mejor sobrar que pasarse).
CHARS_PER_TOKEN = 3
# Coste fijo aproximado de cada mensaje (rol, separadores...).
TOKENS_PER_MESSAGE = 4
TRUNCATION_MARK = " …[recortado]"


class ContextOverflowError(ValueError):
    """Ni siquiera las instrucciones caben en el presupuesto."""


class Summarizer(Protocol):
    """Algo capaz de resumir mensajes antiguos (normalmente, otro LLM)."""

    async def summarize(self, messages: Sequence[ChatMessage], *, max_tokens: int) -> str: ...


def estimate_tokens(text: str) -> int:
    """Estimación barata y pesimista de tokens (sin cargar el tokenizador real)."""
    return math.ceil(len(text) / CHARS_PER_TOKEN)


def message_tokens(message: ChatMessage) -> int:
    return estimate_tokens(message.content) + TOKENS_PER_MESSAGE


def truncate_text(text: str, max_tokens: int) -> str:
    """Recorta un texto para que ocupe como mucho ``max_tokens``."""
    if max_tokens <= 0:
        return ""
    if estimate_tokens(text) <= max_tokens:
        return text
    keep = max(0, max_tokens * CHARS_PER_TOKEN - len(TRUNCATION_MARK))
    return text[:keep].rstrip() + TRUNCATION_MARK


def _split(messages: Sequence[ChatMessage]) -> tuple[list[ChatMessage], list[ChatMessage]]:
    system = [m for m in messages if m.role == "system"]
    rest = [m for m in messages if m.role != "system"]
    return system, rest


def _newest_that_fit(rest: Sequence[ChatMessage], budget: int) -> list[ChatMessage]:
    # Recorremos del más nuevo al más viejo y paramos en cuanto uno no cabe:
    # así nunca quedan "huecos" en medio de la conversación.
    kept: list[ChatMessage] = []
    used = 0
    for message in reversed(rest):
        cost = message_tokens(message)
        if used + cost > budget:
            break
        kept.append(message)
        used += cost
    kept.reverse()
    return kept


def fit_messages(messages: Sequence[ChatMessage], *, budget_tokens: int) -> list[ChatMessage]:
    """Devuelve los mensajes que caben en el presupuesto, sin resumir.

    Mantiene todos los "system" y los mensajes más recientes; si se descarta
    algo, añade una nota para que el modelo sepa que falta historia.
    """
    system, rest = _split(messages)
    system_cost = sum(message_tokens(m) for m in system)
    if system_cost > budget_tokens:
        raise ContextOverflowError(
            f"las instrucciones ocupan {system_cost} tokens; presupuesto {budget_tokens}"
        )

    note_budget = 30  # reservado para la nota de "se omitieron N mensajes"
    kept = _newest_that_fit(rest, budget_tokens - system_cost - note_budget)
    dropped = len(rest) - len(kept)
    if dropped == 0:
        return [*system, *kept]
    note = ChatMessage("system", f"[Se omitieron {dropped} mensajes antiguos para no exceder el contexto.]")
    return [*system, note, *kept]


async def fit_messages_with_summary(
    messages: Sequence[ChatMessage],
    *,
    budget_tokens: int,
    summarizer: Summarizer,
    summary_tokens: int = 200,
) -> list[ChatMessage]:
    """Como fit_messages, pero lo que no cabe se sustituye por un resumen.

    El resumen también tiene un tamaño máximo, así que el total sigue acotado
    por muy larga que sea la conversación.
    """
    system, rest = _split(messages)
    system_cost = sum(message_tokens(m) for m in system)
    reserved = summary_tokens + TOKENS_PER_MESSAGE + 10
    if system_cost + reserved > budget_tokens:
        raise ContextOverflowError("no queda sitio para instrucciones y resumen")

    kept = _newest_that_fit(rest, budget_tokens - system_cost - reserved)
    dropped = rest[: len(rest) - len(kept)]
    if not dropped:
        return [*system, *kept]
    summary = await summarizer.summarize(dropped, max_tokens=summary_tokens)
    # Aunque el resumidor se pase de largo, lo recortamos: el límite es nuestro.
    summary = truncate_text(summary, summary_tokens)
    return [*system, ChatMessage("system", f"Resumen de la conversación anterior: {summary}"), *kept]
