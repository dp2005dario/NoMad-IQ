"""Recuperación de contexto real (la "R" de RAG: Retrieval-Augmented Generation).

RAG en una frase: antes de preguntar al modelo, buscamos nosotros los datos
relevantes en nuestras bases de datos y se los damos; el modelo razona sobre
ellos en vez de tirar de memoria. Como un examen "a libro abierto" donde el
libro lo elegimos nosotros.

Dos fuentes:
    - PriceHistory: estadísticas de precios reales (PostgreSQL). Implementación
      en store.py.
    - KnowledgeBase: notas de viaje buscadas por significado en Qdrant (base de
      datos vectorial). Opcional: si no está configurada, no se usa.

Ambas son "Protocol": en los tests se sustituyen por versiones falsas.
"""

from __future__ import annotations

import logging
from typing import Any, Protocol

import httpx
from pydantic import BaseModel, ValidationError

from ai_orchestrator.domain import FareAlert, KnowledgeSnippet, PriceStats
from ai_orchestrator.llm.client import Embedder, LLMError

log = logging.getLogger(__name__)


class RetrievalError(Exception):
    """No se pudo consultar una fuente de contexto (problema temporal)."""


class PriceHistory(Protocol):
    async def stats(self, alert: FareAlert, *, window_days: int) -> PriceStats | None:
        """Resumen de precios reales de la ruta de la alerta, o None si no hay datos."""
        ...


class KnowledgeBase(Protocol):
    async def search(self, query: str, *, limit: int) -> list[KnowledgeSnippet]: ...


class NoKnowledge:
    """Base de conocimiento vacía: se usa cuando Qdrant no está configurado."""

    async def search(self, query: str, *, limit: int) -> list[KnowledgeSnippet]:
        return []


class _QdrantPoint(BaseModel):
    score: float
    payload: dict[str, Any] | None = None


class _QdrantResult(BaseModel):
    points: list[_QdrantPoint]


class _QdrantResponse(BaseModel):
    result: _QdrantResult


class QdrantKnowledge:
    """Busca fragmentos de conocimiento en Qdrant por similitud de significado.

    Cómo funciona una búsqueda vectorial, sin matemáticas:
        1. El texto de la pregunta se convierte en una lista de números (un
           "vector") con un modelo de embeddings de Ollama.
        2. Qdrant guarda vectores de muchos textos y devuelve los más
           "cercanos": los que hablan de lo mismo aunque usen otras palabras.

    Cada punto de la colección debe tener en su payload un campo "text" y,
    opcionalmente, "source". Los puntos sin "text" se ignoran.
    """

    def __init__(
        self,
        http: httpx.AsyncClient,
        embedder: Embedder,
        *,
        collection: str,
        min_score: float = 0.5,
    ) -> None:
        # El AsyncClient lleva ya la URL base y la cabecera api-key (ver __main__).
        self._http = http
        self._embedder = embedder
        self._collection = collection
        self._min_score = min_score

    async def search(self, query: str, *, limit: int) -> list[KnowledgeSnippet]:
        if limit <= 0:
            return []
        try:
            vector = await self._embedder.embed(query)
        except LLMError as exc:
            raise RetrievalError(f"no se pudo vectorizar la consulta: {exc}") from exc
        try:
            resp = await self._http.post(
                f"/collections/{self._collection}/points/query",
                json={
                    "query": vector,
                    "limit": limit,
                    "with_payload": True,
                    # Por debajo de este parecido, el resultado no es relevante:
                    # mejor no dar contexto que dar contexto que despiste.
                    "score_threshold": self._min_score,
                },
            )
        except httpx.HTTPError as exc:
            raise RetrievalError(f"Qdrant no responde: {exc}") from exc
        if resp.status_code != 200:
            raise RetrievalError(f"Qdrant devolvió {resp.status_code}")
        try:
            points = _QdrantResponse.model_validate(resp.json()).result.points
        except (ValidationError, ValueError) as exc:
            raise RetrievalError("respuesta de Qdrant con forma inesperada") from exc

        snippets: list[KnowledgeSnippet] = []
        for point in points:
            payload = point.payload or {}
            text = payload.get("text")
            if not isinstance(text, str) or not text.strip():
                continue
            source = payload.get("source")
            snippets.append(
                KnowledgeSnippet(
                    text=text.strip(),
                    source=source[:200] if isinstance(source, str) and source else "desconocida",
                    score=point.score,
                )
            )
        return snippets
