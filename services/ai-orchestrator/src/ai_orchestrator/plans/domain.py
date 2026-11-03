"""Las reglas de los planes del grupo (sin base de datos: fácil de probar)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime

# Topes: con esto un viaje nunca crece sin límite (y la base de datos tampoco).
MAX_PLANS = 60
MAX_PLANS_PER_MEMBER = 15
# Sitios de "¿Qué os apetece?" y zonas para dormir (pantalla Grupo): van
# aparte y no gastan el tope de planes de nadie.
MAX_EXTRAS = 40

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
    # Ya está "en el plan del grupo" (alguien del match lo añadió).
    planned: bool = False
    # "plan" (Elegid planes), "crave" (¿Qué os apetece?) o "sleep" (dónde dormir).
    kind: str = "plan"


@dataclass(frozen=True, slots=True)
class Board:
    """Los planes de un viaje, tal como los ve un miembro."""

    negotiation_id: str
    my_seat: int
    # Los asientos que cuentan para el match (los de cuentas borradas, no).
    active_seats: frozenset[int]
    plans: tuple[Plan, ...]
    # El nombre de cada asiento (el que puso al unirse, o "Viajero 2").
    names: dict[int, str] = field(default_factory=dict)


def is_match(plan: Plan, active_seats: frozenset[int]) -> bool:
    """Match viajero = dos o más miembros activos han dicho que sí (como en la
    maqueta: "solo salen los sitios que habéis marcado dos o más")."""
    return sum(1 for seat in active_seats if plan.votes.get(seat) is True) >= 2


def match_with(plan: Plan, board: Board) -> list[str]:
    """Con quién coincides en un plan: los nombres de los OTROS que dijeron
    que sí. Solo se cuenta si tú también dijiste que sí y hay match: los votos
    son secretos hasta que coincidís."""
    if plan.votes.get(board.my_seat) is not True or not is_match(plan, board.active_seats):
        return []
    return [
        board.names.get(seat, f"Viajero {seat}")
        for seat in sorted(board.active_seats)
        if seat != board.my_seat and plan.votes.get(seat) is True
    ]


def has_voted(seat: int, board: Board) -> bool:
    """Si esa persona ya ha votado algún plan (para "ya votó" / "sin entrar")."""
    return any(seat in p.votes for p in board.plans if p.kind == "plan")


class NotMatchError(Exception):
    """Solo se mete en el plan del grupo un match en el que tú dijiste sí."""


class PlanLimitError(Exception):
    """Demasiados planes en el viaje o de esta persona."""
