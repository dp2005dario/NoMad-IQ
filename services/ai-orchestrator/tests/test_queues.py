"""Tests de "Sin colas": la API con un almacén de mentira."""

from __future__ import annotations

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.queues.api import queues_router
from ai_orchestrator.queues.domain import PlaceQueue, QueueLimitError, WaitHour, WaitNow


class MemoryQueues:
    def __init__(self) -> None:
        self.reports: list[tuple[str, str, int, int]] = []
        self.limit = False

    async def place(self, place: str, user_id: str, local_hour: int) -> PlaceQueue:
        mine = [r for r in self.reports if r[0] == place]
        return PlaceQueue(
            place=place,
            now=WaitNow(wait=2, reporters=len(mine), minutes_ago=5) if len(mine) >= 2 else None,
            hours=[WaitHour(hour=10, wait=1, reporters=4)],
            reported_this_hour=any(r[1] == user_id and r[2] == local_hour for r in mine),
        )

    async def report(self, place: str, user_id: str, local_hour: int, wait: int) -> None:
        if self.limit:
            raise QueueLimitError(user_id)
        self.reports.append((place, user_id, local_hour, wait))


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


async def test_queue_api_validates_and_never_says_who() -> None:
    store = MemoryQueues()
    app = create_api(InMemoryStore(), queues=queues_router(store))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        for user in ("a", "b"):
            r = await c.post("/v1/queues/Q243", json={"wait": 2, "local_hour": 11}, headers=h(user))
            assert r.status_code == 204
        body = (await c.get("/v1/queues/Q243?hour=11", headers=h("a"))).json()
        assert body["now"] == {"wait": 2, "reporters": 2, "minutes_ago": 5}
        assert body["reported_this_hour"] is True
        assert "user" not in str(body)
        # Validación: sitios que no son Wikidata, esperas y horas imposibles.
        assert (await c.get("/v1/queues/eiffel?hour=1", headers=h("a"))).status_code in (400, 422)
        assert (await c.get("/v1/queues/Q243?hour=24", headers=h("a"))).status_code in (400, 422)
        for bad in ({"wait": 5, "local_hour": 1}, {"wait": 1, "local_hour": -1}, {"wait": 1}):
            assert (await c.post("/v1/queues/Q243", json=bad, headers=h("a"))).status_code in (400, 422)
        assert (await c.get("/v1/queues/Q243?hour=1")).status_code == 401
        store.limit = True
        r = await c.post("/v1/queues/Q243", json={"wait": 0, "local_hour": 1}, headers=h("a"))
        assert r.status_code == 429
