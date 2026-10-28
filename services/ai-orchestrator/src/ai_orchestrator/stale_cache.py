"""Caché en Redis que guarda una copia "pasada de fecha" por si Overpass falla.

Una ficha se guarda con DOS claves:

* ``<clave>``        → el dato. Dura ``ttl + stale`` (por ejemplo 7 + 30 días).
* ``<clave>:fresh``  → solo una marca. Dura ``ttl`` (por ejemplo 7 días).

Mientras la marca exista, el dato es "fresco" y se sirve sin preguntar a
Overpass. Cuando la marca caduca, hay que refrescar; pero si Overpass está
caído, el dato viejo (obsoleto, "stale") sigue ahí y es mejor enseñar algo
algo antiguo que dar un error. Un cajero o una fuente cambian muy poco.
"""

from __future__ import annotations

from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError

# Cuánto sobrevive el dato después de dejar de ser fresco.
DEFAULT_STALE_SECONDS = 30 * 24 * 3600


async def read(redis: Redis, key: str, *, fresh_only: bool, what: str) -> str | bytes | None:
    """El dato guardado; con ``fresh_only`` solo si todavía no ha caducado."""
    try:
        if fresh_only:
            raw, mark = await redis.mget([key, f"{key}:fresh"])
            return raw if mark is not None else None
        raw = await redis.get(key)
    except (RedisError, OSError) as exc:
        raise CacheError(f"leer {what} de Redis: {exc}") from exc
    return raw


async def write(redis: Redis, key: str, raw: str, *, ttl_seconds: int, stale_seconds: int, what: str) -> None:
    """Guarda el dato (vida larga) y la marca de "fresco" (vida corta)."""
    try:
        await redis.set(key, raw, ex=ttl_seconds + stale_seconds)
        await redis.set(f"{key}:fresh", "1", ex=ttl_seconds)
    except (RedisError, OSError) as exc:
        raise CacheError(f"guardar {what} en Redis: {exc}") from exc
