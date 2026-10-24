"""Cupos diarios por persona ("bono de N usos al día"), guardados en Redis.

Los usan el chat con Flyra y el modo cámara: cada uso cuesta máquina (el
modelo de IA), así que cada cuenta tiene un tope diario y el coste nunca
se dispara aunque alguien insista. Coste 0 €.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Protocol

from redis.asyncio import Redis
from redis.exceptions import RedisError

log = logging.getLogger(__name__)


class QuotaExceededError(Exception):
    """Ya gastó los usos gratuitos de hoy."""

    def __init__(self, retry_after: int) -> None:
        super().__init__("cupo diario agotado")
        self.retry_after = retry_after


class QuotaUnavailableError(Exception):
    """Redis no responde: no sabemos cuántos usos lleva (temporal)."""


class Quota(Protocol):
    """Cuántos usos lleva hoy cada persona. En los tests, uno en memoria."""

    async def take(self, user_id: str, day: str, limit: int) -> int | None: ...

    async def give_back(self, user_id: str, day: str) -> None: ...


class RedisQuota:
    """Un contador por persona y día en Redis (caduca solo a los dos días).

    INCR es atómico: aunque lleguen dos peticiones a la vez desde dos móviles,
    cada una suma 1 y nadie se cuela del límite.
    """

    def __init__(self, redis: Redis, *, prefix: str) -> None:
        self._redis = redis
        self._prefix = prefix

    def _key(self, user_id: str, day: str) -> str:
        return f"{self._prefix}:{day}:{user_id}"

    async def take(self, user_id: str, day: str, limit: int) -> int | None:
        """Gasta un uso. Devuelve los que quedan, o None si no quedaba ninguno."""
        key = self._key(user_id, day)
        try:
            async with self._redis.pipeline(transaction=True) as pipe:
                pipe.incr(key)
                pipe.expire(key, 2 * 24 * 3600)
                used, _ = await pipe.execute()
        except (RedisError, OSError) as exc:
            raise QuotaUnavailableError(f"cupo en Redis: {exc}") from exc
        if int(used) > limit:
            return None
        return limit - int(used)

    async def give_back(self, user_id: str, day: str) -> None:
        try:
            await self._redis.decr(self._key(user_id, day))
        except (RedisError, OSError):
            log.warning("no se pudo devolver un uso del cupo", extra={"prefix": self._prefix})


def day_key(now: datetime) -> str:
    """El día (UTC) del contador: "20261023"."""
    return now.strftime("%Y%m%d")


def seconds_to_midnight(now: datetime) -> int:
    """Segundos hasta que se renueva el cupo (medianoche UTC), mínimo 60."""
    tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(60, int((tomorrow - now).total_seconds()))
