"""Consumidor de geo.zone-entries.v1: prepara audioguías en segundo plano.

Es un "trabajo de fondo" (riesgo nº 1 del análisis): el móvil nunca espera
aquí. Kafka hace de cola: si de golpe entran mil personas en zonas, los
eventos esperan en Kafka y se procesan al ritmo que aguante Ollama.

Cómo procesa cada lote:
    1. Traduce cada mensaje; los rotos van a la DLQ sin parar al resto.
    2. **Agrupa** las entradas que piden el MISMO guion (zona + idioma).
       Un autobús de 50 personas en un lote = 1 trabajo, no 50.
    3. Ejecuta a la vez los trabajos de zonas distintas (Ollama limita cuántos
       llegan al modelo a la vez, ver llm/client.py).
    4. Solo cuando todo el lote está hecho, confirma (commit) a Kafka.

Si se cae a mitad, el lote se vuelve a leer: repetirlo es inofensivo, porque
lo que ya se generó está en la caché y sale como CACHED.
"""

from __future__ import annotations

import asyncio
import logging
from collections import Counter
from collections.abc import Awaitable, Callable, Sequence
from functools import partial

from ai_orchestrator.audioguides.events import decode_zone_entry
from ai_orchestrator.audioguides.service import AudioguideService, Outcome
from ai_orchestrator.consumer import KafkaConsumerLike, KafkaProducerLike, KafkaRecord, RetryPolicy
from ai_orchestrator.events import InvalidEventError, dlq_headers

log = logging.getLogger(__name__)


class ZoneEntryConsumer:
    def __init__(
        self,
        consumer: KafkaConsumerLike,
        producer: KafkaProducerLike,
        service: AudioguideService,
        *,
        dlq_topic: str,
        max_records: int,
        transient_errors: tuple[type[Exception], ...],
        retry: RetryPolicy | None = None,
    ) -> None:
        self._consumer = consumer
        self._producer = producer
        self._service = service
        self._dlq_topic = dlq_topic
        self._max_records = max_records
        self._transient = transient_errors
        self._retry = retry or RetryPolicy()
        self.running = False

    async def run(self) -> None:
        """Bucle principal. Termina cuando se cancela la tarea (apagado)."""
        self.running = True
        try:
            while True:
                batches = await self._consumer.getmany(timeout_ms=1000, max_records=self._max_records)
                if not batches:
                    continue
                records = [r for part in batches.values() for r in part]
                outcomes = await self.process_batch(records)
                try:
                    await self._consumer.commit()
                except self._transient as exc:
                    log.warning("no se pudo confirmar el lote a Kafka", extra={"error": str(exc)})
                log.debug("lote de entradas a zonas procesado", extra={"outcomes": dict(outcomes)})
        finally:
            self.running = False

    async def process_batch(self, records: Sequence[KafkaRecord]) -> Counter[Outcome | str]:
        """Procesa un lote completo y devuelve cuántos mensajes acabaron de cada forma."""
        outcomes: Counter[Outcome | str] = Counter()
        # dict.fromkeys conserva el orden y quita repetidos: un trabajo por guion.
        jobs: dict[tuple[str, str], None] = {}
        for record in records:
            headers = list(record.headers or [])
            try:
                entry = decode_zone_entry(record.value, headers)
            except InvalidEventError as exc:
                dead_letter = partial(self._dead_letter, record, headers, str(exc))
                await self._retrying(dead_letter, context="dlq")
                outcomes["dead_lettered"] += 1
                continue
            target = self._service.target(entry)
            if target is None:
                outcomes[Outcome.NOT_NARRATED] += 1
                continue
            if target in jobs:
                # Mismo guion que otro mensaje del lote: ni siquiera miramos la caché.
                outcomes["merged_in_batch"] += 1
                continue
            jobs[target] = None

        results: list[asyncio.Task[Outcome]] = []
        async with asyncio.TaskGroup() as tg:
            for zone_id, language in jobs:
                # partial "congela" zone_id y language de ESTA vuelta del bucle.
                job = partial(self._service.ensure_zone, zone_id, language)
                results.append(tg.create_task(self._retrying(job, context=zone_id)))
        for task in results:
            outcomes[task.result()] += 1
        return outcomes

    async def _retrying[T](self, fn: Callable[[], Awaitable[T]], *, context: str) -> T:
        attempt = 0
        while True:
            attempt += 1
            try:
                return await fn()
            except self._transient as exc:
                # Redis, PostgreSQL o Kafka caídos: esperamos y repetimos. El
                # lote no se confirma hasta que esto termine: nada se pierde.
                delay = self._retry.delay(attempt)
                log.warning(
                    "fallo temporal en audioguías, se reintenta",
                    extra={"context": context, "delay": delay, "error": str(exc)},
                )
                await asyncio.sleep(delay)

    async def _dead_letter(self, record: KafkaRecord, headers: list[tuple[str, bytes]], reason: str) -> None:
        log.error(
            "entrada a zona inválida enviada a la DLQ",
            extra={"offset": record.offset, "partition": record.partition, "error": reason},
        )
        await self._producer.send_and_wait(
            self._dlq_topic,
            value=record.value,
            key=record.key,
            headers=dlq_headers(
                headers, reason=reason, topic=record.topic, partition=record.partition, offset=record.offset
            ),
        )
