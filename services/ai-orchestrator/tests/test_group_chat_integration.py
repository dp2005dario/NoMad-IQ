"""Chat del viaje contra un PostgreSQL REAL (el de docker compose).

Solo se ejecutan con:

    make up && make test-integration      # o: uv run pytest -m integration
"""

from __future__ import annotations

import asyncio

import asyncpg
import pytest
from test_plans_integration import person, pool, trip

from ai_orchestrator.erasure import PostgresEraser
from ai_orchestrator.group_chat.domain import TripKind
from ai_orchestrator.group_chat.store import PostgresChat, TripNotFoundError

pytestmark = pytest.mark.integration

__all__ = ["pool"]


async def test_chat_order_names_kind_and_erasure(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    ana, beto, stranger = person(), person(), person()
    trip_id = await trip(pool, ana, beto)
    store = PostgresChat(pool)

    first = await store.post(trip_id, ana, "Hola")
    # Muchos a la vez: los números salen en orden y no se pierde ninguno.
    await asyncio.gather(*(store.post(trip_id, beto if i % 2 else ana, f"m{i}") for i in range(20)))
    await store.post_flyra(trip_id, "Soy Flyra")

    page = await store.page(trip_id, ana, after=None)
    ids = [m.message_id for m in page.messages]
    assert ids == sorted(ids) and len(ids) == 22
    assert page.messages[-1].seat is None
    assert page.kind is TripKind.FRIENDS and page.title == "Planes"
    newer = await store.page(trip_id, beto, after=first.message_id, limit=5)
    assert len(newer.messages) == 5 and newer.messages[0].message_id > first.message_id

    await store.set_name(trip_id, beto, "Mamá")
    await store.set_kind(trip_id, beto, TripKind.FAMILY)
    page = await store.page(trip_id, ana, after=None, limit=1)
    assert [m.name for m in page.members] == [page.members[0].name, "Mamá"]
    assert page.kind is TripKind.FAMILY
    assert await store.others(trip_id, ana) == [beto]

    with pytest.raises(TripNotFoundError):
        await store.post(trip_id, stranger, "hola")
    with pytest.raises(TripNotFoundError):
        await store.page(trip_id, stranger, after=None)

    # Beto borra su cuenta: sus mensajes y su nombre se van; los de Ana y Flyra, no.
    await PostgresEraser(pool).erase(beto)
    page = await store.page(trip_id, ana, after=None)
    assert {m.seat for m in page.messages} == {1, None}
    assert page.members[1].name != "Mamá" and not page.members[1].active
    assert await store.others(trip_id, ana) == []
