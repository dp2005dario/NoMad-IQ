"""Respuestas estructuradas: obligar al modelo a contestar en JSON válido.

El problema (riesgo nº 2 de la revisión):
    Los modelos tienden a "charlar": "¡Claro! Aquí tienes tu plan: {...}" o a
    dejarse una llave sin cerrar. Si el programa espera un JSON perfecto, eso
    lo rompe.

La solución, en cuatro capas:
    1. Le pasamos a Ollama el esquema JSON exacto (lo genera Pydantic).
    2. Temperatura baja: el modelo es menos "creativo" y más obediente.
    3. Validamos SIEMPRE la respuesta con Pydantic (tipos, longitudes, valores
       permitidos) y además con comprobaciones propias (``checks``), por
       ejemplo "no escribas cifras".
    4. Si falla, se lo decimos al modelo ("tu respuesta no vale por X,
       corrígela") y reintentamos, pero un número LIMITADO de veces. Después,
       nos rendimos con un error claro y quien llama usa su plan B.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Sequence

from pydantic import BaseModel, ValidationError

from ai_orchestrator.llm.client import ChatMessage, LLMClient

log = logging.getLogger(__name__)

# Una respuesta mucho más larga que esto ya no es una respuesta corta en JSON:
# es el modelo desbocado. No la procesamos.
MAX_RAW_RESPONSE_CHARS = 20_000


class StructuredOutputError(Exception):
    """El modelo no dio una respuesta válida tras todos los intentos."""

    def __init__(self, attempts: int, problems: Sequence[str]) -> None:
        super().__init__(f"sin respuesta válida tras {attempts} intentos: {'; '.join(problems)}")
        self.attempts = attempts
        self.problems = list(problems)


def extract_json_object(raw: str) -> str:
    """Saca el objeto JSON de una respuesta, tolerando "envoltorios" típicos.

    Ej.: "```json\\n{...}\\n```" o "Aquí lo tienes: {...}". No arregla JSON
    roto (eso sería adivinar): solo quita lo que sobra alrededor.
    """
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end < start:
        return raw.strip()
    return raw[start : end + 1]


def _describe(exc: ValidationError) -> list[str]:
    # Mensajes cortos y concretos para que el modelo sepa qué corregir.
    return [f"campo '{'.'.join(map(str, e['loc'])) or '(raíz)'}': {e['msg']}" for e in exc.errors()[:5]]


async def generate_structured[T: BaseModel](
    client: LLMClient,
    messages: Sequence[ChatMessage],
    schema: type[T],
    *,
    temperature: float,
    max_tokens: int,
    max_attempts: int,
    checks: Callable[[T], Sequence[str]] | None = None,
) -> T:
    """Pide al LLM una respuesta que encaje en ``schema`` y pase ``checks``.

    Errores de conexión con Ollama (LLMUnavailableError) NO se reintentan
    aquí: se propagan para que quien llama decida (normalmente, plan B).
    """
    if max_attempts < 1:
        raise ValueError("max_attempts debe ser >= 1")
    conversation = list(messages)
    json_schema = schema.model_json_schema()
    problems: list[str] = []

    for attempt in range(1, max_attempts + 1):
        raw = await client.chat(
            conversation, json_schema=json_schema, temperature=temperature, max_tokens=max_tokens
        )
        if len(raw) > MAX_RAW_RESPONSE_CHARS:
            problems = [f"respuesta demasiado larga ({len(raw)} caracteres)"]
        else:
            try:
                value = schema.model_validate_json(extract_json_object(raw))
            except ValidationError as exc:
                problems = _describe(exc)
            else:
                problems = list(checks(value)) if checks else []
                if not problems:
                    return value

        log.warning(
            "respuesta del LLM inválida",
            extra={"attempt": attempt, "max_attempts": max_attempts, "problems": problems},
        )
        # Le enseñamos al modelo su respuesta y qué estaba mal. Recortamos su
        # respuesta para que un intento fallido no llene la ventana de contexto.
        conversation += [
            ChatMessage("assistant", raw[:2000]),
            ChatMessage(
                "user",
                "Tu respuesta no es válida por: "
                + "; ".join(problems)
                + ". Responde de nuevo SOLO con el objeto JSON corregido, sin texto adicional.",
            ),
        ]

    raise StructuredOutputError(max_attempts, problems)
