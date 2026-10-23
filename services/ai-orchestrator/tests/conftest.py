"""Piezas compartidas por los tests: datos de ejemplo y dobles ("fakes").

Un "fake" es una versión de juguete de algo real (Ollama, PostgreSQL...) que
cumple la misma forma (el mismo Protocol). Así los tests son rápidos, no
necesitan GPU ni red, y dan siempre el mismo resultado.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Sequence
from dataclasses import replace
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
from ai_orchestrator.negotiation.domain import MAX_MEMBERS, MemberPreferences, NegotiationResult, Status
from ai_orchestrator.negotiation.events import request_message
from ai_orchestrator.negotiation.store import (
    MemberRecord,
    NegotiationClosedError,
    NegotiationFullError,
    NegotiationNotFoundError,
    NegotiationRecord,
    NewNegotiation,
    NotEnoughReadyError,
    NotOrganizerError,
    alias_for,
    new_invite_code,
)
from ai_orchestrator.outbox import OutboxMessage
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


# --- Negociación de grupo ------------------------------------------------------


class InMemoryNegotiations:
    """NegotiationStore en memoria, con las mismas transiciones de estado que PostgreSQL."""

    def __init__(self) -> None:
        self.records: dict[str, NegotiationRecord] = {}
        self.outbox: list[OutboxMessage] = []
        self.now = FIXED_NOW

    async def create(self, draft: NewNegotiation) -> NegotiationRecord:
        negotiation_id = new_uuid()
        record = NegotiationRecord(
            negotiation_id=negotiation_id,
            organizer_id=draft.organizer_id,
            title=draft.title,
            currency=draft.currency,
            language=draft.language,
            options=draft.options,
            max_rounds=draft.max_rounds,
            status=Status.COLLECTING,
            deadline=draft.deadline,
            created_at=self.now,
            concluded_at=None,
            result=None,
            members=tuple(
                MemberRecord(
                    user_id=u,
                    seat=i,
                    alias=alias_for(i),
                    preferences=None,
                    submitted_at=None,
                    display_name=draft.organizer_name if i == 1 else None,
                )
                for i, u in enumerate(draft.member_ids, start=1)
            ),
            invites_open=draft.invites_open,
            invite_code=new_invite_code() if draft.invites_open else None,
        )
        self.records[negotiation_id] = record
        return record

    async def join(self, code: str, user_id: str, display_name: str | None) -> NegotiationRecord:
        record = next((r for r in self.records.values() if r.invites_open and r.invite_code == code), None)
        if record is None:
            raise NegotiationNotFoundError(code)
        if any(m.user_id == user_id for m in record.members):
            return record
        if record.status is not Status.COLLECTING or record.deadline < self.now:
            raise NegotiationClosedError(record.negotiation_id)
        if len(record.members) >= MAX_MEMBERS:
            raise NegotiationFullError(record.negotiation_id)
        seat = max(m.seat for m in record.members) + 1
        member = MemberRecord(
            user_id=user_id,
            seat=seat,
            alias=alias_for(seat),
            preferences=None,
            submitted_at=None,
            display_name=display_name,
        )
        record = replace(record, members=(*record.members, member))
        self.records[record.negotiation_id] = record
        return record

    async def start(self, negotiation_id: str, user_id: str) -> NegotiationRecord:
        record = await self.get_for_member(negotiation_id, user_id)
        if record is None:
            raise NegotiationNotFoundError(negotiation_id)
        if record.organizer_id != user_id:
            raise NotOrganizerError(negotiation_id)
        if record.status is not Status.COLLECTING or record.deadline < self.now:
            raise NegotiationClosedError(negotiation_id)
        if sum(1 for m in record.members if m.submitted_at) < 2:
            raise NotEnoughReadyError(negotiation_id)
        return self._queue(record)

    def _queue(self, record: NegotiationRecord) -> NegotiationRecord:
        self.outbox.append(request_message("requests", record.negotiation_id, self.now))
        record = replace(record, status=Status.QUEUED, invites_open=False, invite_code=None)
        self.records[record.negotiation_id] = record
        return record

    async def get_for_member(self, negotiation_id: str, user_id: str) -> NegotiationRecord | None:
        record = self.records.get(negotiation_id)
        return record if record and any(m.user_id == user_id for m in record.members) else None

    async def list_for_member(self, user_id: str, *, limit: int) -> list[NegotiationRecord]:
        mine = [r for r in self.records.values() if any(m.user_id == user_id for m in r.members)]
        return mine[:limit]

    async def submit_preferences(
        self, negotiation_id: str, user_id: str, preferences: MemberPreferences
    ) -> NegotiationRecord:
        record = await self.get_for_member(negotiation_id, user_id)
        if record is None:
            raise NegotiationNotFoundError(negotiation_id)
        if record.status is not Status.COLLECTING or record.deadline < self.now:
            raise NegotiationClosedError(negotiation_id)
        members = tuple(
            replace(m, preferences=preferences, submitted_at=self.now) if m.user_id == user_id else m
            for m in record.members
        )
        record = replace(record, members=members)
        self.records[negotiation_id] = record
        if all(m.submitted_at for m in members) and not record.invites_open:
            return self._queue(record)
        return record

    async def claim(self, negotiation_id: str, *, lease_seconds: int) -> NegotiationRecord | None:
        record = self.records.get(negotiation_id)
        if record is None or record.status is not Status.QUEUED:
            return None
        record = replace(record, status=Status.RUNNING)
        self.records[negotiation_id] = record
        return record

    async def conclude(self, negotiation_id: str, result: NegotiationResult, message: OutboxMessage) -> bool:
        record = self.records[negotiation_id]
        if record.status is not Status.RUNNING:
            return False
        self.records[negotiation_id] = replace(
            record,
            status=Status.CONCLUDED,
            result=result,
            concluded_at=self.now,
            members=tuple(replace(m, preferences=None) for m in record.members),
        )
        self.outbox.append(message)
        return True

    async def expire(self, negotiation_id: str) -> bool:
        record = self.records[negotiation_id]
        if record.status is not Status.RUNNING:
            return False
        self.records[negotiation_id] = replace(
            record, status=Status.EXPIRED, members=tuple(replace(m, preferences=None) for m in record.members)
        )
        return True


def negotiation_turn_json(ranking: Sequence[str], acceptable: Sequence[str], argument: str) -> str:
    return json.dumps({"ranking": list(ranking), "acceptable": list(acceptable), "argument": argument})
