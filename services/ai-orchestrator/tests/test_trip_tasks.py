"""Pruebas del reparto de tareas de un viaje en grupo (store en memoria)."""

from __future__ import annotations

import uuid
from dataclasses import replace

import httpx
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.trip_tasks.api import task_router
from ai_orchestrator.trip_tasks.store import (
    MAX_TASKS,
    NotAllowedError,
    Task,
    TaskLimitError,
    TaskList,
    TaskNotFoundError,
    TripNotFoundError,
)

TRIP = str(uuid.uuid4())
DARIO = "11111111-1111-4111-8111-111111111111"
NOELIA = "22222222-2222-4222-8222-222222222222"
MARTA = "44444444-4444-4444-8444-444444444444"
STRANGER = "33333333-3333-4333-8333-333333333333"


class MemoryTasks:
    def __init__(self) -> None:
        self.seats = {DARIO: 1, NOELIA: 2, MARTA: 3}
        self.names = {1: "Darío", 2: "Noelia", 3: "Marta"}
        self.tasks: list[Task] = []

    def _seat(self, trip: str, user: str) -> int:
        if trip != TRIP or user not in self.seats:
            raise TripNotFoundError(trip)
        return self.seats[user]

    def _list(self, seat: int) -> TaskList:
        return TaskList(TRIP, seat, self.names, tuple(self.tasks))

    def _find(self, task_id: str) -> int:
        for i, t in enumerate(self.tasks):
            if t.task_id == task_id:
                return i
        raise TaskNotFoundError(task_id)

    async def list(self, negotiation_id: str, user_id: str) -> TaskList:
        return self._list(self._seat(negotiation_id, user_id))

    async def add(self, negotiation_id: str, user_id: str, label: str) -> TaskList:
        seat = self._seat(negotiation_id, user_id)
        if len(self.tasks) >= MAX_TASKS:
            raise TaskLimitError(negotiation_id)
        self.tasks.append(Task(str(uuid.uuid4()), label, seat, None, False))
        return self._list(seat)

    async def take(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList:
        seat = self._seat(negotiation_id, user_id)
        i = self._find(task_id)
        t = self.tasks[i]
        self.tasks[i] = replace(t, owner_seat=None if t.owner_seat == seat else seat)
        return self._list(seat)

    async def done(self, negotiation_id: str, user_id: str, task_id: str, *, done: bool) -> TaskList:
        seat = self._seat(negotiation_id, user_id)
        i = self._find(task_id)
        self.tasks[i] = replace(self.tasks[i], done=done)
        return self._list(seat)

    async def delete(self, negotiation_id: str, user_id: str, task_id: str) -> TaskList:
        seat = self._seat(negotiation_id, user_id)
        i = self._find(task_id)
        if seat not in (self.tasks[i].added_by_seat, 1):
            raise NotAllowedError(task_id)
        self.tasks.pop(i)
        return self._list(seat)


def h(user: str) -> dict[str, str]:
    return {"X-User-ID": user, "X-User-Roles": "USER"}


async def test_split_the_tasks_of_the_trip() -> None:
    store = MemoryTasks()
    app = create_api(InMemoryStore(), tasks=task_router(store))
    base = f"/v1/group-negotiations/{TRIP}/tasks"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get(base, headers=h(STRANGER))).status_code == 404
        resp = await c.post(base, json={"label": "  Reservar   el hotel "}, headers=h(NOELIA))
        assert resp.status_code == 201
        task = resp.json()["tasks"][0]
        assert task["label"] == "Reservar el hotel" and task["owner"] is None and task["added_by_me"]
        assert (await c.post(base, json={"label": "   "}, headers=h(NOELIA))).status_code == 400

        # Darío se encarga; Noelia ve quién es.
        tid = task["task_id"]
        mine = (await c.put(f"{base}/{tid}/take", headers=h(DARIO))).json()["tasks"][0]
        assert mine["mine"] and mine["owner"] == "Darío"
        seen = (await c.get(base, headers=h(NOELIA))).json()["tasks"][0]
        assert seen["owner"] == "Darío" and not seen["mine"]
        done = await c.put(f"{base}/{tid}/done", json={"done": True}, headers=h(DARIO))
        assert done.json()["tasks"][0]["done"] is True
        # Otra vez "me encargo yo" = la suelta.
        assert (await c.put(f"{base}/{tid}/take", headers=h(DARIO))).json()["tasks"][0]["owner"] is None

        # Solo quien la puso o el organizador la quitan.
        assert (await c.delete(f"{base}/{tid}", headers=h(MARTA))).status_code == 403
        assert (await c.delete(f"{base}/{tid}", headers=h(DARIO))).json()["tasks"] == []
        assert (await c.put(f"{base}/{tid}/take", headers=h(DARIO))).status_code == 404

        store.tasks = [Task(str(uuid.uuid4()), "x", 1, None, False) for _ in range(MAX_TASKS)]
        assert (await c.post(base, json={"label": "Una más"}, headers=h(DARIO))).status_code == 409
