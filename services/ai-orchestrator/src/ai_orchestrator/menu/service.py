"""El cerebro del traductor de cartas: cupo, instrucciones y modelo.

Paso a paso:
    1. Cupo de hoy de esa persona (Redis). Gastado = "vuelve mañana" (429).
    2. Se numeran las líneas de la carta y se le pide al modelo un JSON con
       un plato por línea que SEA un plato (los títulos de sección, el wifi o
       el NIF se quedan fuera).
    3. Se valida lo que contesta el modelo: solo platos cuyo "original" esté
       de verdad en la carta, y con los textos recortados.

Si el modelo tarda o falla, se devuelve el uso (no cuenta) y la app ofrece
volver a intentarlo.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from ai_orchestrator.flyra.service import LANGUAGE_NAMES
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.menu.domain import (
    MAX_DISHES,
    MAX_FIELD_CHARS,
    Dish,
    MenuReply,
    MenuRequest,
)
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.quota import (
    Quota,
    QuotaExceededError,
    QuotaUnavailableError,
    day_key,
    seconds_to_midnight,
)

__all__ = ["MENU_SCHEMA", "MenuBusyError", "MenuService", "MenuSettings", "build_messages", "parse_reply"]

log = logging.getLogger(__name__)

QUOTA_PREFIX = "ai:menu:quota:v1"

# Las instrucciones van en inglés: los modelos pequeños las siguen mejor.
SYSTEM_PROMPT = """You are Flyra, the travel assistant inside the NomadIQ app.
The traveller photographed a restaurant menu. You get the lines of text read from that photo.

For every line that is an actual DISH or DRINK, return one entry. Skip section headings,
addresses, phone numbers, tax lines, wifi passwords and anything that is not food.

For each dish:
- "original": the dish name exactly as it appears in the menu line.
- "name": what it is, in {language}, short and plain (at most 12 words).
- "description": one short sentence about the main ingredients or how it is cooked.
  Leave it empty if you are not sure.
- "allergens": warn only about common allergens you are confident about
  (gluten, dairy, egg, peanut, shellfish, fish, soy, sesame, nuts). Say which one and why,
  in {language}, in at most 15 words. Leave empty if unsure.
- "order_phrase": how to ask for it politely in {place_language}, written in that language.
- "order_sounds": how that phrase sounds, written with Latin letters.
- "price": the price exactly as printed on the line, or empty if the line has none.

Rules:
- Never invent a dish that is not in the lines, and never change its price.
- If you cannot tell what a dish is, still include it with an empty description:
  say nothing rather than something wrong. Allergy warnings are advice, not a guarantee.
- Answer only with the JSON object.
"""

MENU_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "dishes": {
            "type": "array",
            "maxItems": MAX_DISHES,
            "items": {
                "type": "object",
                "properties": {
                    "original": {"type": "string"},
                    "name": {"type": "string"},
                    "description": {"type": "string"},
                    "allergens": {"type": "string"},
                    "order_phrase": {"type": "string"},
                    "order_sounds": {"type": "string"},
                    "price": {"type": "string"},
                },
                "required": ["original", "name"],
            },
        }
    },
    "required": ["dishes"],
}


class MenuBusyError(Exception):
    """El modelo no está, tarda demasiado o contesta algo que no vale."""


@dataclass(frozen=True, slots=True)
class MenuSettings:
    daily_limit: int
    timeout_seconds: float
    temperature: float = 0.2
    # Una carta de 40 platos con sus frases ocupa bastante.
    max_tokens: int = 1800


def _language_name(tag: str | None, fallback: str = "the local language") -> str:
    if not tag:
        return fallback
    base = tag.split("-")[0]
    return LANGUAGE_NAMES.get(base, f"the language with code '{tag}'")


def build_messages(request: MenuRequest) -> list[ChatMessage]:
    """Instrucciones + las líneas numeradas de la carta."""
    system = SYSTEM_PROMPT.format(
        language=_language_name(request.language, "English"),
        place_language=_language_name(request.place_language),
    )
    lines = "\n".join(f"{i + 1}. {line}" for i, line in enumerate(request.lines))
    return [
        ChatMessage(role="system", content=system),
        ChatMessage(role="user", content=f"Menu lines:\n{lines}"),
    ]


def _field(raw: Any) -> str:
    return clean_text(raw)[:MAX_FIELD_CHARS] if isinstance(raw, str) else ""


def parse_reply(text: str, request: MenuRequest) -> list[Dish]:
    """Lo que contesta el modelo, validado contra la carta de verdad."""
    try:
        rows = json.loads(text)["dishes"]
    except (ValueError, KeyError, TypeError) as exc:
        raise MenuBusyError("el modelo no devolvió una carta") from exc
    if not isinstance(rows, list):
        raise MenuBusyError("el modelo no devolvió una lista de platos")
    # Para comprobar que el plato está de verdad en la foto: se compara sin
    # mayúsculas ni espacios de sobra.
    seen: set[str] = set()
    joined = " \n ".join(request.lines).casefold()
    dishes: list[Dish] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        original = _field(row.get("original"))
        name = _field(row.get("name"))
        if not original or not name or original.casefold() not in joined:
            continue  # un plato inventado no se enseña
        key = original.casefold()
        if key in seen:
            continue
        seen.add(key)
        dishes.append(
            Dish(
                original=original,
                name=name,
                description=_field(row.get("description")),
                allergens=_field(row.get("allergens")),
                order_phrase=_field(row.get("order_phrase")),
                order_sounds=_field(row.get("order_sounds")),
                price=_field(row.get("price")),
            )
        )
        if len(dishes) >= MAX_DISHES:
            break
    if not dishes:
        raise MenuBusyError("ningún plato reconocible")
    return dishes


class MenuService:
    def __init__(
        self,
        *,
        llm: LLMClient,
        quota: Quota,
        settings: MenuSettings,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._llm = llm
        self._quota = quota
        self._settings = settings
        self._clock = clock

    async def translate(self, user_id: str, request: MenuRequest) -> MenuReply:
        now = self._clock()
        day = day_key(now)
        try:
            remaining = await self._quota.take(user_id, day, self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise MenuBusyError(str(exc)) from exc
        if remaining is None:
            raise QuotaExceededError(retry_after=seconds_to_midnight(now))
        try:
            text = await asyncio.wait_for(
                self._llm.chat(
                    build_messages(request),
                    json_schema=MENU_SCHEMA,
                    temperature=self._settings.temperature,
                    max_tokens=self._settings.max_tokens,
                ),
                timeout=self._settings.timeout_seconds,
            )
            dishes = parse_reply(text, request)
        except (LLMError, TimeoutError, MenuBusyError) as exc:
            # No es culpa de la persona: no le cuenta como carta.
            await self._quota.give_back(user_id, day)
            raise MenuBusyError(str(exc) or "tiempo agotado") from exc
        # Solo números en el log: nunca el texto de la carta.
        log.info(
            "carta traducida",
            extra={"lines": len(request.lines), "dishes": len(dishes), "remaining": remaining},
        )
        return MenuReply(dishes=dishes, remaining_today=remaining)
