"""Versión del contenido de cada zona, recordada en memoria unos segundos.

Para saber qué guion buscar en Redis hace falta la versión de los hechos de la
zona (la clave es ``<zona>:<idioma>:<versión>``). Si la pidiéramos a
PostgreSQL en CADA entrada, mil turistas en la Puerta del Sol serían mil
consultas: la "tormenta de consultas" que avisaba el análisis de diseño.

Por eso cada copia del servicio recuerda la versión de cada zona durante
``ttl_seconds`` (60 s por defecto):

- PostgreSQL recibe como mucho UNA consulta por zona y minuto por copia del
  servicio, entre o no entre gente. Lo que cuesta depende del número de
  zonas, no del número de usuarios.
- Si dos tareas preguntan a la vez por la misma zona que no está en memoria,
  solo una consulta (``SingleFlight``); la otra espera la respuesta.
- También se recuerda "esta zona no existe" (None): un evento con un zone_id
  inventado no puede usarse para martillear la base de datos.

El precio: tras corregir un hecho, el guion nuevo tarda como mucho
``ttl_seconds`` en empezar a usarse (antes podían ser días). Es "consistencia
eventual" con una ventana corta y acotada.

La pieza genérica, :class:`TtlMemo`, también la usa la API para recordar los
manifiestos de audio (misma idea: muchos oyentes, una consulta).
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable, Hashable
from typing import Protocol

from ai_orchestrator.audioguides.cache import SingleFlight

# Tope de entradas recordadas, para que la memoria no crezca sin límite si
# llegan muchas claves distintas (por ejemplo, zone_id inventados).
MAX_ENTRIES = 100_000


class TtlMemo[K: Hashable, V]:
    """Recuerda el resultado de una consulta durante ``ttl_seconds`` (incluido "no hay")."""

    def __init__(self, *, ttl_seconds: float, clock: Callable[[], float] = time.monotonic) -> None:
        self._ttl = ttl_seconds
        # monotonic: un reloj que nunca va hacia atrás (no le afectan los
        # cambios de hora del sistema). Se inyecta para poder probarlo.
        self._clock = clock
        self._entries: dict[K, tuple[V, float]] = {}
        self._flight: SingleFlight[V] = SingleFlight()

    async def get(self, key: K, load: Callable[[], Awaitable[V]]) -> V:
        now = self._clock()
        cached = self._entries.get(key)
        if cached is not None and cached[1] > now:
            return cached[0]
        value, _ = await self._flight.do(repr(key), load)
        if len(self._entries) >= MAX_ENTRIES:
            # Limpieza sencilla: fuera lo caducado; si aún no cabe, se vacía.
            self._entries = {k: v for k, v in self._entries.items() if v[1] > now}
            if len(self._entries) >= MAX_ENTRIES:
                self._entries.clear()
        self._entries[key] = (value, now + self._ttl)
        return value

    def forget(self, key: K) -> None:
        self._entries.pop(key, None)


class VersionSource(Protocol):
    async def content_version(self, zone_id: str) -> int | None: ...


class ZoneVersionCache:
    def __init__(
        self,
        source: VersionSource,
        *,
        ttl_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._source = source
        self._memo: TtlMemo[str, int | None] = TtlMemo(ttl_seconds=ttl_seconds, clock=clock)

    async def get(self, zone_id: str) -> int | None:
        """Versión del contenido de la zona (0 = sin hechos), o None si no existe."""
        return await self._memo.get(zone_id, lambda: self._source.content_version(zone_id))

    def forget(self, zone_id: str) -> None:
        """Olvida una zona (la próxima pregunta irá a PostgreSQL)."""
        self._memo.forget(zone_id)
