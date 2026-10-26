"""Las reglas de los planes del grupo (sin base de datos: fácil de probar)."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime

# Topes: con esto un viaje nunca crece sin límite (y la base de datos tampoco).
MAX_PLANS = 60
MAX_PLANS_PER_MEMBER = 15

# La foto y el artículo solo pueden ser de Wikimedia: así nadie mete en la
# app de los demás un enlace a cualquier web.
PHOTO_RE = re.compile(r"^https://upload\.wikimedia\.org/[^\s\"'<>]{1,450}$")
ARTICLE_RE = re.compile(r"^https://[a-z\-]{2,12}\.(m\.)?wikipedia\.org/wiki/[^\s\"'<>]{1,400}$")


@dataclass(frozen=True, slots=True)
class Plan:
    plan_id: str
    added_by_seat: int
    title: str
    note: str | None
    wikidata_id: str | None
    photo_url: str | None
    article_url: str | None
    created_at: datetime
    # Los votos por asiento (True = sí).
    votes: dict[int, bool]


@dataclass(frozen=True, slots=True)
class Board:
    """Los planes de un viaje, tal como los ve un miembro."""

    negotiation_id: str
    my_seat: int
    # Los asientos que cuentan para el match (los de cuentas borradas, no).
    active_seats: frozenset[int]
    plans: tuple[Plan, ...]


def is_match(plan: Plan, active_seats: frozenset[int]) -> bool:
    """Match = todos los miembros activos (al menos dos) han dicho que sí."""
    if len(active_seats) < 2:
        return False
    return all(plan.votes.get(seat) is True for seat in active_seats)


class PlanLimitError(Exception):
    """Demasiados planes en el viaje o de esta persona."""
