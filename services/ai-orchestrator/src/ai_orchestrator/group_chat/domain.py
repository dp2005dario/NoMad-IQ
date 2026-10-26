"""Las reglas del chat del viaje (sin base de datos: fácil de probar).

Coste 0 € con miles de grupos:
    - Topes: 300 mensajes al día por persona y viaje, y 2000 letras por
      mensaje. Un grupo no puede llenar el disco.
    - Limpieza: los mensajes de más de 180 días se borran solos. El chat es
      para organizar el viaje, no un archivo para siempre (y lo que no se
      guarda no se puede filtrar).
    - Flyra solo trabaja cuando alguien la llama con "@Flyra", y gasta el
      cupo diario de esa persona (el mismo que el chat privado).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum

MAX_TEXT = 2000
MAX_PER_DAY = 300
KEEP_FOR = timedelta(days=180)
# Cuántos mensajes manda la app de golpe (la primera vez, o al subir).
PAGE = 50
# Cuántos mensajes anteriores lee Flyra para entender de qué se habla.
FLYRA_CONTEXT = 12

# "@Flyra" al principio (con o sin coma o dos puntos detrás).
_MENTION = re.compile(r"^\s*@flyra\b[\s,:]*", re.IGNORECASE)


class TripKind(StrEnum):
    FRIENDS = "friends"
    COUPLE = "couple"
    FAMILY = "family"


# Cómo se adapta Flyra a cada tipo de viaje (va en sus instrucciones, en
# inglés como el resto: los modelos pequeños las siguen mejor así).
KIND_HINTS = {
    TripKind.FRIENDS: "a group of friends: shared kitty, voting on plans, fair splits",
    TripKind.COUPLE: "a couple: plans for two, romantic ideas, costs split in half",
    TripKind.FAMILY: (
        "a family: relaxed pace, avoid steep walks and long queues, "
        "places friendly for children and older people, benches and toilets nearby"
    ),
}


def asks_flyra(text: str) -> bool:
    return _MENTION.match(text) is not None


@dataclass(frozen=True, slots=True)
class Member:
    seat: int
    # El nombre que eligió para el chat, o su alias ("Viajero 2").
    name: str
    # False = cuenta borrada (su asiento sigue, anónimo).
    active: bool


@dataclass(frozen=True, slots=True)
class Message:
    message_id: int
    # None = Flyra.
    seat: int | None
    text: str
    created_at: datetime


@dataclass(frozen=True, slots=True)
class ChatPage:
    negotiation_id: str
    title: str
    kind: TripKind
    my_seat: int
    members: tuple[Member, ...]
    messages: tuple[Message, ...]


class ChatLimitError(Exception):
    """Ya escribió demasiados mensajes hoy en este viaje."""
