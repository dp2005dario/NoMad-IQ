"""Las reglas de las quedadas (sin base de datos: fácil de probar)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

MeetupKind = Literal["food", "walk", "drinks", "culture", "other"]

MAX_ACTIVE_CREATED = 3
MAX_ACTIVE_JOINED = 10
# Con tantas denuncias de personas distintas, la quedada deja de verse.
REPORTS_TO_HIDE = 3
# Se puede proponer como mucho con un mes de antelación.
MAX_AHEAD = timedelta(days=30)
# Una quedada se sigue viendo un rato después de empezar (por si llegas tarde).
SHOWN_AFTER_START = timedelta(hours=2)
# Y se borra una semana después.
KEEP_AFTER_START = timedelta(days=7)


@dataclass(frozen=True, slots=True)
class Member:
    user_id: str
    name: str
    country: str | None
    visible: bool


@dataclass(frozen=True, slots=True)
class Meetup:
    meetup_id: str
    city: str
    kind: MeetupKind
    title: str
    place: str
    starts_at: datetime
    capacity: int
    creator_id: str
    reports: int
    members: tuple[Member, ...]

    def member(self, user_id: str) -> Member | None:
        return next((m for m in self.members if m.user_id == user_id), None)

    @property
    def full(self) -> bool:
        return len(self.members) >= self.capacity

    def shown(self, now: datetime) -> bool:
        return self.reports < REPORTS_TO_HIDE and self.starts_at > now - SHOWN_AFTER_START


class MeetupLimitError(Exception):
    """Demasiadas quedadas propuestas o apuntadas a la vez."""


class MeetupFullError(Exception):
    pass


class MeetupNotFoundError(Exception):
    """No existe, ya pasó o está oculta por denuncias."""
