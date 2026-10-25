"""Avisar en el móvil de que hay mensajes nuevos en el chat del viaje.

Camino: este módulo deja un GroupChatActivity en el buzón (outbox) de
PostgreSQL → el relé lo publica en Kafka → el notifier manda un push cifrado
a los teléfonos de esas personas ("Mensajes nuevos en tu viaje").

Dos frenos para que cueste 0 € y no moleste:
    - Como mucho UN aviso por viaje cada 2 minutos (Redis SET NX con
      caducidad). Si el grupo está charlando, el resto de mensajes ya los
      verán al abrir el chat.
    - Sin clave de seudónimos (NOTIFY_PSEUDONYM_KEY) no se avisa: nunca se
      manda un user_id real por Kafka.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from datetime import UTC, datetime

from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.negotiation.events import chat_activity_message
from ai_orchestrator.outbox import enqueue
from ai_orchestrator.pseudonym import Pseudonymizer
from ai_orchestrator.store import Pool

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:chat:push:v1"


class PushThrottle:
    """¿Es el primer aviso de este viaje en los últimos [seconds] segundos?

    Con Redis vale para todas las copias del servicio a la vez. Sin Redis (o si
    falla), cada copia lleva su propia cuenta en memoria: como mucho, un aviso
    de más.
    """

    def __init__(
        self, redis: Redis | None, seconds: int, clock: Callable[[], float] = time.monotonic
    ) -> None:
        self._redis = redis
        self._seconds = seconds
        self._clock = clock
        self._local: dict[str, float] = {}

    async def first(self, trip_id: str) -> bool:
        if self._redis is not None:
            try:
                return bool(await self._redis.set(f"{KEY_PREFIX}:{trip_id}", "1", nx=True, ex=self._seconds))
            except RedisError:
                log.warning("redis no responde: freno de avisos en memoria")
        now = self._clock()
        if now - self._local.get(trip_id, float("-inf")) < self._seconds:
            return False
        if len(self._local) > 10_000:
            # Que el diccionario no crezca sin límite: se olvida lo viejo.
            self._local = {k: v for k, v in self._local.items() if now - v < self._seconds}
        self._local[trip_id] = now
        return True


class ChatPusher:
    """La función "avisa a estos" que usa la API del chat (ChatPush)."""

    def __init__(
        self,
        *,
        pool: Pool,
        pseudonymizer: Pseudonymizer,
        topic: str,
        throttle: PushThrottle,
        on_outbox: Callable[[], None],
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._pool = pool
        self._pseudonymizer = pseudonymizer
        self._topic = topic
        self._throttle = throttle
        self._on_outbox = on_outbox
        self._clock = clock

    async def __call__(self, trip_id: str, user_ids: list[str]) -> None:
        if not user_ids or not await self._throttle.first(trip_id):
            return
        message = chat_activity_message(
            self._topic,
            trip_id,
            [self._pseudonymizer.recipient(u) for u in user_ids],
            self._clock(),
        )
        async with self._pool.acquire() as conn:
            await enqueue(conn, message)
        # Que el relé no espere a su siguiente vuelta.
        self._on_outbox()
