"""Cliente asíncrono de Ollama (el servidor que ejecuta el modelo de IA en local).

El problema que resuelve (riesgo nº 1 de la revisión):
    Una respuesta del modelo puede tardar 5, 10 o 30 segundos. Si el programa
    se quedara "parado" esperando (llamada bloqueante), durante ese tiempo no
    podría atender a nadie más: como un camarero que, tras pedir un plato en
    cocina, se queda quieto en la puerta hasta que sale.

    Con ``httpx.AsyncClient`` y ``await``, el camarero toma nota, la deja en
    cocina y sigue atendiendo otras mesas; cuando el plato está listo, vuelve.
    Un solo proceso atiende cientos de peticiones a la vez.

Además:
    - Tiempo máximo por llamada: si Ollama no contesta, no esperamos eternamente.
    - Semáforo (``asyncio.Semaphore``): como el número de mesas de la cocina.
      Si Ollama solo puede con 2 peticiones a la vez, la tercera espera su
      turno en vez de saturar la GPU y hacer lentas a todas.
"""

from __future__ import annotations

import asyncio
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Literal, Protocol

import httpx
from pydantic import BaseModel, ValidationError


@dataclass(frozen=True, slots=True)
class ChatMessage:
    """Un mensaje de la conversación con el modelo.

    role: "system" (instrucciones), "user" (la petición) o "assistant" (lo que
    respondió el modelo antes).
    """

    role: Literal["system", "user", "assistant"]
    content: str


class LLMError(Exception):
    """Base de los errores del LLM."""


class LLMUnavailableError(LLMError):
    """Ollama no responde, tarda demasiado o está sobrecargado (temporal)."""


class LLMResponseError(LLMError):
    """Ollama respondió algo que no entendemos o rechazó la petición."""


class LLMClient(Protocol):
    """Lo que el resto del servicio necesita de un LLM.

    Es un "Protocol": describe la forma, no la implementación. Así en los
    tests usamos un LLM falso (sin Ollama real) que cumple la misma forma.
    """

    @property
    def model(self) -> str: ...

    async def chat(
        self,
        messages: Sequence[ChatMessage],
        *,
        json_schema: dict[str, Any] | None,
        temperature: float,
        max_tokens: int,
    ) -> str: ...


class Embedder(Protocol):
    """Convierte texto en un vector de números (para buscar por significado)."""

    async def embed(self, text: str) -> list[float]: ...


# Modelos de la respuesta de Ollama: validamos también lo que NOS llega.
class _OllamaMessage(BaseModel):
    content: str


class _OllamaChatResponse(BaseModel):
    message: _OllamaMessage
    done: bool = True


class _OllamaEmbedResponse(BaseModel):
    embeddings: list[list[float]]


class OllamaClient:
    """Implementación real contra la API HTTP de Ollama (/api/chat, /api/embed)."""

    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        model: str,
        embed_model: str,
        num_ctx: int,
        max_concurrency: int,
    ) -> None:
        # El AsyncClient se crea fuera (en __main__) con la URL base, el
        # tiempo máximo y los certificados. Aquí solo lo usamos.
        self._http = http
        self._model = model
        self._embed_model = embed_model
        self._num_ctx = num_ctx
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
        payload: dict[str, Any] = {
            "model": self._model,
            "messages": [{"role": m.role, "content": m.content} for m in messages],
            # Sin "streaming": queremos la respuesta completa de una vez para validarla.
            "stream": False,
            "options": {
                "temperature": temperature,
                # Límite de tokens de la respuesta: corta divagaciones largas.
                "num_predict": max_tokens,
                "num_ctx": self._num_ctx,
            },
        }
        if json_schema is not None:
            # "Salidas estructuradas" de Ollama: le pasamos el esquema JSON y
            # el modelo solo puede generar texto que encaje en él. Aun así lo
            # validamos después (structured.py): confiar, pero verificar.
            payload["format"] = json_schema
        data = await self._post("/api/chat", payload)
        try:
            return _OllamaChatResponse.model_validate(data).message.content
        except ValidationError as exc:
            raise LLMResponseError("respuesta de /api/chat con forma inesperada") from exc

    async def embed(self, text: str) -> list[float]:
        data = await self._post("/api/embed", {"model": self._embed_model, "input": text})
        try:
            parsed = _OllamaEmbedResponse.model_validate(data)
        except ValidationError as exc:
            raise LLMResponseError("respuesta de /api/embed con forma inesperada") from exc
        if len(parsed.embeddings) != 1 or not parsed.embeddings[0]:
            raise LLMResponseError("/api/embed no devolvió exactamente un vector")
        return parsed.embeddings[0]

    async def _post(self, path: str, payload: dict[str, Any]) -> Any:
        # "async with" espera turno en el semáforo y lo libera al terminar,
        # incluso si hay un error.
        async with self._slots:
            try:
                resp = await self._http.post(path, json=payload)
            except httpx.TimeoutException as exc:
                raise LLMUnavailableError(f"Ollama no respondió a tiempo ({path})") from exc
            except httpx.TransportError as exc:
                raise LLMUnavailableError(f"no se pudo conectar con Ollama ({path}): {exc}") from exc
        # 429/5xx: problema temporal del servidor. 4xx: petición incorrecta
        # (por ejemplo, el modelo no está descargado: "ollama pull ...").
        if resp.status_code == 429 or resp.status_code >= 500:
            raise LLMUnavailableError(f"Ollama devolvió {resp.status_code} en {path}")
        if resp.status_code >= 400:
            raise LLMResponseError(f"Ollama rechazó la petición ({resp.status_code}): {resp.text[:200]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise LLMResponseError(f"Ollama devolvió algo que no es JSON en {path}") from exc
