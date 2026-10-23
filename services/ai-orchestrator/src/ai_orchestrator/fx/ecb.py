"""Lee el archivo diario del Banco Central Europeo.

Es un XML pequeño (~2 KB) así:

    <Cube time='2026-10-23'>
        <Cube currency='USD' rate='1.0812'/>
        <Cube currency='JPY' rate='163.21'/>
        ...

No usamos un lector de XML completo: solo buscamos esos dos atributos con
una expresión regular muy estricta. Así un archivo raro (o malicioso) nunca
puede hacer cosas raras con el lector, y lo que no encaja simplemente se ignora.
"""

from __future__ import annotations

import re
from datetime import date

import httpx

ECB_URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
# El archivo real pesa ~2 KB: si llega algo de más de 64 KB, no es él.
MAX_BYTES = 64 * 1024

_DAY = re.compile(r"time=['\"](\d{4}-\d{2}-\d{2})['\"]")
_RATE = re.compile(r"currency=['\"]([A-Z]{3})['\"]\s+rate=['\"](\d{1,7}(?:\.\d{1,8})?)['\"]")


class EcbError(Exception):
    """El BCE no responde o responde algo que no es su archivo."""


def parse_ecb(text: str) -> tuple[date, dict[str, float]]:
    """(día, {moneda: unidades por 1 euro}). Lanza EcbError si no tiene sentido."""
    day = _DAY.search(text)
    rates = {code: float(value) for code, value in _RATE.findall(text)}
    if day is None or len(rates) < 10:
        raise EcbError("el archivo del BCE no tiene la forma esperada")
    try:
        when = date.fromisoformat(day.group(1))
    except ValueError as exc:
        raise EcbError("fecha del BCE no válida") from exc
    rates = {c: r for c, r in rates.items() if 0 < r < 10_000_000}
    rates["EUR"] = 1.0
    return when, rates


class EcbClient:
    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def latest(self) -> tuple[date, dict[str, float]]:
        try:
            resp = await self._http.get(ECB_URL)
        except httpx.HTTPError as exc:
            raise EcbError(f"BCE sin respuesta: {type(exc).__name__}") from exc
        if resp.status_code != 200:
            raise EcbError(f"BCE respondió {resp.status_code}")
        if len(resp.content) > MAX_BYTES:
            raise EcbError("respuesta del BCE demasiado grande")
        return parse_ecb(resp.text)
