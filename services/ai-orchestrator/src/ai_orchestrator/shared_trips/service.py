"""Flyra adapta un viaje compartido a tu presupuesto.

Paso a paso:
    1. ¿Ya lo adaptó alguien a este mismo presupuesto y en este idioma? Se
       devuelve lo guardado en Redis (gratis, sin gastar cupo). Con miles de
       personas copiando el mismo viaje famoso, casi todo sale de aquí.
    2. Si no, se gasta un uso del cupo diario de esa persona.
    3. Se le pasan al modelo las líneas numeradas con su precio y el
       presupuesto, y se le pide un JSON con alternativas más baratas.
    4. domain.apply_alternatives() aplica las reglas: nada más caro, nada
       inventado. Si el modelo falla, se devuelve el uso.

El presupuesto se redondea a la decena para la caché (1.795 € y 1.800 € son
el mismo viaje), pero el "¿cabe?" se calcula con lo que pidió la persona.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.flyra.service import LANGUAGE_NAMES
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.quota import (
    Quota,
    QuotaExceededError,
    QuotaUnavailableError,
    day_key,
    seconds_to_midnight,
)
from ai_orchestrator.shared_trips.domain import MAX_ITEMS, AdaptReply, TripItem, apply_alternatives
from ai_orchestrator.shared_trips.store import TripRecord

__all__ = [
    "ADAPT_SCHEMA",
    "QUOTA_PREFIX",
    "AdaptBusyError",
    "AdaptCache",
    "AdaptSettings",
    "RedisAdaptCache",
    "TripAdapter",
    "build_messages",
    "parse_reply",
]

log = logging.getLogger(__name__)

QUOTA_PREFIX = "ai:tripadapt:quota:v1"
_CACHE_PREFIX = "ai:tripadapt:v1"
# Un viaje compartido no cambia (no se puede editar): una semana de caché.
_CACHE_TTL_SECONDS = 7 * 24 * 3600

# Divisas sin decimales: el modelo ve "690", no "6.90".
_ZERO_DECIMAL = frozenset({"JPY", "KRW", "CLP", "ISK", "VND", "XOF", "XAF"})

SYSTEM_PROMPT = """You are Flyra, the travel assistant inside the NomadIQ app.
Someone shared a trip as a numbered list of things with their price. Another traveller
wants to copy it but has a smaller budget.

Propose cheaper alternatives so the total fits the budget, keeping the spirit of the trip
(same destination, same kind of experience). Change the expensive things first and keep
what is already cheap. Typical swaps: a flight with one stop or on a weekday, a smaller
hotel or a private room in a hostel, local buses instead of private transfers, local
restaurants instead of fine dining, doing an excursion on your own instead of guided.

For every line you change, return {{"line": <number>, "title": <new title in {language},
at most 10 words>, "price": <new price as a whole number in {currency}>}}.
Lines you keep: do not return them.

Rules:
- A new price must be LOWER than the original price of that line, and realistic.
- Never add new lines, never merge lines, never change what kind of thing a line is.
- If the budget is impossible, still make the best cheaper version you can.
- Answer only with the JSON object.
"""

ADAPT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "changes": {
            "type": "array",
            "maxItems": MAX_ITEMS,
            "items": {
                "type": "object",
                "properties": {
                    "line": {"type": "integer"},
                    "title": {"type": "string"},
                    "price": {"type": "integer"},
                },
                "required": ["line", "title", "price"],
            },
        }
    },
    "required": ["changes"],
}


class AdaptBusyError(Exception):
    """El modelo no está, tarda demasiado o contesta algo que no vale."""


class AdaptCache(Protocol):
    async def get(self, key: str) -> str | None: ...

    async def put(self, key: str, value: str) -> None: ...


class RedisAdaptCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, key: str) -> str | None:
        try:
            raw = await self._redis.get(f"{_CACHE_PREFIX}:{key}")
        except RedisError:
            # Sin caché se sigue funcionando: solo cuesta más modelo.
            return None
        return raw.decode() if isinstance(raw, bytes) else raw

    async def put(self, key: str, value: str) -> None:
        try:
            await self._redis.set(f"{_CACHE_PREFIX}:{key}", value, ex=_CACHE_TTL_SECONDS)
        except RedisError:
            log.warning("no se pudo guardar una adaptación en la caché")


@dataclass(frozen=True, slots=True)
class AdaptSettings:
    daily_limit: int
    timeout_seconds: float
    temperature: float = 0.3
    max_tokens: int = 900


def _factor(currency: str) -> int:
    return 1 if currency in _ZERO_DECIMAL else 100


def _language_name(tag: str) -> str:
    return LANGUAGE_NAMES.get(tag.split("-")[0], f"the language with code '{tag}'")


def build_messages(trip: TripRecord, budget_minor: int, language: str) -> list[ChatMessage]:
    f = _factor(trip.currency)
    lines = "\n".join(
        f"{i + 1}. [{item.kind}] {item.title}: {item.price_minor // f} {trip.currency}"
        for i, item in enumerate(trip.items)
    )
    total = sum(i.price_minor for i in trip.items) // f
    user = (
        f"Trip: {trip.title}, {trip.destination}, {trip.days} days.\n"
        f"{lines}\n"
        f"Original total: {total} {trip.currency}. Budget: {budget_minor // f} {trip.currency}."
    )
    return [
        ChatMessage(
            role="system",
            content=SYSTEM_PROMPT.format(language=_language_name(language), currency=trip.currency),
        ),
        ChatMessage(role="user", content=user),
    ]


def parse_reply(text: str, items: tuple[TripItem, ...], currency: str) -> dict[int, tuple[str, int]]:
    """Lo que contesta el modelo -> línea (desde 0) -> (título, precio en céntimos)."""
    try:
        rows = json.loads(text)["changes"]
    except (ValueError, KeyError, TypeError) as exc:
        raise AdaptBusyError("el modelo no devolvió cambios") from exc
    if not isinstance(rows, list):
        raise AdaptBusyError("el modelo no devolvió una lista")
    f = _factor(currency)
    out: dict[int, tuple[str, int]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        line, title, price = row.get("line"), row.get("title"), row.get("price")
        # bool es un int en Python: True no es la línea 1.
        if not isinstance(line, int) or isinstance(line, bool) or not 1 <= line <= len(items):
            continue
        if not isinstance(price, int) or isinstance(price, bool) or price < 0:
            continue
        if not isinstance(title, str) or not (clean := clean_text(title)[:80]):
            continue
        out.setdefault(line - 1, (clean, price * f))
    return out


class TripAdapter:
    def __init__(
        self,
        *,
        llm: LLMClient,
        quota: Quota,
        cache: AdaptCache,
        settings: AdaptSettings,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._llm = llm
        self._quota = quota
        self._cache = cache
        self._settings = settings
        self._clock = clock

    async def adapt(self, user_id: str, trip: TripRecord, budget_minor: int, language: str) -> AdaptReply:
        items = list(trip.items)
        f = _factor(trip.currency)
        # Si ya cabe, no hace falta el modelo: se copia tal cual.
        if sum(i.price_minor for i in items) <= budget_minor:
            return apply_alternatives(items, {}, budget_minor)

        bucket = max(1, round(budget_minor / (10 * f))) * 10 * f
        key = f"{trip.code}:{bucket}:{language}"
        cached = await self._cache.get(key)
        if cached is not None:
            try:
                alts = {int(k): (str(v[0]), int(v[1])) for k, v in json.loads(cached).items()}
            except (ValueError, TypeError, IndexError, AttributeError):
                alts = None
            if alts is not None:
                return apply_alternatives(items, alts, budget_minor)

        now = self._clock()
        day = day_key(now)
        try:
            remaining = await self._quota.take(user_id, day, self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise AdaptBusyError(str(exc)) from exc
        if remaining is None:
            raise QuotaExceededError(retry_after=seconds_to_midnight(now))
        try:
            text = await asyncio.wait_for(
                self._llm.chat(
                    build_messages(trip, bucket, language),
                    json_schema=ADAPT_SCHEMA,
                    temperature=self._settings.temperature,
                    max_tokens=self._settings.max_tokens,
                ),
                timeout=self._settings.timeout_seconds,
            )
            alts = parse_reply(text, trip.items, trip.currency)
        except (LLMError, TimeoutError, AdaptBusyError) as exc:
            await self._quota.give_back(user_id, day)
            raise AdaptBusyError(str(exc) or "tiempo agotado") from exc
        await self._cache.put(key, json.dumps({str(k): list(v) for k, v in alts.items()}))
        reply = apply_alternatives(items, alts, budget_minor)
        log.info(
            "viaje adaptado",
            extra={"lines": len(items), "changed": sum(i.changed for i in reply.items), "fits": reply.fits},
        )
        return reply.model_copy(update={"remaining_today": remaining})
