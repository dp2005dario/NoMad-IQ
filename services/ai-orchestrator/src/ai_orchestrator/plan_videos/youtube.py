"""Cliente de YouTube Data API v3: buscar vídeos cortos de un sitio.

La clave viaja en la cabecera X-Goog-Api-Key, nunca en la URL (así no
acaba en registros ni en mensajes de error).
"""

from __future__ import annotations

import html
from typing import Any
from urllib.parse import urlparse

import httpx
from pydantic import SecretStr

from ai_orchestrator.plan_videos.domain import VIDEO_ID, PlanVideo

SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
MAX_RESULTS = 40
THUMB_HOSTS = ("i.ytimg.com", "i9.ytimg.com")


class YouTubeBusyError(Exception):
    """Se acabó el cupo de YouTube o pide que esperemos."""


class YouTubeError(Exception):
    """YouTube no responde o responde algo raro."""


def _clean(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    # YouTube manda los títulos con "&amp;", "&#39;"...
    text = " ".join(html.unescape(value).split())
    return text[:limit] or None


def _thumb(snippet: dict[str, Any]) -> str | None:
    thumbs = snippet.get("thumbnails")
    if not isinstance(thumbs, dict):
        return None
    for size in ("high", "medium", "default"):
        t = thumbs.get(size)
        url = t.get("url") if isinstance(t, dict) else None
        if isinstance(url, str) and len(url) < 500:
            u = urlparse(url)
            if u.scheme == "https" and (u.hostname or "") in THUMB_HOSTS:
                return url
    return None


def parse_videos(data: Any) -> list[PlanVideo]:
    """Los vídeos de una respuesta de search.list (lo raro se salta)."""
    items = data.get("items") if isinstance(data, dict) else None
    out: list[PlanVideo] = []
    seen: set[str] = set()
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        ref = item.get("id")
        vid = ref.get("videoId") if isinstance(ref, dict) else None
        snippet = item.get("snippet")
        if not isinstance(vid, str) or not VIDEO_ID["youtube"].match(vid) or vid in seen:
            continue
        if not isinstance(snippet, dict):
            continue
        title = _clean(snippet.get("title"), 140)
        if title is None:
            continue
        seen.add(vid)
        out.append(
            PlanVideo(
                id=vid,
                title=title,
                channel=_clean(snippet.get("channelTitle"), 60),
                thumb=_thumb(snippet),
            )
        )
    return out


class YouTubeClient:
    def __init__(self, http: httpx.AsyncClient, key: SecretStr) -> None:
        self._http = http
        self._key = key

    async def shorts(self, query: str, language: str) -> list[PlanVideo]:
        """Hasta 40 vídeos cortos (< 4 min) para ``query``."""
        try:
            resp = await self._http.get(
                SEARCH_URL,
                params={
                    "part": "snippet",
                    "q": query,
                    "type": "video",
                    "videoDuration": "short",
                    "videoEmbeddable": "true",
                    "safeSearch": "strict",
                    "relevanceLanguage": language,
                    "maxResults": str(MAX_RESULTS),
                },
                headers={"X-Goog-Api-Key": self._key.get_secret_value()},
            )
        except httpx.HTTPError as exc:
            raise YouTubeError(f"YouTube no responde: {type(exc).__name__}") from exc
        if resp.status_code in (403, 429):
            raise YouTubeBusyError(f"YouTube {resp.status_code}")
        if resp.status_code != 200:
            raise YouTubeError(f"YouTube {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise YouTubeError("YouTube: respuesta que no es JSON") from exc
        return parse_videos(data)
