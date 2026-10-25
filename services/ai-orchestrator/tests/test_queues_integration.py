"""Sin colas contra un PostgreSQL REAL: mínimos de personas, mediana, borrado."""

from __future__ import annotations

import random
import uuid
from collections.abc import AsyncIterator

import asyncpg
import pytest
from test_integration import _settings

from ai_orchestrator.erasure import PostgresEraser
from ai_orchestrator.queues.domain import MAX_REPORTS_PER_DAY, QueueLimitError
from ai_orchestrator.queues.store import PostgresQueues
from ai_orchestrator.store import create_pool, migrate

pytestmark = pytest.mark.integration


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def place() -> str:
    # Un "sitio" distinto por test para no mezclar datos.
    return f"Q{random.randint(10**9, 10**11)}"  # noqa: S311 - no es criptografía


async def test_minimums_median_and_erasure(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresQueues(pool)
    q = place()
    people = [str(uuid.uuid4()) for _ in range(3)]
    await store.report(q, people[0], 10, 1)
    first = await store.place(q, people[0], 10)
    assert first.now is None and first.hours == [] and first.reported_this_hour
    await store.report(q, people[1], 10, 3)
    await store.report(q, people[1], 10, 4)  # repetir la misma hora cambia, no suma
    now = (await store.place(q, people[2], 10)).now
    assert now is not None and now.reporters == 2 and now.minutes_ago == 0
    await store.report(q, people[2], 10, 2)
    hours = (await store.place(q, people[2], 9)).hours
    assert [(x.hour, x.wait, x.reporters) for x in hours] == [(10, 2, 3)]

    await PostgresEraser(pool).erase(people[1])
    assert (await store.place(q, people[0], 10)).hours == []


async def test_daily_limit(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresQueues(pool)
    user = str(uuid.uuid4())
    for hour in range(MAX_REPORTS_PER_DAY):
        await store.report(place(), user, hour % 24, 0)
    with pytest.raises(QueueLimitError):
        await store.report(place(), user, 3, 0)
