"""'Borrar mis datos': la ruta de la API y las piezas sin base de datos."""

from __future__ import annotations

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.erasure import ErasureReport, _count, anonymous_id
from ai_orchestrator.identity import USER_ID_RE


class FakeEraser:
    def __init__(self) -> None:
        self.erased: list[str] = []

    async def erase(self, user_id: str) -> ErasureReport:
        self.erased.append(user_id)
        return ErasureReport(0, 0, 0, 0)


def client(eraser: FakeEraser) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), eraser=eraser)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_borra_los_datos_de_quien_llama() -> None:
    eraser = FakeEraser()
    async with client(eraser) as http:
        r = await http.delete("/v1/me/data", headers={"X-User-ID": "u-1", "X-User-Roles": "USER"})
        assert r.status_code == 204
        # Repetirlo no falla (la app reintenta si se cortó la conexión).
        r = await http.delete("/v1/me/data", headers={"X-User-ID": "u-1", "X-User-Roles": "USER"})
        assert r.status_code == 204
    assert eraser.erased == ["u-1", "u-1"]


async def test_sin_identidad_no_borra_nada() -> None:
    eraser = FakeEraser()
    async with client(eraser) as http:
        assert (await http.delete("/v1/me/data")).status_code == 401
    assert eraser.erased == []


async def test_sin_borrador_la_ruta_no_existe() -> None:
    app = create_api(InMemoryStore())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as http:
        r = await http.delete("/v1/me/data", headers={"X-User-ID": "u-1", "X-User-Roles": "USER"})
        assert r.status_code in (404, 405)


def test_id_anonimo_es_valido_y_distinto_cada_vez() -> None:
    a, b = anonymous_id(), anonymous_id()
    assert a != b
    assert a.startswith("erased:") and len(a) <= 128
    assert USER_ID_RE.fullmatch(a)


def test_cuenta_filas_del_estado_de_asyncpg() -> None:
    assert _count("DELETE 3") == 3
    assert _count("UPDATE 0") == 0
    assert _count("raro") == 0
