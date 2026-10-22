"""Negociación de grupo contra PostgreSQL y Kafka REALES (los de docker compose).

Como el resto de tests de integración, solo se ejecutan con:

    make up && make test-integration      # o: uv run pytest -m integration

Si el ai-orchestrator de docker compose también está en marcha (como en la
CI), compite con estos tests por las mismas órdenes y el mismo outbox. Las
comprobaciones miran el estado FINAL (está concluida, hay un anuncio en
Kafka...), no quién hizo el trabajo: así valen en los dos casos.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import asyncpg
import pytest
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
from test_integration import BROKERS, _settings

from ai_orchestrator.negotiation.agents import AgentSettings
from ai_orchestrator.negotiation.consumer import NegotiationRequestConsumer
from ai_orchestrator.negotiation.domain import GroupOption, MemberPreferences, Outcome, Status
from ai_orchestrator.negotiation.engine import EngineResult
from ai_orchestrator.negotiation.events import concluded_message
from ai_orchestrator.negotiation.service import NegotiationService, NegotiationSettings, build_result
from ai_orchestrator.negotiation.store import (
    NegotiationClosedError,
    NegotiationNotFoundError,
    NewNegotiation,
    PostgresNegotiations,
)
from ai_orchestrator.outbox import OutboxRelay
from ai_orchestrator.store import create_pool, migrate
from nomadiq.ai.v1 import negotiation_pb2

pytestmark = pytest.mark.integration

REQUESTS = "ai.group-negotiation-requests.v1"
RESULTS = "ai.group-negotiations.v1"
OPTIONS = (
    GroupOption(option_id="lisboa", label="Lisboa", price_minor=30000, tags=("playa",)),
    GroupOption(option_id="roma", label="Roma", price_minor=40000, tags=("museos",)),
)
PREFS = MemberPreferences(budget_max_minor=100000, interests=("playa",), notes="secreto")


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def draft(*members: str, hours: float = 24) -> NewNegotiation:
    return NewNegotiation(
        organizer_id=members[0],
        title="Test de integración",
        currency="EUR",
        language="es",
        options=OPTIONS,
        member_ids=members,
        max_rounds=3,
        deadline=datetime.now(UTC) + timedelta(hours=hours),
    )


def people(n: int) -> tuple[str, ...]:
    return tuple(f"it-{uuid.uuid4()}" for _ in range(n))


async def pending_requests(pool: asyncpg.Pool[asyncpg.Record], negotiation_id: str) -> int:
    count = await pool.fetchval(
        "SELECT count(*) FROM ai.outbox WHERE topic = $1 AND msg_key = $2", REQUESTS, negotiation_id.encode()
    )
    return int(count)


async def test_lifecycle_and_privacy(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresNegotiations(pool, requests_topic=REQUESTS)
    ana, beto = people(2)
    record = await store.create(draft(ana, beto))
    nid = record.negotiation_id
    assert [m.alias for m in record.members] == ["Viajero 1", "Viajero 2"]
    assert record.options == OPTIONS
    assert await store.get_for_member(nid, "intruso") is None
    with pytest.raises(NegotiationNotFoundError):
        await store.submit_preferences(nid, "intruso", PREFS)

    after_one = await store.submit_preferences(nid, ana, PREFS)
    assert after_one.status is Status.COLLECTING
    assert await pending_requests(pool, nid) == 0
    after_two = await store.submit_preferences(nid, beto, PREFS)
    assert after_two.status is Status.QUEUED
    assert await pending_requests(pool, nid) == 1
    with pytest.raises(NegotiationClosedError):
        await store.submit_preferences(nid, beto, PREFS)
    assert [r.negotiation_id for r in await store.list_for_member(beto, limit=5)] == [nid]

    # El ai-orchestrator de compose (si está en marcha) puede reclamarla antes.
    claimed = await store.claim(nid, lease_seconds=60)
    if claimed is None:
        pytest.skip("otra copia del servicio se adelantó: el ciclo completo lo cubre el test e2e")
    assert claimed.status is Status.RUNNING
    assert await store.claim(nid, lease_seconds=60) is None  # nadie la reclama dos veces

    outcome = EngineResult(Outcome.CONSENSUS, "lisboa", 1, {}, ())
    result = build_result(outcome, OPTIONS, [], "es")
    message = concluded_message(RESULTS, nid, result, [], datetime.now(UTC))
    assert await store.conclude(nid, result, message) is True
    assert await store.conclude(nid, result, message) is False
    final = await store.get_for_member(nid, ana)
    assert final is not None and final.status is Status.CONCLUDED and final.result == result
    # Minimización: las preferencias privadas ya no están en la base de datos.
    assert all(m.preferences is None for m in final.members)
    assert all(m.submitted_at is not None for m in final.members)


async def test_simultaneous_last_submissions_queue_once(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresNegotiations(pool, requests_topic=REQUESTS)
    members = people(4)
    nid = (await store.create(draft(*members))).negotiation_id
    await store.submit_preferences(nid, members[0], PREFS)
    await store.submit_preferences(nid, members[1], PREFS)
    # Los dos últimos a la vez: FOR UPDATE los pone en fila.
    await asyncio.gather(*(store.submit_preferences(nid, m, PREFS) for m in members[2:]))
    assert await pending_requests(pool, nid) == 1


async def test_sweep_handles_deadlines_and_dead_workers(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresNegotiations(pool, requests_topic=REQUESTS)
    # A: 2 de 3 listos al vencer el plazo -> se negocia con esos dos.
    a = people(3)
    a_id = (await store.create(draft(*a))).negotiation_id
    for m in a[:2]:
        await store.submit_preferences(a_id, m, PREFS)
    # B: 1 de 2 listo -> caduca y se borran sus preferencias.
    b = people(2)
    b_id = (await store.create(draft(*b))).negotiation_id
    await store.submit_preferences(b_id, b[0], PREFS)
    await pool.execute(
        "UPDATE ai.group_negotiations SET deadline = now() - interval '1 minute' "
        "WHERE negotiation_id = ANY($1::uuid[])",
        [a_id, b_id],
    )
    # C: "running" con el préstamo caducado (su proceso murió) -> vuelve a la cola.
    c = people(2)
    c_id = (await store.create(draft(*c))).negotiation_id
    await pool.execute(
        "UPDATE ai.group_negotiations SET status = 'running', lease_until = now() - interval '1 second' "
        "WHERE negotiation_id = $1::uuid",
        c_id,
    )

    await store.sweep()
    states = {
        str(r["negotiation_id"]): r["status"]
        for r in await pool.fetch(
            "SELECT negotiation_id, status FROM ai.group_negotiations WHERE negotiation_id = ANY($1::uuid[])",
            [a_id, b_id, c_id],
        )
    }
    # Otra copia del servicio podría haberlas empezado ya: "queued" o más allá.
    assert states[a_id] in {"queued", "running", "concluded"}
    assert states[b_id] == "expired"
    # (C no tiene preferencias: quien la procese la caducará sin romperse.)
    assert states[c_id] in {"queued", "running", "expired"}
    assert await pending_requests(pool, a_id) == 1
    assert await pending_requests(pool, c_id) == 1
    expired = await store.get_for_member(b_id, b[0])
    assert expired is not None and all(m.preferences is None for m in expired.members)


async def test_end_to_end_through_kafka(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    """API -> outbox -> Kafka (orden) -> consumidor -> agentes -> outbox -> Kafka (resultado)."""
    store = PostgresNegotiations(pool, requests_topic=REQUESTS)
    producer = AIOKafkaProducer(bootstrap_servers=BROKERS, acks="all", enable_idempotence=True)
    await producer.start()
    requests = AIOKafkaConsumer(
        REQUESTS,
        bootstrap_servers=BROKERS,
        group_id=f"negotiations-test-{uuid.uuid4()}",
        enable_auto_commit=False,
        auto_offset_reset="earliest",
    )
    results = AIOKafkaConsumer(
        RESULTS,
        bootstrap_servers=BROKERS,
        group_id=f"results-test-{uuid.uuid4()}",
        auto_offset_reset="earliest",
    )
    # Grupos nuevos desde el principio ("earliest"): las órdenes viejas de otros
    # tests se descartan solas (ya no están en cola) y el resultado se busca por clave.
    await requests.start()
    await results.start()
    relay = OutboxRelay(pool, producer, poll_seconds=0.2)
    service = NegotiationService(
        store=store,
        llm=None,  # sin LLM: los agentes usan reglas (lo que importa aquí son las tuberías)
        settings=NegotiationSettings(
            results_topic=RESULTS,
            lease_seconds=120,
            round_timeout_seconds=5,
            total_timeout_seconds=10,
            agent=AgentSettings(0.1, 300, 1),
        ),
        on_outbox=relay.kick.set,
    )
    worker = NegotiationRequestConsumer(
        requests,
        producer,
        service,
        dlq_topic="ai.group-negotiation-requests-dlq.v1",
        max_records=1,
        transient_errors=(),
    )
    tasks = [asyncio.create_task(relay.run()), asyncio.create_task(worker.run())]
    try:
        ana, beto = people(2)
        nid = (await store.create(draft(ana, beto))).negotiation_id
        await store.submit_preferences(nid, ana, PREFS)
        await store.submit_preferences(nid, beto, MemberPreferences(budget_max_minor=35000))
        relay.kick.set()

        async with asyncio.timeout(60):
            async for msg in results:
                for task in tasks:
                    if task.done():
                        task.result()  # si el relé o el consumidor se pararon por un error, que se vea
                if msg.key == nid.encode():
                    evt = negotiation_pb2.GroupNegotiationConcluded.FromString(msg.value)
                    break
        # Roma (400 €) supera el presupuesto de Beto (350 €): solo queda Lisboa.
        assert evt.chosen_option_id == "lisboa"
        assert evt.outcome == negotiation_pb2.NEGOTIATION_OUTCOME_CONSENSUS
        final = await store.get_for_member(nid, beto)
        assert final is not None and final.status is Status.CONCLUDED
        assert final.result is not None and final.result.excluded_over_budget == ("roma",)
        assert b"secreto" not in msg.value
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await requests.stop()
        await results.stop()
        await producer.stop()
