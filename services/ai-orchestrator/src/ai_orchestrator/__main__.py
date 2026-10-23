"""Punto de entrada: monta todas las piezas y las pone a funcionar.

Se arranca con:  python -m ai_orchestrator   (o el comando "ai-orchestrator").

Qué hace, en orden:
    1. Lee y valida la configuración (si algo es inseguro, no arranca).
    2. Conecta con PostgreSQL y aplica las migraciones.
    3. Prepara el cliente de Ollama (y de Qdrant, si está configurado).
    4. Arranca a la vez, en el mismo proceso y sin bloquearse entre sí:
         - el consumidor de Kafka (genera recomendaciones en segundo plano),
         - el consumidor de entradas a zonas (prepara audioguías en Redis),
         - el consumidor de órdenes de negociación de grupo (agentes de IA),
         - el relé del outbox (manda a Kafka lo pendiente y revisa plazos),
         - la API con mTLS (puerto 8085),
         - la API de salud (puerto 8086).
    5. Al recibir la orden de apagado (Ctrl+C o SIGTERM de Docker) cierra todo
       con orden: deja de aceptar peticiones, termina lo que tiene entre manos
       y cierra conexiones. Lo que no llegó a confirmarse en Kafka se volverá a
       leer al arrancar de nuevo, así que no se pierde nada.

Opción --healthcheck: comprueba /healthz y sale con 0 o 1 (lo usa Docker).
Opción --pregenerate-audioguides es,en: prepara por adelantado los guiones de
todas las zonas narrables en esos idiomas y termina (útil antes de un evento
o cada noche, para que el primer turista ya lo encuentre hecho).
Opción --audio-worker: en vez de todo lo anterior, arranca SOLO el worker que
graba las audioguías con Piper (va en su propio contenedor: la síntesis de voz
gasta mucha CPU y no debe frenar a la API) y la API de salud. El worker
también pasa cada AUDIO_GC_INTERVAL_SECONDS el recolector del audio viejo.
Opción --gc-audio: pasa el recolector del audio viejo una vez y termina.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import signal
import ssl
import sys
import urllib.request
from collections.abc import Callable, Generator
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any

import httpx
import uvicorn
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
from aiokafka.errors import KafkaError
from fastapi import APIRouter
from pydantic import ValidationError
from redis.asyncio import Redis

from ai_orchestrator.api import create_api, create_management_api
from ai_orchestrator.audioguides.audio_catalog import AudioCatalog
from ai_orchestrator.audioguides.audio_gc import AudioGarbageCollector, GcSettings
from ai_orchestrator.audioguides.audio_jobs import NOTIFY_CHANNEL, PostgresAudioJobs, PostgresAudioManifests
from ai_orchestrator.audioguides.audio_store import FilesystemAudioStore
from ai_orchestrator.audioguides.audio_worker import AudioWorker, WorkerSettings
from ai_orchestrator.audioguides.cache import CacheError, RedisScriptCache
from ai_orchestrator.audioguides.consumer import ZoneEntryConsumer
from ai_orchestrator.audioguides.facts import PostgresZoneFacts
from ai_orchestrator.audioguides.service import AudioguideService, ServiceSettings
from ai_orchestrator.audioguides.speech import PiperOpusSynthesizer, SpeechError, discover_voices
from ai_orchestrator.audioguides.versions import ZoneVersionCache
from ai_orchestrator.audioguides.writer import AudioguideWriter, WriterSettings
from ai_orchestrator.config import Settings
from ai_orchestrator.consumer import AlertProcessor, FareAlertConsumer
from ai_orchestrator.llm.client import LLMClient, OllamaClient
from ai_orchestrator.logs import setup_logging
from ai_orchestrator.negotiation.agents import AgentSettings
from ai_orchestrator.negotiation.api import ApiSettings, negotiation_router
from ai_orchestrator.negotiation.consumer import NegotiationRequestConsumer
from ai_orchestrator.negotiation.service import NegotiationService, NegotiationSettings
from ai_orchestrator.negotiation.store import PostgresNegotiations, SweepReport
from ai_orchestrator.outbox import OutboxRelay
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.places.service import PlaceService, PlaceSettings, RedisPlaceCache
from ai_orchestrator.places.wikimedia import RateLimiter, WikimediaClient
from ai_orchestrator.pseudonym import Pseudonymizer
from ai_orchestrator.recommender import FareRecommender, RecommenderSettings
from ai_orchestrator.retrieval import KnowledgeBase, NoKnowledge, QdrantKnowledge
from ai_orchestrator.store import (
    Pool,
    PostgresPriceHistory,
    PostgresRecommendations,
    StoreError,
    create_pool,
    migrate,
)

log = logging.getLogger("ai_orchestrator")

# Dentro de un contenedor hay que escuchar en todas las interfaces para que
# Docker pueda enrutar el tráfico; fuera, el puerto solo se publica en
# 127.0.0.1 (docker-compose.yml) y en producción lo protege mTLS.
LISTEN_HOST = "0.0.0.0"  # noqa: S104


class _Server(uvicorn.Server):
    """Servidor uvicorn que NO captura las señales de apagado por su cuenta:
    tenemos dos servidores y un consumidor, y el apagado lo coordinamos nosotros."""

    @contextlib.contextmanager
    def capture_signals(self) -> Generator[None]:
        yield


def _client_tls(ca: Path | None, cert: Path | None = None, key: Path | None = None) -> ssl.SSLContext:
    """TLS de cliente: verifica al servidor (con nuestra CA si se da) y, si hay
    certificado propio, se presenta con él (mTLS)."""
    ctx = ssl.create_default_context(cafile=str(ca) if ca else None)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    if cert and key:
        ctx.load_cert_chain(str(cert), str(key))
    return ctx


def _mtls_server_factory(
    settings: Settings,
) -> Callable[[uvicorn.Config, Callable[[], ssl.SSLContext]], ssl.SSLContext]:
    def factory(_: uvicorn.Config, __: Callable[[], ssl.SSLContext]) -> ssl.SSLContext:
        assert settings.tls_cert_file and settings.tls_key_file and settings.tls_client_ca_file  # noqa: S101
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        # Solo TLS 1.3, como el resto de la plataforma.
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(str(settings.tls_cert_file), str(settings.tls_key_file))
        # mTLS: el CLIENTE también debe enseñar un certificado de nuestra CA.
        ctx.load_verify_locations(cafile=str(settings.tls_client_ca_file))
        ctx.verify_mode = ssl.CERT_REQUIRED
        return ctx

    return factory


def _server(app: object, port: int, *, tls: Settings | None) -> _Server:
    config = uvicorn.Config(
        app,  # type: ignore[arg-type]
        host=LISTEN_HOST,
        port=port,
        log_config=None,  # usamos nuestros logs JSON
        access_log=False,
        lifespan="off",
        server_header=False,  # no anunciamos qué servidor usamos
        proxy_headers=False,  # no nos fiamos de X-Forwarded-For
        ssl_context_factory=_mtls_server_factory(tls) if tls else None,
    )
    return _Server(config)


def _ollama(settings: Settings, stack: AsyncExitStack) -> OllamaClient:
    ollama_http = httpx.AsyncClient(
        base_url=settings.ollama_url,
        # connect: 5 s para conectar; read: lo que puede tardar el modelo.
        timeout=httpx.Timeout(settings.ollama_timeout_seconds, connect=5.0),
        verify=_client_tls(
            settings.ollama_tls_ca_file, settings.ollama_tls_cert_file, settings.ollama_tls_key_file
        ),
    )
    stack.push_async_callback(ollama_http.aclose)
    # UN solo cliente (y un solo semáforo) para recomendaciones y audioguías:
    # entre los dos nunca mandan a Ollama más de OLLAMA_MAX_CONCURRENCY a la vez.
    return OllamaClient(
        ollama_http,
        model=settings.ollama_model,
        embed_model=settings.ollama_embed_model,
        num_ctx=settings.ollama_num_ctx,
        max_concurrency=settings.ollama_max_concurrency,
    )


def _redis(settings: Settings, stack: AsyncExitStack) -> Redis:
    """Una conexión a Redis (la usan las audioguías y las fichas de ciudad)."""
    assert settings.redis_host and settings.redis_password  # noqa: S101 (config.py lo garantiza)
    tls: dict[str, object] = {}
    if settings.redis_tls:
        tls = {
            "ssl": True,
            "ssl_ca_certs": str(settings.redis_tls_ca_file) if settings.redis_tls_ca_file else None,
            "ssl_min_version": ssl.TLSVersion.TLSv1_3,
        }
    redis = Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        password=settings.redis_password.get_secret_value(),
        # Si Redis no contesta en 2 s, mejor un error claro (y reintentar) que colgarse.
        socket_timeout=2.0,
        socket_connect_timeout=2.0,
        **tls,  # type: ignore[arg-type]
    )
    stack.push_async_callback(redis.aclose)
    return redis


def _places(settings: Settings, redis: Redis, stack: AsyncExitStack) -> PlaceService:
    """Fichas de ciudad: Wikimedia con límite de ritmo + caché en Redis."""
    http = httpx.AsyncClient(
        headers={"User-Agent": settings.wikimedia_user_agent},
        timeout=httpx.Timeout(settings.wikimedia_timeout_seconds, connect=5.0),
        # Sin seguir redirecciones a otros sitios ni cookies: solo la API.
        follow_redirects=False,
    )
    stack.push_async_callback(http.aclose)
    return PlaceService(
        airports=Airports.bundled(),
        wikimedia=WikimediaClient(
            http,
            limiter=RateLimiter(settings.wikimedia_rate_per_second, settings.wikimedia_burst),
        ),
        cache=RedisPlaceCache(redis),
        settings=PlaceSettings(ttl_seconds=settings.place_ttl_seconds),
    )


def _audioguides(
    settings: Settings, pool: Pool, llm: LLMClient | None, stack: AsyncExitStack
) -> tuple[AudioguideService, RedisScriptCache, ZoneVersionCache]:
    """Monta la caché de Redis y el servicio de audioguías."""
    redis = _redis(settings, stack)
    cache = RedisScriptCache(redis)
    facts = PostgresZoneFacts(pool)
    versions = ZoneVersionCache(facts, ttl_seconds=settings.audioguide_version_cache_seconds)
    service = AudioguideService(
        facts=facts,
        versions=versions,
        writer=AudioguideWriter(
            llm=llm,
            settings=WriterSettings(
                temperature=settings.llm_temperature,
                max_output_tokens=settings.audioguide_max_output_tokens,
                max_attempts=settings.llm_max_attempts,
                max_words=settings.audioguide_max_words,
            ),
        ),
        cache=cache,
        settings=ServiceSettings(
            default_language=settings.audioguide_default_language,
            llm_ttl_seconds=settings.audioguide_llm_ttl_seconds,
            rules_ttl_seconds=settings.audioguide_rules_ttl_seconds,
            lock_ttl_seconds=settings.audioguide_lock_ttl_seconds,
        ),
    )
    return service, cache, versions


async def pregenerate(settings: Settings, languages: list[str]) -> int:
    """Rellena la caché de audioguías de todas las zonas narrables y termina."""
    async with AsyncExitStack() as stack:
        pool = await create_pool(settings)
        stack.push_async_callback(pool.close)
        await migrate(pool)
        llm = _ollama(settings, stack) if settings.llm_enabled else None
        service, _, _ = _audioguides(settings, pool, llm, stack)
        results = await service.pregenerate(languages)
        log.info("audioguías pregeneradas", extra={"outcomes": {k.value: v for k, v in results.items()}})
        return 0


async def run(settings: Settings) -> int:
    async with AsyncExitStack() as stack:
        # --- PostgreSQL ---------------------------------------------------------
        pool = await create_pool(settings)
        stack.push_async_callback(pool.close)
        applied = await migrate(pool)
        log.info("base de datos lista", extra={"migrations_applied": applied})
        recommendations = PostgresRecommendations(pool)

        # --- Ollama y Qdrant -------------------------------------------------------
        llm: LLMClient | None = None
        knowledge: KnowledgeBase = NoKnowledge()
        if settings.llm_enabled:
            ollama = _ollama(settings, stack)
            llm = ollama
            if settings.qdrant_url and settings.qdrant_api_key:
                qdrant_http = httpx.AsyncClient(
                    base_url=settings.qdrant_url,
                    headers={"api-key": settings.qdrant_api_key.get_secret_value()},
                    timeout=httpx.Timeout(10.0, connect=5.0),
                    verify=_client_tls(settings.qdrant_tls_ca_file),
                )
                stack.push_async_callback(qdrant_http.aclose)
                knowledge = QdrantKnowledge(qdrant_http, ollama, collection=settings.qdrant_collection)
        else:
            log.warning("LLM_ENABLED=false: todas las recomendaciones saldrán de reglas")

        recommender = FareRecommender(
            llm=llm,
            history=PostgresPriceHistory(pool),
            knowledge=knowledge,
            settings=RecommenderSettings(
                temperature=settings.llm_temperature,
                max_output_tokens=settings.llm_max_output_tokens,
                max_attempts=settings.llm_max_attempts,
                history_window_days=settings.price_history_window_days,
                knowledge_max_snippets=settings.knowledge_max_snippets,
                context_tokens=settings.ollama_num_ctx,
            ),
        )

        # --- Kafka ---------------------------------------------------------------------
        kafka_tls = _client_tls(settings.kafka_tls_ca_file) if settings.kafka_tls_ca_file else None
        kafka_common = {
            "bootstrap_servers": settings.kafka_broker_list,
            "client_id": settings.kafka_client_id,
            "security_protocol": "SSL" if kafka_tls else "PLAINTEXT",
            "ssl_context": kafka_tls,
        }
        # Productor para las DLQ y el outbox. acks="all" + idempotencia: no se pierde ni se duplica.
        producer = AIOKafkaProducer(**kafka_common, acks="all", enable_idempotence=True)
        await producer.start()
        stack.push_async_callback(producer.stop)
        consumer = AIOKafkaConsumer(
            settings.kafka_topic_fare_alerts,
            **kafka_common,
            group_id=settings.kafka_group_id,
            # Confirmamos nosotros, a mano, después de guardar (ver consumer.py).
            enable_auto_commit=False,
            # Un grupo nuevo empieza por las alertas más antiguas que haya.
            auto_offset_reset="earliest",
            # Una inferencia puede tardar: damos margen antes de que Kafka
            # crea que el consumidor ha muerto y le quite sus particiones.
            max_poll_interval_ms=600_000,
        )
        await consumer.start()
        stack.push_async_callback(consumer.stop)

        alert_consumer = FareAlertConsumer(
            consumer,
            producer,
            AlertProcessor(recommender, recommendations),
            dlq_topic=settings.kafka_topic_dlq,
            max_records=settings.kafka_max_poll_records,
            transient_errors=(StoreError, KafkaError),
        )

        # --- Audioguías por zona (segundo consumidor, su propio grupo) -------------------
        audioguides: AudioguideService | None = None
        audio: AudioCatalog | None = None
        zone_consumer: ZoneEntryConsumer | None = None
        script_cache: RedisScriptCache | None = None
        if settings.audioguides_enabled:
            audioguides, script_cache, versions = _audioguides(settings, pool, llm, stack)
            if settings.audio_dir is not None:
                # Solo LEE el audio que graba el worker (en Docker, volumen de solo lectura).
                audio = AudioCatalog(
                    versions=versions,
                    manifests=PostgresAudioManifests(pool),
                    store=FilesystemAudioStore(settings.audio_dir),
                    default_language=settings.audioguide_default_language,
                    public_base_url=settings.audio_public_base_url,
                    cache_seconds=settings.audio_manifest_cache_seconds,
                )
            entries = AIOKafkaConsumer(
                settings.kafka_topic_zone_entries,
                **kafka_common,
                group_id=settings.kafka_audioguides_group_id,
                enable_auto_commit=False,
                # Un grupo nuevo empieza por lo MÁS RECIENTE: una entrada de
                # hace horas ya no necesita audioguía urgente.
                auto_offset_reset="latest",
                max_poll_interval_ms=600_000,
            )
            await entries.start()
            stack.push_async_callback(entries.stop)
            zone_consumer = ZoneEntryConsumer(
                entries,
                producer,
                audioguides,
                dlq_topic=settings.kafka_topic_zone_entries_dlq,
                # Lotes grandes: agrupar entradas a la misma zona es lo que
                # convierte "un autobús" en "una generación".
                max_records=200,
                transient_errors=(StoreError, CacheError, KafkaError),
            )

        # --- Fichas de ciudad (Wikipedia/Wikidata con caché en Redis) -------------------
        places: PlaceService | None = None
        if settings.places_enabled:
            places = _places(settings, _redis(settings, stack), stack)

        # --- Negociación de grupo (tercer consumidor + relé del outbox) -----------------
        negotiations: APIRouter | None = None
        negotiation_consumer: NegotiationRequestConsumer | None = None
        relay: OutboxRelay | None = None
        if settings.negotiations_enabled:
            negotiations, negotiation_consumer, relay = await _negotiations(
                settings, pool, llm, producer, kafka_common, stack
            )

        # --- Servidores HTTP --------------------------------------------------------------
        async def readiness() -> dict[str, bool]:
            # Ollama NO cuenta: sin él seguimos funcionando con reglas.
            checks = {"database": await recommendations.ping(), "kafka_consumer": alert_consumer.running}
            if zone_consumer is not None and script_cache is not None:
                checks["redis"] = await script_cache.ping()
                checks["zone_entries_consumer"] = zone_consumer.running
            if negotiation_consumer is not None and relay is not None:
                checks["negotiation_consumer"] = negotiation_consumer.running
                checks["outbox_relay"] = relay.running
            return checks

        api = _server(
            create_api(
                recommendations,
                audioguides=audioguides,
                audio=audio,
                negotiations=negotiations,
                places=places,
                expose_docs=settings.expose_api_docs,
            ),
            settings.http_port,
            tls=None if settings.http_insecure_dev else settings,
        )
        management = _server(create_management_api(readiness), settings.management_port, tls=None)

        # --- A funcionar ---------------------------------------------------------------------
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)

        tasks = {
            asyncio.create_task(alert_consumer.run(), name="consumer"),
            asyncio.create_task(api.serve(), name="api"),
            asyncio.create_task(management.serve(), name="management"),
        }
        if zone_consumer is not None:
            tasks.add(asyncio.create_task(zone_consumer.run(), name="zone-entries"))
        if negotiation_consumer is not None and relay is not None:
            tasks.add(asyncio.create_task(negotiation_consumer.run(), name="negotiations"))
            tasks.add(asyncio.create_task(relay.run(), name="outbox"))
        stopper = asyncio.create_task(stop.wait(), name="stop")
        log.info("ai-orchestrator en marcha", extra={"http_port": settings.http_port, "llm": bool(llm)})
        done, _ = await asyncio.wait({*tasks, stopper}, return_when=asyncio.FIRST_COMPLETED)

        exit_code = 0
        for task in done:
            if task is not stopper:
                # Una pieza terminó sola: algo va mal. Paramos todo (el
                # orquestador de contenedores nos reiniciará).
                exc = task.exception() if not task.cancelled() else None
                log.error(
                    "una tarea terminó inesperadamente", extra={"task": task.get_name(), "error": repr(exc)}
                )
                exit_code = 1

        log.info("apagando")
        api.should_exit = True
        management.should_exit = True
        for task in tasks:
            if task.get_name() in {"consumer", "zone-entries", "negotiations", "outbox"}:
                task.cancel()
        stopper.cancel()
        await asyncio.gather(*tasks, stopper, return_exceptions=True)
        return exit_code


async def _negotiations(
    settings: Settings,
    pool: Pool,
    llm: LLMClient | None,
    producer: AIOKafkaProducer,
    kafka_common: dict[str, Any],
    stack: AsyncExitStack,
) -> tuple[APIRouter, NegotiationRequestConsumer, OutboxRelay]:
    """Monta la negociación de grupo: almacén, relé del outbox, servicio, consumidor y rutas."""
    store = PostgresNegotiations(
        pool,
        requests_topic=settings.kafka_topic_negotiation_requests,
        retention_days=settings.negotiation_retention_days,
    )
    loop = asyncio.get_running_loop()
    next_sweep = 0.0

    async def housekeeping() -> None:
        # El barrido de plazos no necesita ir cada 2 s: como mucho cada 30 s.
        nonlocal next_sweep
        if loop.time() < next_sweep:
            return
        next_sweep = loop.time() + 30.0
        report = await store.sweep()
        if report != SweepReport():
            log.info("barrido de negociaciones", extra={"report": report})

    relay = OutboxRelay(
        pool,
        producer,
        poll_seconds=settings.outbox_poll_seconds,
        housekeeping=housekeeping,
        transient_errors=(KafkaError,),
    )
    pseudonymizer = None
    if settings.notify_pseudonym_key is not None:
        pseudonymizer = Pseudonymizer.from_hex(settings.notify_pseudonym_key.get_secret_value())
    else:
        log.warning("sin NOTIFY_PSEUDONYM_KEY: los resultados de negociación se anuncian sin destinatarios")
    service = NegotiationService(
        store=store,
        llm=llm,
        settings=NegotiationSettings(
            results_topic=settings.kafka_topic_negotiation_results,
            lease_seconds=settings.negotiation_lease_seconds,
            round_timeout_seconds=settings.negotiation_round_timeout_seconds,
            total_timeout_seconds=settings.negotiation_total_timeout_seconds,
            agent=AgentSettings(
                temperature=settings.llm_temperature,
                max_output_tokens=settings.negotiation_max_output_tokens,
                max_attempts=settings.llm_max_attempts,
            ),
        ),
        pseudonymizer=pseudonymizer,
        on_outbox=relay.kick.set,
    )
    requests = AIOKafkaConsumer(
        settings.kafka_topic_negotiation_requests,
        **kafka_common,
        group_id=settings.kafka_negotiations_group_id,
        enable_auto_commit=False,
        auto_offset_reset="earliest",
        # Una negociación puede durar minutos: de una en una, y con margen de
        # sobra antes de que Kafka crea que este consumidor ha muerto.
        max_poll_interval_ms=settings.negotiation_lease_seconds * 1000,
    )
    await requests.start()
    stack.push_async_callback(requests.stop)
    consumer = NegotiationRequestConsumer(
        requests,
        producer,
        service,
        dlq_topic=settings.kafka_topic_negotiation_requests_dlq,
        max_records=1,
        transient_errors=(StoreError, KafkaError),
    )
    router = negotiation_router(
        store,
        ApiSettings(
            default_max_rounds=settings.negotiation_default_max_rounds,
            collect_hours=settings.negotiation_collect_hours,
        ),
        on_outbox=relay.kick.set,
    )
    return router, consumer, relay


def _audio_gc(
    settings: Settings, manifests: PostgresAudioManifests, store: FilesystemAudioStore
) -> AudioGarbageCollector:
    return AudioGarbageCollector(
        manifests=manifests,
        store=store,
        settings=GcSettings(
            keep=settings.audio_gc_keep,
            grace_days=settings.audio_gc_grace_days,
            orphan_grace_hours=settings.audio_gc_orphan_hours,
        ),
    )


async def gc_audio(settings: Settings) -> int:
    """Pasa una vez el recolector del audio viejo y termina."""
    if settings.audio_dir is None:
        log.error("el recolector necesita AUDIO_DIR (dónde está el audio)")
        return 2
    async with AsyncExitStack() as stack:
        pool = await create_pool(settings)
        stack.push_async_callback(pool.close)
        await migrate(pool)
        report = await _audio_gc(
            settings, PostgresAudioManifests(pool), FilesystemAudioStore(settings.audio_dir)
        ).run_once()
        if report.skipped:
            log.info("otro proceso está limpiando ahora mismo: no hago nada")
        return 0


async def run_audio_worker(settings: Settings) -> int:
    """Arranca solo el worker de audio (y la API de salud) hasta recibir la orden de apagado."""
    if settings.audio_dir is None:
        log.error("el worker de audio necesita AUDIO_DIR (dónde guardar los .opus)")
        return 2
    try:
        voices = discover_voices(settings.tts_voices_dir)
        synthesizer = PiperOpusSynthesizer(
            voices,
            piper_bin=settings.tts_piper_bin,
            opusenc_bin=settings.tts_opusenc_bin,
            bitrate_kbps=settings.tts_bitrate_kbps,
            timeout_seconds=settings.tts_timeout_seconds,
        )
    except SpeechError as exc:
        log.error("el worker de audio no puede arrancar", extra={"error": str(exc)})
        return 2
    if not voices:
        log.error(
            "no hay ninguna voz instalada: ejecuta 'make voices'",
            extra={"voices_dir": str(settings.tts_voices_dir)},
        )
        return 2

    async with AsyncExitStack() as stack:
        pool = await create_pool(settings)
        stack.push_async_callback(pool.close)
        await migrate(pool)
        llm = _ollama(settings, stack) if settings.llm_enabled else None
        audioguides, script_cache, _ = _audioguides(settings, pool, llm, stack)
        jobs = PostgresAudioJobs(pool)
        manifests = PostgresAudioManifests(pool)
        store = FilesystemAudioStore(settings.audio_dir)
        worker = AudioWorker(
            jobs=jobs,
            manifests=manifests,
            store=store,
            synthesizer=synthesizer,
            audioguides=audioguides,
            settings=WorkerSettings(
                languages=tuple(voices),
                lease_seconds=settings.audio_job_lease_seconds,
                poll_seconds=settings.audio_poll_seconds,
                max_attempts=settings.audio_max_attempts,
                upgrade_delay_seconds=float(settings.audioguide_rules_ttl_seconds),
                llm_enabled=settings.llm_enabled,
                gc_interval_seconds=settings.audio_gc_interval_seconds,
            ),
            gc=_audio_gc(settings, manifests, store),
        )

        # "Timbre": una conexión que escucha los pg_notify del trigger. Si esa
        # conexión se cae, no se pierde nada: el worker revisa la cola cada
        # AUDIO_POLL_SECONDS de todos modos.
        wake = asyncio.Event()
        listener = await pool.acquire()
        stack.push_async_callback(pool.release, listener)
        await listener.add_listener(NOTIFY_CHANNEL, lambda *_: wake.set())
        stack.push_async_callback(listener.remove_listener, NOTIFY_CHANNEL, lambda *_: None)

        async def readiness() -> dict[str, bool]:
            return {
                "database": await PostgresRecommendations(pool).ping(),
                "redis": await script_cache.ping(),
                "audio_worker": worker.running,
            }

        management = _server(create_management_api(readiness), settings.management_port, tls=None)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
        tasks = {
            asyncio.create_task(worker.run(wake), name="audio-worker"),
            asyncio.create_task(management.serve(), name="management"),
        }
        stopper = asyncio.create_task(stop.wait(), name="stop")
        log.info(
            "worker de audio en marcha",
            extra={"voices": {lang: v.name for lang, v in voices.items()}, "llm": bool(llm)},
        )
        done, _ = await asyncio.wait({*tasks, stopper}, return_when=asyncio.FIRST_COMPLETED)
        exit_code = 0
        for task in done:
            if task is not stopper:
                failure = task.exception() if not task.cancelled() else None
                log.error(
                    "una tarea terminó inesperadamente",
                    extra={"task": task.get_name(), "error": repr(failure)},
                )
                exit_code = 1
        log.info("apagando el worker de audio")
        management.should_exit = True
        for task in tasks:
            if task.get_name() == "audio-worker":
                # Si estaba grabando, se corta; el trabajo vuelve a la cola
                # cuando caduque su préstamo y otro worker lo terminará.
                task.cancel()
        stopper.cancel()
        await asyncio.gather(*tasks, stopper, return_exceptions=True)
        return exit_code


def healthcheck() -> int:
    port = os.environ.get("MANAGEMENT_PORT", "8086")
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=3) as resp:
            return 0 if resp.status == 200 else 1
    except OSError:
        return 1


def main() -> None:
    parser = argparse.ArgumentParser(prog="ai-orchestrator")
    parser.add_argument(
        "--healthcheck", action="store_true", help="comprueba /healthz y sale con 0 si está sano"
    )
    parser.add_argument(
        "--pregenerate-audioguides",
        metavar="IDIOMAS",
        help="prepara las audioguías de todas las zonas en esos idiomas (ej.: es,en) y termina",
    )
    parser.add_argument(
        "--audio-worker",
        action="store_true",
        help="arranca solo el worker que graba las audioguías con Piper",
    )
    parser.add_argument(
        "--gc-audio",
        action="store_true",
        help="borra una vez el audio viejo (respetando la ventana de gracia) y termina",
    )
    args = parser.parse_args()
    if args.healthcheck:
        sys.exit(healthcheck())

    try:
        # Los valores vienen del entorno, por eso no se pasan argumentos.
        settings = Settings()
    except ValidationError as exc:
        # Mensaje claro y sin trazas: es un problema de configuración, no del programa.
        print(f"ai-orchestrator no arranca:\n{exc}", file=sys.stderr)
        sys.exit(2)
    setup_logging(settings.log_level)
    if args.pregenerate_audioguides:
        if not settings.audioguides_enabled:
            print("AUDIOGUIDES_ENABLED=false: no hay nada que pregenerar", file=sys.stderr)
            sys.exit(2)
        languages = [lang.strip() for lang in args.pregenerate_audioguides.split(",") if lang.strip()]
        sys.exit(asyncio.run(pregenerate(settings, languages)))
    if args.gc_audio:
        sys.exit(asyncio.run(gc_audio(settings)))
    if args.audio_worker:
        if not settings.audioguides_enabled:
            print("AUDIOGUIDES_ENABLED=false: el worker de audio no tiene nada que hacer", file=sys.stderr)
            sys.exit(2)
        sys.exit(asyncio.run(run_audio_worker(settings)))
    sys.exit(asyncio.run(run(settings)))


if __name__ == "__main__":
    main()
