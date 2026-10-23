"""Tests del servicio, los mensajes de Kafka, el consumidor y los seudónimos."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import timedelta
from typing import Any

import pytest
from conftest import FIXED_NOW, FakeLLM, InMemoryNegotiations, negotiation_turn_json

from ai_orchestrator.events import InvalidEventError
from ai_orchestrator.negotiation.agents import AgentSettings
from ai_orchestrator.negotiation.consumer import NegotiationRequestConsumer
from ai_orchestrator.negotiation.domain import GroupOption, MemberPreferences, Outcome, Status
from ai_orchestrator.negotiation.events import (
    CONCLUDED_TYPE,
    REQUESTED_TYPE,
    decode_request,
    request_message,
)
from ai_orchestrator.negotiation.service import NegotiationService, NegotiationSettings, RunOutcome
from ai_orchestrator.negotiation.store import NewNegotiation
from ai_orchestrator.pseudonym import Pseudonymizer
from nomadiq.ai.v1 import negotiation_pb2

OPTIONS = (
    GroupOption(option_id="lisboa", label="Lisboa", price_minor=30000, tags=("ciudad", "playa")),
    GroupOption(option_id="roma", label="Roma", price_minor=40000, tags=("ciudad", "museos")),
    GroupOption(option_id="tokio", label="Tokio", price_minor=90000, tags=("ciudad", "tecnologia")),
)
SETTINGS = NegotiationSettings(
    results_topic="ai.group-negotiations.v1",
    lease_seconds=600,
    round_timeout_seconds=5,
    total_timeout_seconds=10,
    agent=AgentSettings(temperature=0.1, max_output_tokens=300, max_attempts=1),
)
KEY = bytes(range(32))


async def queued(store: InMemoryNegotiations, *prefs: MemberPreferences) -> str:
    """Crea una negociación y envía las preferencias de todos: queda en cola."""
    members = tuple(f"user-{i}" for i in range(len(prefs)))
    record = await store.create(
        NewNegotiation(
            organizer_id=members[0],
            title="Puente de mayo",
            currency="EUR",
            language="es",
            options=OPTIONS,
            member_ids=members,
            max_rounds=3,
            deadline=FIXED_NOW + timedelta(days=1),
        )
    )
    for user_id, p in zip(members, prefs, strict=True):
        await store.submit_preferences(record.negotiation_id, user_id, p)
    return record.negotiation_id


def service(
    store: InMemoryNegotiations, llm: FakeLLM | None = None, kicks: list[int] | None = None
) -> NegotiationService:
    return NegotiationService(
        store=store,
        llm=llm,
        settings=SETTINGS,
        pseudonymizer=Pseudonymizer(KEY),
        on_outbox=(lambda: kicks.append(1)) if kicks is not None else None,
    )


async def test_rules_only_negotiation_end_to_end() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store,
        MemberPreferences(budget_max_minor=100000, interests=("playa",)),
        MemberPreferences(budget_max_minor=50000, interests=("museos",), notes="Odio madrugar"),
    )
    assert store.records[negotiation_id].status is Status.QUEUED
    kicks: list[int] = []
    assert await service(store, kicks=kicks).run(negotiation_id) is RunOutcome.CONCLUDED

    record = store.records[negotiation_id]
    assert record.status is Status.CONCLUDED and record.result is not None
    result = record.result
    # Tokio supera el presupuesto del Viajero 2: descartada sin decir de quién.
    assert result.excluded_over_budget == ("tokio",)
    assert result.chosen_option_id in {"lisboa", "roma"}
    assert result.llm_used is False
    assert [m.alias for m in result.members] == ["Viajero 1", "Viajero 2"]
    assert all(m.chosen_rank in {1, 2} for m in result.members)
    assert "presupuesto de alguien" in result.explanation
    # Las preferencias privadas se borran al terminar.
    assert all(m.preferences is None for m in record.members)
    assert kicks == [1]

    # El anuncio de Kafka: sin datos personales, con seudónimos.
    message = store.outbox[-1]
    assert message.topic == "ai.group-negotiations.v1"
    assert dict(message.headers)["ce_type"] == CONCLUDED_TYPE.encode()
    evt = negotiation_pb2.GroupNegotiationConcluded.FromString(message.value)
    assert evt.negotiation_id == negotiation_id
    assert evt.chosen_option_id == result.chosen_option_id
    assert list(evt.recipients) == [
        Pseudonymizer(KEY).recipient("user-0"),
        Pseudonymizer(KEY).recipient("user-1"),
    ]
    assert b"user-0" not in message.value and b"Odio" not in message.value


async def test_llm_agents_reach_consensus() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store, MemberPreferences(budget_max_minor=100000), MemberPreferences(budget_max_minor=100000)
    )
    llm = FakeLLM(
        [
            negotiation_turn_json(["tokio", "roma", "lisboa"], ["tokio", "roma"], "Sueña con Japón."),
            negotiation_turn_json(["roma", "lisboa", "tokio"], ["roma"], "Quiere arte y buena comida."),
        ]
    )
    await service(store, llm).run(negotiation_id)
    result = store.records[negotiation_id].result
    assert result is not None
    assert (result.outcome, result.chosen_option_id, result.rounds) == (Outcome.CONSENSUS, "roma", 1)
    assert result.llm_used is True
    assert [m.argument for m in result.members] == ["Sueña con Japón.", "Quiere arte y buena comida."]
    assert result.explanation == "Acuerdo en la ronda 1: todos aceptan «Roma»."


async def test_nobody_can_afford_anything() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store, MemberPreferences(budget_max_minor=100), MemberPreferences(budget_max_minor=100000)
    )
    await service(store, FakeLLM([])).run(negotiation_id)
    result = store.records[negotiation_id].result
    assert result is not None
    assert result.outcome is Outcome.NO_FEASIBLE_OPTION and result.chosen_option_id is None
    evt = negotiation_pb2.GroupNegotiationConcluded.FromString(store.outbox[-1].value)
    assert evt.outcome == negotiation_pb2.NEGOTIATION_OUTCOME_NO_FEASIBLE_OPTION


async def test_duplicate_orders_do_nothing() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store, MemberPreferences(budget_max_minor=100000), MemberPreferences(budget_max_minor=100000)
    )
    svc = service(store)
    assert await svc.run(negotiation_id) is RunOutcome.CONCLUDED
    outbox = len(store.outbox)
    assert await svc.run(negotiation_id) is RunOutcome.SKIPPED
    assert len(store.outbox) == outbox
    assert await svc.run("00000000-0000-0000-0000-000000000000") is RunOutcome.SKIPPED


def test_request_message_roundtrip() -> None:
    message = request_message("t", "6F9619FF-8B86-D011-B42D-00C04FC964FF", FIXED_NOW)
    headers = list(message.headers)
    assert dict(headers)["ce_type"] == REQUESTED_TYPE.encode()
    assert message.key == b"6F9619FF-8B86-D011-B42D-00C04FC964FF"
    assert decode_request(message.value, headers) == "6f9619ff-8b86-d011-b42d-00c04fc964ff"


@pytest.mark.parametrize(
    ("value", "headers", "error"),
    [
        (b"", [], "vacío"),
        (b"\xff\xff", [], "ilegible"),
        (negotiation_pb2.GroupNegotiationRequested(negotiation_id="nope").SerializeToString(), [], "UUID"),
        (b"x", [("ce_type", b"otra.cosa")], "ce_type"),
        (b"x", [("content-type", b"application/json")], "content-type"),
    ],
)
def test_bad_requests_are_rejected(value: bytes, headers: list[tuple[str, bytes]], error: str) -> None:
    with pytest.raises(InvalidEventError, match=error):
        decode_request(value, headers)


def test_pseudonym_matches_go_and_rust() -> None:
    # Mismo vector que services/notifier/internal/pseudonym (Go) y el geo-engine (Rust).
    p = Pseudonymizer.from_hex(KEY.hex())
    assert p.recipient("ana") == "L3EwJq7E81uOwDP3QpkOd8aLg_sQhE63kbas17KB9rk"
    assert "00010203" not in repr(p)
    with pytest.raises(ValueError, match="32 bytes"):
        Pseudonymizer(b"corta")
    with pytest.raises(ValueError, match="hexadecimal"):
        Pseudonymizer.from_hex("zz" * 32)


# --- Consumidor con Kafka falso ----------------------------------------------


@dataclass
class Record:
    value: bytes | None
    headers: list[tuple[str, bytes]]
    key: bytes | None = b"k"
    topic: str = "ai.group-negotiation-requests.v1"
    partition: int = 0
    offset: int = 0


@dataclass
class FakeProducer:
    sent: list[dict[str, Any]] = field(default_factory=list)

    async def send_and_wait(
        self, topic: str, *, value: bytes | None, key: bytes | None, headers: list[tuple[str, bytes]]
    ) -> None:
        self.sent.append({"topic": topic, "value": value, "headers": headers})


async def test_consumer_runs_orders_and_dead_letters_garbage() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store, MemberPreferences(budget_max_minor=100000), MemberPreferences(budget_max_minor=100000)
    )
    order = store.outbox[0]
    producer = FakeProducer()
    consumer = NegotiationRequestConsumer(
        consumer=None,  # type: ignore[arg-type]  (process() no usa el consumidor real)
        producer=producer,
        service=service(store),
        dlq_topic="dlq",
        max_records=1,
        transient_errors=(),
    )
    outcomes = await consumer.process([Record(order.value, list(order.headers)), Record(b"\x00basura", [])])
    assert outcomes == [RunOutcome.CONCLUDED, "dead_lettered"]
    assert store.records[negotiation_id].status is Status.CONCLUDED
    assert producer.sent[0]["topic"] == "dlq"
    assert dict(producer.sent[0]["headers"])["dlq_reason"]


async def test_a_queue_without_enough_people_expires() -> None:
    store = InMemoryNegotiations()
    negotiation_id = await queued(
        store, MemberPreferences(budget_max_minor=100000), MemberPreferences(budget_max_minor=100000)
    )
    # Simula una orden que llega con un solo miembro con preferencias.
    record = store.records[negotiation_id]
    store.records[negotiation_id] = replace(
        record, members=(record.members[0], replace(record.members[1], preferences=None))
    )
    assert await service(store).run(negotiation_id) is RunOutcome.EXPIRED
    assert store.records[negotiation_id].status is Status.EXPIRED
    assert all(m.preferences is None for m in store.records[negotiation_id].members)
