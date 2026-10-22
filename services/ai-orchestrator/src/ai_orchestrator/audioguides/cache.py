"""Caché de guiones por zona+idioma en Redis, con protección "single flight".

El problema (riesgo nº 2 del análisis: "thundering herd", la estampida):
    Llega un autobús con 50 turistas a la Plaza Mayor. 50 eventos de entrada
    casi a la vez. Si cada uno pidiera su propio guion al LLM, Ollama recibiría
    50 peticiones idénticas, la GPU se saturaría y TODOS esperarían minutos.

La solución, en tres capas (de la más barata a la más cara):
    1. **Caché en Redis.** El guion de una zona es el mismo para todos los que
       hablan ese idioma: se genera una vez y se guarda con la clave
       ``ai:audioguide:v1:<zone_id>:<idioma>``. Los siguientes 49 lo encuentran
       hecho (lectura de ~1 ms).
    2. **Single flight local** (:class:`SingleFlight`). Si dentro de ESTE proceso
       dos tareas piden la misma clave a la vez, la segunda no lanza otra
       generación: espera el resultado de la primera. Analogía: si alguien ya
       ha ido a por el pan, no vas tú también; esperas a que vuelva.
    3. **Cerrojo distribuido en Redis.** Si hay varias copias del servicio
       (o un trabajo de pregeneración en paralelo), solo una consigue el
       cerrojo ``SET ... NX PX`` y genera; las demás saben que "alguien ya está
       en ello" y no repiten el trabajo. El cerrojo caduca solo: si quien lo
       tenía se cae, no se queda bloqueado para siempre.

Además, la clave de Kafka de las entradas es el zone_id: todas las entradas a
una zona caen en la misma partición y las procesa UN consumidor. Las capas 2
y 3 cubren los casos que eso no evita (reparto de particiones, pregeneración).
"""

from __future__ import annotations

import asyncio
import secrets
from collections.abc import Awaitable, Callable
from typing import Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.domain import AudioguideScript

# El "v1" de la clave permite cambiar el formato del guion en el futuro sin
# leer por error guiones antiguos: basta con pasar a "v2".
KEY_PREFIX = "ai:audioguide:v1"
LOCK_PREFIX = "ai:audioguide-lock:v1"

# Borra el cerrojo SOLO si sigue siendo nuestro (mismo token). Sin esta
# comprobación, si nuestro cerrojo caducó y otro lo cogió, lo borraríamos sin
# querer. Se hace en un script Lua porque Redis lo ejecuta de una vez, sin
# que nadie pueda colarse entre el "comprobar" y el "borrar".
_UNLOCK_SCRIPT = """
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
end
return 0
"""


class CacheError(Exception):
    """Redis no disponible (temporal: el mensaje se reintentará)."""


def content_key(zone_id: str, language: str) -> str:
    return f"{KEY_PREFIX}:{zone_id}:{language}"


def lock_key(zone_id: str, language: str) -> str:
    return f"{LOCK_PREFIX}:{zone_id}:{language}"


class ScriptCache(Protocol):
    """Lo que el servicio necesita de la caché (en los tests hay una en memoria)."""

    async def get(self, zone_id: str, language: str) -> AudioguideScript | None: ...

    async def put(self, script: AudioguideScript, *, ttl_seconds: int) -> None: ...

    async def try_lock(self, zone_id: str, language: str, *, ttl_seconds: int) -> str | None:
        """Intenta coger el cerrojo. Devuelve el token si lo consigue, None si ya es de otro."""
        ...

    async def unlock(self, zone_id: str, language: str, token: str) -> None: ...

    async def ping(self) -> bool: ...


class RedisScriptCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, zone_id: str, language: str) -> AudioguideScript | None:
        try:
            raw = await self._redis.get(content_key(zone_id, language))
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer guion de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return AudioguideScript.model_validate_json(raw)
        except ValidationError:
            # Un valor ilegible (formato viejo, corrupto) no debe bloquear la
            # zona para siempre: se trata como "no hay" y se regenera.
            return None

    async def put(self, script: AudioguideScript, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(
                content_key(script.zone_id, script.language), script.model_dump_json(), ex=ttl_seconds
            )
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar guion en Redis: {exc}") from exc

    async def try_lock(self, zone_id: str, language: str, *, ttl_seconds: int) -> str | None:
        # Token aleatorio: identifica a ESTE dueño del cerrojo.
        token = secrets.token_hex(16)
        try:
            # NX = solo si no existe; EX = caduca solo pasados ttl_seconds.
            acquired = await self._redis.set(lock_key(zone_id, language), token, nx=True, ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"cerrojo en Redis: {exc}") from exc
        return token if acquired else None

    async def unlock(self, zone_id: str, language: str, token: str) -> None:
        try:
            await self._redis.eval(_UNLOCK_SCRIPT, 1, lock_key(zone_id, language), token)
        except (RedisError, OSError):
            # No es grave: el cerrojo caducará solo.
            return

    async def ping(self) -> bool:
        try:
            return bool(await self._redis.ping())
        except (RedisError, OSError):
            return False


class SingleFlight[T]:
    """Junta las llamadas simultáneas con la misma clave en UNA sola ejecución.

    La primera llamada con una clave ejecuta la función; las que lleguen
    mientras tanto esperan ese mismo resultado (o el mismo error). Al terminar
    la clave se libera, así una llamada posterior vuelve a ejecutar.
    """

    def __init__(self) -> None:
        self._inflight: dict[str, asyncio.Future[T]] = {}

    @property
    def inflight(self) -> int:
        return len(self._inflight)

    async def do(self, key: str, fn: Callable[[], Awaitable[T]]) -> tuple[T, bool]:
        """Devuelve (resultado, compartido). ``compartido`` = True si esperamos a otra."""
        existing = self._inflight.get(key)
        if existing is not None:
            # shield: si cancelan a ESTA espera, la tarea original sigue viva
            # para quienes también la esperan.
            return await asyncio.shield(existing), True
        future: asyncio.Future[T] = asyncio.get_running_loop().create_future()
        self._inflight[key] = future
        try:
            result = await fn()
        except asyncio.CancelledError:
            # Nos cancelaron (apagado): quienes esperaban también se cancelan.
            future.cancel()
            raise
        except Exception as exc:
            future.set_exception(exc)
            # Si nadie más esperaba, marcamos el error como "visto" para que
            # asyncio no avise de una excepción que nadie recogió.
            future.exception()
            raise
        else:
            future.set_result(result)
            return result, False
        finally:
            del self._inflight[key]
