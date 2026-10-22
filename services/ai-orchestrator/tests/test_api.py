"""Tests de la API: identidad desde el gateway, RBAC y aislamiento por usuario."""

from __future__ import annotations

import httpx
import pytest
from conftest import ALERT_ID, USER_ID, InMemoryStore, make_recommendation, new_uuid

from ai_orchestrator.api import create_api, create_management_api
from ai_orchestrator.store import StoreError

USER = {"X-User-ID": USER_ID, "X-User-Roles": "USER"}


@pytest.fixture
def store() -> InMemoryStore:
    s = InMemoryStore()
    s.items[ALERT_ID] = make_recommendation()
    other = new_uuid()
    s.items[other] = make_recommendation(alert_id=other, user_id="otra-persona")
    return s


def api(store: InMemoryStore, **kw: bool) -> httpx.AsyncClient:
    # ASGITransport: llama a la app directamente, sin abrir puertos.
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=create_api(store, **kw)), base_url="http://t")


async def test_lists_only_my_recommendations(store: InMemoryStore) -> None:
    async with api(store) as c:
        resp = await c.get("/v1/recommendations", headers=USER)
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert [i["alert_id"] for i in items] == [ALERT_ID]
    assert "user_id" not in items[0]  # no exponemos datos internos


async def test_get_one(store: InMemoryStore) -> None:
    async with api(store) as c:
        resp = await c.get(f"/v1/recommendations/{ALERT_ID}", headers=USER)
    assert resp.status_code == 200
    assert resp.json()["verdict"] == "BUY_NOW"


async def test_someone_elses_recommendation_is_404(store: InMemoryStore) -> None:
    foreign = next(k for k, v in store.items.items() if v.user_id == "otra-persona")
    async with api(store) as c:
        resp = await c.get(f"/v1/recommendations/{foreign}", headers=USER)
    assert resp.status_code == 404
    assert resp.headers["content-type"] == "application/problem+json"


@pytest.mark.parametrize(
    ("headers", "status"),
    [
        ({}, 401),
        ({"X-User-ID": ""}, 401),
        ({"X-User-ID": "x" * 200, "X-User-Roles": "USER"}, 401),
        ({"X-User-ID": "a b<script>", "X-User-Roles": "USER"}, 401),
        ({"X-User-ID": USER_ID, "X-User-Roles": "user;drop"}, 401),
        ({"X-User-ID": USER_ID}, 403),
        ({"X-User-ID": USER_ID, "X-User-Roles": "GUEST"}, 403),
        ({"X-User-ID": USER_ID, "X-User-Roles": "ADMIN,USER"}, 200),
    ],
)
async def test_identity_headers_are_validated(
    store: InMemoryStore, headers: dict[str, str], status: int
) -> None:
    async with api(store) as c:
        resp = await c.get("/v1/recommendations", headers=headers)
    assert resp.status_code == status


async def test_bad_parameters_are_400(store: InMemoryStore) -> None:
    async with api(store) as c:
        assert (await c.get("/v1/recommendations/no-uuid", headers=USER)).status_code == 400
        assert (await c.get("/v1/recommendations?limit=1000", headers=USER)).status_code == 400


async def test_unknown_route_uses_problem_json(store: InMemoryStore) -> None:
    async with api(store) as c:
        resp = await c.get("/nada", headers=USER)
    assert resp.status_code == 404
    assert resp.json()["title"] == "No encontrado"


async def test_database_down_is_503(store: InMemoryStore) -> None:
    async def broken(user_id: str, *, limit: int) -> list[object]:
        raise StoreError("conexión rechazada en 10.0.0.5")

    store.list_for_user = broken  # type: ignore[method-assign,assignment]
    async with api(store) as c:
        resp = await c.get("/v1/recommendations", headers=USER)
    assert resp.status_code == 503
    assert "10.0.0.5" not in resp.text  # no se filtran detalles internos


async def test_docs_hidden_by_default(store: InMemoryStore) -> None:
    async with api(store) as c:
        assert (await c.get("/docs")).status_code == 404
        assert (await c.get("/openapi.json")).status_code == 404
    async with api(store, expose_docs=True) as c:
        assert (await c.get("/openapi.json")).status_code == 200


async def test_management_endpoints() -> None:
    state = {"database": True, "kafka_consumer": True}

    async def readiness() -> dict[str, bool]:
        return dict(state)

    transport = httpx.ASGITransport(app=create_management_api(readiness))
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
        assert (await c.get("/healthz")).status_code == 200
        assert (await c.get("/readyz")).status_code == 200
        state["database"] = False
        resp = await c.get("/readyz")
        assert resp.status_code == 503
        assert resp.json()["checks"]["database"] is False
