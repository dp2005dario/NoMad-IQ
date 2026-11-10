"""Buscar dónde está una dirección o un sitio, con Nominatim (OpenStreetMap).

    GET /v1/geocode?q=Hotel%20Avenida%20Palace&lat=38.71&lon=-9.14

Para qué: la app sabe el NOMBRE o la DIRECCIÓN de tu hotel (Modo fácil o la
reserva de la Bóveda) pero no dónde está en el mapa. Con esto se busca y la
persona elige el bueno; nunca se coloca solo.

Nominatim es gratis pero tiene normas (https://operations.osmfoundation.org/
policies/nominatim/): como mucho 1 petición por segundo, decir quién eres
(User-Agent) y guardar lo ya buscado. Por eso:
- solo con cuenta (así nadie la usa como buscador gratis);
- un dispensador de turnos de 1 por segundo (si hay cola larga: "vuelve luego");
- una caché en memoria de lo buscado (500 búsquedas, 1 día).

Lo que se busca NO se guarda en ningún sitio más ni se escribe en los logs.
"""

from __future__ import annotations

import time
from collections import OrderedDict
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated, Any, Protocol

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.quota import QuotaUnavailableError, day_key
from ai_orchestrator.shop_photos.google import GoogleBusyError, GoogleError, GooglePlacesClient, find_places

NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)"
MAX_RESULTS = 5
CACHE_SIZE = 500
CACHE_SECONDS = 24 * 3600


class Place(BaseModel):
    name: str
    address: str
    lat: float
    lon: float
    # De dónde sale (Google pide decirlo si se enseña fuera de su mapa).
    source: str | None = None


class Places(BaseModel):
    items: list[Place]
    source: str = "OpenStreetMap (Nominatim)"


class GeocodeBusyError(Exception):
    """Demasiadas búsquedas a la vez: la app lo dirá y se puede reintentar."""


class GeocodeError(Exception):
    """Nominatim no responde o responde algo raro."""


class Geocoder(Protocol):
    async def search(self, query: str, near: tuple[float, float] | None) -> list[Place]: ...


def parse_nominatim(data: Any) -> list[Place]:
    """Del JSON de Nominatim (formato jsonv2) a sitios limpios."""
    if not isinstance(data, list):
        raise GeocodeError("respuesta rara")
    out: list[Place] = []
    for item in data[:MAX_RESULTS]:
        if not isinstance(item, dict):
            continue
        try:
            lat = float(item["lat"])
            lon = float(item["lon"])
        except (KeyError, TypeError, ValueError):
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue
        address = " ".join(str(item.get("display_name") or "").split())[:300]
        name = " ".join(str(item.get("name") or "").split())[:120] or address.split(",")[0]
        if not address:
            continue
        out.append(Place(name=name, address=address, lat=lat, lon=lon))
    return out


class NominatimGeocoder:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._http = http
        # 1 por segundo, como pide Nominatim; esperar más de 3 s no compensa.
        self._limiter = limiter or RateLimiter(1, 1, busy=lambda: GeocodeBusyError("cola de búsquedas"))
        self._clock = clock
        self._cache: OrderedDict[tuple[str, int | None, int | None], tuple[float, list[Place]]] = (
            OrderedDict()
        )

    async def search(self, query: str, near: tuple[float, float] | None) -> list[Place]:
        q = " ".join(query.split()).lower()
        # La caché agrupa por zona de ~10 km: el mismo hotel buscado desde
        # cerca da lo mismo.
        key = (q, round(near[0] * 10) if near else None, round(near[1] * 10) if near else None)
        hit = self._cache.get(key)
        if hit is not None and self._clock() - hit[0] < CACHE_SECONDS:
            self._cache.move_to_end(key)
            return hit[1]
        await self._limiter.acquire(max_wait=3)
        params: dict[str, str | int] = {"q": query, "format": "jsonv2", "limit": MAX_RESULTS}
        if near is not None:
            # Preferir lo de cerca (unos 50 km), sin descartar lo de fuera.
            lat, lon = near
            params["viewbox"] = f"{lon - 0.5},{lat + 0.5},{lon + 0.5},{lat - 0.5}"
        try:
            resp = await self._http.get(NOMINATIM_URL, params=params, headers={"User-Agent": USER_AGENT})
        except httpx.HTTPError as exc:
            raise GeocodeError(type(exc).__name__) from exc
        if resp.status_code == 429:
            raise GeocodeBusyError("Nominatim pide esperar")
        if resp.status_code != 200:
            raise GeocodeError(f"HTTP {resp.status_code}")
        try:
            places = parse_nominatim(resp.json())
        except ValueError as exc:
            raise GeocodeError("JSON roto") from exc
        self._cache[key] = (self._clock(), places)
        if len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return places


class DailyQuota(Protocol):
    async def take(self, user_id: str, day: str, limit: int) -> int | None: ...


class GoogleFirstGeocoder:
    """El buscador del Mapa "como Google Maps": primero Google Places (si hay
    clave y queda cupo hoy) y, si no, Nominatim (OpenStreetMap, gratis)."""

    def __init__(
        self,
        google: GooglePlacesClient,
        fallback: Geocoder,
        *,
        quota: DailyQuota,
        daily_limit: int,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._google = google
        self._fallback = fallback
        self._quota = quota
        self._limit = daily_limit
        self._clock = clock
        self._cache: OrderedDict[tuple[str, int | None, int | None], tuple[float, list[Place]]] = (
            OrderedDict()
        )

    async def search(self, query: str, near: tuple[float, float] | None) -> list[Place]:
        q = " ".join(query.split()).lower()
        key = (q, round(near[0] * 10) if near else None, round(near[1] * 10) if near else None)
        hit = self._cache.get(key)
        if hit is not None and self._clock() - hit[0] < CACHE_SECONDS:
            self._cache.move_to_end(key)
            return hit[1]
        try:
            left = await self._quota.take("all", day_key(datetime.now(UTC)), self._limit)
        except QuotaUnavailableError:
            left = None
        if left is None:
            return await self._fallback.search(query, near)
        try:
            found = await find_places(self._google, query, near)
        except (GoogleError, GoogleBusyError):
            # Google caído o saturado: se busca en OpenStreetMap.
            return await self._fallback.search(query, near)
        places = [Place(name=n, address=a, lat=la, lon=lo, source="Google Maps") for n, a, la, lo in found]
        if not places:
            return await self._fallback.search(query, near)
        self._cache[key] = (self._clock(), places)
        if len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return places


def geocode_router(geocoder: Geocoder) -> APIRouter:
    router = APIRouter()

    @router.get("/v1/geocode", response_model=Places)
    async def geocode(
        _: Annotated[Principal, Depends(current_principal)],
        q: Annotated[str, Query(min_length=3, max_length=200)],
        lat: Annotated[float | None, Query(ge=-85, le=85)] = None,
        lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    ) -> Places:
        near = (lat, lon) if lat is not None and lon is not None else None
        try:
            items = await geocoder.search(q, near)
        except GeocodeBusyError as exc:
            raise HTTPException(
                status_code=503, detail="búsqueda ocupada", headers={"Retry-After": "5"}
            ) from exc
        except GeocodeError as exc:
            raise HTTPException(status_code=503, detail="búsqueda no disponible") from exc
        return Places(items=items)

    return router
