"""Tests de integración: PostgreSQL y Kafka REALES (los de docker compose).

No se ejecutan con un "pytest" normal (están marcados como integration).
Para lanzarlos:

    make up                      # arranca Kafka, PostgreSQL... (desde la raíz)
    make test-integration        # o, a mano, desde services/ai-orchestrator:
    uv run pytest -m integration

El LLM sigue siendo falso: queremos probar las tuberías (Kafka -> servicio ->
PostgreSQL), no la calidad del modelo. La tabla de precios la crea el
price-consumer y la de zonas (geo.zones) el geo-engine: si no existen, esos
tests se saltan con un aviso. Las audioguías usan además el Redis real.
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
from redis.asyncio import Redis

from ai_orchestrator.audioguides.audio_jobs import (
    AudioManifest,
    AudioPart,
    PostgresAudioJobs,
    PostgresAudioManifests,
)
from ai_orchestrator.audioguides.audio_store import audio_key
from ai_orchestrator.audioguides.cache import RedisScriptCache, lock_key
from ai_orchestrator.audioguides.facts import PostgresZoneFacts
from ai_orchestrator.audioguides.service import AudioguideService, Outcome, ServiceSettings
from ai_orchestrator.audioguides.versions import ZoneVersionCache
from ai_orchestrator.audioguides.writer import AudioguideWriter, WriterSettings
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
        redis_host=os.environ.get("REDIS_HOST", "localhost"),
        redis_password=os.environ["REDIS_PASSWORD"],
        redis_tls=False,
        redis_insecure_dev=True,
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


async def test_audioguide_with_real_postgres_and_redis(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    if not await pool.fetchval("SELECT to_regclass('geo.zones') IS NOT NULL"):
        pytest.skip("geo.zones no existe: arranca antes el geo-engine (make up-apps)")
    zone_id = await pool.fetchval("SELECT zone_id::text FROM geo.zones WHERE slug = 'madrid-museos'")
    if zone_id is None:
        pytest.skip("sin zonas de demostración (SEED_DEMO_ZONES=true en el geo-engine)")

    settings = _settings()
    assert settings.redis_password is not None
    redis = Redis(
        host=settings.redis_host or "localhost",
        port=settings.redis_port,
        password=settings.redis_password.get_secret_value(),
    )
    cache = RedisScriptCache(redis)
    try:
        # Los hechos de la migración 0002 se leen por slug e idioma, con la
        # versión de contenido de la zona (migración 0003).
        facts = await PostgresZoneFacts(pool).load(zone_id, language="es", fallback_language="en")
        assert facts is not None and facts.slug == "madrid-museos"
        version = facts.content_version
        assert version >= 1
        assert await PostgresZoneFacts(pool).content_version(zone_id) == version
        assert await PostgresZoneFacts(pool).content_version(str(uuid.uuid4())) is None

        # Empezamos limpios (por si quedó algo de otra ejecución).
        key = f"ai:audioguide:v2:{zone_id}:es:{version}"
        await redis.delete(key, lock_key(zone_id, "es", version))
        assert any("1819" in f.text for f in facts.facts)
        fr = await PostgresZoneFacts(pool).load(zone_id, language="fr", fallback_language="en")
        assert fr is not None and fr.facts_language == "en", "sin traducción al francés: se usa el inglés"

        draft = (
            '{"title": "Paseo del Arte", "segments": ['
            '{"text": "El Prado abrió al público en 1819, hace ya mucho.", "fact_ids": ["F1"]},'
            '{"text": "Y dentro te esperan Las Meninas de Velázquez.", "fact_ids": ["F2"]}]}'
        )
        llm = FakeLLM([draft] * 5)
        source = PostgresZoneFacts(pool)
        service = AudioguideService(
            facts=source,
            versions=ZoneVersionCache(source, ttl_seconds=60),
            writer=AudioguideWriter(
                llm=llm, settings=WriterSettings(0.1, 900, 3, 260), clock=lambda: FIXED_NOW
            ),
            cache=cache,
            settings=ServiceSettings(
                default_language="en", llm_ttl_seconds=600, rules_ttl_seconds=60, lock_ttl_seconds=30
            ),
        )
        # Diez entradas a la vez: una sola generación, el resto comparte.
        outcomes = await asyncio.gather(*(service.ensure_zone(zone_id, "es") for _ in range(10)))
        assert outcomes.count(Outcome.GENERATED) == 1
        assert len(llm.calls) == 1
        script = await cache.get(zone_id, "es", version)
        assert script is not None and script.source == "llm" and script.content_version == version
        ttl = await redis.ttl(key)
        assert 0 < ttl <= 600
        assert await redis.exists(lock_key(zone_id, "es", version)) == 0, "el cerrojo se soltó"

        # El cerrojo real: el segundo no lo consigue; un token ajeno no lo borra.
        token = await cache.try_lock(zone_id, "xx", version, ttl_seconds=30)
        assert token is not None
        assert await cache.try_lock(zone_id, "xx", version, ttl_seconds=30) is None
        await cache.unlock(zone_id, "xx", version, "token-ajeno")
        assert await redis.exists(lock_key(zone_id, "xx", version)) == 1
        await cache.unlock(zone_id, "xx", version, token)
        assert await redis.exists(lock_key(zone_id, "xx", version)) == 0
        assert await cache.ping()
    finally:
        await redis.aclose()


async def test_editing_facts_bumps_the_zone_content_version(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    # Una zona de prueba propia: no tocamos los hechos de las zonas de demostración.
    slug = f"test-{uuid.uuid4().hex[:12]}"

    async def version() -> int | None:
        value = await pool.fetchval("SELECT content_version FROM ai.zone_content WHERE zone_slug = $1", slug)
        return None if value is None else int(value)

    try:
        await pool.execute(
            "INSERT INTO ai.zone_facts (zone_slug, language, position, fact) "
            "VALUES ($1, 'es', 1, 'Un hecho.')",
            slug,
        )
        assert await version() == 1, "el primer hecho crea la versión 1"
        await pool.execute("UPDATE ai.zone_facts SET fact = 'Un hecho corregido.' WHERE zone_slug = $1", slug)
        assert await version() == 2, "corregir un hecho sube la versión"
        await pool.execute("DELETE FROM ai.zone_facts WHERE zone_slug = $1", slug)
        assert await version() == 3, "borrar un hecho también"
    finally:
        await pool.execute("DELETE FROM ai.zone_facts WHERE zone_slug = $1", slug)
        await pool.execute("DELETE FROM ai.zone_content WHERE zone_slug = $1", slug)
        # Cada versión dejó apuntado su trabajo de audio (migración 0004).
        await pool.execute("DELETE FROM ai.audio_jobs WHERE zone_slug = $1", slug)


async def test_fixing_a_fact_leaves_an_audio_job_in_the_outbox(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    slug = f"test-{uuid.uuid4().hex[:12]}"
    jobs = PostgresAudioJobs(pool)
    try:
        await pool.execute(
            "INSERT INTO ai.zone_facts (zone_slug, language, position, fact) "
            "VALUES ($1, 'es', 1, 'Un hecho.')",
            slug,
        )
        await pool.execute("UPDATE ai.zone_facts SET fact = 'Un hecho corregido.' WHERE zone_slug = $1", slug)
        rows = await pool.fetch(
            "SELECT content_version FROM ai.audio_jobs WHERE zone_slug = $1 ORDER BY content_version", slug
        )
        # La MISMA transacción que cambió el hecho apuntó el trabajo (outbox).
        assert [r["content_version"] for r in rows] == [1, 2]

        # Que nuestros trabajos sean los primeros de la cola (la base de datos es compartida).
        await pool.execute(
            "UPDATE ai.audio_jobs SET available_at = now() - interval '10 years' WHERE zone_slug = $1", slug
        )
        first = await jobs.claim(lease_seconds=60)
        assert first is not None and first.zone_slug == slug and first.attempt == 1
        # La zona no existe en geo.zones (es de prueba) y su versión actual es la 2.
        assert first.zone_id is None and first.current_version == 2
        second = await jobs.claim(lease_seconds=60)
        assert second is not None and second.zone_slug == slug
        # Prestado: nadie más lo coge mientras dure el préstamo.
        assert (first.content_version, second.content_version) in {(1, 2), (2, 1)}

        await jobs.retry(first, delay_seconds=3600, error="piper caído")
        await jobs.complete(second)
        state = {
            r["content_version"]: r
            for r in await pool.fetch(
                "SELECT content_version, done_at, last_error, available_at > now() AS later "
                "FROM ai.audio_jobs WHERE zone_slug = $1",
                slug,
            )
        }
        assert state[first.content_version]["last_error"] == "piper caído"
        assert state[first.content_version]["later"] and state[first.content_version]["done_at"] is None
        assert state[second.content_version]["done_at"] is not None
    finally:
        await pool.execute("DELETE FROM ai.audio_jobs WHERE zone_slug = $1", slug)
        await pool.execute("DELETE FROM ai.zone_facts WHERE zone_slug = $1", slug)
        await pool.execute("DELETE FROM ai.zone_content WHERE zone_slug = $1", slug)


async def test_audio_manifests_roundtrip(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    try:
        zone = await pool.fetchrow("SELECT zone_id, slug FROM geo.zones WHERE slug = 'madrid-centro'")
    except asyncpg.UndefinedTableError:
        pytest.skip("geo.zones no existe: arranca antes el geo-engine")
    if zone is None:
        pytest.skip("falta la zona madrid-centro (la crea el geo-engine)")
    manifests = PostgresAudioManifests(pool)
    digest = uuid.uuid4().hex[:16]
    key = f"madrid-centro/it/v0/{digest}/parte-1.opus"
    manifest = AudioManifest(
        zone_slug="madrid-centro",
        language="it",
        content_language="es",
        content_version=0,
        script_digest=digest,
        source="rules",
        voice="es-carlfm-x-low",
        parts=(AudioPart(index=1, key=key, duration_seconds=3.3, text="Bienvenido."),),
    )
    try:
        assert not await manifests.exists("madrid-centro", "it", 0, digest)
        await manifests.save(manifest)
        await manifests.save(manifest)  # repetir no duplica
        assert await manifests.exists("madrid-centro", "it", 0, digest)
        found = await manifests.latest(str(zone["zone_id"]), "it", 0)
        assert found is not None and found.script_digest == digest
        assert found.parts[0].key == key and found.parts[0].text == "Bienvenido."
        assert await manifests.latest(str(uuid.uuid4()), "it", 0) is None
    finally:
        await pool.execute("DELETE FROM ai.zone_audio WHERE script_digest = $1", digest)


async def test_audio_gc_keeps_two_recordings_and_a_grace_window(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    # Cuatro grabaciones de una zona de prueba, sustituidas hace 60, 40 y 1 días.
    slug = f"test-{uuid.uuid4().hex[:12]}"
    manifests = PostgresAudioManifests(pool)

    def recording(version: int) -> AudioManifest:
        digest = f"{version:016x}"
        return AudioManifest(
            zone_slug=slug,
            language="es",
            content_language="es",
            content_version=version,
            script_digest=digest,
            source="rules",
            voice="es-test",
            parts=(
                AudioPart(
                    index=1, key=audio_key(slug, "es", version, digest, 1), duration_seconds=1.0, text="Hola."
                ),
            ),
        )

    try:
        for version, days_ago in ((1, 100), (2, 60), (3, 40), (4, 1)):
            await manifests.save(recording(version))
            await pool.execute(
                "UPDATE ai.zone_audio SET created_at = now() - make_interval(days => $3) "
                "WHERE zone_slug = $1 AND content_version = $2",
                slug,
                version,
                days_ago,
            )

        async def expired(grace_days: float) -> list[int]:
            found = await manifests.expired(keep=2, grace_days=grace_days, limit=1000)
            return [m.content_version for m in found if m.zone_slug == slug]

        # v4 (actual) y v3 (reserva) nunca. v2 lleva 40 días sustituida y v1, 60.
        assert await expired(30) == [1, 2]
        assert await expired(50) == [1]
        assert await expired(90) == []

        await manifests.mark_purged(recording(1))
        stone = await manifests.tombstone(slug, "es", 1, f"{1:016x}")
        assert stone is not None and stone.zone_id is None  # la zona de prueba no está en geo.zones
        assert await manifests.tombstone(slug, "es", 2, f"{2:016x}") is None  # v2 sigue viva
        keys = await manifests.referenced_keys()
        assert recording(1).parts[0].key not in keys and recording(2).parts[0].key in keys
        # Con v1 ya borrada, la cuenta sigue igual: v2 es la siguiente candidata.
        assert await expired(30) == [2]

        # Una lápida que vuelve a grabarse revive.
        await manifests.save(recording(1))
        assert await manifests.exists(slug, "es", 1, f"{1:016x}")

        async with manifests.exclusive() as first:
            async with manifests.exclusive() as second:
                # El cerrojo es por conexión: la segunda no lo consigue.
                assert first and not second
    finally:
        await pool.execute("DELETE FROM ai.zone_audio WHERE zone_slug = $1", slug)
