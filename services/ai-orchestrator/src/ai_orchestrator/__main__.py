"""Punto de entrada: monta todas las piezas y las pone a funcionar.

Se arranca con:  python -m ai_orchestrator   (o el comando "ai-orchestrator").

Qué hace, en orden:
    1. Lee y valida la configuración (si algo es inseguro, no arranca).
    2. Conecta con PostgreSQL y aplica las migraciones.
    3. Prepara el cliente de Ollama (y de Qdrant, si está configurado).
    4. Arranca a la vez, en el mismo proceso y sin bloquearse entre sí:
         - el consumidor de Kafka (genera recomendaciones en segundo plano),
         - el consumidor de entradas a zonas (prepara audioguías en Redis),
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

import httpx
import uvicorn
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
from aiokafka.errors import KafkaError
from pydantic import ValidationError
from redis.asyncio import Redis

from ai_orchestrator.api import create_api, create_management_api
from ai_orchestrator.audioguides.cache import CacheError, RedisScriptCache
from ai_orchestrator.audioguides.consumer import ZoneEntryConsumer
from ai_orchestrator.audioguides.facts import PostgresZoneFacts
from ai_orchestrator.audioguides.service import AudioguideService, ServiceSettings
from ai_orchestrator.audioguides.writer import AudioguideWriter, WriterSettings
from ai_orchestrator.config import Settings
from ai_orchestrator.consumer import AlertProcessor, FareAlertConsumer
from ai_orchestrator.llm.client import LLMClient, OllamaClient
from ai_orchestrator.logs import setup_logging
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


def _audioguides(
    settings: Settings, pool: Pool, llm: LLMClient | None, stack: AsyncExitStack
) -> tuple[AudioguideService, RedisScriptCache]:
    """Monta la caché de Redis y el servicio de audioguías."""
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
    cache = RedisScriptCache(redis)
    service = AudioguideService(
        facts=PostgresZoneFacts(pool),
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
    return service, cache


async def pregenerate(settings: Settings, languages: list[str]) -> int:
    """Rellena la caché de audioguías de todas las zonas narrables y termina."""
    async with AsyncExitStack() as stack:
        pool = await create_pool(settings)
        stack.push_async_callback(pool.close)
        await migrate(pool)
        llm = _ollama(settings, stack) if settings.llm_enabled else None
        service, _ = _audioguides(settings, pool, llm, stack)
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
        # Productor solo para la DLQ. acks="all" + idempotencia: no se pierde ni se duplica.
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
        zone_consumer: ZoneEntryConsumer | None = None
        script_cache: RedisScriptCache | None = None
        if settings.audioguides_enabled:
            audioguides, script_cache = _audioguides(settings, pool, llm, stack)
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

        # --- Servidores HTTP --------------------------------------------------------------
        async def readiness() -> dict[str, bool]:
            # Ollama NO cuenta: sin él seguimos funcionando con reglas.
            checks = {"database": await recommendations.ping(), "kafka_consumer": alert_consumer.running}
            if zone_consumer is not None and script_cache is not None:
                checks["redis"] = await script_cache.ping()
                checks["zone_entries_consumer"] = zone_consumer.running
            return checks

        api = _server(
            create_api(recommendations, audioguides=audioguides, expose_docs=settings.expose_api_docs),
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
            if task.get_name() in {"consumer", "zone-entries"}:
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
    sys.exit(asyncio.run(run(settings)))


if __name__ == "__main__":
    main()
