"""Cliente asíncrono de Google Gemini (la IA de Google, en sus servidores).

Para qué sirve:
    En un servidor pequeño (8 GB de memoria) no cabe un modelo de IA local
    (Ollama). Gemini tiene un plan GRATIS con una clave de Google AI Studio:
    con ella, Flyra (el chat), el traductor de cartas y "copia este viaje"
    funcionan sin Ollama.

Cómo se activa:
    Con la clave en el servidor (nunca en el código ni en el chat):
        sudo infrastructure/production/poner-clave.sh GEMINI_API_KEY
        sudo infrastructure/production/deploy.sh
    Si GEMINI_API_KEY está puesta, el servicio usa Gemini; si no, Ollama
    (cuando LLM_ENABLED=true) o nada.

Seguridad:
    - La clave viaja SOLO en la cabecera "x-goog-api-key", nunca en la URL
      (las URLs acaban en logs).
    - Nunca escribimos la clave ni el texto de la conversación en los logs.

Cumple la misma forma (``LLMClient``) que ``OllamaClient``: el resto del
servicio no sabe ni le importa cuál de los dos contesta.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Sequence
from typing import Any

import httpx
from pydantic import BaseModel, ValidationError

from ai_orchestrator.llm.client import ChatMessage, LLMResponseError, LLMUnavailableError

GEMINI_URL = "https://generativelanguage.googleapis.com"

# Algunos modelos de Gemini "piensan" antes de contestar, y lo que piensan
# cuenta como tokens de la respuesta. Este margen extra evita que la
# respuesta salga cortada a medias por culpa de lo que pensó.
THINKING_ALLOWANCE = 2048


class _Part(BaseModel):
    text: str = ""
    # True = es "lo que pensó" el modelo, no la respuesta: no se enseña.
    thought: bool = False


class _Content(BaseModel):
    parts: list[_Part] = []


class _Candidate(BaseModel):
    content: _Content | None = None


class _GenerateResponse(BaseModel):
    candidates: list[_Candidate] = []


def _contents(messages: Sequence[ChatMessage]) -> tuple[str, list[dict[str, Any]]]:
    """Separa las instrucciones ("system") del hilo, en el formato de Gemini.

    Gemini llama "model" a lo que en otros sitios es "assistant".
    """
    system: list[str] = []
    contents: list[dict[str, Any]] = []
    for m in messages:
        if m.role == "system":
            system.append(m.content)
            continue
        parts: list[dict[str, Any]] = [{"text": m.content}]
        # Fotos (solo modelos con visión): van como datos en base64.
        parts += [{"inline_data": {"mime_type": "image/jpeg", "data": img}} for img in m.images]
        role = "model" if m.role == "assistant" else "user"
        if contents and contents[-1]["role"] == role:
            # Dos mensajes seguidos del mismo lado: Gemini los quiere juntos.
            contents[-1]["parts"] += parts
        else:
            contents.append({"role": role, "parts": parts})
    return "\n\n".join(system), contents


class GeminiClient:
    """Implementación real contra la API de Gemini (generateContent)."""

    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        api_key: str,
        model: str,
        max_concurrency: int,
    ) -> None:
        # El AsyncClient se crea fuera (en __main__) con la URL base y el
        # tiempo máximo. La clave va en cada petición, en una cabecera.
        self._http = http
        self._api_key = api_key
        self._model = model
        self._slots = asyncio.Semaphore(max_concurrency)

    @property
    def model(self) -> str:
        return self._model

    async def chat(
        self,
        messages: Sequence[ChatMessage],
        *,
        json_schema: dict[str, Any] | None,
        temperature: float,
        max_tokens: int,
    ) -> str:
        system, contents = _contents(messages)
        if json_schema is not None:
            # Le pedimos JSON y le enseñamos la forma exacta. Aun así se
            # valida después (structured.py): confiar, pero verificar.
            system += (
                "\n\nAnswer ONLY with JSON that matches this JSON Schema, with no other text:\n"
                + json.dumps(json_schema, ensure_ascii=False)
            )
        config: dict[str, Any] = {
            "temperature": temperature,
            "maxOutputTokens": max_tokens + THINKING_ALLOWANCE,
        }
        if json_schema is not None:
            config["responseMimeType"] = "application/json"
        payload: dict[str, Any] = {"contents": contents, "generationConfig": config}
        if system:
            payload["systemInstruction"] = {"parts": [{"text": system}]}
        data = await self._post(payload)
        try:
            parsed = _GenerateResponse.model_validate(data)
        except ValidationError as exc:
            raise LLMResponseError("respuesta de Gemini con forma inesperada") from exc
        if not parsed.candidates or parsed.candidates[0].content is None:
            # Sin respuesta: casi siempre, el filtro de seguridad de Google.
            raise LLMResponseError("Gemini no devolvió ninguna respuesta")
        text = "".join(p.text for p in parsed.candidates[0].content.parts if not p.thought)
        if not text.strip():
            raise LLMResponseError("Gemini devolvió una respuesta vacía")
        return text

    async def _post(self, payload: dict[str, Any]) -> Any:
        path = f"/v1beta/models/{self._model}:generateContent"
        async with self._slots:
            try:
                resp = await self._http.post(path, json=payload, headers={"x-goog-api-key": self._api_key})
            except httpx.TimeoutException as exc:
                raise LLMUnavailableError("Gemini no respondió a tiempo") from exc
            except httpx.TransportError as exc:
                raise LLMUnavailableError(f"no se pudo conectar con Gemini: {type(exc).__name__}") from exc
        # 429: se acabó el cupo gratis del minuto o del día. 5xx: Google tiene
        # un problema. Las dos cosas son temporales.
        if resp.status_code == 429 or resp.status_code >= 500:
            raise LLMUnavailableError(f"Gemini devolvió {resp.status_code}")
        if resp.status_code >= 400:
            # 400/403: clave mala o modelo que no existe. No copiamos el texto
            # de la respuesta entero: solo el código.
            raise LLMResponseError(f"Gemini rechazó la petición ({resp.status_code})")
        try:
            return resp.json()
        except ValueError as exc:
            raise LLMResponseError("Gemini devolvió algo que no es JSON") from exc
