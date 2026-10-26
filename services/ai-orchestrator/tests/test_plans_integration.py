"""Elegid planes contra un PostgreSQL REAL (el de docker compose).

Solo se ejecutan con:

    make up && make test-integration      # o: uv run pytest -m integration
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import asyncpg
import pytest
from test_integration import _settings

from ai_orchestrator.erasure import PostgresEraser
from ai_orchestrator.negotiation.domain import GroupOption
from ai_orchestrator.negotiation.store import NewNegotiation, PostgresNegotiations
from ai_orchestrator.plans.api import NewPlanBody
from ai_orchestrator.plans.domain import MAX_PLANS_PER_MEMBER, PlanLimitError, is_match
from ai_orchestrator.plans.store import PlanNotFoundError, PostgresPlans, TripNotFoundError
from ai_orchestrator.store import create_pool, migrate

pytestmark = pytest.mark.integration

OPTIONS = (
    GroupOption(option_id="lisboa", label="Lisboa", price_minor=30000),
    GroupOption(option_id="roma", label="Roma", price_minor=40000),
)


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def person() -> str:
    return str(uuid.uuid4())


async def trip(pool: asyncpg.Pool[asyncpg.Record], *members: str) -> str:
    record = await PostgresNegotiations(pool, requests_topic="ai.group-negotiation-requests.v1").create(
        NewNegotiation(
            organizer_id=members[0],
            title="Planes",
            currency="EUR",
            language="es",
            options=OPTIONS,
            member_ids=members,
            max_rounds=3,
            deadline=datetime.now(UTC) + timedelta(hours=24),
        )
    )
    return record.negotiation_id


async def test_plans_votes_and_erasure(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    ana, beto, carla, stranger = person(), person(), person(), person()
    trip_id = await trip(pool, ana, beto, carla)
    store = PostgresPlans(pool)

    belem = NewPlanBody(title="Torre de Belém", wikidata_id="Q193208")
    board = await store.add(trip_id, ana, [belem, NewPlanBody(title="Fado", note="21:30")])
    assert [p.title for p in board.plans] == ["Torre de Belém", "Fado"]
    # La misma atracción no se repite.
    assert len((await store.add(trip_id, beto, [belem])).plans) == 2
    with pytest.raises(TripNotFoundError):
        await store.board(trip_id, stranger)

    first = board.plans[0].plan_id
    await store.vote(trip_id, ana, first, yes=True)
    await store.vote(trip_id, beto, first, yes=False)
    board = await store.vote(trip_id, beto, first, yes=True)  # cambia de opinión
    assert board.plans[0].votes == {1: True, 2: True}
    assert not is_match(board.plans[0], board.active_seats)

    # Carla borra su cuenta: su asiento deja de contar y ya hay match.
    await PostgresEraser(pool).erase(carla)
    board = await store.board(trip_id, ana)
    assert board.active_seats == frozenset({1, 2})
    assert is_match(board.plans[0], board.active_seats)

    # Solo quien lo puso lo quita.
    fado = board.plans[1].plan_id
    with pytest.raises(PlanNotFoundError):
        await store.delete(trip_id, beto, fado)
    assert len((await store.delete(trip_id, ana, fado)).plans) == 1
    with pytest.raises(PlanNotFoundError):
        await store.vote(trip_id, ana, str(uuid.uuid4()), yes=True)


async def test_plan_limits(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    ana, beto = person(), person()
    trip_id = await trip(pool, ana, beto)
    store = PostgresPlans(pool)
    await store.add(trip_id, ana, [NewPlanBody(title=f"Plan {i}") for i in range(MAX_PLANS_PER_MEMBER)])
    with pytest.raises(PlanLimitError):
        await store.add(trip_id, ana, [NewPlanBody(title="Uno más")])
    assert (
        len((await store.add(trip_id, beto, [NewPlanBody(title="El mío")])).plans) == MAX_PLANS_PER_MEMBER + 1
    )
