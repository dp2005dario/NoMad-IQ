"""Tests de integración: PostgreSQL y Kafka REALES (los de docker compose).

No se ejecutan con un "pytest" normal (están marcados como integration).
Para lanzarlos:

    make up                      # arranca Kafka, PostgreSQL... (desde la raíz)
    make test-integration        # o, a mano, desde services/ai-orchestrator:
    uv run pytest -m integration

El LLM sigue siendo falso: queremos probar las tuberías (Kafka -> servicio ->
PostgreSQL), no la calidad del modelo. La tabla de precios la crea el
price-consumer: si no existe, esos tests se saltan con un aviso.
"""

from __future__ import annotations

import asyncio
import os
import random
import string
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime

import asyncpg
import pytest
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
from conftest import (
    FIXED_NOW,
    PROTO_HEADERS,
    FakeKnowledge,
    FakeLLM,
    advice_json,
    encode_alert_proto,
    make_alert,
    make_recommendation,
)

from ai_orchestrator.config import Settings
from ai_orchestrator.consumer import AlertProcessor, FareAlertConsumer
from ai_orchestrator.domain import Money
from ai_orchestrator.recommender import FareRecommender, RecommenderSettings
from ai_orchestrator.store import (
    PostgresPriceHistory,
    PostgresRecommendations,
    create_pool,
    load_migrations,
    migrate,
)

pytestmark = pytest.mark.integration

BROKERS = os.environ.get("KAFKA_BROKERS", "localhost:29092")
ALERTS_TOPIC = "flights.fare-alerts.v1"
DLQ_TOPIC = "flights.fare-alerts-dlq.v1"


def _settings() -> Settings:
    return Settings(
        _env_file=None,
        kafka_brokers=BROKERS,
        pghost=os.environ.get("PGHOST", "localhost"),
        pguser=os.environ["PGUSER"],
        pgpassword=os.environ["PGPASSWORD"],
        pgdatabase=os.environ["PGDATABASE"],
        pgsslmode="disable",
        db_insecure_dev=True,
        http_insecure_dev=True,
        ollama_insecure_dev=True,
    )


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def _random_route() -> tuple[str, str]:
    # Una ruta inventada por test: así los datos de un test no afectan a otro.
    letters = random.sample(string.ascii_uppercase, 6)
    return "".join(letters[:3]), "".join(letters[3:])


async def test_migrations_are_idempotent(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    assert await migrate(pool) == 0  # la segunda vez no hay nada que aplicar
    versions = await pool.fetch("SELECT version FROM ai.ai_orchestrator_migrations ORDER BY version")
    assert [r["version"] for r in versions] == [m.version for m in load_migrations()]


async def test_recommendations_roundtrip_and_isolation(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    repo = PostgresRecommendations(pool)
    alert_id = str(uuid.uuid4())
    user = f"user-{uuid.uuid4()}"
    rec = make_recommendation(alert_id=alert_id, user_id=user, facts={"precio_actual": "520,00 EUR"})
    assert await repo.save(rec) is True
    assert await repo.save(rec) is False  # duplicado: no hace nada
    assert await repo.exists(alert_id)
    assert await repo.get_for_user(user, alert_id) == rec
    assert await repo.get_for_user("otra-persona", alert_id) is None
    assert [r.alert_id for r in await repo.list_for_user(user, limit=10)] == [alert_id]
    assert await repo.ping()


async def test_price_history_stats(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    exists = await pool.fetchval("SELECT to_regclass('flights.price_observations') IS NOT NULL")
    if not exists:
        pytest.skip("flights.price_observations no existe: arranca antes el price-consumer")
    origin, destination = _random_route()
    departure = date(2027, 3, 14)
    now = datetime.now(UTC)
    for i, amount in enumerate([60000, 50000, 70000, 99000]):
        await pool.execute(
            """INSERT INTO flights.price_observations
               (event_id, route_key, origin_iata, destination_iata, departure_date, cabin, currency,
                amount_minor, provider, observed_at, kafka_partition, kafka_offset)
               VALUES ($1, $2, $3, $4, $5, 'ECONOMY', 'EUR', $6, 'test', $7, 0, $8)""",
            uuid.uuid4(),
            f"{origin}-{destination}:{departure.isoformat()}:ECONOMY",
            origin,
            destination,
            departure,
            amount,
            now,
            i,
        )
    alert = make_alert(origin=origin, destination=destination, departure_date=departure)
    stats = await PostgresPriceHistory(pool).stats(alert, window_days=30)
    assert stats is not None
    assert stats.samples == 4
    assert stats.minimum == Money(currency="EUR", amount_minor=50000)
    assert stats.maximum == Money(currency="EUR", amount_minor=99000)
    assert stats.median == Money(currency="EUR", amount_minor=60000)  # un precio que existe

    other = make_alert(origin=destination, destination=origin, departure_date=departure)
    assert await PostgresPriceHistory(pool).stats(other, window_days=30) is None


async def test_end_to_end_from_kafka_to_postgres(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    alert = make_alert(alert_id=str(uuid.uuid4()), user_id=f"e2e-{uuid.uuid4()}")
    garbage_key = f"basura-{uuid.uuid4()}".encode()

    # zstd, igual que comprimen sus mensajes los servicios Go (franz-go).
    producer = AIOKafkaProducer(
        bootstrap_servers=BROKERS, acks="all", enable_idempotence=True, compression_type="zstd"
    )
    await producer.start()
    try:
        await producer.send_and_wait(
            ALERTS_TOPIC, b"esto no es protobuf", key=garbage_key, headers=PROTO_HEADERS
        )
        await producer.send_and_wait(
            ALERTS_TOPIC, encode_alert_proto(alert), key=alert.user_id.encode(), headers=PROTO_HEADERS
        )

        consumer = AIOKafkaConsumer(
            ALERTS_TOPIC,
            bootstrap_servers=BROKERS,
            group_id=f"ai-orchestrator-test-{uuid.uuid4()}",
            enable_auto_commit=False,
            auto_offset_reset="earliest",
        )
        await consumer.start()
        repo = PostgresRecommendations(pool)
        recommender = FareRecommender(
            # Sin historial para esta ruta: el texto solo usa huecos de la alerta.
            llm=FakeLLM(
                [advice_json(explanation="Baja un {bajada_porcentaje}; si te encaja, cómpralo.")] * 1000
            ),
            history=PostgresPriceHistory(pool),
            knowledge=FakeKnowledge(),
            settings=RecommenderSettings(0.1, 300, 3, 30, 0, 4096),
            clock=lambda: FIXED_NOW,
        )
        service = FareAlertConsumer(
            consumer, producer, AlertProcessor(recommender, repo), dlq_topic=DLQ_TOPIC, max_records=50
        )
        task = asyncio.create_task(service.run())
        try:
            async with asyncio.timeout(60):
                while not await repo.exists(alert.alert_id):
                    if task.done():
                        task.result()  # si el servicio se paró por un error, que se vea
                    await asyncio.sleep(0.2)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            await consumer.stop()

        rec = await repo.get_for_user(alert.user_id, alert.alert_id)
        assert rec is not None
        # Si el ai-orchestrator de docker compose también está en marcha (como
        # en la CI), puede procesar la alerta antes que este test: sin Ollama,
        # la guardará por reglas. Ambos caminos deben dar el precio real.
        assert rec.source in {"llm", "rules"}
        assert "520,00 EUR" in rec.headline

        # El mensaje roto acabó en la DLQ con su motivo.
        dlq = AIOKafkaConsumer(
            DLQ_TOPIC,
            bootstrap_servers=BROKERS,
            group_id=f"dlq-check-{uuid.uuid4()}",
            auto_offset_reset="earliest",
        )
        await dlq.start()
        try:
            async with asyncio.timeout(30):
                async for msg in dlq:
                    if msg.key == garbage_key:
                        headers = dict(msg.headers)
                        assert headers["dlq_source_topic"] == ALERTS_TOPIC.encode()
                        assert headers["dlq_reason"]
                        break
        finally:
            await dlq.stop()
    finally:
        await producer.stop()
