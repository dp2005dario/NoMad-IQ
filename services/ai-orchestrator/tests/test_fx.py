"""Pruebas de los tipos de cambio (sin el BCE de verdad)."""

from __future__ import annotations

from datetime import date

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.fx.ecb import EcbError, parse_ecb
from ai_orchestrator.fx.service import FxRates, FxService, FxUnavailableError

# Un trozo del archivo real del BCE (con sus comillas simples).
ECB_XML = """<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<Cube><Cube time='2026-10-23'>
<Cube currency='USD' rate='1.0812'/><Cube currency='JPY' rate='163.21'/><Cube currency='BGN' rate='1.9558'/>
<Cube currency='CZK' rate='25.301'/><Cube currency='DKK' rate='7.4593'/><Cube currency='GBP' rate='0.8512'/>
<Cube currency='HUF' rate='395.10'/><Cube currency='PLN' rate='4.3060'/><Cube currency='SEK' rate='11.452'/>
<Cube currency='CHF' rate='0.9421'/><Cube currency='MXN' rate='19.874'/><Cube currency='xx' rate='9'/>
</Cube></Cube></gesmes:Envelope>"""


def test_parse_ecb() -> None:
    day, rates = parse_ecb(ECB_XML)
    assert day == date(2026, 10, 23)
    assert rates["EUR"] == 1.0 and rates["JPY"] == 163.21 and rates["MXN"] == 19.874
    assert "xx" not in rates
    with pytest.raises(EcbError):
        parse_ecb("<html>mantenimiento</html>")


class FakeSource:
    def __init__(self) -> None:
        self.calls = 0
        self.fail = False

    async def latest(self) -> tuple[date, dict[str, float]]:
        self.calls += 1
        if self.fail:
            raise EcbError("caído")
        return parse_ecb(ECB_XML)


class MemoryCache:
    def __init__(self) -> None:
        self.saved: FxRates | None = None

    async def get(self) -> FxRates | None:
        return self.saved

    async def put(self, rates: FxRates, *, ttl_seconds: int) -> None:
        self.saved = rates


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


async def test_cache_layers_and_stale_fallback() -> None:
    src, cache, clock = FakeSource(), MemoryCache(), Clock()
    svc = FxService(source=src, cache=cache, clock=clock)
    first = await svc.rates()
    assert first.rates["USD"] == 1.0812 and cache.saved == first
    await svc.rates()
    assert src.calls == 1  # de memoria
    # Pasa el tiempo, Redis se vacía y el BCE se cae: se usa la última buena.
    clock.now = 10_000
    cache.saved = None
    src.fail = True
    assert (await svc.rates()).date == date(2026, 10, 23)
    # Sin ninguna copia y sin BCE: no disponible.
    with pytest.raises(FxUnavailableError):
        await FxService(source=src, cache=MemoryCache()).rates()


async def test_api_is_public() -> None:
    svc = FxService(source=FakeSource(), cache=MemoryCache())
    transport = httpx.ASGITransport(app=create_api(InMemoryStore(), fx=svc))
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
        ok = await c.get("/v1/fx/rates")
        assert ok.status_code == 200
        assert ok.json()["rates"]["GBP"] == 0.8512
        assert ok.headers["cache-control"] == "public, max-age=3600"
        broken = FakeSource()
        broken.fail = True
        down = create_api(InMemoryStore(), fx=FxService(source=broken, cache=MemoryCache()))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=down), base_url="http://t") as c:
        assert (await c.get("/v1/fx/rates")).status_code == 503
