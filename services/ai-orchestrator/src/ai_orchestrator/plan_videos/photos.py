"""La foto de un sitio (para el fondo de la tarjeta de cada viaje en grupo).

Sale de la ficha de Wikipedia del sitio ("Lisboa"): su foto principal, de
upload.wikimedia.org (licencias libres). Sin clave y gratis; se guarda 30
días en Redis para no preguntar cada vez.
"""

from __future__ import annotations

import json
from typing import Any
from urllib.parse import quote, urlparse

import httpx
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError

PHOTO_PREFIX = "ai:planvideos:photo:v1"
SUMMARY_URL = "https://{lang}.wikipedia.org/api/rest_v1/page/summary/{title}"
PHOTO_HOST = "upload.wikimedia.org"
# Wikipedia pide que digamos quiénes somos (sin datos de nadie).
USER_AGENT = "ECLIPTA/1.0 (travel app; group trips)"


def lead_photo(data: Any) -> str | None:
    """La foto principal de un resumen de Wikipedia (solo de upload.wikimedia.org)."""
    if not isinstance(data, dict) or data.get("type") == "disambiguation":
        return None
    for key in ("thumbnail", "originalimage"):
        img = data.get(key)
        src = img.get("source") if isinstance(img, dict) else None
        if isinstance(src, str) and len(src) < 1000:
            u = urlparse(src)
            if u.scheme == "https" and u.hostname == PHOTO_HOST:
                return src
    return None


class WikipediaPhotos:
    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def photo_of(self, place: str, language: str) -> str | None:
        """En tu idioma y, si no hay ficha, en inglés."""
        for lang in dict.fromkeys((language, "en")):
            url = SUMMARY_URL.format(lang=lang, title=quote(place.replace(" ", "_"), safe=""))
            try:
                resp = await self._http.get(url, headers={"User-Agent": USER_AGENT})
                data = resp.json() if resp.status_code == 200 else None
            except (httpx.HTTPError, ValueError):
                data = None
            found = lead_photo(data)
            if found is not None:
                return found
        return None


class RedisPhotoCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, key: str) -> tuple[bool, str | None]:
        """(¿estaba?, la foto o None)."""
        try:
            raw = await self._redis.get(f"{PHOTO_PREFIX}:{key}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer foto de Redis: {exc}") from exc
        if raw is None:
            return False, None
        try:
            value = json.loads(raw).get("url")
        except (ValueError, AttributeError):
            return False, None
        return True, value if isinstance(value, str) else None

    async def put(self, key: str, url: str | None, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(f"{PHOTO_PREFIX}:{key}", json.dumps({"url": url}), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar foto en Redis: {exc}") from exc
