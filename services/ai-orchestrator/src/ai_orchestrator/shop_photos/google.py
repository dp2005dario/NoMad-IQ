"""Cliente de Places API (New) de Google: buscar un sitio y sacar su foto.

Dos llamadas por sitio:
    1. ``places:searchText`` con el nombre y el punto: devuelve el sitio de
       Google que más se parece y la lista de sus fotos.
    2. ``<foto>/media?skipHttpRedirect=true``: devuelve la dirección
       pública de la foto (en googleusercontent.com), sin la clave dentro.

La clave viaja SOLO en la cabecera X-Goog-Api-Key: nunca en la URL, para que
no acabe en registros ni en mensajes de error.
"""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import quote, urlparse

import httpx
from pydantic import SecretStr

from ai_orchestrator.places.wikimedia import RateLimiter

SEARCH_URL = "https://places.googleapis.com/v1/places:searchText"
MEDIA_URL = "https://places.googleapis.com/v1/{name}/media"
# Solo pedimos lo justo (Google cobra según los campos que pides).
SEARCH_FIELDS = "places.id,places.photos"
# Para el buscador del Mapa: nombre, dirección y dónde está.
FIND_FIELDS = "places.displayName,places.formattedAddress,places.location"
# Las fotos solo pueden venir de los servidores de Google.
PHOTO_HOSTS = (".googleusercontent.com",)
# "places/ChIJ.../photos/AUc7...": letras, números, "_", "-" y "/".
_PHOTO_NAME = re.compile(r"^places/[A-Za-z0-9_-]{1,200}/photos/[A-Za-z0-9_-]{1,800}$")
# Lo cerca que tiene que estar el sitio de Google del punto de OpenStreetMap.
BIAS_RADIUS_M = 150.0


class GoogleBusyError(Exception):
    """Hemos llegado a nuestro límite o Google pide que esperemos."""


class GoogleError(Exception):
    """Google no responde o responde algo raro."""


def _https_url(value: Any, hosts: tuple[str, ...]) -> str | None:
    if not isinstance(value, str) or len(value) > 2000:
        return None
    u = urlparse(value)
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not any(host.endswith(h) for h in hosts):
        return None
    return value


def first_photo(data: Any) -> tuple[str, str | None, str | None] | None:
    """(nombre de la foto, autor, web del autor) de la primera foto, o None."""
    places = data.get("places") if isinstance(data, dict) else None
    if not isinstance(places, list) or not places or not isinstance(places[0], dict):
        return None
    photos = places[0].get("photos")
    if not isinstance(photos, list) or not photos or not isinstance(photos[0], dict):
        return None
    photo = photos[0]
    name = photo.get("name")
    if not isinstance(name, str) or not _PHOTO_NAME.match(name):
        return None
    author: str | None = None
    author_url: str | None = None
    who = photo.get("authorAttributions")
    if isinstance(who, list) and who and isinstance(who[0], dict):
        display = who[0].get("displayName")
        if isinstance(display, str) and display.strip():
            author = " ".join(display.split())[:60]
        author_url = _https_url(who[0].get("uri"), (".google.com", "google.com"))
    return name, author, author_url


class GooglePlacesClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        key: SecretStr,
        limiter: RateLimiter,
        max_wait_seconds: float = 2.0,
        width_px: int = 480,
    ) -> None:
        self._http = http
        self._key = key
        self._limiter = limiter
        self._max_wait = max_wait_seconds
        self._width = width_px

    def _headers(self, fields: str | None = None) -> dict[str, str]:
        h = {"X-Goog-Api-Key": self._key.get_secret_value(), "Accept": "application/json"}
        if fields:
            h["X-Goog-FieldMask"] = fields
        return h

    async def _call(self, method: str, url: str, **kwargs: Any) -> Any:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.request(method, url, **kwargs)
        except httpx.HTTPError as exc:
            # Solo el tipo de error: el mensaje podría llevar la petición.
            raise GoogleError(f"{type(exc).__name__} al llamar a Google") from exc
        if resp.status_code in (429, 503):
            raise GoogleBusyError(f"Google respondió {resp.status_code}")
        if resp.status_code != 200:
            raise GoogleError(f"Google respondió {resp.status_code}")
        try:
            return resp.json()
        except ValueError as exc:
            raise GoogleError("respuesta de Google que no es JSON") from exc

    async def call_search(self, body: dict[str, Any], fields: str) -> Any:
        """Una búsqueda de texto con los campos que se pidan."""
        return await self._call("POST", SEARCH_URL, headers=self._headers(fields), json=body)

    async def photo_of(self, name: str, lat: float, lon: float) -> tuple[str, str | None, str | None] | None:
        """(dirección de la foto, autor, web del autor) del sitio, o None si no tiene."""
        found = await self._call(
            "POST",
            SEARCH_URL,
            headers=self._headers(SEARCH_FIELDS),
            json={
                "textQuery": name,
                "maxResultCount": 1,
                "locationBias": {
                    "circle": {
                        "center": {"latitude": round(lat, 5), "longitude": round(lon, 5)},
                        "radius": BIAS_RADIUS_M,
                    }
                },
            },
        )
        first = first_photo(found)
        if first is None:
            return None
        photo_name, author, author_url = first
        media = await self._call(
            "GET",
            MEDIA_URL.format(name=quote(photo_name, safe="/")),
            headers=self._headers(),
            params={"maxWidthPx": str(self._width), "skipHttpRedirect": "true"},
        )
        url = _https_url(media.get("photoUri") if isinstance(media, dict) else None, PHOTO_HOSTS)
        if url is None:
            return None
        return url, author, author_url


def parse_found(data: Any, limit: int = 8) -> list[tuple[str, str, float, float]]:
    """(nombre, dirección, lat, lon) de cada sitio que devolvió Google."""
    places = data.get("places") if isinstance(data, dict) else None
    if not isinstance(places, list):
        return []
    out: list[tuple[str, str, float, float]] = []
    for p in places[:limit]:
        if not isinstance(p, dict):
            continue
        loc = p.get("location")
        lat = loc.get("latitude") if isinstance(loc, dict) else None
        lon = loc.get("longitude") if isinstance(loc, dict) else None
        if not isinstance(lat, int | float) or not isinstance(lon, int | float):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        shown = p.get("displayName")
        name = shown.get("text") if isinstance(shown, dict) else None
        address = p.get("formattedAddress")
        address = " ".join(address.split())[:300] if isinstance(address, str) else ""
        name = (
            " ".join(name.split())[:120] if isinstance(name, str) and name.strip() else address.split(",")[0]
        )
        if not name:
            continue
        out.append((name, address or name, float(lat), float(lon)))
    return out


async def find_places(
    client: GooglePlacesClient, query: str, near: tuple[float, float] | None
) -> list[tuple[str, str, float, float]]:
    """Buscar "de todo", como en Google Maps (para el buscador del Mapa)."""
    body: dict[str, Any] = {"textQuery": query, "maxResultCount": 8}
    if near is not None:
        body["locationBias"] = {
            "circle": {
                "center": {"latitude": round(near[0], 3), "longitude": round(near[1], 3)},
                "radius": 20_000.0,
            }
        }
    found = await client.call_search(body, FIND_FIELDS)
    return parse_found(found)
