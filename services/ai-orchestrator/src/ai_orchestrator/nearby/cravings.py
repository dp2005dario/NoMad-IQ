"""«¿Qué os apetece?» (pantalla Grupo): sitios cerca para un antojo.

El grupo elige un antojo (tapas, pescado, vegetariano, café o vistas) y la
app enseña los sitios de OpenStreetMap que hay a un paseo. Igual que "Cerca
de ti" (service.py): la app manda la casilla de ~1 km donde está (nunca el
punto exacto), y cada casilla y antojo se pregunta a Overpass como mucho una
vez por semana (Redis).

Lo que NO hay (y la app lo dice): reseñas, "lo más popular" ni precios.
Esos datos son de pago; aquí solo nombre, sitio y horario de OSM.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Literal, Protocol, get_args

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from redis.asyncio import Redis

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError, as_urls, post_query
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.nearby.domain import ATTRIBUTION, CELL_DEGREES, LICENSE_URL, cell_of
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.stale_cache import DEFAULT_STALE_SECONDS, read, write

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:cravings:v1"
# Como mucho estos sitios por antojo y casilla (de sobra para elegir).
MAX_RESULTS = 60

# Los antojos de la maqueta: Tapas, Pescado, Vegetariano, Café y Con vistas.
Craving = Literal["tapas", "fish", "veggie", "cafe", "views"]
CRAVINGS: tuple[str, ...] = get_args(Craving)


class CravingSpot(BaseModel):
    model_config = ConfigDict(frozen=True)

    # "n123" (un punto de OSM), "w456" (un edificio) o "r789".
    id: str
    lat: float
    lon: float
    name: str
    # El horario tal cual lo escribe OSM ("Mo-Su 08:00-22:00").
    opening_hours: str | None = None
    # El tipo de cocina de OSM ("tapas;spanish"), si lo pone.
    cuisine: str | None = None


class Cravings(BaseModel):
    model_config = ConfigDict(frozen=True)

    kind: Craving
    # El centro de la casilla consultada (no el punto exacto de nadie).
    lat: float
    lon: float
    spots: list[CravingSpot] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL


def build_query(kind: str, south: float, west: float, north: float, east: float) -> str:
    """La consulta para UN antojo. Los números con formato fijo y el antojo
    sale de una lista cerrada: nunca entra texto raro."""
    box = f"{south:.5f},{west:.5f},{north:.5f},{east:.5f}"
    food = '["amenity"~"^(restaurant|bar|pub|cafe|fast_food)$"]["name"]'
    lines = {
        "tapas": [f'nwr{food}["cuisine"~"tapas",i]({box});'],
        "fish": [f'nwr{food}["cuisine"~"seafood|fish",i]({box});'],
        "veggie": [
            f'nwr{food}["diet:vegetarian"~"^(yes|only)$"]({box});',
            f'nwr{food}["diet:vegan"~"^(yes|only)$"]({box});',
            f'nwr{food}["cuisine"~"vegetarian|vegan",i]({box});',
        ],
        "cafe": [f'nwr["amenity"="cafe"]["name"]({box});'],
        "views": [f'nwr["tourism"="viewpoint"]["name"]({box});'],
    }[kind]
    return "[out:json][timeout:25];(" + "".join(lines) + f");out center {MAX_RESULTS};"


def _text(tags: dict[str, Any], key: str, limit: int = 80) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def parse_spot(row: Any) -> CravingSpot | None:
    """Un sitio de la respuesta, o None si le falta algo (nombre o sitio)."""
    if not isinstance(row, dict):
        return None
    kind_raw, oid = row.get("type"), row.get("id")
    if kind_raw not in ("node", "way", "relation") or not isinstance(oid, int) or oid <= 0:
        return None
    where = row if kind_raw == "node" else row.get("center")
    if not isinstance(where, dict):
        return None
    lat, lon = where.get("lat"), where.get("lon")
    if not (
        isinstance(lat, int | float)
        and isinstance(lon, int | float)
        and -90 <= lat <= 90
        and -180 <= lon <= 180
    ):
        return None
    raw_tags = row.get("tags")
    tags: dict[str, Any] = raw_tags if isinstance(raw_tags, dict) else {}
    name = _text(tags, "name")
    if name is None:
        return None
    return CravingSpot(
        id=f"{kind_raw[0]}{oid}",
        lat=float(lat),
        lon=float(lon),
        name=name,
        opening_hours=_text(tags, "opening_hours"),
        cuisine=_text(tags, "cuisine", 40),
    )


class CravingSource(Protocol):
    async def spots_in(
        self, kind: str, south: float, west: float, north: float, east: float
    ) -> list[CravingSpot]: ...


class CravingCache(Protocol):
    async def get(self, kind: str, lat: float, lon: float) -> Cravings | None:
        """Solo si es fresco."""
        ...

    async def get_stale(self, kind: str, lat: float, lon: float) -> Cravings | None:
        """Aunque esté pasado de fecha (para cuando Overpass falla)."""
        ...

    async def put(self, found: Cravings, *, ttl_seconds: int) -> None: ...


class CravingsOverpass:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str | Sequence[str],
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._urls = as_urls(url)
        self._max_wait = max_wait_seconds

    async def spots_in(
        self, kind: str, south: float, west: float, north: float, east: float
    ) -> list[CravingSpot]:
        await self._limiter.acquire(self._max_wait)
        resp = await post_query(self._http, self._urls, build_query(kind, south, west, north, east))
        if resp.status_code in (429, 503, 504):
            raise OverpassBusyError(f"Overpass respondió {resp.status_code}")
        if resp.status_code != 200:
            raise OverpassError(f"Overpass respondió {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise OverpassError("respuesta de Overpass que no es JSON") from exc
        rows = data.get("elements") if isinstance(data, dict) else None
        if not isinstance(rows, list):
            raise OverpassError("respuesta de Overpass sin lista de elementos")
        seen: set[str] = set()
        out: list[CravingSpot] = []
        for spot in (parse_spot(r) for r in rows):
            if spot is not None and spot.id not in seen:
                seen.add(spot.id)
                out.append(spot)
        return out[:MAX_RESULTS]


class RedisCravingCache:
    def __init__(self, redis: Redis, *, stale_seconds: int = DEFAULT_STALE_SECONDS) -> None:
        self._redis = redis
        self._stale = stale_seconds

    @staticmethod
    def _key(kind: str, lat: float, lon: float) -> str:
        return f"{KEY_PREFIX}:{kind}:{lat:.2f}:{lon:.2f}"

    async def _read(self, kind: str, lat: float, lon: float, *, fresh_only: bool) -> Cravings | None:
        raw = await read(self._redis, self._key(kind, lat, lon), fresh_only=fresh_only, what="'antojos'")
        if raw is None:
            return None
        try:
            return Cravings.model_validate_json(raw)
        except ValidationError:
            return None

    async def get(self, kind: str, lat: float, lon: float) -> Cravings | None:
        return await self._read(kind, lat, lon, fresh_only=True)

    async def get_stale(self, kind: str, lat: float, lon: float) -> Cravings | None:
        return await self._read(kind, lat, lon, fresh_only=False)

    async def put(self, found: Cravings, *, ttl_seconds: int) -> None:
        await write(
            self._redis,
            self._key(found.kind, found.lat, found.lon),
            found.model_dump_json(),
            ttl_seconds=ttl_seconds,
            stale_seconds=self._stale,
            what="'antojos'",
        )


class CravingsBusyError(Exception):
    """Demasiadas casillas nuevas a la vez: la app lo reintentará."""


class CravingsUnavailableError(Exception):
    """Overpass no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class CravingSettings:
    ttl_seconds: int = 7 * 24 * 3600
    # 1 = la casilla y sus 8 vecinas (~3 km de lado). La app se queda con lo
    # que está a un paseo (1 km) y lo ordena por cercanía y gustos.
    ring: int = 1


class CravingService:
    def __init__(
        self, *, source: CravingSource, cache: CravingCache, settings: CravingSettings | None = None
    ) -> None:
        self._source = source
        self._cache = cache
        self._settings = settings or CravingSettings()
        self._flight: SingleFlight[Cravings] = SingleFlight()

    async def near(self, lat: float, lon: float, kind: str) -> Cravings:
        if kind not in CRAVINGS:
            raise ValueError(f"antojo desconocido: {kind}")
        c_lat, c_lon = cell_of(lat, lon)
        cached = await self._cache.get(kind, c_lat, c_lon)
        if cached is not None:
            return cached
        try:
            result, _ = await self._flight.do(
                f"{kind}:{c_lat:.2f}:{c_lon:.2f}", lambda: self._build(kind, c_lat, c_lon)
            )
        except OverpassBusyError as exc:
            stale = await self._stale(kind, c_lat, c_lon)
            if stale is not None:
                return stale
            raise CravingsBusyError(str(exc)) from exc
        except OverpassError as exc:
            # Sin coordenadas en el registro: dirían dónde está alguien.
            log.warning("Overpass no disponible", extra={"error": str(exc)})
            stale = await self._stale(kind, c_lat, c_lon)
            if stale is not None:
                return stale
            raise CravingsUnavailableError(str(exc)) from exc
        return result

    async def _stale(self, kind: str, lat: float, lon: float) -> Cravings | None:
        try:
            return await self._cache.get_stale(kind, lat, lon)
        except CacheError:
            return None  # si Redis también falla, se da el error original

    async def _build(self, kind: str, lat: float, lon: float) -> Cravings:
        half = CELL_DEGREES * (self._settings.ring + 0.5)
        found = await self._source.spots_in(kind, lat - half, lon - half, lat + half, lon + half)
        result = Cravings.model_validate({"kind": kind, "lat": lat, "lon": lon, "spots": found})
        await self._cache.put(result, ttl_seconds=self._settings.ttl_seconds)
        return result
