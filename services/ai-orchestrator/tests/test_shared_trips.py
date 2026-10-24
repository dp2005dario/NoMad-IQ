"""Pruebas de "Copia este viaje": las reglas, la adaptación y la API (todo en memoria)."""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import UTC, datetime

import httpx
import pytest
from conftest import FakeLLM, InMemoryStore
from pydantic import ValidationError
from test_flyra import MemoryQuota

from ai_orchestrator.api import create_api
from ai_orchestrator.llm.client import LLMUnavailableError
from ai_orchestrator.quota import QuotaExceededError
from ai_orchestrator.shared_trips.api import shared_trip_router
from ai_orchestrator.shared_trips.domain import MAX_PER_OWNER, ShareTrip, TripItem, apply_alternatives
from ai_orchestrator.shared_trips.service import (
    AdaptBusyError,
    AdaptSettings,
    TripAdapter,
    build_messages,
    parse_reply,
)
from ai_orchestrator.shared_trips.store import TooManySharedError, TripRecord

NOW = datetime(2026, 10, 24, 10, 0, tzinfo=UTC)
LAURA = "11111111-1111-4111-8111-111111111111"
DARIO = "22222222-2222-4222-8222-222222222222"

JAPAN = {
    "title": "Japón en 10 días",
    "author": "laura.viaja",
    "destination": "Tokio y Kioto",
    "days": 10,
    "currency": "EUR",
    "items": [
        {"kind": "flight", "title": "Vuelo directo Madrid-Tokio", "price_minor": 98000},
        {"kind": "stay", "title": "Hotel en Shinjuku, 9 noches", "price_minor": 81000},
        {"kind": "transport", "title": "JR Pass de 7 días", "price_minor": 38000},
        {"kind": "food", "title": "Cena kaiseki en Kioto", "price_minor": 15000},
        {"kind": "activity", "title": "Excursión a Hakone con guía", "price_minor": 8000},
    ],
}


class MemoryTrips:
    def __init__(self) -> None:
        self.trips: dict[str, TripRecord] = {}
        self.copied: set[tuple[str, str]] = set()
        self._n = 0

    async def share(self, owner_id: str, trip: ShareTrip) -> TripRecord:
        if sum(1 for t in self.trips.values() if t.owner_id == owner_id) >= MAX_PER_OWNER:
            raise TooManySharedError
        self._n += 1
        code = f"7K2M9QX{self._n}"
        record = TripRecord(
            code=code,
            owner_id=owner_id,
            author=trip.author,
            title=trip.title,
            destination=trip.destination,
            days=trip.days,
            currency=trip.currency,
            items=tuple(trip.items),
            copies=0,
            created_at=NOW,
        )
        self.trips[code] = record
        return record

    async def get(self, code: str) -> TripRecord | None:
        return self.trips.get(code)

    async def mine(self, owner_id: str) -> list[TripRecord]:
        return [t for t in self.trips.values() if t.owner_id == owner_id]

    async def copy(self, code: str, user_id: str) -> TripRecord | None:
        t = self.trips.get(code)
        if t is None:
            return None
        if t.owner_id != user_id and (code, user_id) not in self.copied:
            self.copied.add((code, user_id))
            t = replace(t, copies=t.copies + 1)
            self.trips[code] = t
        return t

    async def unshare(self, code: str, owner_id: str) -> bool:
        t = self.trips.get(code)
        if t is None or t.owner_id != owner_id:
            return False
        del self.trips[code]
        return True


class MemoryCache:
    def __init__(self) -> None:
        self.data: dict[str, str] = {}

    async def get(self, key: str) -> str | None:
        return self.data.get(key)

    async def put(self, key: str, value: str) -> None:
        self.data[key] = value


def record(**extra: object) -> TripRecord:
    trip = ShareTrip.model_validate({**JAPAN, **extra})
    return TripRecord(
        code="7K2M9QXD",
        owner_id=LAURA,
        author=trip.author,
        title=trip.title,
        destination=trip.destination,
        days=trip.days,
        currency=trip.currency,
        items=tuple(trip.items),
        copies=0,
        created_at=NOW,
    )


CHEAPER = json.dumps(
    {
        "changes": [
            {"line": 1, "title": "Vuelo con escala en Estambul", "price": 690},
            {"line": 2, "title": "Hotel cápsula premium en Ueno", "price": 450},
            # Más caro que el original: no vale.
            {"line": 3, "title": "JR Pass de 14 días", "price": 600},
            {"line": 4, "title": "Cena en izakaya local", "price": 40},
            # Una línea que no existe: no vale.
            {"line": 9, "title": "Karaoke", "price": 10},
        ]
    }
)


def adapter(llm: FakeLLM, limit: int = 3) -> tuple[TripAdapter, MemoryQuota, MemoryCache]:
    quota, cache = MemoryQuota(), MemoryCache()
    svc = TripAdapter(
        llm=llm,
        quota=quota,
        cache=cache,
        settings=AdaptSettings(daily_limit=limit, timeout_seconds=5),
        clock=lambda: NOW,
    )
    return svc, quota, cache


# --- Reglas --------------------------------------------------------------------------------


def test_share_validation() -> None:
    with pytest.raises(ValidationError):
        ShareTrip.model_validate({**JAPAN, "items": []})
    with pytest.raises(ValidationError):
        ShareTrip.model_validate({**JAPAN, "items": [{"kind": "rocket", "title": "x", "price_minor": 1}]})
    with pytest.raises(ValidationError):
        ShareTrip.model_validate({**JAPAN, "author": "   "})


def test_alternatives_never_cost_more() -> None:
    items = [TripItem(kind="flight", title="Directo", price_minor=1000)]
    reply = apply_alternatives(items, {0: ("Con escala", 1200)}, 900)
    assert reply.items[0].title == "Directo" and not reply.fits
    reply = apply_alternatives(items, {0: ("Con escala", 700)}, 900)
    assert reply.items[0].was_title == "Directo" and reply.total_minor == 700 and reply.fits


def test_parse_reply_drops_bad_lines() -> None:
    alts = parse_reply(CHEAPER, record().items, "EUR")
    assert alts[0] == ("Vuelo con escala en Estambul", 69000)
    assert 8 not in alts
    # El JR Pass más caro llega aquí, pero apply_alternatives lo descarta.
    reply = apply_alternatives(list(record().items), alts, 180000)
    assert reply.items[2].title == "JR Pass de 7 días"
    assert reply.total_minor == 69000 + 45000 + 38000 + 4000 + 8000
    with pytest.raises(AdaptBusyError):
        parse_reply("no es json", record().items, "EUR")


def test_prompt_uses_whole_units() -> None:
    msgs = build_messages(record(), 180000, "es")
    assert "Vuelo directo Madrid-Tokio: 980 EUR" in msgs[1].content
    assert "Budget: 1800 EUR" in msgs[1].content
    assert "Spanish" in msgs[0].content
    yen = build_messages(record(currency="JPY"), 180000, "en")
    assert "98000 JPY" in yen[1].content


# --- Adaptar -------------------------------------------------------------------------------


async def test_adapt_uses_quota_once_then_cache() -> None:
    llm = FakeLLM([CHEAPER])
    svc, quota, _ = adapter(llm)
    first = await svc.adapt(DARIO, record(), 180000, "es")
    assert first.fits and first.remaining_today == 2
    # Otra persona con casi el mismo presupuesto: sale de la caché, sin modelo ni cupo.
    second = await svc.adapt(LAURA, record(), 179800, "es")
    assert second.total_minor == first.total_minor and second.remaining_today is None
    assert len(llm.calls) == 1 and quota.used == {(DARIO, "20261024"): 1}


async def test_adapt_skips_model_when_it_already_fits() -> None:
    llm = FakeLLM([])
    svc, _, _ = adapter(llm)
    reply = await svc.adapt(DARIO, record(), 300000, "es")
    assert reply.fits and not llm.calls and all(not i.changed for i in reply.items)


async def test_adapt_gives_quota_back_when_model_fails() -> None:
    svc, quota, cache = adapter(FakeLLM([LLMUnavailableError("caído")]))
    with pytest.raises(AdaptBusyError):
        await svc.adapt(DARIO, record(), 180000, "es")
    assert quota.used[(DARIO, "20261024")] == 0 and not cache.data


async def test_adapt_quota_exhausted() -> None:
    svc, _, _ = adapter(FakeLLM([CHEAPER, CHEAPER]), limit=1)
    await svc.adapt(DARIO, record(), 180000, "es")
    with pytest.raises(QuotaExceededError):
        await svc.adapt(DARIO, record(), 120000, "es")


# --- API -----------------------------------------------------------------------------------


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


def client(store: MemoryTrips, svc: TripAdapter | None = None) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), shared_trips=shared_trip_router(store, svc))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_full_flow() -> None:
    store = MemoryTrips()
    svc, _, _ = adapter(FakeLLM([CHEAPER]))
    async with client(store, svc) as c:
        shared = await c.post("/v1/shared-trips", json=JAPAN, headers=h(LAURA))
        assert shared.status_code == 201, shared.text
        code = shared.json()["code"]
        assert shared.json()["total_minor"] == 240000 and shared.json()["mine"]

        seen = await c.get(f"/v1/shared-trips/{code.lower()}", headers=h(DARIO))
        assert seen.status_code == 200 and not seen.json()["mine"]
        assert "owner" not in seen.text and LAURA not in seen.text

        # Copiar dos veces cuenta una; la autora no cuenta.
        await c.post(f"/v1/shared-trips/{code}/copy", headers=h(DARIO))
        again = await c.post(f"/v1/shared-trips/{code}/copy", headers=h(DARIO))
        await c.post(f"/v1/shared-trips/{code}/copy", headers=h(LAURA))
        assert again.json()["copies"] == 1
        assert (await c.get(f"/v1/shared-trips/{code}", headers=h(LAURA))).json()["copies"] == 1

        adapted = await c.post(
            f"/v1/shared-trips/{code}/adapt",
            json={"budget_minor": 180000, "language": "es"},
            headers=h(DARIO),
        )
        assert adapted.status_code == 200 and adapted.json()["fits"]
        assert adapted.headers["cache-control"] == "no-store"

        mine = await c.get("/v1/shared-trips/mine", headers=h(LAURA))
        assert [t["code"] for t in mine.json()["items"]] == [code]

        # Solo la autora puede dejar de compartirlo.
        assert (await c.delete(f"/v1/shared-trips/{code}", headers=h(DARIO))).status_code == 404
        assert (await c.delete(f"/v1/shared-trips/{code}", headers=h(LAURA))).status_code == 204
        assert (await c.get(f"/v1/shared-trips/{code}", headers=h(DARIO))).status_code == 404


async def test_api_errors() -> None:
    store = MemoryTrips()
    async with client(store) as c:
        assert (await c.get("/v1/shared-trips/!!", headers=h(DARIO))).status_code == 404
        assert (await c.get("/v1/shared-trips/7K2M9QXD")).status_code == 401
        for _ in range(MAX_PER_OWNER):
            await c.post("/v1/shared-trips", json=JAPAN, headers=h(LAURA))
        full = await c.post("/v1/shared-trips", json=JAPAN, headers=h(LAURA))
        assert full.status_code == 409
        # Sin modelo no existe la ruta de adaptar.
        code = next(iter(store.trips))
        r = await c.post(f"/v1/shared-trips/{code}/adapt", json={"budget_minor": 100}, headers=h(DARIO))
        assert r.status_code in (404, 405)


async def test_api_quota_and_busy() -> None:
    store = MemoryTrips()
    svc, _, _ = adapter(FakeLLM([LLMUnavailableError("caído")]), limit=1)
    async with client(store, svc) as c:
        code = (await c.post("/v1/shared-trips", json=JAPAN, headers=h(LAURA))).json()["code"]
        busy = await c.post(f"/v1/shared-trips/{code}/adapt", json={"budget_minor": 100000}, headers=h(DARIO))
        assert busy.status_code == 503 and busy.headers["retry-after"] == "30"
