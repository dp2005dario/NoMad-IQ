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
            {"alias": "Viajero 1", "name": None, "submitted": False, "me": True},
            {"alias": "Viajero 2", "name": None, "submitted": False, "me": False},
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
        first_member = {"alias": "Viajero 1", "name": None, "submitted": True, "me": False}
        assert seen.json()["members"][0] == first_member

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
        {"my_name": "   "},
        {"my_name": "x" * 41},
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


INVITE_PREFS = {"budget_max_minor": 50000, "interests": ["playa"]}


async def test_invite_flow(store: InMemoryNegotiations) -> None:
    """Lo que hace la app: crear sin miembros, compartir el código, entrar, Empezar."""
    kicks: list[int] = []
    async with client(store, kicks) as c:
        created = await c.post(
            "/v1/group-negotiations", json=body(members=[], my_name="Darío"), headers=headers(ORGANIZER)
        )
        assert created.status_code == 201
        view = created.json()
        negotiation_id = view["negotiation_id"]
        code = view["invite_code"]
        assert len(code) == 8 and view["i_organize"] is True
        assert view["members"] == [{"alias": "Viajero 1", "name": "Darío", "submitted": False, "me": True}]

        # El amigo lo escribe a su manera: minúsculas, guion y una "o" en vez de un cero.
        typed = (code[:4] + "-" + code[4:]).lower().replace("0", "o")
        joined = await c.post(
            "/v1/group-negotiations/join", json={"code": typed, "my_name": "Noelia"}, headers=headers(FRIEND)
        )
        assert joined.status_code == 200
        assert joined.json()["negotiation_id"] == negotiation_id
        assert joined.json()["my_alias"] == "Viajero 2" and joined.json()["i_organize"] is False
        assert [m["name"] for m in joined.json()["members"]] == ["Darío", "Noelia"]
        # Entrar dos veces no duplica el asiento.
        again = await c.post("/v1/group-negotiations/join", json={"code": code}, headers=headers(FRIEND))
        assert len(again.json()["members"]) == 2

        # Todos han enviado, pero el grupo sigue abierto: NO arranca sola.
        for who in (ORGANIZER, FRIEND):
            put = await c.put(
                f"/v1/group-negotiations/{negotiation_id}/preferences",
                json=INVITE_PREFS,
                headers=headers(who),
            )
            assert put.json()["status"] == "collecting"
        assert kicks == [] and store.outbox == []

        # Solo el organizador puede empezar.
        forbidden = await c.post(f"/v1/group-negotiations/{negotiation_id}/start", headers=headers(FRIEND))
        assert forbidden.status_code == 403
        started = await c.post(f"/v1/group-negotiations/{negotiation_id}/start", headers=headers(ORGANIZER))
        assert started.status_code == 200
        assert started.json()["status"] == "queued"
        assert started.json()["invite_code"] is None
        assert kicks == [1] and len(store.outbox) == 1

        # El código ya no vale: el grupo está cerrado.
        late = await c.post("/v1/group-negotiations/join", json={"code": code}, headers=headers(STRANGER))
        assert late.status_code == 404
        twice = await c.post(f"/v1/group-negotiations/{negotiation_id}/start", headers=headers(ORGANIZER))
        assert twice.status_code == 409


async def test_start_needs_two_ready(store: InMemoryNegotiations) -> None:
    async with client(store) as c:
        created = await c.post("/v1/group-negotiations", json=body(members=[]), headers=headers(ORGANIZER))
        negotiation_id = created.json()["negotiation_id"]
        await c.put(
            f"/v1/group-negotiations/{negotiation_id}/preferences",
            json=INVITE_PREFS,
            headers=headers(ORGANIZER),
        )
        alone = await c.post(f"/v1/group-negotiations/{negotiation_id}/start", headers=headers(ORGANIZER))
        assert alone.status_code == 409
        stranger = await c.post(f"/v1/group-negotiations/{negotiation_id}/start", headers=headers(STRANGER))
        assert stranger.status_code == 404


async def test_join_rejects_bad_codes_and_full_groups(store: InMemoryNegotiations) -> None:
    async with client(store) as c:
        for bad in ("", "1234", "ZZZZZZZZ", "ÑÑÑÑÑÑÑÑ", "U" * 8):
            resp = await c.post("/v1/group-negotiations/join", json={"code": bad}, headers=headers(FRIEND))
            assert resp.status_code in (400, 404), bad

        created = await c.post("/v1/group-negotiations", json=body(members=[]), headers=headers(ORGANIZER))
        code = created.json()["invite_code"]
        for i in range(7):
            who = headers(f"user-{i}")
            ok = await c.post("/v1/group-negotiations/join", json={"code": code}, headers=who)
            assert ok.status_code == 200
        full = await c.post("/v1/group-negotiations/join", json={"code": code}, headers=headers(STRANGER))
        assert full.status_code == 409

        store.now = FIXED_NOW + timedelta(days=4)
        other = await c.post("/v1/group-negotiations", json=body(members=[]), headers=headers(FRIEND))
        other_code = {"code": other.json()["invite_code"]}
        late = await c.post("/v1/group-negotiations/join", json=other_code, headers=headers(STRANGER))
        assert late.status_code == 409
