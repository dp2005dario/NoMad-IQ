"""Pruebas del chat del viaje: la API con un store en memoria y Flyra de guion."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import httpx
from conftest import FakeLLM, InMemoryStore
from test_flyra import MemoryQuota

from ai_orchestrator.api import create_api
from ai_orchestrator.flyra.service import FlyraService, FlyraSettings
from ai_orchestrator.group_chat.api import chat_router, flyra_request
from ai_orchestrator.group_chat.domain import (
    MAX_PER_DAY,
    ChatLimitError,
    ChatPage,
    Member,
    Message,
    TripKind,
    asks_flyra,
)
from ai_orchestrator.group_chat.store import TripNotFoundError
from ai_orchestrator.llm.client import LLMUnavailableError

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=UTC)
TRIP = str(uuid.uuid4())
DARIO = "11111111-1111-4111-8111-111111111111"
MAMA = "22222222-2222-4222-8222-222222222222"
STRANGER = "33333333-3333-4333-8333-333333333333"
URL = f"/v1/group-negotiations/{TRIP}/chat"


class MemoryChat:
    def __init__(self) -> None:
        self.seats = {DARIO: 1, MAMA: 2}
        self.names: dict[int, str | None] = {1: None, 2: None}
        self.kind = TripKind.FRIENDS
        self.messages: list[Message] = []
        self.limit = MAX_PER_DAY

    def _seat(self, trip: str, user: str) -> int:
        if trip != TRIP or user not in self.seats:
            raise TripNotFoundError(trip)
        return self.seats[user]

    def _add(self, seat: int | None, text: str) -> Message:
        msg = Message(len(self.messages) + 1, seat, text, NOW)
        self.messages.append(msg)
        return msg

    async def page(
        self, negotiation_id: str, user_id: str, *, after: int | None, limit: int = 50
    ) -> ChatPage:
        seat = self._seat(negotiation_id, user_id)
        msgs = (
            self.messages[-limit:]
            if after is None
            else [m for m in self.messages if m.message_id > after][:limit]
        )
        return ChatPage(
            TRIP,
            "Lisboa",
            self.kind,
            seat,
            tuple(Member(s, self.names[s] or f"Viajero {s}", True) for s in sorted(self.names)),
            tuple(msgs),
        )

    async def post(self, negotiation_id: str, user_id: str, text: str) -> Message:
        seat = self._seat(negotiation_id, user_id)
        if sum(1 for m in self.messages if m.seat == seat) >= self.limit:
            raise ChatLimitError(negotiation_id)
        return self._add(seat, text)

    async def post_flyra(self, negotiation_id: str, text: str) -> Message:
        return self._add(None, text)

    async def set_kind(self, negotiation_id: str, user_id: str, kind: TripKind) -> None:
        self._seat(negotiation_id, user_id)
        self.kind = kind

    async def set_name(self, negotiation_id: str, user_id: str, name: str | None) -> None:
        self.names[self._seat(negotiation_id, user_id)] = name

    async def others(self, negotiation_id: str, user_id: str) -> list[str]:
        return [u for u in self.seats if u != user_id]


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def flyra(llm: FakeLLM, limit: int = 5) -> FlyraService:
    return FlyraService(
        llm=llm,
        quota=MemoryQuota(),
        settings=FlyraSettings(daily_limit=limit, timeout_seconds=5),
        clock=lambda: NOW,
    )


def client(
    store: MemoryChat, svc: FlyraService | None = None, pushed: list | None = None
) -> httpx.AsyncClient:
    async def push(trip: str, users: list[str]) -> None:
        if pushed is not None:
            pushed.append((trip, users))

    app = create_api(InMemoryStore(), group_chat=chat_router(store, svc, push))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


def test_mention() -> None:
    assert asks_flyra("@Flyra ¿dónde cenamos?")
    assert asks_flyra("  @flyra, plan si llueve")
    assert not asks_flyra("le pregunto a @Flyra luego")
    assert not asks_flyra("@Flyrax hola")


async def test_write_read_and_poll() -> None:
    store = MemoryChat()
    pushed: list = []
    async with client(store, pushed=pushed) as c:
        r = await c.post(
            URL, json={"text": "Mañana qué hacemos?\n\n\n\nMamá no quiere andar mucho"}, headers=h(DARIO)
        )
        assert r.status_code == 201
        first = r.json()["messages"][0]
        # Los saltos de línea se quedan (pero no más de uno en blanco).
        assert first["text"] == "Mañana qué hacemos?\n\nMamá no quiere andar mucho"
        assert first["mine"] and first["name"] == "Viajero 1" and not first["flyra"]
        assert pushed == [(TRIP, [MAMA])]

        assert (await c.put(f"{URL}/me", json={"name": "  Mamá "}, headers=h(MAMA))).status_code == 204
        await c.post(URL, json={"text": "¡Hola! Ya estoy aquí"}, headers=h(MAMA))

        view = (await c.get(URL, headers=h(DARIO))).json()
        assert [m["name"] for m in view["messages"]] == ["Viajero 1", "Mamá"]
        assert [m["mine"] for m in view["messages"]] == [True, False]
        assert view["members"][1] == {"seat": 2, "name": "Mamá", "me": False, "active": True}
        r = await c.get(URL, params={"after": first["id"]}, headers=h(DARIO))
        assert [m["text"] for m in r.json()["messages"]] == ["¡Hola! Ya estoy aquí"]
        assert r.headers["cache-control"] == "no-store"

        # Fuera del viaje: no existe.
        assert (await c.get(URL, headers=h(STRANGER))).status_code == 404
        assert (await c.post(URL, json={"text": "hola"}, headers=h(STRANGER))).status_code == 404
        # Vacío o solo espacios: no.
        assert (await c.post(URL, json={"text": "  \n "}, headers=h(DARIO))).status_code == 400


async def test_daily_limit_and_kind() -> None:
    store = MemoryChat()
    store.limit = 1
    async with client(store) as c:
        await c.post(URL, json={"text": "uno"}, headers=h(DARIO))
        assert (await c.post(URL, json={"text": "dos"}, headers=h(DARIO))).status_code == 429
        assert (await c.put(f"{URL}/kind", json={"kind": "family"}, headers=h(MAMA))).status_code == 204
        assert (await c.get(URL, headers=h(DARIO))).json()["kind"] == "family"
        assert (await c.put(f"{URL}/kind", json={"kind": "solo"}, headers=h(MAMA))).status_code == 400


async def test_flyra_answers_the_group() -> None:
    store = MemoryChat()
    store.kind = TripKind.FAMILY
    store.names[2] = "Mamá"
    llm = FakeLLM(["Por la tarde, Belém: paseo junto al río, sin cuestas."])
    async with client(store, flyra(llm)) as c:
        await c.post(URL, json={"text": "Me apetece ver el mar"}, headers=h(MAMA))
        r = await c.post(URL, json={"text": "@Flyra ¿qué hacemos?", "language": "es"}, headers=h(DARIO))
        body = r.json()
        assert body["flyra_error"] is None
        assert [m["flyra"] for m in body["messages"]] == [False, True]
        assert body["messages"][1]["name"] == "Flyra"
        assert body["messages"][1]["seat"] is None
        sent = llm.calls[0]["messages"]
        # Lo que lee: el tipo de viaje, quiénes son y quién dijo qué.
        assert "family" in sent[0].content and "Mamá" in sent[0].content
        assert "Spanish" in sent[0].content
        assert [m.content for m in sent[1:]] == [
            "Mamá: Me apetece ver el mar",
            "Viajero 1: @Flyra ¿qué hacemos?",
        ]
        # Sin "@Flyra" no la molesta.
        await c.post(URL, json={"text": "vale"}, headers=h(MAMA))
        assert len(llm.calls) == 1


async def test_flyra_quota_and_busy_keep_the_message() -> None:
    store = MemoryChat()
    llm = FakeLLM([LLMUnavailableError("caído"), "ok"])
    async with client(store, flyra(llm, limit=1)) as c:
        busy = (await c.post(URL, json={"text": "@Flyra hola"}, headers=h(DARIO))).json()
        assert busy["flyra_error"] == "busy" and len(busy["messages"]) == 1
        await c.post(URL, json={"text": "@Flyra hola"}, headers=h(DARIO))
        quota = (await c.post(URL, json={"text": "@Flyra otra"}, headers=h(DARIO))).json()
        assert quota["flyra_error"] == "quota"
        # Los tres mensajes de Dario están; Flyra contestó una vez.
        assert sum(1 for m in store.messages if m.seat == 1) == 3
        assert sum(1 for m in store.messages if m.seat is None) == 1


def test_flyra_request_starts_with_a_person_and_fits() -> None:
    msgs = [Message(1, None, "Hola, soy Flyra", NOW)] + [Message(i, 1, "x" * 2000, NOW) for i in range(2, 12)]
    page = ChatPage(TRIP, "Lisboa", TripKind.COUPLE, 1, (Member(1, "Dario", True),), tuple(msgs))
    request, context = flyra_request(page, "es")
    assert request.messages[0].role == "user"
    assert sum(len(m.text) for m in request.messages) <= 12000
    assert "couple" in context
