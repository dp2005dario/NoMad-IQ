"""La pregunta a Overpass para "Cerca de ti" (agua, baños, wifi, enchufes y
sitios que ver) y cómo se lee la respuesta."""

from __future__ import annotations

import re
from typing import Any

import httpx

from ai_orchestrator.atms.overpass import USER_AGENT, OverpassBusyError, OverpassError
from ai_orchestrator.nearby.domain import NearbySpot, SpotKind
from ai_orchestrator.places.wikimedia import RateLimiter

# Como mucho estos sitios por consulta (un centro histórico tiene cientos de
# fuentes y bancos: con esto la respuesta nunca pesa demasiado).
MAX_RESULTS = 400
_QID = re.compile(r"^Q[1-9][0-9]{0,11}$")


def build_query(south: float, west: float, north: float, east: float) -> str:
    """La consulta. Los números con formato fijo: nunca entra texto raro."""
    box = f"{south:.5f},{west:.5f},{north:.5f},{east:.5f}"
    return (
        "[out:json][timeout:25];("
        f'nwr["amenity"="drinking_water"]({box});'
        f'nwr["amenity"="toilets"]["access"!~"private|customers|no"]({box});'
        f'nwr["internet_access"="wlan"]["internet_access:fee"="no"]({box});'
        f'nwr["amenity"="device_charging_station"]({box});'
        # Sitios que ver: solo los que tienen Wikidata (los conocidos).
        f'nwr["tourism"~"^(attraction|viewpoint|museum|gallery|artwork)$"]["wikidata"]({box});'
        f'nwr["historic"~"^(monument|castle|memorial|ruins|archaeological_site)$"]["wikidata"]({box});'
        f");out center {MAX_RESULTS};"
    )


def _text(tags: dict[str, Any], key: str, limit: int = 80) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def _kind(tags: dict[str, Any]) -> SpotKind | None:
    amenity = tags.get("amenity")
    if amenity == "drinking_water":
        return "water"
    if amenity == "toilets":
        return "toilets"
    if amenity == "device_charging_station":
        return "charging"
    if tags.get("internet_access") == "wlan" and tags.get("internet_access:fee") == "no":
        return "wifi"
    if tags.get("tourism") or tags.get("historic"):
        return "sight"
    return None


def parse_spot(row: Any) -> NearbySpot | None:
    """Un sitio de la respuesta, o None si le falta algo."""
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
    kind = _kind(tags)
    if kind is None:
        return None
    qid = tags.get("wikidata")
    name = _text(tags, "name")
    if kind == "sight" and (name is None or not isinstance(qid, str) or not _QID.match(qid)):
        return None  # un "sitio que ver" sin nombre ni Wikidata no sirve
    fee = tags.get("fee")
    return NearbySpot(
        id=f"{kind_raw[0]}{oid}",
        kind=kind,
        lat=float(lat),
        lon=float(lon),
        name=name,
        opening_hours=_text(tags, "opening_hours"),
        fee=True if fee == "yes" else False if fee == "no" else None,
        wikidata_id=qid if kind == "sight" else None,
    )


class NearbyOverpass:
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

    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[NearbySpot]:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.post(
                self._url,
                data={"data": build_query(south, west, north, east)},
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
        except httpx.HTTPError as exc:
            # Solo el tipo de error: el mensaje podría llevar la zona.
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
        out: list[NearbySpot] = []
        for spot in (parse_spot(r) for r in rows):
            if spot is not None and spot.id not in seen:
                seen.add(spot.id)
                out.append(spot)
        return out[:MAX_RESULTS]
