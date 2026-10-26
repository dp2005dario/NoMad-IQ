"""Radar local en PostgreSQL (ver migrations/0015_radar.sql)."""

from __future__ import annotations

from decimal import Decimal
from typing import Protocol, cast

import asyncpg

from ai_orchestrator.radar.domain import (
    MAX_POSTS_PER_DAY,
    MIN_PRICE_REPORTERS,
    MIN_SCAM_REPORTERS,
    PRICE_DAYS,
    SCAM_DAYS,
    CityRadar,
    PriceItem,
    PriceRange,
    RadarLimitError,
    ScamCategory,
    ScamCount,
)
from ai_orchestrator.store import Conn, Pool, StoreError

_DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


class RadarStore(Protocol):
    async def city(self, city: str, user_id: str) -> CityRadar: ...

    async def report_scam(self, city: str, user_id: str, category: ScamCategory) -> None: ...

    async def withdraw_scam(self, city: str, user_id: str, category: ScamCategory) -> None: ...

    async def add_price(
        self, city: str, user_id: str, item: PriceItem, currency: str, amount: Decimal
    ) -> None: ...


class PostgresRadar:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def city(self, city: str, user_id: str) -> CityRadar:
        try:
            async with self._pool.acquire() as conn:
                scams = await conn.fetch(
                    "SELECT category, count(*) AS n FROM ai.radar_scam_reports"
                    " WHERE city = $1 AND reported_on >= current_date - $2::int"
                    " GROUP BY category HAVING count(*) >= $3 ORDER BY n DESC, category",
                    city,
                    SCAM_DAYS,
                    MIN_SCAM_REPORTERS,
                )
                prices = await conn.fetch(
                    "SELECT item, currency, count(*) AS n,"
                    " percentile_cont(0.25) WITHIN GROUP (ORDER BY amount) AS low,"
                    " percentile_cont(0.5) WITHIN GROUP (ORDER BY amount) AS median,"
                    " percentile_cont(0.75) WITHIN GROUP (ORDER BY amount) AS high"
                    " FROM ai.radar_prices WHERE city = $1 AND paid_on >= current_date - $2::int"
                    " GROUP BY item, currency HAVING count(*) >= $3 ORDER BY item, n DESC",
                    city,
                    PRICE_DAYS,
                    MIN_PRICE_REPORTERS,
                )
                mine = await conn.fetch(
                    "SELECT category FROM ai.radar_scam_reports"
                    " WHERE city = $1 AND user_id = $2 AND reported_on >= current_date - $3::int",
                    city,
                    user_id,
                    SCAM_DAYS,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"leer radar: {exc}") from exc
        return CityRadar(
            city=city,
            scams=[ScamCount(category=r["category"], reporters=int(r["n"])) for r in scams],
            prices=[
                PriceRange(
                    item=r["item"],
                    currency=r["currency"],
                    reporters=int(r["n"]),
                    low=round(float(r["low"]), 2),
                    median=round(float(r["median"]), 2),
                    high=round(float(r["high"]), 2),
                )
                for r in prices
            ],
            my_scams=[cast(ScamCategory, r["category"]) for r in mine],
        )

    async def _check_limit(self, conn: Conn, user_id: str) -> None:
        # Bloqueo por persona (dentro de la transacción) para contar bien.
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('radar:' || $1))", user_id)
        today = await conn.fetchval(
            "SELECT (SELECT count(*) FROM ai.radar_scam_reports"
            " WHERE user_id = $1 AND reported_on = current_date)"
            " + (SELECT count(*) FROM ai.radar_prices WHERE user_id = $1 AND paid_on = current_date)",
            user_id,
        )
        if int(today or 0) >= MAX_POSTS_PER_DAY:
            raise RadarLimitError(user_id)

    async def report_scam(self, city: str, user_id: str, category: ScamCategory) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                await self._check_limit(conn, user_id)
                await conn.execute(
                    "INSERT INTO ai.radar_scam_reports (city, category, user_id) VALUES ($1, $2, $3)"
                    " ON CONFLICT (city, category, user_id) DO UPDATE SET reported_on = current_date",
                    city,
                    category,
                    user_id,
                )
                # Barrido de lo caducado de esa ciudad (con índice: barato).
                await conn.execute(
                    "DELETE FROM ai.radar_scam_reports"
                    " WHERE city = $1 AND reported_on < current_date - $2::int",
                    city,
                    SCAM_DAYS,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"avisar timo: {exc}") from exc

    async def withdraw_scam(self, city: str, user_id: str, category: ScamCategory) -> None:
        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    "DELETE FROM ai.radar_scam_reports WHERE city = $1 AND category = $2 AND user_id = $3",
                    city,
                    category,
                    user_id,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"quitar aviso: {exc}") from exc

    async def add_price(
        self, city: str, user_id: str, item: PriceItem, currency: str, amount: Decimal
    ) -> None:
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                await self._check_limit(conn, user_id)
                await conn.execute(
                    "INSERT INTO ai.radar_prices (city, item, currency, amount, user_id)"
                    " VALUES ($1, $2, $3, $4, $5)"
                    " ON CONFLICT (city, item, user_id) DO UPDATE SET currency = EXCLUDED.currency,"
                    " amount = EXCLUDED.amount, paid_on = current_date",
                    city,
                    item,
                    currency,
                    amount,
                    user_id,
                )
                await conn.execute(
                    "DELETE FROM ai.radar_prices WHERE city = $1 AND paid_on < current_date - $2::int",
                    city,
                    PRICE_DAYS,
                )
        except _DB_ERRORS as exc:
            raise StoreError(f"apuntar precio: {exc}") from exc
