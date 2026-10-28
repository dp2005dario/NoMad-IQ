"""La pregunta a Overpass del modo coche y cómo se lee la respuesta."""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

import httpx

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError, as_urls, post_query
from ai_orchestrator.drive.domain import DriveKind, DriveSpot
from ai_orchestrator.places.wikimedia import RateLimiter

# Topes por tipo: un área metropolitana tiene miles de aparcamientos. Cada
# tipo tiene su propio "out", así uno no se come el sitio de los demás.
MAX_FUEL = 150
MAX_PARKING = 150
MAX_EV = 100
MAX_LEZ = 20
_WEB = re.compile(r"^https://[^\s\"'<>]{4,300}$")


def build_query(south: float, west: float, north: float, east: float) -> str:
    """La consulta. Los números con formato fijo: nunca entra texto raro."""
    box = f"{south:.5f},{west:.5f},{north:.5f},{east:.5f}"
    return (
        "[out:json][timeout:25];"
        f'nwr["amenity"="fuel"]({box});out center {MAX_FUEL};'
        # Aparcamientos públicos que se pueden encontrar: con nombre o de
        # disuasión (park & ride). Los "sin nombre" son miles de huecos de calle.
        f'(nwr["amenity"="parking"]["access"!~"private|customers|no|permit"]["name"]({box});'
        f'nwr["amenity"="parking"]["park_ride"="yes"]({box}););out center {MAX_PARKING};'
        f'nwr["amenity"="charging_station"]["access"!~"private|customers|no"]({box});out center {MAX_EV};'
        f'relation["boundary"="low_emission_zone"]({box});out center {MAX_LEZ};'
    )


def _text(tags: dict[str, Any], key: str, limit: int = 80) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def _kind(tags: dict[str, Any]) -> DriveKind | None:
    amenity = tags.get("amenity")
    if amenity == "fuel":
        return "fuel"
    if amenity == "parking":
        return "parking"
    if amenity == "charging_station":
        return "ev"
    if tags.get("boundary") == "low_emission_zone":
        return "lez"
    return None


def _capacity(tags: dict[str, Any]) -> int | None:
    raw = tags.get("capacity")
    if isinstance(raw, str) and raw.isdigit() and 0 < int(raw) <= 100_000:
        return int(raw)
    return None


def parse_spot(row: Any) -> DriveSpot | None:
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
    name = _text(tags, "name")
    if kind == "lez" and name is None:
        return None  # una zona sin nombre no se puede explicar
    fee = tags.get("fee")
    website = tags.get("website")
    return DriveSpot(
        id=f"{kind_raw[0]}{oid}",
        kind=kind,
        lat=float(lat),
        lon=float(lon),
        name=name,
        brand=_text(tags, "brand") or _text(tags, "operator") if kind in ("fuel", "ev") else None,
        opening_hours=_text(tags, "opening_hours"),
        fee=True if fee == "yes" else False if fee == "no" else None,
        capacity=_capacity(tags) if kind in ("parking", "ev") else None,
        # Solo enlaces https: nada de "javascript:" ni webs sin cifrar.
        website=website if kind == "lez" and isinstance(website, str) and _WEB.match(website) else None,
    )


class DriveOverpass:
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

    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[DriveSpot]:
        await self._limiter.acquire(self._max_wait)
        resp = await post_query(self._http, self._urls, build_query(south, west, north, east))
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
        out: list[DriveSpot] = []
        for spot in (parse_spot(r) for r in rows):
            if spot is not None and spot.id not in seen:
                seen.add(spot.id)
                out.append(spot)
        return out
