"""Consumidor de Kafka: lee alertas de precio y genera sus recomendaciones.

¿Por qué el LLM trabaja AQUÍ y no en la API?
    Es la mitigación de fondo del riesgo nº 1 (bloqueo). La API nunca espera
    al modelo: solo lee recomendaciones ya hechas de PostgreSQL (milisegundos).
    El trabajo pesado (inferencia) ocurre en segundo plano, al ritmo que
    aguante Ollama, y Kafka hace de cola de trabajo: si llegan mil alertas de
    golpe, esperan en Kafka sin tumbar nada. Para ir más rápido basta con
    arrancar más copias del servicio: Kafka les reparte las particiones.

Garantías:
    - "Al menos una vez": solo confirmamos a Kafka (commit) que un lote está
      hecho DESPUÉS de guardarlo. Si el proceso muere a medias, se repite.
    - Idempotencia: repetir una alerta no duplica nada (clave primaria
      alert_id) y ni siquiera vuelve a llamar al LLM (se comprueba antes).
    - Mensajes rotos van a la DLQ y no bloquean al resto.
    - Fallos temporales (base de datos caída) se reintentan con espera
      creciente, sin perder el mensaje.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Protocol

from ai_orchestrator.domain import FareAlert
from ai_orchestrator.events import InvalidEventError, decode_fare_alert, dlq_headers
from ai_orchestrator.recommender import FareRecommender
from ai_orchestrator.store import RecommendationStore, StoreError

log = logging.getLogger(__name__)


class Outcome(StrEnum):
    CREATED = "created"
    DUPLICATE = "duplicate"
    DEAD_LETTERED = "dead_lettered"


class AlertProcessor:
    """La lógica de UNA alerta, sin nada de Kafka (fácil de probar)."""

    def __init__(self, recommender: FareRecommender, store: RecommendationStore) -> None:
        self._recommender = recommender
        self._store = store

    async def handle(self, alert: FareAlert) -> Outcome:
        # Comprobación previa barata: si ya la procesamos (reentrega de
        # Kafka), no gastamos segundos de GPU en repetirla.
        if await self._store.exists(alert.alert_id):
            return Outcome.DUPLICATE
        rec = await self._recommender.recommend(alert)
        created = await self._store.save(rec)
        log.info(
            "recomendación generada",
            extra={
                "alert_id": alert.alert_id,
                "verdict": rec.verdict.value,
                "source": rec.source,
                "correlation_id": alert.correlation_id,
                "duplicate": not created,
            },
        )
        return Outcome.CREATED if created else Outcome.DUPLICATE


# --- Lo mínimo que usamos de aiokafka (así los tests usan versiones falsas) ---


class KafkaRecord(Protocol):
    @property
    def topic(self) -> str: ...
    @property
    def partition(self) -> int: ...
    @property
    def offset(self) -> int: ...
    @property
    def key(self) -> bytes | None: ...
    @property
    def value(self) -> bytes | None: ...
    @property
    def headers(self) -> Sequence[tuple[str, bytes]]: ...


class KafkaConsumerLike(Protocol):
    async def getmany(self, *, timeout_ms: int, max_records: int) -> dict[Any, list[Any]]: ...
    async def commit(self) -> None: ...


class KafkaProducerLike(Protocol):
    # Argumentos con nombre (después de *): aiokafka tiene otros parámetros en
    # medio (partition, timestamp_ms) y pasarlos por posición los confundiría.
    async def send_and_wait(
        self, topic: str, *, value: bytes | None, key: bytes | None, headers: list[tuple[str, bytes]]
    ) -> Any: ...


@dataclass(frozen=True, slots=True)
class RetryPolicy:
    """Espera creciente entre reintentos: 0,5 s, 1 s, 2 s... hasta 30 s."""

    initial_seconds: float = 0.5
    max_seconds: float = 30.0

    def delay(self, attempt: int) -> float:
        return float(min(self.max_seconds, self.initial_seconds * 2 ** (attempt - 1)))


class FareAlertConsumer:
    def __init__(
        self,
        consumer: KafkaConsumerLike,
        producer: KafkaProducerLike,
        processor: AlertProcessor,
        *,
        dlq_topic: str,
        max_records: int,
        retry: RetryPolicy | None = None,
        transient_errors: tuple[type[Exception], ...] = (StoreError,),
    ) -> None:
        self._consumer = consumer
        self._producer = producer
        self._processor = processor
        self._dlq_topic = dlq_topic
        self._max_records = max_records
        self._retry = retry or RetryPolicy()
        # Errores que consideramos temporales (se reintentan). Cualquier otro
        # es un fallo de programación: el proceso termina y se reinicia, y el
        # mensaje se vuelve a leer porque no se confirmó (fallar rápido).
        self._transient = transient_errors
        self.running = False

    async def run(self) -> None:
        """Bucle principal. Termina cuando se cancela la tarea (apagado)."""
        self.running = True
        try:
            while True:
                batches = await self._consumer.getmany(timeout_ms=1000, max_records=self._max_records)
                if not batches:
                    continue
                # Cada partición en paralelo (no comparten usuarios, porque la
                # clave del mensaje es el user_id); dentro de una partición, en
                # orden. Así las alertas de una persona nunca se adelantan.
                # El LLM no se satura: OllamaClient limita la concurrencia.
                async with asyncio.TaskGroup() as tg:
                    for records in batches.values():
                        tg.create_task(self._process_partition(records))
                # Todo el lote está guardado: ya podemos confirmarlo a Kafka.
                try:
                    await self._consumer.commit()
                except self._transient as exc:
                    # Por ejemplo, Kafka repartió las particiones mientras
                    # procesábamos. No pasa nada: el lote se volverá a
                    # entregar y la idempotencia evita duplicados.
                    log.warning("no se pudo confirmar el lote a Kafka", extra={"error": str(exc)})
        finally:
            self.running = False

    async def _process_partition(self, records: Sequence[KafkaRecord]) -> None:
        for record in records:
            await self._process_with_retry(record)

    async def _process_with_retry(self, record: KafkaRecord) -> Outcome:
        attempt = 0
        while True:
            attempt += 1
            try:
                return await self._process(record)
            except self._transient as exc:
                # Temporal: esperamos y repetimos. NO pasamos al siguiente
                # mensaje (se perdería el orden y el commit lo daría por hecho).
                delay = self._retry.delay(attempt)
                log.warning(
                    "fallo temporal, se reintenta",
                    extra={
                        "offset": record.offset,
                        "partition": record.partition,
                        "delay": delay,
                        "error": str(exc),
                    },
                )
                await asyncio.sleep(delay)

    async def _process(self, record: KafkaRecord) -> Outcome:
        headers = list(record.headers or [])
        try:
            alert = decode_fare_alert(record.value, headers)
        except InvalidEventError as exc:
            log.error(
                "mensaje inválido enviado a la DLQ",
                extra={"offset": record.offset, "partition": record.partition, "error": str(exc)},
            )
            await self._producer.send_and_wait(
                self._dlq_topic,
                value=record.value,
                key=record.key,
                headers=dlq_headers(
                    headers,
                    reason=str(exc),
                    topic=record.topic,
                    partition=record.partition,
                    offset=record.offset,
                ),
            )
            return Outcome.DEAD_LETTERED
        return await self._processor.handle(alert)
