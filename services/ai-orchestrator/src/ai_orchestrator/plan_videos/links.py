"""Enlaces de TikTok e Instagram que pegan los usuarios.

TikTok e Instagram no dejan a otras apps BUSCAR sus vídeos, pero sí
enseñar uno concreto con su reproductor oficial si tienes el enlace. Así
que cualquiera con sesión puede pegar el enlace de un vídeo para un sitio
("Lisboa") y le sale a todos en el carrusel de ese sitio.

    - Solo se aceptan enlaces de tiktok.com / instagram.com (y los cortos
      vm.tiktok.com, que se siguen UNA vez y solo hasta tiktok.com).
    - El título y la miniatura de TikTok salen de su oEmbed (público, sin
      clave). Instagram pide clave para eso: va sin miniatura.
    - Como mucho 40 por sitio (los más nuevos) y 20 al día por persona.
"""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlparse

import httpx
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError
from ai_orchestrator.plan_videos.domain import PlanVideo

LINKS_PREFIX = "ai:planvideos:links:v1"
MAX_PER_PLACE = 40
# Un enlace pegado vive medio año (si nadie lo vuelve a pegar).
LINK_TTL_SECONDS = 180 * 24 * 3600
OEMBED_URL = "https://www.tiktok.com/oembed"

_TIKTOK = re.compile(r"^/(?:@[A-Za-z0-9._-]{1,40}/video|v|embed(?:/v2)?|player/v1)/([0-9]{15,25})/?$")
_INSTAGRAM = re.compile(r"^/(?:[A-Za-z0-9._]{1,40}/)?(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,40})/?$")
SHORT_HOSTS = ("vm.tiktok.com", "vt.tiktok.com")
TIKTOK_THUMB_HOSTS = (".tiktokcdn.com", ".tiktokcdn-us.com", ".tiktokcdn-eu.com", ".ttwstatic.com")


class BadLinkError(Exception):
    """No es un enlace de vídeo de TikTok o Instagram."""


def parse_link(url: str) -> tuple[str, str] | None:
    """("tiktok", "7301...") o ("instagram", "C1a2...") si el enlace vale."""
    try:
        u = urlparse(url.strip())
    except ValueError:
        return None
    host = (u.hostname or "").lower()
    if u.scheme not in ("https", "http"):
        return None
    if host in ("tiktok.com", "www.tiktok.com", "m.tiktok.com"):
        m = _TIKTOK.match(u.path)
        return ("tiktok", m.group(1)) if m else None
    if host in ("instagram.com", "www.instagram.com", "m.instagram.com"):
        m = _INSTAGRAM.match(u.path)
        return ("instagram", m.group(1)) if m else None
    return None


def is_short_tiktok(url: str) -> bool:
    try:
        u = urlparse(url.strip())
    except ValueError:
        return False
    return u.scheme == "https" and (u.hostname or "").lower() in SHORT_HOSTS


def _thumb(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > 1500:
        return None
    u = urlparse(value)
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not any(host.endswith(h) for h in TIKTOK_THUMB_HOSTS):
        return None
    return value


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:limit] or None


class LinkResolver:
    """Convierte un enlace pegado en un vídeo (con título y miniatura si se puede)."""

    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def resolve(self, url: str) -> PlanVideo:
        if is_short_tiktok(url):
            url = await self._follow_short(url)
        found = parse_link(url)
        if found is None:
            raise BadLinkError("no es un vídeo de TikTok o Instagram")
        source, vid = found
        if source == "instagram":
            return PlanVideo(source="instagram", id=vid, title="Instagram")
        title, author, thumb = await self._tiktok_info(vid)
        return PlanVideo(source="tiktok", id=vid, title=title or "TikTok", channel=author, thumb=thumb)

    async def _follow_short(self, url: str) -> str:
        """vm.tiktok.com/abc → la dirección larga (un salto, solo a tiktok.com)."""
        try:
            resp = await self._http.get(url, follow_redirects=False)
        except httpx.HTTPError as exc:
            raise BadLinkError("no se pudo abrir el enlace corto") from exc
        target = resp.headers.get("location", "")
        if resp.status_code not in (301, 302, 303, 307, 308) or parse_link(target) is None:
            raise BadLinkError("el enlace corto no lleva a un vídeo")
        return target

    async def _tiktok_info(self, vid: str) -> tuple[str | None, str | None, str | None]:
        """Título, autor y miniatura de su oEmbed (si falla, sin ellos)."""
        try:
            resp = await self._http.get(OEMBED_URL, params={"url": f"https://www.tiktok.com/video/{vid}"})
            data = resp.json() if resp.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            data = None
        if not isinstance(data, dict):
            return None, None, None
        return (
            _text(data.get("title"), 140),
            _text(data.get("author_name"), 60),
            _thumb(data.get("thumbnail_url")),
        )


class RedisLinkStore:
    """Los enlaces pegados de cada sitio (lista en Redis, los más nuevos primero)."""

    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def list(self, place_key: str) -> list[PlanVideo]:
        try:
            raw = await self._redis.lrange(f"{LINKS_PREFIX}:{place_key}", 0, MAX_PER_PLACE - 1)
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer enlaces de Redis: {exc}") from exc
        out: list[PlanVideo] = []
        for item in raw:
            try:
                out.append(PlanVideo.model_validate_json(item))
            except ValueError:
                continue
        return out

    async def add(self, place_key: str, video: PlanVideo) -> None:
        key = f"{LINKS_PREFIX}:{place_key}"
        try:
            for item in await self._redis.lrange(key, 0, -1):
                try:
                    old = PlanVideo.model_validate_json(item)
                except ValueError:
                    continue
                if old.source == video.source and old.id == video.id:
                    await self._redis.lrem(key, 0, item)
            async with self._redis.pipeline(transaction=True) as pipe:
                pipe.lpush(key, video.model_dump_json())
                pipe.ltrim(key, 0, MAX_PER_PLACE - 1)
                pipe.expire(key, LINK_TTL_SECONDS)
                await pipe.execute()
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar enlace en Redis: {exc}") from exc
