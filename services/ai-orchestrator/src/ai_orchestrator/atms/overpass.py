"""Cliente de Overpass (el buscador de OpenStreetMap), con límite de ritmo.

Overpass es gratis y sin clave, pero pide "uso justo": pocas peticiones por
segundo y una cabecera User-Agent que diga quién eres. Por eso cada casilla
se pregunta una vez al día como mucho (ver service.py).
"""

from __future__ import annotations

import re
from typing import Any

import httpx

from ai_orchestrator.atms.domain import Atm
from ai_orchestrator.places.wikimedia import RateLimiter

DEFAULT_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)"
# Como mucho estos cajeros por casilla (una ciudad densa tiene decenas).
MAX_RESULTS = 80

_CURRENCY = re.compile(r"^currency:([A-Z]{3})$")


class OverpassBusyError(Exception):
    """Hemos llegado a nuestro límite o Overpass pide que esperemos."""


class OverpassError(Exception):
    """Overpass no responde o responde algo raro."""


def build_query(south: float, west: float, north: float, east: float) -> str:
    """La pregunta a Overpass: cajeros sueltos y bancos con cajero.

    Los números se escriben con formato fijo (``:.5f``): así nunca puede
    colarse texto raro en la consulta.
    """
    box = f"{south:.5f},{west:.5f},{north:.5f},{east:.5f}"
    return (
        "[out:json][timeout:20];"
        f'(nwr["amenity"="atm"]({box});'
        f'nwr["amenity"="bank"]["atm"="yes"]({box}););'
        f"out center {MAX_RESULTS};"
    )


def _text(tags: dict[str, Any], key: str, limit: int = 80) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def parse_atm(row: Any) -> Atm | None:
    """Un cajero de la respuesta, o None si le falta algo."""
    if not isinstance(row, dict):
        return None
    kind = row.get("type")
    oid = row.get("id")
    if kind not in ("node", "way", "relation") or not isinstance(oid, int) or oid <= 0:
        return None
    # Los puntos traen lat/lon; los edificios, un "center".
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
    hours = _text(tags, "opening_hours")
    fee = tags.get("fee")
    currencies = sorted(
        m.group(1)
        for k, v in tags.items()
        if isinstance(k, str) and v == "yes" and (m := _CURRENCY.match(k)) is not None
    )
    return Atm(
        id=f"{kind[0]}{oid}",
        lat=float(lat),
        lon=float(lon),
        name=_text(tags, "name") or _text(tags, "brand"),
        operator=_text(tags, "operator") or _text(tags, "network"),
        opening_hours=hours,
        open_24h=hours == "24/7",
        fee=True if fee == "yes" else False if fee == "no" else None,
        in_bank=tags.get("amenity") == "bank",
        currencies=currencies[:10],
    )


class OverpassClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str = DEFAULT_URL,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._url = url
        self._max_wait = max_wait_seconds

    async def atms_in(self, south: float, west: float, north: float, east: float) -> list[Atm]:
        """Los cajeros dentro de un rectángulo de unos pocos kilómetros."""
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.post(
                self._url,
                data={"data": build_query(south, west, north, east)},
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
        except httpx.HTTPError as exc:
            # Solo el tipo de error: el mensaje podría llevar la consulta
            # (y la consulta lleva la zona).
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
        out: list[Atm] = []
        for atm in (parse_atm(r) for r in rows):
            if atm is not None and atm.id not in seen:
                seen.add(atm.id)
                out.append(atm)
        return out[:MAX_RESULTS]
