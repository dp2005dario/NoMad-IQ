"""Pruebas de "Elegid planes": el match y la API (store en memoria)."""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, datetime

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.plans.api import plan_router
from ai_orchestrator.plans.domain import (
    MAX_PLANS_PER_MEMBER,
    Board,
    NotMatchError,
    Plan,
    PlanLimitError,
    is_match,
    match_with,
)
from ai_orchestrator.plans.store import NewPlan, PlanNotFoundError, TripNotFoundError

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=UTC)
TRIP = str(uuid.uuid4())
DARIO = "11111111-1111-4111-8111-111111111111"
NOELIA = "22222222-2222-4222-8222-222222222222"
STRANGER = "33333333-3333-4333-8333-333333333333"


def plan(votes: dict[int, bool]) -> Plan:
    return Plan("p", 1, "Fado", None, None, None, None, NOW, votes)


def test_match_needs_two_yes() -> None:
    both = frozenset({1, 2})
    assert is_match(plan({1: True, 2: True}), both)
    assert not is_match(plan({1: True}), both)
    assert not is_match(plan({1: True, 2: False}), both)
    # El voto de una cuenta borrada (asiento 3, ya no activo) no cuenta.
    assert is_match(plan({1: True, 2: True, 3: False}), both)
    assert not is_match(plan({1: True, 3: True}), both)
    # Solo, no hay match: hace falta un grupo.
    assert not is_match(plan({1: True}), frozenset({1}))
    # En un grupo de 4, con que dos digan que sí ya es match viajero.
    four = frozenset({1, 2, 3, 4})
    assert is_match(plan({2: True, 4: True, 1: False}), four)


def test_match_with_is_secret_until_you_coincide() -> None:
    names = {1: "Dario", 2: "Marta", 3: "Álex"}
    seats = frozenset({1, 2, 3})
    p = plan({2: True, 3: True})
    # Yo no he dicho que sí: no veo quién lo marcó.
    assert match_with(p, Board(TRIP, 1, seats, (p,), names)) == []
    # Yo sí: veo con quién coincido (sin mí).
    p = plan({1: True, 2: True, 3: False})
    assert match_with(p, Board(TRIP, 1, seats, (p,), names)) == ["Marta"]


class MemoryPlans:
    def __init__(self) -> None:
        self.seats = {DARIO: 1, NOELIA: 2}
        self.plans: list[Plan] = []

    def _seat(self, trip: str, user: str) -> int:
        if trip != TRIP or user not in self.seats:
            raise TripNotFoundError(trip)
        return self.seats[user]

    def _board(self, seat: int) -> Board:
        return Board(TRIP, seat, frozenset(self.seats.values()), tuple(self.plans), {1: "Dario", 2: "Noelia"})

    async def board(self, negotiation_id: str, user_id: str) -> Board:
        return self._board(self._seat(negotiation_id, user_id))

    async def add(self, negotiation_id: str, user_id: str, plans: list[NewPlan]) -> Board:
        seat = self._seat(negotiation_id, user_id)
        known = {p.wikidata_id for p in self.plans if p.wikidata_id}
        fresh = [p for p in plans if p.wikidata_id is None or p.wikidata_id not in known]
        if sum(1 for p in self.plans if p.added_by_seat == seat) + len(fresh) > MAX_PLANS_PER_MEMBER:
            raise PlanLimitError(negotiation_id)
        for p in fresh:
            self.plans.append(
                Plan(
                    str(uuid.uuid4()),
                    seat,
                    p.title,
                    p.note,
                    p.wikidata_id,
                    p.photo_url,
                    p.article_url,
                    NOW,
                    {},
                )
            )
        return self._board(seat)

    async def vote(self, negotiation_id: str, user_id: str, plan_id: str, *, yes: bool) -> Board:
        seat = self._seat(negotiation_id, user_id)
        for i, p in enumerate(self.plans):
            if p.plan_id == plan_id:
                self.plans[i] = replace(p, votes={**p.votes, seat: yes})
                return self._board(seat)
        raise PlanNotFoundError(plan_id)

    async def plan(self, negotiation_id: str, user_id: str, plan_id: str) -> Board:
        seat = self._seat(negotiation_id, user_id)
        board = self._board(seat)
        for i, p in enumerate(self.plans):
            if p.plan_id == plan_id:
                if p.votes.get(seat) is not True or not is_match(p, board.active_seats):
                    raise NotMatchError(plan_id)
                self.plans[i] = replace(p, planned=True)
                return self._board(seat)
        raise PlanNotFoundError(plan_id)

    async def delete(self, negotiation_id: str, user_id: str, plan_id: str) -> Board:
        seat = self._seat(negotiation_id, user_id)
        before = len(self.plans)
        self.plans = [p for p in self.plans if not (p.plan_id == plan_id and p.added_by_seat == seat)]
        if len(self.plans) == before:
            raise PlanNotFoundError(plan_id)
        return self._board(seat)


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def client(store: MemoryPlans) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), plans=plan_router(store))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


URL = f"/v1/group-negotiations/{TRIP}/plans"
BELEM = {
    "title": "Torre de Belém",
    "wikidata_id": "Q193208",
    "photo_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Belem.jpg/500px-Belem.jpg",
    "article_url": "https://es.wikipedia.org/wiki/Torre_de_Bel%C3%A9m",
}


async def test_add_vote_and_match() -> None:
    store = MemoryPlans()
    async with client(store) as c:
        r = await c.post(
            URL,
            json={"plans": [BELEM, {"title": "Fado en Alfama", "note": "Esta noche · 21:30 · ≈ 25 €"}]},
            headers=h(DARIO),
        )
        assert r.status_code == 201
        plans = r.json()["plans"]
        assert [p["title"] for p in plans] == ["Torre de Belém", "Fado en Alfama"]
        assert plans[0]["mine"] and plans[0]["my_vote"] is None
        # La misma atracción otra vez no se repite.
        again = await c.post(URL, json={"plans": [BELEM]}, headers=h(NOELIA))
        assert len(again.json()["plans"]) == 2
        belem, fado = plans[0]["plan_id"], plans[1]["plan_id"]

        await c.put(f"{URL}/{belem}/vote", json={"yes": True}, headers=h(DARIO))
        await c.put(f"{URL}/{fado}/vote", json={"yes": True}, headers=h(DARIO))
        view = (await c.put(f"{URL}/{belem}/vote", json={"yes": True}, headers=h(NOELIA))).json()
        view = (await c.put(f"{URL}/{fado}/vote", json={"yes": False}, headers=h(NOELIA))).json()
        by_title = {p["title"]: p for p in view["plans"]}
        assert view["members"] == 2
        assert by_title["Torre de Belém"]["match"] is True
        assert by_title["Fado en Alfama"]["match"] is False
        # Nadie ve quién votó qué: solo cuántos.
        assert by_title["Fado en Alfama"]["yes"] == 1 and by_title["Fado en Alfama"]["voted"] == 2
        assert by_title["Fado en Alfama"]["my_vote"] is False
        # Con quién coincides: solo en el match y sin ti.
        assert by_title["Torre de Belém"]["match_with"] == ["Dario"]
        assert by_title["Fado en Alfama"]["match_with"] == []
        assert view["people"] == [
            {"name": "Dario", "me": False, "voted": True},
            {"name": "Noelia", "me": True, "voted": True},
        ]
        # "Añadir al plan": el match sí; lo que no es match, no.
        r = await c.put(f"{URL}/{fado}/planned", headers=h(DARIO))
        assert r.status_code == 409
        r = await c.put(f"{URL}/{belem}/planned", headers=h(NOELIA))
        assert r.status_code == 200
        assert {p["title"]: p["planned"] for p in r.json()["plans"]} == {
            "Torre de Belém": True,
            "Fado en Alfama": False,
        }
        assert not by_title["Fado en Alfama"]["mine"]

        # Solo quien lo puso puede quitarlo.
        assert (await c.delete(f"{URL}/{fado}", headers=h(NOELIA))).status_code == 404
        assert (await c.delete(f"{URL}/{fado}", headers=h(DARIO))).status_code == 200


async def test_strangers_and_bad_links_are_refused() -> None:
    store = MemoryPlans()
    async with client(store) as c:
        assert (await c.get(URL, headers=h(STRANGER))).status_code == 404
        bad_photo = {**BELEM, "photo_url": "https://evil.example/x.jpg"}
        assert (await c.post(URL, json={"plans": [bad_photo]}, headers=h(DARIO))).status_code == 400
        bad_link = {"title": "x", "article_url": "javascript:alert(1)"}
        assert (await c.post(URL, json={"plans": [bad_link]}, headers=h(DARIO))).status_code == 400
        assert (await c.post(URL, json={"plans": []}, headers=h(DARIO))).status_code == 400
        many = {"plans": [{"title": f"Plan {i}"} for i in range(10)]}
        assert (await c.post(URL, json=many, headers=h(DARIO))).status_code == 201
        assert (await c.post(URL, json=many, headers=h(DARIO))).status_code == 409
        missing = f"{URL}/{uuid.uuid4()}/vote"
        assert (await c.put(missing, json={"yes": True}, headers=h(DARIO))).status_code == 404
