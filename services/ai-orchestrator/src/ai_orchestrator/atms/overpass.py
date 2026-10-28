"""Cliente de Overpass (el buscador de OpenStreetMap), con límite de ritmo.

Overpass es gratis y sin clave, pero pide "uso justo": pocas peticiones por
segundo y una cabecera User-Agent que diga quién eres. Por eso cada casilla
se pregunta una vez al día como mucho (ver service.py).
"""

from __future__ import annotations

import asyncio
import re
from collections.abc import Sequence
from typing import Any

import httpx

from ai_orchestrator.atms.domain import Atm
from ai_orchestrator.places.wikimedia import RateLimiter

DEFAULT_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)"
# Como mucho estos cajeros por casilla (una ciudad densa tiene decenas).
MAX_RESULTS = 80

_CURRENCY = re.compile(r"^currency:([A-Z]{3})$")


# Respuestas "pasajeras": el servidor está saturado o caído un rato. Con estas
# probamos el siguiente espejo; con otras (400, 403...) el fallo es nuestro y
# otro servidor diría lo mismo.
RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})
# Pausa corta antes de repetir un servidor que falló rápido.
RETRY_PAUSE_SECONDS = 0.5


class OverpassBusyError(Exception):
    """Hemos llegado a nuestro límite o Overpass pide que esperemos."""


class OverpassError(Exception):
    """Overpass no responde o responde algo raro."""


def as_urls(url: str | Sequence[str]) -> tuple[str, ...]:
    """Acepta una dirección o una lista de espejos (en orden de preferencia)."""
    return (url,) if isinstance(url, str) else tuple(url)


async def post_query(
    http: httpx.AsyncClient,
    urls: Sequence[str],
    query: str,
    *,
    retry_pause: float = RETRY_PAUSE_SECONDS,
) -> httpx.Response:
    """Manda la consulta a los servidores Overpass, en orden, hasta que uno responda.

    Funciona en dos pasadas:

    1. Se prueba cada servidor una vez. Si uno falla de forma pasajera (error
       de red, 429, 5xx) se pasa al siguiente.
    2. Los que fallaron *rápido* se repiten una vez tras una pausa corta. Los
       que se agotaron por tiempo (timeout) NO se repiten: ya habrían gastado
       otros 25 s y la app está esperando.

    Si todos fallan devuelve la última respuesta HTTP (para que quien llama
    decida si era "ocupado" o "error"), o lanza ``OverpassError`` si lo
    último fue un fallo de red.
    """
    pending = list(urls)
    last_resp: httpx.Response | None = None
    last_error: str | None = None
    for round_number in range(2):
        retry: list[str] = []
        for url in pending:
            try:
                resp = await http.post(
                    url,
                    data={"data": query},
                    headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
                )
            except httpx.TimeoutException as exc:
                # Solo el tipo de error: el mensaje podría llevar la zona.
                last_resp, last_error = None, f"{type(exc).__name__} al llamar a Overpass"
                continue  # lento: no se repite
            except httpx.HTTPError as exc:
                last_resp, last_error = None, f"{type(exc).__name__} al llamar a Overpass"
                retry.append(url)
                continue
            if resp.status_code not in RETRYABLE_STATUS:
                return resp  # éxito (o un error nuestro que no se arregla cambiando de servidor)
            last_resp, last_error = resp, None
            retry.append(url)
        if round_number == 0 and retry:
            await asyncio.sleep(retry_pause)
        pending = retry
        if not pending:
            break
    if last_resp is not None:
        return last_resp
    raise OverpassError(last_error or "ningún servidor Overpass configurado")


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
        url: str | Sequence[str] = DEFAULT_URL,
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._urls = as_urls(url)
        self._max_wait = max_wait_seconds

    async def atms_in(self, south: float, west: float, north: float, east: float) -> list[Atm]:
        """Los cajeros dentro de un rectángulo de unos pocos kilómetros."""
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
        out: list[Atm] = []
        for atm in (parse_atm(r) for r in rows):
            if atm is not None and atm.id not in seen:
                seen.add(atm.id)
                out.append(atm)
        return out[:MAX_RESULTS]
