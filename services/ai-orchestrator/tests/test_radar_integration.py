"""Radar contra un PostgreSQL REAL: mínimos de personas, percentiles, borrado."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from decimal import Decimal

import asyncpg
import pytest
from test_integration import _settings

from ai_orchestrator.erasure import PostgresEraser
from ai_orchestrator.radar.domain import MAX_POSTS_PER_DAY, RadarLimitError
from ai_orchestrator.radar.store import PostgresRadar
from ai_orchestrator.store import create_pool, migrate

pytestmark = pytest.mark.integration


@pytest.fixture
async def pool() -> AsyncIterator[asyncpg.Pool[asyncpg.Record]]:
    p = await create_pool(_settings())
    await migrate(p)
    yield p
    await p.close()


def city() -> str:
    # Una "ciudad" distinta por test (3 letras) para no mezclar datos.
    return "".join(chr(65 + int(c, 16) % 26) for c in uuid.uuid4().hex[:3])


async def test_minimums_percentiles_and_erasure(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresRadar(pool)
    c = city()
    people = [str(uuid.uuid4()) for _ in range(5)]
    for p in people[:2]:
        await store.report_scam(c, p, "taxi")
    assert (await store.city(c, people[0])).scams == []
    await store.report_scam(c, people[2], "taxi")
    await store.report_scam(c, people[2], "taxi")  # repetir no suma
    radar = await store.city(c, people[0])
    assert [(s.category, s.reporters) for s in radar.scams] == [("taxi", 3)]
    assert radar.my_scams == ["taxi"]

    for p, amount in zip(people[:4], (300, 400, 500, 600), strict=True):
        await store.add_price(c, p, "coffee", "JPY", Decimal(amount))
    assert (await store.city(c, people[0])).prices == []
    await store.add_price(c, people[4], "coffee", "JPY", Decimal(10000))
    # La misma persona cambia su precio: cuenta una vez, el último.
    await store.add_price(c, people[4], "coffee", "JPY", Decimal(700))
    prices = (await store.city(c, people[0])).prices
    assert len(prices) == 1
    assert (prices[0].reporters, prices[0].low, prices[0].median, prices[0].high) == (5, 400, 500, 600)

    await PostgresEraser(pool).erase(people[2])
    assert (await store.city(c, people[0])).scams == []


async def test_daily_limit(pool: asyncpg.Pool[asyncpg.Record]) -> None:
    store = PostgresRadar(pool)
    user = str(uuid.uuid4())
    cities = [city() for _ in range(MAX_POSTS_PER_DAY)]
    for c in cities:
        await store.add_price(c, user, "water", "EUR", Decimal("1.5"))
    with pytest.raises(RadarLimitError):
        await store.add_price(city(), user, "water", "EUR", Decimal("1.5"))
