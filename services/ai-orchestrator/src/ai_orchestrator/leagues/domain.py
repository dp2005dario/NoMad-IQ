"""Las reglas de las ligas de cromos (sin base de datos: fácil de probar)."""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.negotiation.domain import clean_text

MAX_MEMBERS = 30
MAX_CARDS = 1000
MAX_PENDING = 20
# Los cambios ya decididos más antiguos se borran pasado este número.
MAX_SWAPS_KEPT = 500

Rarity = Literal["legendary", "epic", "rare", "common"]
POINTS: dict[Rarity, int] = {"legendary": 150, "epic": 80, "rare": 40, "common": 10}
SwapStatus = Literal["pending", "accepted", "declined"]


def rarity_of(year: int | None) -> Rarity:
    """La misma regla que la app (mobile/lib/features/passport/passport.dart)."""
    if year is None:
        return "common"
    if year < 1000:
        return "legendary"
    if year < 1600:
        return "epic"
    if year < 1900:
        return "rare"
    return "common"


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


class Card(BaseModel):
    """Un cromo: el monumento (su id de Wikidata), su nombre y su año."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    qid: str = Field(pattern=r"^Q[1-9][0-9]{0,11}$")
    name: Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]
    year: int | None = Field(default=None, ge=-10000, le=2100)
    # El mes en que lo sacaste ("2026-10"): para la liga del mes.
    month: str = Field(pattern=r"^20[0-9]{2}-(0[1-9]|1[0-2])$")


@dataclass(frozen=True, slots=True)
class Member:
    seat: int
    user_id: str
    name: str
    cards: tuple[Card, ...] = ()
    countries: int = 0
    city: str | None = None
    city_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class Swap:
    swap_id: str
    from_seat: int
    to_seat: int
    give: Card
    want: Card
    status: SwapStatus
    created_at: datetime


@dataclass(frozen=True, slots=True)
class League:
    league_id: str
    title: str
    invite_code: str
    members: tuple[Member, ...]
    swaps: tuple[Swap, ...] = field(default=())

    def member(self, user_id: str) -> Member | None:
        return next((m for m in self.members if m.user_id == user_id), None)

    def seat(self, seat: int) -> Member | None:
        return next((m for m in self.members if m.seat == seat), None)


def points(cards: Iterable[Card], month: str | None = None) -> int:
    """Puntos de unos cromos; con [month], solo los sacados ese mes."""
    return sum(POINTS[rarity_of(c.year)] for c in cards if month is None or c.month == month)


def received(league: League, seat: int) -> list[Card]:
    """Las copias que ha recibido [seat] en cambios aceptados."""
    out: list[Card] = []
    for s in league.swaps:
        if s.status != "accepted":
            continue
        if s.from_seat == seat:
            out.append(s.want)
        elif s.to_seat == seat:
            out.append(s.give)
    return out


class SwapNotAllowedError(Exception):
    """El cambio no vale (ya lo tiene, no es tuyo...)."""


def check_swap(league: League, me: Member, them: Member, give_qid: str, want_qid: str) -> tuple[Card, Card]:
    """¿Vale este cambio? Devuelve los dos cromos o lanza SwapNotAllowedError.

    Reglas: das uno que has ganado TÚ (una copia no se vuelve a cambiar) y que
    él no tiene; pides uno que ha ganado ÉL y que tú no tienes (ni ganado ni
    recibido).
    """
    if me.seat == them.seat:
        raise SwapNotAllowedError("contigo mismo no")
    give = next((c for c in me.cards if c.qid == give_qid), None)
    want = next((c for c in them.cards if c.qid == want_qid), None)
    if give is None or want is None:
        raise SwapNotAllowedError("ese cromo no está")
    mine = {c.qid for c in me.cards} | {c.qid for c in received(league, me.seat)}
    theirs = {c.qid for c in them.cards} | {c.qid for c in received(league, them.seat)}
    if want.qid in mine or give.qid in theirs:
        raise SwapNotAllowedError("ya lo tiene")
    return give, want
