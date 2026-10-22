"""Tests de la búsqueda en Qdrant con un servidor simulado."""

from __future__ import annotations

import json

import httpx
import pytest

from ai_orchestrator.llm.client import LLMUnavailableError
from ai_orchestrator.retrieval import NoKnowledge, QdrantKnowledge, RetrievalError


class FakeEmbedder:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail

    async def embed(self, text: str) -> list[float]:
        if self.fail:
            raise LLMUnavailableError("caído")
        return [0.1, 0.2, 0.3]


def qdrant(handler: object, embedder: FakeEmbedder | None = None) -> QdrantKnowledge:
    http = httpx.AsyncClient(base_url="http://qdrant.test", transport=httpx.MockTransport(handler))  # type: ignore[arg-type]
    return QdrantKnowledge(http, embedder or FakeEmbedder(), collection="travel_knowledge")


async def test_search_returns_snippets_with_text() -> None:
    seen: dict[str, object] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["path"] = req.url.path
        seen["body"] = json.loads(req.content)
        return httpx.Response(
            200,
            json={
                "result": {
                    "points": [
                        {
                            "id": 1,
                            "score": 0.9,
                            "payload": {"text": " Lleva abrigo ", "source": "guia-tokio"},
                        },
                        {"id": 2, "score": 0.8, "payload": {"otra": "cosa"}},  # sin texto: se ignora
                    ]
                },
                "status": "ok",
            },
        )

    snippets = await qdrant(handler).search("Tokio", limit=3)
    assert [(s.text, s.source) for s in snippets] == [("Lleva abrigo", "guia-tokio")]
    assert seen["path"] == "/collections/travel_knowledge/points/query"
    assert seen["body"]["limit"] == 3  # type: ignore[index]


async def test_errors_become_retrieval_errors() -> None:
    with pytest.raises(RetrievalError):
        await qdrant(lambda _: httpx.Response(500)).search("x", limit=1)
    with pytest.raises(RetrievalError):
        await qdrant(lambda _: httpx.Response(200, json={"rara": 1})).search("x", limit=1)
    with pytest.raises(RetrievalError):
        await qdrant(lambda _: httpx.Response(200), FakeEmbedder(fail=True)).search("x", limit=1)


async def test_zero_limit_and_no_knowledge() -> None:
    assert await qdrant(lambda _: httpx.Response(500)).search("x", limit=0) == []
    assert await NoKnowledge().search("x", limit=5) == []
