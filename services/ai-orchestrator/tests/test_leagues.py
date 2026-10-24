"""Pruebas de "Cromos con amigos": las reglas y la API (store en memoria)."""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.leagues.api import league_router
from ai_orchestrator.leagues.domain import (
    MAX_MEMBERS,
    MAX_PENDING,
    Card,
    League,
    Member,
    Swap,
    SwapNotAllowedError,
    check_swap,
    points,
    rarity_of,
    received,
)
from ai_orchestrator.leagues.store import (
    LeagueFullError,
    LeagueNotFoundError,
    SwapNotFoundError,
    TooManyPendingError,
)

NOW = datetime(2026, 10, 24, 12, 0, tzinfo=UTC)
DARIO = "11111111-1111-4111-8111-111111111111"
NOELIA = "22222222-2222-4222-8222-222222222222"
STRANGER = "33333333-3333-4333-8333-333333333333"


def card(qid: str, name: str, year: int | None, month: str = "2026-10") -> Card:
    return Card(qid=qid, name=name, year=year, month=month)


TOKYO_TOWER = card("Q183536", "Torre de Tokio", 1958)
FUSHIMI = card("Q1059207", "Fushimi Inari", 711)
EIFFEL = card("Q243", "Torre Eiffel", 1889, "2026-09")
COLOSSEUM = card("Q10285", "Coliseo", 80)


class MemoryLeagues:
    def __init__(self) -> None:
        self.leagues: dict[str, League] = {}
        self.codes: dict[str, str] = {}

    def _mine(self, league_id: str, user_id: str) -> League:
        league = self.leagues.get(league_id)
        if league is None or league.member(user_id) is None:
            raise LeagueNotFoundError(league_id)
        return league

    async def create(self, user_id: str, name: str, title: str) -> League:
        league_id = str(uuid.uuid4())
        league = League(league_id, title, "7K2M9QXD", (Member(1, user_id, name),))
        self.leagues[league_id] = league
        self.codes["7K2M9QXD"] = league_id
        return league

    async def join(self, code: str, user_id: str, name: str) -> League:
        league_id = self.codes.get(code)
        if league_id is None:
            raise LeagueNotFoundError(code)
        league = self.leagues[league_id]
        if league.member(user_id) is None:
            if len(league.members) >= MAX_MEMBERS:
                raise LeagueFullError(league_id)
            seat = max(m.seat for m in league.members) + 1
            league = replace(league, members=(*league.members, Member(seat, user_id, name)))
            self.leagues[league_id] = league
        return league

    async def list_for_member(self, user_id: str) -> list[League]:
        return [lg for lg in self.leagues.values() if lg.member(user_id) is not None]

    async def get_for_member(self, league_id: str, user_id: str) -> League | None:
        league = self.leagues.get(league_id)
        return league if league is not None and league.member(user_id) is not None else None

    def _put_member(self, league: League, member: Member) -> None:
        self.leagues[league.league_id] = replace(
            league, members=tuple(member if m.seat == member.seat else m for m in league.members)
        )

    async def update_me(self, league_id: str, user_id: str, cards: list[Card], countries: int) -> None:
        league = self._mine(league_id, user_id)
        me = league.member(user_id)
        assert me is not None
        self._put_member(league, replace(me, cards=tuple(cards), countries=countries))

    async def set_city(self, league_id: str, user_id: str, city: str | None) -> None:
        league = self._mine(league_id, user_id)
        me = league.member(user_id)
        assert me is not None
        self._put_member(league, replace(me, city=city, city_at=NOW if city else None))

    async def propose(self, league_id: str, user_id: str, to_seat: int, give_qid: str, want_qid: str) -> Swap:
        league = self._mine(league_id, user_id)
        me = league.member(user_id)
        them = league.seat(to_seat)
        assert me is not None
        if them is None:
            raise SwapNotAllowedError("no está")
        give, want = check_swap(league, me, them, give_qid, want_qid)
        if sum(1 for s in league.swaps if s.status == "pending" and s.from_seat == me.seat) >= MAX_PENDING:
            raise TooManyPendingError(league_id)
        swap = Swap(str(uuid.uuid4()), me.seat, to_seat, give, want, "pending", NOW)
        self.leagues[league_id] = replace(league, swaps=(swap, *league.swaps))
        return swap

    async def decide(self, league_id: str, user_id: str, swap_id: str, *, accept: bool) -> Swap:
        league = self._mine(league_id, user_id)
        me = league.member(user_id)
        swap = next((s for s in league.swaps if s.swap_id == swap_id), None)
        assert me is not None
        if swap is None or swap.to_seat != me.seat or swap.status != "pending":
            raise SwapNotFoundError(swap_id)
        if accept:
            giver = league.seat(swap.from_seat)
            assert giver is not None
            check_swap(league, giver, me, swap.give.qid, swap.want.qid)
        done = replace(swap, status="accepted" if accept else "declined")
        self.leagues[league_id] = replace(
            league, swaps=tuple(done if s.swap_id == swap_id else s for s in league.swaps)
        )
        return done

    async def leave(self, league_id: str, user_id: str) -> None:
        league = self._mine(league_id, user_id)
        me = league.member(user_id)
        assert me is not None
        self.leagues[league_id] = replace(
            league,
            members=tuple(m for m in league.members if m.user_id != user_id),
            swaps=tuple(s for s in league.swaps if me.seat not in (s.from_seat, s.to_seat)),
        )


# --- Reglas --------------------------------------------------------------------------------


def test_rarity_and_points_like_the_app() -> None:
    assert rarity_of(None) == "common" and rarity_of(1958) == "common"
    assert rarity_of(1889) == "rare" and rarity_of(1200) == "epic" and rarity_of(711) == "legendary"
    cards = [TOKYO_TOWER, FUSHIMI, EIFFEL]
    assert points(cards) == 10 + 150 + 40
    assert points(cards, "2026-10") == 160


def test_swap_rules() -> None:
    me = Member(1, DARIO, "Darío", cards=(TOKYO_TOWER, EIFFEL))
    them = Member(2, NOELIA, "Noelia", cards=(FUSHIMI, EIFFEL))
    league = League("l", "Liga", "7K2M9QXD", (me, them))
    give, want = check_swap(league, me, them, TOKYO_TOWER.qid, FUSHIMI.qid)
    assert give == TOKYO_TOWER and want == FUSHIMI
    for give_qid, want_qid in ((EIFFEL.qid, FUSHIMI.qid), (TOKYO_TOWER.qid, EIFFEL.qid), ("Q1", FUSHIMI.qid)):
        with pytest.raises(SwapNotAllowedError):
            check_swap(league, me, them, give_qid, want_qid)
    # Una vez cambiado, no se puede volver a pedir la misma.
    done = Swap("s", 1, 2, TOKYO_TOWER, FUSHIMI, "accepted", NOW)
    league = replace(league, swaps=(done,))
    assert received(league, 1) == [FUSHIMI] and received(league, 2) == [TOKYO_TOWER]
    with pytest.raises(SwapNotAllowedError):
        check_swap(league, me, them, TOKYO_TOWER.qid, FUSHIMI.qid)


# --- API -----------------------------------------------------------------------------------


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def client(store: MemoryLeagues) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), leagues=league_router(store, clock=lambda: NOW))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


def cards_json(*cards: Card) -> list[dict[str, Any]]:
    return [c.model_dump() for c in cards]


async def test_full_flow() -> None:
    store = MemoryLeagues()
    async with client(store) as c:
        created = await c.post(
            "/v1/leagues", json={"title": "Exploradores", "my_name": "Darío"}, headers=h(DARIO)
        )
        assert created.status_code == 201, created.text
        lid = created.json()["league_id"]
        joined = await c.post(
            "/v1/leagues/join", json={"code": "7k2m-9qxd", "my_name": "Noelia"}, headers=h(NOELIA)
        )
        assert joined.json()["my_seat"] == 2
        assert (await c.get(f"/v1/leagues/{lid}", headers=h(STRANGER))).status_code == 404

        r = await c.put(
            f"/v1/leagues/{lid}/me",
            json={"cards": cards_json(TOKYO_TOWER, EIFFEL, EIFFEL), "countries": 9},
            headers=h(DARIO),
        )
        assert r.status_code == 204
        await c.put(
            f"/v1/leagues/{lid}/me",
            json={"cards": cards_json(FUSHIMI, COLOSSEUM), "countries": 14},
            headers=h(NOELIA),
        )
        await c.put(f"/v1/leagues/{lid}/me/city", json={"city": "Kioto"}, headers=h(NOELIA))

        view = (await c.get(f"/v1/leagues/{lid}", headers=h(DARIO))).json()
        assert view["month"] == "2026-10"
        assert [s["name"] for s in view["standings"]] == ["Noelia", "Darío"]
        noelia = view["standings"][0]
        assert noelia["points_month"] == 300 and noelia["legendary"] == 2 and noelia["city"] == "Kioto"
        darío = view["standings"][1]
        # La Torre Eiffel es de septiembre: cuenta en el total, no en el mes. Repetida, una vez.
        assert darío["points_month"] == 10 and darío["points_total"] == 50 and darío["cards"] == 2
        assert "user_id" not in str(view) and DARIO not in str(view)

        theirs = (await c.get(f"/v1/leagues/{lid}/members/2/cards", headers=h(DARIO))).json()
        assert [x["qid"] for x in theirs["cards"]] == [FUSHIMI.qid, COLOSSEUM.qid]

        bad = await c.post(
            f"/v1/leagues/{lid}/swaps",
            json={"to_seat": 2, "give_qid": TOKYO_TOWER.qid, "want_qid": EIFFEL.qid},
            headers=h(DARIO),
        )
        assert bad.status_code == 409
        offer = await c.post(
            f"/v1/leagues/{lid}/swaps",
            json={"to_seat": 2, "give_qid": TOKYO_TOWER.qid, "want_qid": FUSHIMI.qid},
            headers=h(DARIO),
        )
        assert offer.status_code == 201
        sid = offer.json()["swap_id"]
        # Solo lo acepta quien lo recibe.
        assert (await c.post(f"/v1/leagues/{lid}/swaps/{sid}/accept", headers=h(DARIO))).status_code == 404
        ok = await c.post(f"/v1/leagues/{lid}/swaps/{sid}/accept", headers=h(NOELIA))
        assert ok.json()["status"] == "accepted"
        mine = (await c.get(f"/v1/leagues/{lid}", headers=h(DARIO))).json()
        assert [x["qid"] for x in mine["received"]] == [FUSHIMI.qid]
        # La copia no da puntos de liga.
        assert next(s for s in mine["standings"] if s["me"])["points_month"] == 10

        listed = (await c.get("/v1/leagues", headers=h(DARIO))).json()["items"]
        assert listed == [{"league_id": lid, "title": "Exploradores", "members": 2, "my_position": 2}]

        await c.put(f"/v1/leagues/{lid}/me/city", json={"city": None}, headers=h(NOELIA))
        assert (await c.get(f"/v1/leagues/{lid}", headers=h(DARIO))).json()["standings"][0]["city"] is None

        assert (await c.delete(f"/v1/leagues/{lid}/me", headers=h(NOELIA))).status_code == 204
        after = (await c.get(f"/v1/leagues/{lid}", headers=h(DARIO))).json()
        assert len(after["standings"]) == 1 and after["swaps"] == [] and after["received"] == []


async def test_api_errors() -> None:
    store = MemoryLeagues()
    async with client(store) as c:
        assert (
            await c.post("/v1/leagues/join", json={"code": "??", "my_name": "X"}, headers=h(DARIO))
        ).status_code == 404
        assert (await c.get("/v1/leagues")).status_code == 401
        lid = (
            await c.post("/v1/leagues", json={"title": "Liga", "my_name": "Darío"}, headers=h(DARIO))
        ).json()["league_id"]
        too_many = {"cards": [card(f"Q{i}", "x", None).model_dump() for i in range(1, 1002)]}
        assert (await c.put(f"/v1/leagues/{lid}/me", json=too_many, headers=h(DARIO))).status_code == 400
        assert (
            await c.put(f"/v1/leagues/{lid}/me/city", json={"city": "Roma"}, headers=h(STRANGER))
        ).status_code == 404
