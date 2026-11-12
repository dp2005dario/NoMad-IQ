"""Datos de cada país para Explorar, del Banco Mundial (gratis, sin clave).

Qué se pide (el dato más reciente que tenga cada país):
    - ST.INT.ARVL       turistas que llegan al año.
    - PA.NUS.PPPC.RF    nivel de precios (EE. UU. = 1): 0,4 = todo cuesta
                        menos de la mitad; 1,2 = más caro que EE. UU.
    - VC.IHR.PSRC.P5    homicidios por cada 100 000 habitantes (para la
                        seguridad: es el dato comparable que hay de casi
                        todos los países).
    - SP.POP.TOTL       habitantes.
    - /v2/country       la capital.

Licencia: CC BY 4.0 (hay que citar "Banco Mundial"; la app lo hace).

Se piden 5 cosas UNA vez y se guardan 30 días en Redis: los datos cambian
una vez al año. Si el Banco Mundial falla, Explorar sigue con el clima.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

log = logging.getLogger(__name__)

WORLDBANK_URL = "https://api.worldbank.org"
FACTS_ATTRIBUTION = "Banco Mundial (CC BY 4.0)"
KEY = "ai:countryfacts:v1"
TTL_FULL = 30 * 24 * 3600
TTL_PARTIAL = 6 * 3600

INDICATORS: dict[str, str] = {
    "arrivals": "ST.INT.ARVL",
    "price": "PA.NUS.PPPC.RF",
    "homicides": "VC.IHR.PSRC.P5",
    "population": "SP.POP.TOTL",
}


class CountryFacts(BaseModel):
    model_config = ConfigDict(frozen=True)

    arrivals: int | None = None
    price: float | None = None
    homicides: float | None = None
    population: int | None = None
    capital: str | None = None


def _rows(data: Any) -> list[dict[str, Any]]:
    """El Banco Mundial contesta [página, [filas]]. Cualquier otra cosa: nada."""
    if isinstance(data, list) and len(data) == 2 and isinstance(data[1], list):
        return [r for r in data[1] if isinstance(r, dict)]
    return []


def _iso2(row: dict[str, Any]) -> str | None:
    country = row.get("country")
    code = country.get("id") if isinstance(country, dict) else None
    if isinstance(code, str) and len(code) == 2 and code.isalpha() and code.isupper():
        return code
    return None


def parse_indicator(data: Any) -> dict[str, float]:
    """{ISO2: valor} de una respuesta de indicador (sin regiones ni vacíos)."""
    out: dict[str, float] = {}
    for row in _rows(data):
        iso = _iso2(row)
        value = row.get("value")
        if iso is not None and isinstance(value, int | float) and not isinstance(value, bool) and value >= 0:
            out[iso] = float(value)
    return out


def parse_capitals(data: Any) -> dict[str, str]:
    """{ISO2: capital} de /v2/country (las regiones no tienen capital)."""
    out: dict[str, str] = {}
    for row in _rows(data):
        iso = row.get("iso2Code")
        city = row.get("capitalCity")
        if isinstance(iso, str) and len(iso) == 2 and isinstance(city, str) and 0 < len(city.strip()) <= 80:
            out[iso] = city.strip()
    return out


class WorldBankFacts:
    """Los datos de todos los países: Redis primero, el Banco Mundial si faltan."""

    def __init__(self, http: httpx.AsyncClient, redis: Redis | None, *, url: str = WORLDBANK_URL) -> None:
        self._http = http
        self._redis = redis
        self._url = url.rstrip("/")
        self._memory: dict[str, CountryFacts] = {}
        self._task: asyncio.Task[None] | None = None

    async def cached(self) -> dict[str, CountryFacts]:
        """Lo que haya ya guardado. Si no hay nada, se pide en segundo plano."""
        if self._memory:
            return self._memory
        found = await self._read()
        if found:
            self._memory = found
            return found
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self.refresh())
        return {}

    async def refresh(self) -> None:
        values: dict[str, dict[str, float]] = {}
        partial = False
        for name, code in INDICATORS.items():
            try:
                values[name] = parse_indicator(
                    await self._get(f"/v2/country/all/indicator/{code}", mrnev="1")
                )
            except (httpx.HTTPError, ValueError) as exc:
                log.warning("Banco Mundial sin %s", code, extra={"error": type(exc).__name__})
                values[name] = {}
                partial = True
        try:
            capitals = parse_capitals(await self._get("/v2/country"))
        except (httpx.HTTPError, ValueError):
            capitals = {}
            partial = True
        isos = set(capitals).union(*[set(v) for v in values.values()])
        facts: dict[str, CountryFacts] = {}
        for iso in isos:
            arrivals = values["arrivals"].get(iso)
            population = values["population"].get(iso)
            facts[iso] = CountryFacts(
                arrivals=round(arrivals) if arrivals is not None else None,
                price=round(values["price"][iso], 3) if iso in values["price"] else None,
                homicides=round(values["homicides"][iso], 2) if iso in values["homicides"] else None,
                population=round(population) if population is not None else None,
                capital=capitals.get(iso),
            )
        if not facts:
            return
        if not partial:
            # A medias no se queda en memoria: en unas horas se vuelve a pedir.
            self._memory = facts
        await self._write(facts, TTL_PARTIAL if partial else TTL_FULL)

    async def _get(self, path: str, **extra: str) -> Any:
        resp = await self._http.get(
            self._url + path,
            params={"format": "json", "per_page": "20000", **extra},
            headers={"Accept": "application/json"},
        )
        resp.raise_for_status()
        return resp.json()

    async def _read(self) -> dict[str, CountryFacts]:
        if self._redis is None:
            return {}
        try:
            raw = await self._redis.get(KEY)
        except (RedisError, OSError):
            return {}
        if not raw:
            return {}
        try:
            data = json.loads(raw)
            return {iso: CountryFacts.model_validate(v) for iso, v in data.items()}
        except (ValueError, AttributeError, ValidationError):
            return {}

    async def _write(self, facts: dict[str, CountryFacts], ttl: int) -> None:
        if self._redis is None:
            return
        body = json.dumps({iso: f.model_dump(exclude_none=True) for iso, f in facts.items()})
        try:
            await self._redis.set(KEY, body, ex=ttl)
        except (RedisError, OSError):
            log.warning("no se pudieron guardar los datos de países en Redis")
