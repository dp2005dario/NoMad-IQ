"""La pregunta a Overpass: lo que hay DENTRO del recinto de un aeropuerto.

En OpenStreetMap cada aeropuerto es un área (``aeroway=aerodrome``) con su
código IATA. Se busca esa área y, dentro, puertas, baños, cafés, etc.
"""

from __future__ import annotations

from typing import Any

import httpx

from ai_orchestrator.airport_guide.domain import AEROWAY_KINDS, AMENITY_KINDS, AirportSpot, SpotKind
from ai_orchestrator.atms.overpass import USER_AGENT, OverpassBusyError, OverpassError
from ai_orchestrator.places.airports import IATA_PATTERN
from ai_orchestrator.places.wikimedia import RateLimiter

# Un aeropuerto grande (Barajas, Heathrow) tiene unos cientos de sitios.
MAX_SPOTS = 800


def build_query(iata: str) -> str:
    """La consulta. El código se comprueba antes (3 letras mayúsculas): así
    nunca puede colarse texto raro en la consulta."""
    if not IATA_PATTERN.match(iata):
        raise ValueError("código IATA no válido")
    amenities = "|".join(sorted(AMENITY_KINDS))
    aeroways = "|".join(sorted(AEROWAY_KINDS))
    return (
        "[out:json][timeout:25];"
        f'(way["aeroway"="aerodrome"]["iata"="{iata}"];'
        f'relation["aeroway"="aerodrome"]["iata"="{iata}"];)->.ap;'
        ".ap map_to_area->.a;"
        f'(nwr(area.a)["aeroway"~"^({aeroways})$"];'
        f'nwr(area.a)["amenity"~"^({amenities})$"];'
        'nwr(area.a)["tourism"="information"];);'
        f"out center {MAX_SPOTS};"
    )


def _text(tags: dict[str, Any], key: str, limit: int = 60) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def _kind(tags: dict[str, Any]) -> SpotKind | None:
    aeroway = tags.get("aeroway")
    if isinstance(aeroway, str) and aeroway in AEROWAY_KINDS:
        return AEROWAY_KINDS[aeroway]
    amenity = tags.get("amenity")
    if isinstance(amenity, str) and amenity in AMENITY_KINDS:
        return AMENITY_KINDS[amenity]
    if tags.get("tourism") == "information":
        return "info"
    return None


def parse_spot(row: Any) -> AirportSpot | None:
    """Un sitio de la respuesta, o None si le falta algo."""
    if not isinstance(row, dict):
        return None
    kind = row.get("type")
    oid = row.get("id")
    if kind not in ("node", "way", "relation") or not isinstance(oid, int) or oid <= 0:
        return None
    where = row if kind == "node" else row.get("center")
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
    spot_kind = _kind(tags)
    if spot_kind is None:
        return None
    ref = _text(tags, "ref", 12)
    if spot_kind == "gate" and ref is None:
        # Una puerta sin número no sirve para llevarte a ella.
        return None
    return AirportSpot(
        id=f"{kind[0]}{oid}",
        kind=spot_kind,
        lat=float(lat),
        lon=float(lon),
        ref=ref,
        name=_text(tags, "name") or _text(tags, "brand"),
        level=_text(tags, "level", 8),
    )


class AirportOverpass:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._url = url
        self._max_wait = max_wait_seconds

    async def spots(self, iata: str) -> list[AirportSpot]:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.post(
                self._url,
                data={"data": build_query(iata)},
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
        except httpx.HTTPError as exc:
            raise OverpassError(f"{type(exc).__name__} al llamar a Overpass") from exc
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
        out: list[AirportSpot] = []
        for spot in (parse_spot(r) for r in rows):
            if spot is not None and spot.id not in seen:
                seen.add(spot.id)
                out.append(spot)
        return out[:MAX_SPOTS]
