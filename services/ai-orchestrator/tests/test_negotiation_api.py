"""Tests de la API de negociación: quién ve qué y qué se puede hacer en cada estado."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import httpx
import pytest
from conftest import FIXED_NOW, InMemoryNegotiations, InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.negotiation.api import ApiSettings, negotiation_router

ORGANIZER = "11111111-1111-4111-8111-111111111111"
FRIEND = "22222222-2222-4222-8222-222222222222"
STRANGER = "33333333-3333-4333-8333-333333333333"


def headers(user_id: str) -> dict[str, str]:
    return {"X-User-ID": user_id, "X-User-Roles": "USER"}


def body(**overrides: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "title": "Escapada de octubre",
        "currency": "EUR",
        "options": [
            {"option_id": "lisboa", "label": "Lisboa", "price_minor": 30000, "tags": ["playa"]},
            {"option_id": "roma", "label": "Roma", "price_minor": 40000, "tags": ["museos"]},
        ],
        "members": [FRIEND],
    }
    return data | overrides


PREFS = {"budget_max_minor": 50000, "interests": ["playa"], "avoid": [], "notes": "Mi presupuesto es secreto"}


@pytest.fixture
def store() -> InMemoryNegotiations:
    return InMemoryNegotiations()


def client(store: InMemoryNegotiations, kicks: list[int] | None = None) -> httpx.AsyncClient:
    router = negotiation_router(
        store,
        ApiSettings(default_max_rounds=3, collect_hours=72),
        on_outbox=(lambda: kicks.append(1)) if kicks is not None else None,
        clock=lambda: FIXED_NOW,
    )
    app = create_api(InMemoryStore(), negotiations=router)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_full_flow_and_privacy(store: InMemoryNegotiations) -> None:
    kicks: list[int] = []
    async with client(store, kicks) as c:
        created = await c.post("/v1/group-negotiations", json=body(), headers=headers(ORGANIZER))
        assert created.status_code == 201
        view = created.json()
        negotiation_id = view["negotiation_id"]
        assert created.headers["location"] == f"/v1/group-negotiations/{negotiation_id}"
        assert view["status"] == "collecting"
        assert view["my_alias"] == "Viajero 1"
        assert view["deadline"].startswith((FIXED_NOW + timedelta(hours=72)).date().isoformat())
        assert view["members"] == [
            {"alias": "Viajero 1", "submitted": False, "me": True},
            {"alias": "Viajero 2", "submitted": False, "me": False},
        ]

        first = await c.put(
            f"/v1/group-negotiations/{negotiation_id}/preferences", json=PREFS, headers=headers(ORGANIZER)
        )
        assert first.status_code == 200
        assert first.json()["status"] == "collecting"
        assert first.json()["my_preferences"]["notes"] == "Mi presupuesto es secreto"
        assert kicks == []

        # El amigo NO ve las preferencias del organizador, ni su user_id.
        seen = await c.get(f"/v1/group-negotiations/{negotiation_id}", headers=headers(FRIEND))
        assert seen.status_code == 200
        assert seen.json()["my_preferences"] is None
        assert "secreto" not in seen.text and ORGANIZER not in seen.text
        assert seen.json()["members"][0] == {"alias": "Viajero 1", "submitted": True, "me": False}

        last = await c.put(
            f"/v1/group-negotiations/{negotiation_id}/preferences", json=PREFS, headers=headers(FRIEND)
        )
        assert last.json()["status"] == "queued"
        assert kicks == [1]  # timbre al relé del outbox
        assert len(store.outbox) == 1

        # Ya en cola: no se pueden cambiar las preferencias.
        late = await c.put(
            f"/v1/group-negotiations/{negotiation_id}/preferences", json=PREFS, headers=headers(FRIEND)
        )
        assert late.status_code == 409
        assert late.headers["content-type"] == "application/problem+json"

        mine = await c.get("/v1/group-negotiations", headers=headers(FRIEND))
        assert [i["negotiation_id"] for i in mine.json()["items"]] == [negotiation_id]


async def test_strangers_get_404(store: InMemoryNegotiations) -> None:
    async with client(store) as c:
        created = await c.post("/v1/group-negotiations", json=body(), headers=headers(ORGANIZER))
        negotiation_id = created.json()["negotiation_id"]
        assert (
            await c.get(f"/v1/group-negotiations/{negotiation_id}", headers=headers(STRANGER))
        ).status_code == 404
        put = await c.put(
            f"/v1/group-negotiations/{negotiation_id}/preferences", json=PREFS, headers=headers(STRANGER)
        )
        assert put.status_code == 404
        assert (await c.get("/v1/group-negotiations", headers=headers(STRANGER))).json()["items"] == []


async def test_late_preferences_are_rejected(store: InMemoryNegotiations) -> None:
    async with client(store) as c:
        created = await c.post("/v1/group-negotiations", json=body(), headers=headers(ORGANIZER))
        store.now = FIXED_NOW + timedelta(days=4)
        late = await c.put(
            f"/v1/group-negotiations/{created.json()['negotiation_id']}/preferences",
            json=PREFS,
            headers=headers(ORGANIZER),
        )
        assert late.status_code == 409


@pytest.mark.parametrize(
    "bad",
    [
        {"members": []},
        {"members": [FRIEND, FRIEND]},
        {"members": [f"u{i}" for i in range(8)]},
        {"members": ["no vale<script>"]},
        {"members": [ORGANIZER]},
        {"options": [body()["options"][0]]},
        {"options": [body()["options"][0], body()["options"][0]]},
        {"language": "xx"},
        {"currency": "euro"},
        {"max_rounds": 11},
        {"sorpresa": True},
    ],
)
async def test_invalid_creation_is_400(store: InMemoryNegotiations, bad: dict[str, Any]) -> None:
    async with client(store) as c:
        resp = await c.post("/v1/group-negotiations", json=body(**bad), headers=headers(ORGANIZER))
    assert resp.status_code == 400
    assert store.records == {}


async def test_identity_is_required(store: InMemoryNegotiations) -> None:
    async with client(store) as c:
        assert (await c.post("/v1/group-negotiations", json=body())).status_code == 401
        assert (
            await c.get("/v1/group-negotiations", headers={"X-User-ID": ORGANIZER, "X-User-Roles": "GUEST"})
        ).status_code == 403
        assert (await c.get("/v1/group-negotiations/no-uuid", headers=headers(ORGANIZER))).status_code == 400
