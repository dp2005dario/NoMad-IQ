"""Piezas compartidas por los tests: datos de ejemplo y dobles ("fakes").

Un "fake" es una versión de juguete de algo real (Ollama, PostgreSQL...) que
cumple la misma forma (el mismo Protocol). Así los tests son rápidos, no
necesitan GPU ni red, y dan siempre el mismo resultado.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Sequence
from datetime import UTC, date, datetime
from typing import Any

import pytest
from google.protobuf.timestamp_pb2 import Timestamp

from ai_orchestrator.domain import (
    AlertType,
    Cabin,
    FareAlert,
    KnowledgeSnippet,
    Money,
    PriceStats,
    Recommendation,
)
from ai_orchestrator.llm.client import ChatMessage, LLMUnavailableError
from ai_orchestrator.recommender import RecommenderSettings
from nomadiq.common.v1 import common_pb2
from nomadiq.flights.v1 import events_pb2, flights_pb2

ALERT_ID = "4b1f6f4e-6a43-4b8e-9a51-2a4f0d6b7c11"
USER_ID = "0f8fad5b-d9cb-469f-a165-70867728950e"
FIXED_NOW = datetime(2026, 10, 21, 12, 0, tzinfo=UTC)


def make_alert(**overrides: Any) -> FareAlert:
    data: dict[str, Any] = {
        "alert_id": ALERT_ID,
        "user_id": USER_ID,
        "alert_type": AlertType.PRICE_DROP,
        "watch_id": "w-1",
        "origin": "MAD",
        "destination": "NRT",
        "departure_date": date(2026, 12, 1),
        "cabin": Cabin.ECONOMY,
        "reference_price": Money(currency="EUR", amount_minor=80000),
        "current_price": Money(currency="EUR", amount_minor=52000),
        "drop_basis_points": 3500,
        "booking_deep_link": "https://example.com/book?aff=nomadiq",
        "correlation_id": "corr-1",
        "occurred_at": datetime(2026, 10, 21, 10, 0, tzinfo=UTC),
    }
    data.update(overrides)
    return FareAlert(**data)


def make_stats(minimum: int = 50000, median: int = 78000, maximum: int = 95000) -> PriceStats:
    return PriceStats(
        window_days=30,
        samples=42,
        minimum=Money(currency="EUR", amount_minor=minimum),
        maximum=Money(currency="EUR", amount_minor=maximum),
        median=Money(currency="EUR", amount_minor=median),
    )


def make_recommendation(**overrides: Any) -> Recommendation:
    data: dict[str, Any] = {
        "alert_id": ALERT_ID,
        "user_id": USER_ID,
        "verdict": "BUY_NOW",
        "headline": "Compra ya",
        "body": "Es un buen precio.",
        "source": "rules",
        "facts": {"precio_actual": "520,00 EUR"},
        "booking_deep_link": "https://example.com/book",
        "correlation_id": "corr-1",
        "alert_occurred_at": datetime(2026, 10, 21, 10, 0, tzinfo=UTC),
        "created_at": FIXED_NOW,
    }
    data.update(overrides)
    return Recommendation.model_validate(data)


def encode_alert_proto(alert: FareAlert | None = None, **field_overrides: Any) -> bytes:
    """Construye el mensaje protobuf tal como lo publica el price-consumer (Go)."""
    a = alert or make_alert()
    occurred = Timestamp()
    occurred.FromDatetime(a.occurred_at)
    evt = events_pb2.FareAlertTriggered(
        metadata=common_pb2.EventMetadata(
            event_id=a.alert_id,
            occurred_at=occurred,
            producer="price-consumer",
            correlation_id=a.correlation_id,
        ),
        alert_id=a.alert_id,
        user_id=a.user_id,
        alert_type=events_pb2.FARE_ALERT_TYPE_PRICE_DROP,
        watch_id=a.watch_id,
        route=flights_pb2.Route(origin_iata=a.origin, destination_iata=a.destination),
        departure_date=common_pb2.Date(
            year=a.departure_date.year, month=a.departure_date.month, day=a.departure_date.day
        ),
        cabin=flights_pb2.CABIN_CLASS_ECONOMY,
        reference_price=common_pb2.Money(
            currency_code=a.reference_price.currency, amount_minor=a.reference_price.amount_minor
        ),
        current_price=common_pb2.Money(
            currency_code=a.current_price.currency, amount_minor=a.current_price.amount_minor
        ),
        drop_basis_points=a.drop_basis_points,
        booking_deep_link=a.booking_deep_link,
    )
    for name, value in field_overrides.items():
        if value is None:
            evt.ClearField(name)
        elif hasattr(value, "SerializeToString"):
            # Los campos que son mensajes no se asignan: se copian.
            getattr(evt, name).CopyFrom(value)
        else:
            setattr(evt, name, value)
    return evt.SerializeToString()


PROTO_HEADERS = [
    ("content-type", b"application/x-protobuf"),
    ("ce_type", b"nomadiq.flights.v1.FareAlertTriggered"),
]


class FakeLLM:
    """LLM de guion: devuelve las respuestas indicadas, en orden.

    Si una respuesta es una excepción, la lanza (para simular caídas).
    Guarda cada llamada para poder comprobar qué se le envió.
    """

    def __init__(self, responses: Sequence[str | Exception]) -> None:
        self._responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    @property
    def model(self) -> str:
        return "fake-model"

    async def chat(
        self,
        messages: Sequence[ChatMessage],
        *,
        json_schema: dict[str, Any] | None,
        temperature: float,
        max_tokens: int,
    ) -> str:
        self.calls.append(
            {
                "messages": list(messages),
                "json_schema": json_schema,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
        )
        if not self._responses:
            raise LLMUnavailableError("el guion se ha quedado sin respuestas")
        nxt = self._responses.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        return nxt


def advice_json(verdict: str = "BUY_NOW", headline: str | None = None, explanation: str | None = None) -> str:
    return json.dumps(
        {
            "verdict": verdict,
            "headline": headline or "Chollo de {origen} a {destino}: {precio_actual}",
            "explanation": explanation
            or "Está por debajo de lo habitual ({precio_mediano_historial}). Si te encaja, cómpralo.",
        }
    )


class FakeHistory:
    def __init__(self, stats: PriceStats | None = None, error: Exception | None = None) -> None:
        self._stats = stats
        self._error = error
        self.calls = 0

    async def stats(self, alert: FareAlert, *, window_days: int) -> PriceStats | None:
        self.calls += 1
        if self._error:
            raise self._error
        return self._stats


class FakeKnowledge:
    def __init__(
        self, snippets: list[KnowledgeSnippet] | None = None, error: Exception | None = None
    ) -> None:
        self._snippets = snippets or []
        self._error = error

    async def search(self, query: str, *, limit: int) -> list[KnowledgeSnippet]:
        if self._error:
            raise self._error
        return self._snippets[:limit]


class InMemoryStore:
    """RecommendationStore en memoria (un diccionario hace de base de datos)."""

    def __init__(self) -> None:
        self.items: dict[str, Recommendation] = {}
        self.healthy = True

    async def exists(self, alert_id: str) -> bool:
        return alert_id in self.items

    async def save(self, rec: Recommendation) -> bool:
        if rec.alert_id in self.items:
            return False
        self.items[rec.alert_id] = rec
        return True

    async def list_for_user(self, user_id: str, *, limit: int) -> list[Recommendation]:
        mine = [r for r in self.items.values() if r.user_id == user_id]
        return sorted(mine, key=lambda r: r.created_at, reverse=True)[:limit]

    async def get_for_user(self, user_id: str, alert_id: str) -> Recommendation | None:
        rec = self.items.get(alert_id)
        return rec if rec and rec.user_id == user_id else None

    async def ping(self) -> bool:
        return self.healthy


@pytest.fixture
def recommender_settings() -> RecommenderSettings:
    return RecommenderSettings(
        temperature=0.1,
        max_output_tokens=300,
        max_attempts=3,
        history_window_days=30,
        knowledge_max_snippets=3,
        context_tokens=4096,
    )


def new_uuid() -> str:
    return str(uuid.uuid4())
