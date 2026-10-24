"""Cliente de NASA POWER (medias climáticas), con límite de ritmo."""

from __future__ import annotations

import calendar
import math
from typing import Any

import httpx

from ai_orchestrator.climate.domain import MonthClimate
from ai_orchestrator.places.wikimedia import RateLimiter

DEFAULT_URL = "https://power.larc.nasa.gov/api/temporal/climatology/point"
USER_AGENT = "NomadIQ/1.0 (https://github.com/dp2005dario/NoMad-IQ)"
MONTHS = ("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")
# T2M = temperatura a 2 m, T2M_MAX = máximas, PRECTOTCORR = lluvia (mm/día).
PARAMETERS = "T2M,T2M_MAX,PRECTOTCORR"


class NasaBusyError(Exception):
    """Hemos llegado a nuestro límite o la NASA pide que esperemos."""


class NasaError(Exception):
    """La NASA no responde o responde algo raro."""


def _number(table: Any, key: str, lo: float, hi: float) -> float | None:
    """Un número razonable de la tabla, o None (la NASA usa -999 = sin dato)."""
    if not isinstance(table, dict):
        return None
    value = table.get(key)
    if not isinstance(value, int | float) or isinstance(value, bool) or math.isnan(value):
        return None
    return float(value) if lo <= value <= hi else None


def parse_months(data: Any) -> list[MonthClimate]:
    """Los 12 meses de la respuesta (los que tengan todos sus datos)."""
    props = data.get("properties") if isinstance(data, dict) else None
    params = props.get("parameter") if isinstance(props, dict) else None
    if not isinstance(params, dict):
        raise NasaError("respuesta de la NASA sin parámetros")
    out: list[MonthClimate] = []
    for i, name in enumerate(MONTHS, start=1):
        temp = _number(params.get("T2M"), name, -90, 60)
        top = _number(params.get("T2M_MAX"), name, -90, 70)
        rain = _number(params.get("PRECTOTCORR"), name, 0, 200)
        if temp is None or top is None or rain is None:
            continue
        # mm al día por los días del mes (un año no bisiesto basta para una media).
        days = calendar.monthrange(2025, i)[1]
        out.append(
            MonthClimate(month=i, temp_c=round(temp, 1), temp_max_c=round(top, 1), rain_mm=round(rain * days))
        )
    return out


class NasaClient:
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

    async def climate_at(self, lat: float, lon: float) -> list[MonthClimate]:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.get(
                self._url,
                params={
                    "parameters": PARAMETERS,
                    "community": "RE",
                    # Formato fijo: nunca se cuela texto raro en la URL.
                    "latitude": f"{lat:.2f}",
                    "longitude": f"{lon:.2f}",
                    "format": "JSON",
                },
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            )
        except httpx.HTTPError as exc:
            # Solo el tipo: el mensaje llevaría la URL (con la zona).
            raise NasaError(f"{type(exc).__name__} al llamar a la NASA") from exc
        if resp.status_code in (429, 503, 504):
            raise NasaBusyError(f"la NASA respondió {resp.status_code}")
        if resp.status_code != 200:
            raise NasaError(f"la NASA respondió {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise NasaError("respuesta de la NASA que no es JSON") from exc
        return parse_months(data)
