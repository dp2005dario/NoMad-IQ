"""Punto de entrada: monta todas las piezas y las pone a funcionar.

Se arranca con:  python -m ai_orchestrator   (o el comando "ai-orchestrator").

Qué hace, en orden:
    1. Lee y valida la configuración (si algo es inseguro, no arranca).
    2. Conecta con PostgreSQL y aplica las migraciones.
    3. Prepara el cliente de Ollama (y de Qdrant, si está configurado).
    4. Arranca a la vez, en el mismo proceso y sin bloquearse entre sí:
         - el consumidor de Kafka (genera recomendaciones en segundo plano),
         - la API con mTLS (puerto 8085),
         - la API de salud (puerto 8086).
    5. Al recibir la orden de apagado (Ctrl+C o SIGTERM de Docker) cierra todo
       con orden: deja de aceptar peticiones, termina lo que tiene entre manos
       y cierra conexiones. Lo que no llegó a confirmarse en Kafka se volverá a
       leer al arrancar de nuevo, así que no se pierde nada.

Opción --healthcheck: comprueba /healthz y sale con 0 o 1 (lo usa Docker).
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

from ai_orchestrator.api import create_api, create_management_api
from ai_orchestrator.config import Settings
from ai_orchestrator.consumer import AlertProcessor, FareAlertConsumer
from ai_orchestrator.llm.client import LLMClient, OllamaClient
from ai_orchestrator.logs import setup_logging
from ai_orchestrator.recommender import FareRecommender, RecommenderSettings
from ai_orchestrator.retrieval import KnowledgeBase, NoKnowledge, QdrantKnowledge
from ai_orchestrator.store import (
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
            ollama_http = httpx.AsyncClient(
                base_url=settings.ollama_url,
                # connect: 5 s para conectar; read: lo que puede tardar el modelo.
                timeout=httpx.Timeout(settings.ollama_timeout_seconds, connect=5.0),
                verify=_client_tls(
                    settings.ollama_tls_ca_file, settings.ollama_tls_cert_file, settings.ollama_tls_key_file
                ),
            )
            stack.push_async_callback(ollama_http.aclose)
            ollama = OllamaClient(
                ollama_http,
                model=settings.ollama_model,
                embed_model=settings.ollama_embed_model,
                num_ctx=settings.ollama_num_ctx,
                max_concurrency=settings.ollama_max_concurrency,
            )
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

        # --- Servidores HTTP --------------------------------------------------------------
        async def readiness() -> dict[str, bool]:
            # Ollama NO cuenta: sin él seguimos funcionando con reglas.
            return {"database": await recommendations.ping(), "kafka_consumer": alert_consumer.running}

        api = _server(
            create_api(recommendations, expose_docs=settings.expose_api_docs),
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
            if task.get_name() == "consumer":
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
    sys.exit(asyncio.run(run(settings)))


if __name__ == "__main__":
    main()
