"""Consumidor de ai.group-negotiation-requests.v1: negocia en segundo plano.

Igual que las recomendaciones y las audioguías, el trabajo pesado (varias
rondas de LLM por miembro) nunca ocurre en la API: la API solo deja la orden
en el outbox y responde en milisegundos. Kafka hace de cola de trabajo y,
para negociar más deprisa, basta con arrancar más copias del servicio.

Garantías (las mismas que consumer.py):
    - "Al menos una vez": se confirma (commit) a Kafka DESPUÉS de guardar.
    - Repetir una orden es inofensivo: el servicio solo negocia lo que está
      en cola (store.claim).
    - Mensajes rotos -> DLQ, sin parar a los demás.
    - Base de datos caída -> se reintenta con espera creciente.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Sequence

from ai_orchestrator.consumer import KafkaConsumerLike, KafkaProducerLike, KafkaRecord, RetryPolicy
from ai_orchestrator.events import InvalidEventError, dlq_headers
from ai_orchestrator.negotiation.events import decode_request
from ai_orchestrator.negotiation.service import NegotiationService, RunOutcome

log = logging.getLogger(__name__)


class NegotiationRequestConsumer:
    def __init__(
        self,
        consumer: KafkaConsumerLike,
        producer: KafkaProducerLike,
        service: NegotiationService,
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
                # Particiones en paralelo; dentro de cada una, en orden. El LLM
                # no se satura: OllamaClient limita las llamadas simultáneas.
                async with asyncio.TaskGroup() as tg:
                    for records in batches.values():
                        tg.create_task(self.process(records))
                try:
                    await self._consumer.commit()
                except self._transient as exc:
                    # Se volverá a entregar; repetir es inofensivo.
                    log.warning("no se pudo confirmar el lote a Kafka", extra={"error": str(exc)})
        finally:
            self.running = False

    async def process(self, records: Sequence[KafkaRecord]) -> list[RunOutcome | str]:
        return [await self._with_retry(record) for record in records]

    async def _with_retry(self, record: KafkaRecord) -> RunOutcome | str:
        attempt = 0
        while True:
            attempt += 1
            try:
                return await self._process(record)
            except self._transient as exc:
                delay = self._retry.delay(attempt)
                log.warning(
                    "fallo temporal en negociación, se reintenta",
                    extra={
                        "offset": record.offset,
                        "partition": record.partition,
                        "delay": delay,
                        "error": str(exc),
                    },
                )
                await asyncio.sleep(delay)

    async def _process(self, record: KafkaRecord) -> RunOutcome | str:
        headers = list(record.headers or [])
        try:
            negotiation_id = decode_request(record.value, headers)
        except InvalidEventError as exc:
            log.error(
                "orden de negociación inválida enviada a la DLQ",
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
            return "dead_lettered"
        return await self._service.run(negotiation_id)
