"""Tests del consumidor con un Kafka falso: commits, DLQ, reintentos e idempotencia."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any

import pytest
from conftest import (
    ALERT_ID,
    FIXED_NOW,
    PROTO_HEADERS,
    FakeHistory,
    FakeKnowledge,
    FakeLLM,
    InMemoryStore,
    advice_json,
    encode_alert_proto,
    make_alert,
    make_stats,
    new_uuid,
)

from ai_orchestrator.consumer import AlertProcessor, FareAlertConsumer, Outcome, RetryPolicy
from ai_orchestrator.domain import Recommendation
from ai_orchestrator.recommender import FareRecommender, RecommenderSettings
from ai_orchestrator.store import StoreError


@dataclass
class Record:
    value: bytes | None
    offset: int
    partition: int = 0
    topic: str = "flights.fare-alerts.v1"
    key: bytes | None = b"user"
    headers: list[tuple[str, bytes]] = field(default_factory=lambda: list(PROTO_HEADERS))


class FakeConsumer:
    """Entrega los lotes indicados y luego se queda esperando (como Kafka sin mensajes)."""

    def __init__(self, batches: list[dict[Any, list[Record]]]) -> None:
        self._batches = batches
        self.commits = 0
        self.drained = asyncio.Event()

    async def getmany(self, *, timeout_ms: int, max_records: int) -> dict[Any, list[Record]]:
        if self._batches:
            return self._batches.pop(0)
        self.drained.set()
        await asyncio.sleep(0.01)
        return {}

    async def commit(self) -> None:
        self.commits += 1


class FakeProducer:
    def __init__(self) -> None:
        self.sent: list[tuple[str, bytes | None, bytes | None, list[tuple[str, bytes]]]] = []

    async def send_and_wait(
        self, topic: str, *, value: bytes | None, key: bytes | None, headers: list[tuple[str, bytes]]
    ) -> None:
        self.sent.append((topic, value, key, headers))


class FlakyStore(InMemoryStore):
    """Falla las primeras N escrituras (base de datos reiniciándose)."""

    def __init__(self, failures: int) -> None:
        super().__init__()
        self.failures = failures

    async def save(self, rec: Recommendation) -> bool:
        if self.failures > 0:
            self.failures -= 1
            raise StoreError("conexión perdida")
        return await super().save(rec)


def build(
    settings: RecommenderSettings, store: InMemoryStore, llm: FakeLLM | None = None
) -> tuple[AlertProcessor, FakeLLM]:
    llm = llm or FakeLLM([advice_json()] * 10)
    rec = FareRecommender(
        llm=llm,
        history=FakeHistory(make_stats()),
        knowledge=FakeKnowledge(),
        settings=settings,
        clock=lambda: FIXED_NOW,
    )
    return AlertProcessor(rec, store), llm


async def run_until_drained(consumer: FareAlertConsumer, fake: FakeConsumer) -> None:
    task = asyncio.create_task(consumer.run())
    await asyncio.wait_for(fake.drained.wait(), timeout=5)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert consumer.running is False


async def test_processes_and_commits_after_saving(recommender_settings: RecommenderSettings) -> None:
    store = InMemoryStore()
    processor, _ = build(recommender_settings, store)
    second = make_alert(alert_id=new_uuid())
    fake = FakeConsumer(
        [
            {
                "p0": [Record(encode_alert_proto(), 0)],
                "p1": [Record(encode_alert_proto(second), 0, partition=1)],
            }
        ]
    )
    consumer = FareAlertConsumer(fake, FakeProducer(), processor, dlq_topic="dlq", max_records=10)
    await run_until_drained(consumer, fake)
    assert set(store.items) == {ALERT_ID, second.alert_id}
    assert fake.commits == 1


async def test_invalid_message_goes_to_dlq_and_does_not_block(
    recommender_settings: RecommenderSettings,
) -> None:
    store = InMemoryStore()
    processor, _ = build(recommender_settings, store)
    producer = FakeProducer()
    fake = FakeConsumer([{"p0": [Record(b"basura", 7), Record(encode_alert_proto(), 8)]}])
    consumer = FareAlertConsumer(
        fake, producer, processor, dlq_topic="flights.fare-alerts-dlq.v1", max_records=10
    )
    await run_until_drained(consumer, fake)
    assert ALERT_ID in store.items  # el siguiente mensaje sí se procesó
    topic, value, _, headers = producer.sent[0]
    assert topic == "flights.fare-alerts-dlq.v1"
    assert value == b"basura"  # contenido original intacto para reprocesarlo
    assert ("dlq_source_offset", b"7") in headers
    assert fake.commits == 1


async def test_transient_errors_are_retried_without_losing_the_message(
    recommender_settings: RecommenderSettings,
) -> None:
    store = FlakyStore(failures=2)
    processor, _ = build(recommender_settings, store)
    fake = FakeConsumer([{"p0": [Record(encode_alert_proto(), 0)]}])
    consumer = FareAlertConsumer(
        fake, FakeProducer(), processor, dlq_topic="dlq", max_records=10, retry=RetryPolicy(0.001, 0.001)
    )
    await run_until_drained(consumer, fake)
    assert ALERT_ID in store.items
    assert fake.commits == 1


async def test_shutdown_during_retry_does_not_commit(recommender_settings: RecommenderSettings) -> None:
    store = FlakyStore(failures=10_000)
    processor, _ = build(recommender_settings, store)
    fake = FakeConsumer([{"p0": [Record(encode_alert_proto(), 0)]}])
    consumer = FareAlertConsumer(
        fake, FakeProducer(), processor, dlq_topic="dlq", max_records=10, retry=RetryPolicy(0.001, 0.001)
    )
    task = asyncio.create_task(consumer.run())
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    # Sin commit: al reiniciar, Kafka volverá a entregar el mensaje.
    assert fake.commits == 0


async def test_duplicates_do_not_call_the_llm_again(recommender_settings: RecommenderSettings) -> None:
    store = InMemoryStore()
    processor, llm = build(recommender_settings, store)
    assert await processor.handle(make_alert()) is Outcome.CREATED
    assert await processor.handle(make_alert()) is Outcome.DUPLICATE
    assert len(llm.calls) == 1


async def test_failed_commit_does_not_stop_the_service(recommender_settings: RecommenderSettings) -> None:
    class CommitFails(FakeConsumer):
        async def commit(self) -> None:
            self.commits += 1
            raise StoreError("rebalanceo")  # cualquier error "temporal" configurado

    store = InMemoryStore()
    processor, _ = build(recommender_settings, store)
    fake = CommitFails([{"p0": [Record(encode_alert_proto(), 0)]}, {"p0": [Record(encode_alert_proto(), 0)]}])
    consumer = FareAlertConsumer(fake, FakeProducer(), processor, dlq_topic="dlq", max_records=10)
    await run_until_drained(consumer, fake)
    assert fake.commits == 2  # siguió funcionando tras el primer fallo
    assert len(store.items) == 1  # la reentrega no duplicó nada


def test_retry_policy_grows_and_is_capped() -> None:
    policy = RetryPolicy(0.5, 30)
    assert [policy.delay(i) for i in (1, 2, 3)] == [0.5, 1.0, 2.0]
    assert policy.delay(50) == 30
