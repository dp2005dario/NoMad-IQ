"""Vocabulario del chat con Flyra: turnos, petición y respuesta.

La conversación NO se guarda en el servidor: la app manda en cada pregunta los
últimos mensajes (como quien relee el hilo antes de contestar) y el servidor
la olvida al responder. Lo que no se guarda no se puede filtrar.

Los límites (cuántos mensajes y cuántas letras) están aquí, en los tipos, por
dos motivos:
    - Coste 0 €: el modelo corre en nuestro servidor; cada letra de más es
      tiempo de máquina. Una conversación de 40 páginas no cabe.
    - Calidad: el modelo pequeño se lía con contextos muy largos.
"""

from __future__ import annotations

import re
from typing import Annotated, Literal, Self

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator

from ai_orchestrator.negotiation.domain import clean_text

MAX_TURNS = 20
MAX_TURN_CHARS = 2000
MAX_TOTAL_CHARS = 12000
MAX_REPLY_CHARS = 2000

# Etiqueta de idioma tipo "es", "pt-BR" o "zh-Hans" (BCP 47, la de los móviles).
_LANGUAGE = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")


def _not_blank(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("el mensaje no puede estar vacío")
    return cleaned


Text = Annotated[str, Field(min_length=1, max_length=MAX_TURN_CHARS), AfterValidator(_not_blank)]


class ChatTurn(BaseModel):
    """Un mensaje del hilo: de la persona ("user") o de Flyra ("flyra")."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    role: Literal["user", "flyra"]
    text: Text


class ChatRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    # El hilo, del más antiguo al más nuevo. El último es la pregunta.
    messages: list[ChatTurn] = Field(min_length=1, max_length=MAX_TURNS)
    # Idioma de la app: Flyra contesta en él (o en el que escriba la persona).
    language: str = Field(default="en", max_length=16)
    # Dónde está la persona, si la app lo sabe y ella lo permite ("Lisboa").
    place: str | None = Field(default=None, max_length=80)

    @model_validator(mode="after")
    def _check(self) -> Self:
        if self.messages[-1].role != "user":
            raise ValueError("el último mensaje tiene que ser de la persona")
        if sum(len(m.text) for m in self.messages) > MAX_TOTAL_CHARS:
            raise ValueError("conversación demasiado larga")
        if not _LANGUAGE.fullmatch(self.language):
            raise ValueError("language no es una etiqueta de idioma")
        if self.place is not None and not clean_text(self.place):
            raise ValueError("place vacío")
        return self


class ChatReply(BaseModel):
    model_config = ConfigDict(frozen=True)

    reply: str
    # Cuántas preguntas le quedan hoy a esta persona (cupo diario gratuito).
    remaining_today: int
