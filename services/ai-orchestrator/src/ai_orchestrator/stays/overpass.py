"""La pregunta a Overpass de "Dormir barato" y cómo se lee la respuesta."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import httpx

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError, as_urls, post_query
from ai_orchestrator.places.wikimedia import RateLimiter
from ai_orchestrator.stays.domain import MAX_KM, STATION_RADIUS_M, WALK_KM, Lodging, Station

# Topes: cerca de París hay miles de alojamientos. Con esto la respuesta
# sigue siendo pequeña y Overpass no se cansa.
MAX_NEAR = 400
MAX_STATIONS = 250
MAX_LODGINGS = 2500
_LODGING = "^(hotel|hostel|guest_house|motel|apartment)$"


def build_query(lat: float, lon: float) -> str:
    """La consulta. Los números con formato fijo: nunca entra texto raro."""
    at = f"{lat:.5f},{lon:.5f}"
    return (
        "[out:json][timeout:25];"
        f'nwr["tourism"~"{_LODGING}"](around:{int(WALK_KM * 1000)},{at});out center {MAX_NEAR};'
        # Estaciones de tren, cercanías y metro (no funiculares ni museos).
        f'node["railway"~"^(station|halt)$"]["name"]["station"!~"funicular|miniature"]'
        f"(around:{int(MAX_KM * 1000)},{at})->.st;"
        f".st out {MAX_STATIONS};"
        f'nwr["tourism"~"{_LODGING}"](around.st:{STATION_RADIUS_M});out center {MAX_LODGINGS};'
    )


def _point(row: dict[str, Any]) -> tuple[float, float] | None:
    where = row if row.get("type") == "node" else row.get("center")
    if not isinstance(where, dict):
        return None
    lat, lon = where.get("lat"), where.get("lon")
    if (
        isinstance(lat, int | float)
        and isinstance(lon, int | float)
        and -90 <= lat <= 90
        and -180 <= lon <= 180
    ):
        return float(lat), float(lon)
    return None


def _name(tags: dict[str, Any]) -> str | None:
    value = tags.get("name")
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:80] or None


def parse(rows: list[Any]) -> tuple[list[Station], list[Lodging]]:
    stations: list[Station] = []
    lodgings: dict[str, Lodging] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        kind_raw, oid = row.get("type"), row.get("id")
        if kind_raw not in ("node", "way", "relation") or not isinstance(oid, int) or oid <= 0:
            continue
        at = _point(row)
        raw_tags = row.get("tags")
        tags: dict[str, Any] = raw_tags if isinstance(raw_tags, dict) else {}
        if at is None:
            continue
        rid = f"{kind_raw[0]}{oid}"
        tourism = tags.get("tourism")
        if isinstance(tourism, str) and tourism in ("hotel", "hostel", "guest_house", "motel", "apartment"):
            if rid in lodgings:
                continue  # repetido (sale una vez por cada estación cercana)
            stars_raw = tags.get("stars")
            stars = (
                int(stars_raw[0])
                if isinstance(stars_raw, str) and stars_raw[:1] in "12345" and stars_raw
                else None
            )
            lodgings[rid] = Lodging(id=rid, lat=at[0], lon=at[1], name=_name(tags), kind=tourism, stars=stars)
        elif tags.get("railway") in ("station", "halt"):
            name = _name(tags)
            if name is not None:
                stations.append(Station(id=rid, lat=at[0], lon=at[1], name=name))
    return stations, list(lodgings.values())


class StayOverpass:
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

    async def around(self, lat: float, lon: float) -> tuple[list[Station], list[Lodging]]:
        await self._limiter.acquire(self._max_wait)
        resp = await post_query(self._http, self._urls, build_query(lat, lon))
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
        return parse(rows)
