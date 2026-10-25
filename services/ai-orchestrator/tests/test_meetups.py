"""Pruebas de las quedadas: reglas y API (store en memoria)."""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.meetups.api import meetup_router
from ai_orchestrator.meetups.domain import (
    KEEP_AFTER_START,
    MAX_ACTIVE_CREATED,
    REPORTS_TO_HIDE,
    Meetup,
    MeetupFullError,
    MeetupLimitError,
    MeetupNotFoundError,
    Member,
)
from ai_orchestrator.meetups.store import NewMeetup
from ai_orchestrator.places.airports import Airports

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=UTC)
DARIO = "11111111-1111-4111-8111-111111111111"
NOELIA = "22222222-2222-4222-8222-222222222222"
LUCA = "33333333-3333-4333-8333-333333333333"
AIRPORTS = Airports.parse(
    "LIS|38.77|-9.13|Lisbon|PT|Europe/Lisbon\nMAD|40.47|-3.56|Madrid|ES|Europe/Madrid\n"
)


class MemoryMeetups:
    def __init__(self) -> None:
        self.meetups: dict[str, Meetup] = {}
        self.reports: set[tuple[str, str]] = set()

    def _get(self, meetup_id: str, now: datetime) -> Meetup:
        m = self.meetups.get(meetup_id)
        if m is None or not m.shown(now):
            raise MeetupNotFoundError(meetup_id)
        return m

    async def list_city(self, city: str, now: datetime) -> list[Meetup]:
        return sorted(
            (m for m in self.meetups.values() if m.city == city and m.shown(now)), key=lambda m: m.starts_at
        )

    async def mine(self, user_id: str, now: datetime) -> list[Meetup]:
        return [m for m in self.meetups.values() if m.member(user_id) and m.shown(now)]

    async def create(self, user_id: str, me: Member, draft: NewMeetup, now: datetime) -> Meetup:
        if sum(1 for m in self.meetups.values() if m.creator_id == user_id) >= MAX_ACTIVE_CREATED:
            raise MeetupLimitError(user_id)
        m = Meetup(
            str(uuid.uuid4()),
            draft.city,
            draft.kind,
            draft.title,
            draft.place,
            draft.starts_at,
            draft.capacity,
            user_id,
            0,
            (me,),
        )
        self.meetups[m.meetup_id] = m
        return m

    async def join(self, meetup_id: str, me: Member, now: datetime) -> Meetup:
        m = self._get(meetup_id, now)
        if m.member(me.user_id) is None:
            if m.full:
                raise MeetupFullError(meetup_id)
            m = replace(m, members=(*m.members, me))
            self.meetups[meetup_id] = m
        return m

    async def leave(self, meetup_id: str, user_id: str, now: datetime) -> Meetup:
        m = self._get(meetup_id, now)
        if m.creator_id == user_id:
            raise MeetupNotFoundError(meetup_id)
        m = replace(m, members=tuple(p for p in m.members if p.user_id != user_id))
        self.meetups[meetup_id] = m
        return m

    async def cancel(self, meetup_id: str, user_id: str) -> None:
        m = self.meetups.get(meetup_id)
        if m is None or m.creator_id != user_id:
            raise MeetupNotFoundError(meetup_id)
        del self.meetups[meetup_id]

    async def report(self, meetup_id: str, user_id: str) -> None:
        m = self.meetups.get(meetup_id)
        if m is not None and (meetup_id, user_id) not in self.reports:
            self.reports.add((meetup_id, user_id))
            self.meetups[meetup_id] = replace(m, reports=m.reports + 1)

    async def sweep(self, now: datetime) -> int:
        old = [k for k, m in self.meetups.items() if m.starts_at < now - KEEP_AFTER_START]
        for k in old:
            del self.meetups[k]
        return len(old)


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def client(store: MemoryMeetups, now: datetime = NOW) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), meetups=meetup_router(store, AIRPORTS, clock=lambda: now))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


def body(**over: object) -> dict[str, object]:
    return {
        "city": "LIS",
        "kind": "food",
        "title": "Cena de bacalao",
        "place": "Praça do Comércio, junto a la estatua",
        "starts_at": (NOW + timedelta(hours=8)).isoformat(),
        "capacity": 3,
        "me": {"name": "Dario", "country": "ES"},
        **over,
    }


def test_shown_hides_old_and_reported() -> None:
    m = Meetup("x", "LIS", "food", "t", "p", NOW, 4, DARIO, 0, ())
    assert m.shown(NOW + timedelta(hours=1))
    assert not m.shown(NOW + timedelta(hours=3))
    assert not replace(m, reports=REPORTS_TO_HIDE).shown(NOW)


async def test_create_join_and_privacy() -> None:
    store = MemoryMeetups()
    async with client(store) as c:
        r = await c.post("/v1/meetups", json=body(), headers=h(DARIO))
        assert r.status_code == 201
        created = r.json()
        assert created["mine"] and created["joined"] and created["going"] == 1
        mid = created["meetup_id"]

        hidden = {"name": "Noelia", "country": "PT", "visible": False}
        joined = (await c.post(f"/v1/meetups/{mid}/join", json={"me": hidden}, headers=h(NOELIA))).json()
        assert joined["joined"] and not joined["mine"] and joined["going"] == 2
        # Nunca sale un user_id; el nombre oculto llega como null.
        assert DARIO not in str(joined) and NOELIA not in str(joined)
        assert joined["people"] == [
            {"name": "Dario", "country": "ES", "organizer": True},
            {"name": None, "country": "PT", "organizer": False},
        ]

        listed = (await c.get("/v1/meetups", params={"city": "LIS"}, headers=h(LUCA))).json()["meetups"]
        assert [m["title"] for m in listed] == ["Cena de bacalao"]
        assert not listed[0]["joined"]
        assert (await c.get("/v1/meetups", params={"city": "MAD"}, headers=h(LUCA))).json()["meetups"] == []

        # Completa (3 plazas): la cuarta persona no entra.
        await c.post(f"/v1/meetups/{mid}/join", json={"me": {"name": "Luca"}}, headers=h(LUCA))
        full = await c.post(
            f"/v1/meetups/{mid}/join", json={"me": {"name": "X"}}, headers=h(str(uuid.uuid4()))
        )
        assert full.status_code == 409

        left = (await c.delete(f"/v1/meetups/{mid}/join", headers=h(LUCA))).json()
        assert left["going"] == 2 and not left["joined"]
        mine = (await c.get("/v1/meetups/mine", headers=h(NOELIA))).json()["meetups"]
        assert [m["meetup_id"] for m in mine] == [mid]

        # Solo quien la propuso la cancela, y no puede "irse" de la suya.
        assert (await c.delete(f"/v1/meetups/{mid}/join", headers=h(DARIO))).status_code == 404
        assert (await c.delete(f"/v1/meetups/{mid}", headers=h(NOELIA))).status_code == 404
        assert (await c.delete(f"/v1/meetups/{mid}", headers=h(DARIO))).status_code == 204
        assert (
            await c.post(f"/v1/meetups/{mid}/join", json={"me": hidden}, headers=h(NOELIA))
        ).status_code == 404


async def test_validation_and_limits() -> None:
    store = MemoryMeetups()
    async with client(store) as c:
        bad = [
            body(city="XXX"),
            body(city="lis"),
            body(kind="party"),
            body(capacity=1),
            body(capacity=13),
            body(starts_at=(NOW - timedelta(minutes=1)).isoformat()),
            body(starts_at=(NOW + timedelta(days=31)).isoformat()),
            body(starts_at="2026-10-26T12:00:00"),
            body(title="   "),
            body(me={"name": "Dario", "user_id": DARIO}),
        ]
        codes = [(await c.post("/v1/meetups", json=b, headers=h(DARIO))).status_code for b in bad]
        assert codes == [404, 400, 400, 400, 400, 400, 400, 400, 400, 400]
        assert (await c.get("/v1/meetups", params={"city": "ZZZ"}, headers=h(DARIO))).status_code == 404

        for _ in range(MAX_ACTIVE_CREATED):
            assert (await c.post("/v1/meetups", json=body(), headers=h(DARIO))).status_code == 201
        assert (await c.post("/v1/meetups", json=body(), headers=h(DARIO))).status_code == 409


async def test_reports_hide_and_old_ones_are_swept() -> None:
    store = MemoryMeetups()
    async with client(store) as c:
        mid = (await c.post("/v1/meetups", json=body(), headers=h(DARIO))).json()["meetup_id"]
        # La misma persona denunciando muchas veces cuenta una vez.
        for _ in range(5):
            assert (await c.post(f"/v1/meetups/{mid}/report", headers=h(NOELIA))).status_code == 204
        assert store.meetups[mid].reports == 1
        await c.post(f"/v1/meetups/{mid}/report", headers=h(LUCA))
        await c.post(f"/v1/meetups/{mid}/report", headers=h(str(uuid.uuid4())))
        assert (await c.get("/v1/meetups", params={"city": "LIS"}, headers=h(DARIO))).json()["meetups"] == []
        # Denunciar algo que no existe también da 204 (no sirve para adivinar ids).
        assert (await c.post(f"/v1/meetups/{uuid.uuid4()}/report", headers=h(DARIO))).status_code == 204

    store2 = MemoryMeetups()
    async with client(store2) as c:
        await c.post("/v1/meetups", json=body(), headers=h(DARIO))
    later = NOW + timedelta(days=9)
    async with client(store2, later) as c:
        fresh = body(starts_at=(later + timedelta(hours=1)).isoformat())
        await c.post("/v1/meetups", json=fresh, headers=h(NOELIA))
    assert len(store2.meetups) == 1
