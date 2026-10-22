"""Buzón de salida ("outbox"): mensajes para Kafka que se guardan primero en PostgreSQL.

El porqué está explicado en la migración 0006. En resumen: el mensaje se
escribe en ai.outbox en la MISMA transacción que el cambio que anuncia, y el
relé de este fichero lo manda a Kafka después.

Garantías del relé:
    - "Al menos una vez": un mensaje se marca como enviado DESPUÉS de que
      Kafka confirme que lo tiene (acks=all). Si el proceso muere entre medias,
      se reenviará: los consumidores deben tolerar duplicados (los nuestros
      lo hacen: ver negotiation/service.py).
    - Varias copias del servicio pueden tener su relé a la vez: cada una coge
      un lote distinto gracias a FOR UPDATE SKIP LOCKED ("lo que otro ya
      tiene cogido, sáltatelo").
    - Orden: dentro de un lote se envían por orden de llegada.
    - Limpieza: lo enviado se borra a los pocos días (ya está en Kafka).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

import asyncpg

from ai_orchestrator.consumer import KafkaProducerLike, RetryPolicy
from ai_orchestrator.store import Conn, Pool, StoreError

log = logging.getLogger(__name__)

# Cuántos mensajes coge el relé de cada vez.
BATCH_SIZE = 100
# Lo enviado se conserva un poco (por si hay que investigar algo) y se borra.
KEEP_PUBLISHED_DAYS = 3


@dataclass(frozen=True, slots=True)
class OutboxMessage:
    """Un mensaje de Kafka listo para enviar (ya codificado en protobuf)."""

    topic: str
    key: bytes
    value: bytes
    headers: tuple[tuple[str, bytes], ...]


async def enqueue(conn: Conn, message: OutboxMessage) -> None:
    """Guarda un mensaje en el buzón. Se llama DENTRO de una transacción abierta."""
    await conn.execute(
        "INSERT INTO ai.outbox (topic, msg_key, payload, headers) VALUES ($1, $2, $3, $4::jsonb)",
        message.topic,
        message.key,
        message.value,
        # Las cabeceras son texto ASCII (ids, tipos, fechas): se guardan como texto.
        json.dumps([[k, v.decode()] for k, v in message.headers]),
    )


class OutboxRelay:
    """El "cartero": cada poco (o cuando le avisan) vacía el buzón hacia Kafka."""

    def __init__(
        self,
        pool: Pool,
        producer: KafkaProducerLike,
        *,
        poll_seconds: float,
        housekeeping: Callable[[], Awaitable[None]] | None = None,
        transient_errors: tuple[type[Exception], ...] = (),
        retry: RetryPolicy | None = None,
    ) -> None:
        self._pool = pool
        self._producer = producer
        self._poll = poll_seconds
        # Tarea periódica extra (por ejemplo, revisar plazos vencidos). Se
        # ejecuta en cada vuelta, antes de vaciar el buzón.
        self._housekeeping = housekeeping
        # Errores temporales además de los de PostgreSQL (en __main__: los de Kafka).
        self._transient: tuple[type[Exception], ...] = (
            StoreError,
            asyncpg.PostgresError,
            OSError,
            TimeoutError,
            *transient_errors,
        )
        self._retry = retry or RetryPolicy()
        # "Timbre": quien deja algo en el buzón lo toca para que el cartero
        # pase YA, en vez de esperar a la siguiente vuelta.
        self.kick = asyncio.Event()
        self.running = False

    async def run(self) -> None:
        """Bucle principal. Termina cuando se cancela la tarea (apagado)."""
        self.running = True
        failures = 0
        try:
            while True:
                try:
                    if self._housekeeping is not None:
                        await self._housekeeping()
                    sent = await self.flush()
                    await self.cleanup()
                    failures = 0
                except self._transient as exc:
                    # Base de datos o Kafka caídos: no se pierde nada (sigue en
                    # el buzón). Esperamos cada vez más y lo volvemos a intentar.
                    failures += 1
                    delay = self._retry.delay(failures)
                    log.warning(
                        "el relé del outbox falló, se reintenta", extra={"delay": delay, "error": str(exc)}
                    )
                    await asyncio.sleep(delay)
                    continue
                if sent == BATCH_SIZE:
                    continue  # quedan más: sin esperar
                self.kick.clear()
                # Espera al timbre o, como mucho, poll_seconds.
                try:
                    async with asyncio.timeout(self._poll):
                        await self.kick.wait()
                except TimeoutError:
                    pass
        finally:
            self.running = False

    async def flush(self) -> int:
        """Envía un lote de mensajes pendientes. Devuelve cuántos envió."""
        async with self._pool.acquire() as conn, conn.transaction():
            rows = await conn.fetch(
                "SELECT id, topic, msg_key, payload, headers FROM ai.outbox "
                "WHERE published_at IS NULL ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED",
                BATCH_SIZE,
            )
            if not rows:
                return 0
            for row in rows:
                headers = [(k, v.encode()) for k, v in json.loads(row["headers"])]
                # Si Kafka falla aquí, la excepción deshace la transacción: los
                # mensajes siguen pendientes y se reintentan en la siguiente vuelta.
                await self._producer.send_and_wait(
                    row["topic"], value=bytes(row["payload"]), key=row["msg_key"], headers=headers
                )
            await conn.execute(
                "UPDATE ai.outbox SET published_at = now() WHERE id = ANY($1::bigint[])",
                [r["id"] for r in rows],
            )
        log.debug("outbox enviado a Kafka", extra={"messages": len(rows)})
        return len(rows)

    async def cleanup(self) -> None:
        await self._pool.execute(
            "DELETE FROM ai.outbox WHERE published_at < now() - make_interval(days => $1)",
            KEEP_PUBLISHED_DAYS,
        )
