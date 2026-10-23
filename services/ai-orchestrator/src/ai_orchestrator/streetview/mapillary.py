"""Cliente de la API de Mapillary (graph.mapillary.com), con límite de ritmo.

Mapillary es gratis con una "client token" (se crea en
https://www.mapillary.com/dashboard/developers). La token viaja SOLO en la
cabecera Authorization: nunca en la URL, para que no acabe en registros de
proxies ni en mensajes de error.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlparse

import httpx
from pydantic import SecretStr

from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.streetview.domain import StreetPhoto

IMAGES_URL = "https://graph.mapillary.com/images"
FIELDS = (
    "id,captured_at,compass_angle,computed_geometry,geometry,is_pano,thumb_256_url,thumb_1024_url,creator"
)
# Las fotos solo pueden venir de los servidores de Mapillary (su CDN es la de
# Meta). Así la app nunca carga imágenes de un sitio que no conocemos.
PHOTO_HOSTS = (".fbcdn.net", ".mapillary.com")


class MapillaryBusyError(Exception):
    """Hemos llegado a nuestro límite o Mapillary pide que esperemos."""


class MapillaryError(Exception):
    """Mapillary no responde o responde algo raro."""


def _photo_url(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    u = urlparse(value)
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not any(host.endswith(h) for h in PHOTO_HOSTS):
        return None
    return value


def _point(row: dict[str, Any]) -> tuple[float, float] | None:
    # computed_geometry es la posición corregida por Mapillary; si no está,
    # la que dio el GPS del móvil.
    for key in ("computed_geometry", "geometry"):
        geo = row.get(key)
        if isinstance(geo, dict):
            coords = geo.get("coordinates")
            if (
                isinstance(coords, list)
                and len(coords) == 2
                and all(isinstance(c, int | float) for c in coords)
                and -180 <= coords[0] <= 180
                and -90 <= coords[1] <= 90
            ):
                return float(coords[1]), float(coords[0])
    return None


def parse_photo(row: Any) -> StreetPhoto | None:
    """Una foto de la respuesta, o None si le falta algo o no es de fiar."""
    if not isinstance(row, dict):
        return None
    pid = row.get("id")
    if not isinstance(pid, str) or not pid.isdigit() or len(pid) > 30:
        return None
    point = _point(row)
    thumb = _photo_url(row.get("thumb_256_url"))
    image = _photo_url(row.get("thumb_1024_url"))
    if point is None or thumb is None or image is None:
        return None
    captured = row.get("captured_at")
    angle = row.get("compass_angle")
    creator = row.get("creator")
    username = creator.get("username") if isinstance(creator, dict) else None
    return StreetPhoto(
        id=pid,
        lat=point[0],
        lon=point[1],
        captured_at=(
            datetime.fromtimestamp(captured / 1000, tz=UTC)
            if isinstance(captured, int) and 0 < captured < 10**14
            else None
        ),
        compass_angle=float(angle) % 360 if isinstance(angle, int | float) else None,
        is_pano=row.get("is_pano") is True,
        thumb_url=thumb,
        image_url=image,
        creator=username[:60] if isinstance(username, str) and username.strip() else None,
        page_url=f"https://www.mapillary.com/app/?pKey={pid}&focus=photo",
    )


class MapillaryClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        token: SecretStr,
        limiter: RateLimiter,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._token = token
        self._limiter = limiter
        self._max_wait = max_wait_seconds

    async def photos_in(self, south: float, west: float, north: float, east: float) -> list[StreetPhoto]:
        """Las fotos dentro de un rectángulo pequeño (unos cientos de metros)."""
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.get(
                IMAGES_URL,
                params={
                    "fields": FIELDS,
                    "bbox": f"{west:.5f},{south:.5f},{east:.5f},{north:.5f}",
                    "limit": "100",
                },
                headers={
                    "Authorization": f"OAuth {self._token.get_secret_value()}",
                    "Accept": "application/json",
                },
            )
        except httpx.HTTPError as exc:
            # Solo el tipo de error: el mensaje podría llevar la petición.
            raise MapillaryError(f"{type(exc).__name__} al llamar a Mapillary") from exc
        if resp.status_code in (429, 503):
            raise MapillaryBusyError(f"Mapillary respondió {resp.status_code}")
        if resp.status_code != 200:
            raise MapillaryError(f"Mapillary respondió {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise MapillaryError("respuesta de Mapillary que no es JSON") from exc
        rows = data.get("data") if isinstance(data, dict) else None
        if not isinstance(rows, list):
            raise MapillaryError("respuesta de Mapillary sin lista de fotos")
        return [p for p in (parse_photo(r) for r in rows) if p is not None]
