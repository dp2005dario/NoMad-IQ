"""Quedadas contra un PostgreSQL REAL (el de docker compose).

Solo se ejecutan con:

    make up && make test-integration      # o: uv run pytest -m integration
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import asyncpg
import pytest
from test_integration import _settings

from ai_orchestrator.erasure import PostgresEraser
from ai_orchestrator.meetups.api import Me, NewMeetupBody
from ai_orchestrator.meetups.domain import (
    MAX_ACTIVE_CREATED,
    MeetupFullError,
    MeetupLimitError,
    MeetupNotFoundError,
    Member,
)
from ai_orchestrator.meetups.store import PostgresMeetups
from ai_orchestrator.store import create_pool, migrate

pytestmark = pytest.mark.integration


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def person() -> str:
    return str(uuid.uuid4())


def me(user: str, name: str = "Ana", *, visible: bool = True) -> Member:
    return Member(user_id=user, name=name, country="ES", visible=visible)


def draft(city: str, now: datetime, capacity: int = 2) -> NewMeetupBody:
    return NewMeetupBody(
        city=city,
        kind="walk",
        title="Paseo al atardecer",
        place="Mirador de Santa Luzia",
        starts_at=now + timedelta(hours=5),
        capacity=capacity,
        me=Me(name="x"),
    )


def city() -> str:
    # Una "ciudad" distinta por prueba: las pruebas no se pisan entre sí.
    return "".join(chr(65 + b % 26) for b in uuid.uuid4().bytes[:3])


async def test_last_seat_race_and_limits(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresMeetups(pool)
    now = datetime.now(UTC)
    c = city()
    organizer = person()
    m = await store.create(organizer, me(organizer, "Dario"), draft(c, now), now)
    assert [p.name for p in m.members] == ["Dario"]

    # Dos personas a la vez por la última plaza: entra solo una.
    a, b = person(), person()
    results = await asyncio.gather(
        store.join(m.meetup_id, me(a), now), store.join(m.meetup_id, me(b), now), return_exceptions=True
    )
    assert sum(isinstance(r, MeetupFullError) for r in results) == 1
    listed = await store.list_city(c, now)
    assert len(listed) == 1 and len(listed[0].members) == 2

    # Tope de quedadas propuestas.
    for _ in range(MAX_ACTIVE_CREATED - 1):
        await store.create(organizer, me(organizer), draft(c, now), now)
    with pytest.raises(MeetupLimitError):
        await store.create(organizer, me(organizer), draft(c, now), now)
    assert len(await store.mine(organizer, now)) == MAX_ACTIVE_CREATED

    # Quien la propuso no se "va", la cancela.
    with pytest.raises(MeetupNotFoundError):
        await store.leave(m.meetup_id, organizer, now)
    await store.cancel(m.meetup_id, organizer)
    with pytest.raises(MeetupNotFoundError):
        await store.cancel(m.meetup_id, organizer)


async def test_reports_sweep_and_erasure(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresMeetups(pool)
    now = datetime.now(UTC)
    c = city()
    organizer, guest = person(), person()
    m = await store.create(organizer, me(organizer), draft(c, now, capacity=4), now)
    await store.join(m.meetup_id, me(guest, visible=False), now)

    for _ in range(3):
        await store.report(m.meetup_id, guest)
    other = await store.create(guest, me(guest), draft(c, now), now)
    await store.report(other.meetup_id, organizer)
    await store.report(other.meetup_id, person())
    await store.report(other.meetup_id, person())
    # 3 denuncias de personas distintas: oculta. 1 repetida: sigue.
    assert [x.meetup_id for x in await store.list_city(c, now)] == [m.meetup_id]

    # El barrido: una semana después ya no queda nada de esta ciudad.
    assert await store.sweep(now + timedelta(days=8)) >= 2
    assert await store.list_city(c, now) == []

    # Borrar mis datos: las mías se cancelan y salgo de las otras.
    mine = await store.create(organizer, me(organizer), draft(c, now, capacity=4), now)
    theirs = await store.create(guest, me(guest), draft(c, now, capacity=4), now)
    await store.join(theirs.meetup_id, me(organizer), now)
    await store.report(theirs.meetup_id, organizer)
    report = await PostgresEraser(pool).erase(organizer)
    assert report.meetups_cancelled == 1
    left = await store.list_city(c, now)
    assert [x.meetup_id for x in left] == [theirs.meetup_id]
    assert left[0].member(organizer) is None
    assert mine.meetup_id not in {x.meetup_id for x in left}
    assert await pool.fetchval("SELECT count(*) FROM ai.meetup_reports WHERE user_id = $1", organizer) == 0
