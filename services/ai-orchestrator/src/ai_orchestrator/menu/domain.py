"""Vocabulario del traductor de cartas: líneas que entran, platos que salen."""

from __future__ import annotations

import re
from typing import Annotated, Self

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator

from ai_orchestrator.negotiation.domain import clean_text

# Una carta normal tiene 20-40 líneas; 80 es de sobra y pone techo al coste.
MAX_LINES = 80
MAX_LINE_CHARS = 120
MAX_TOTAL_CHARS = 3000
MAX_DISHES = 40
MAX_FIELD_CHARS = 160

_LANGUAGE = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")


def _not_blank(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("la línea no puede estar vacía")
    return cleaned


Line = Annotated[str, Field(min_length=1, max_length=MAX_LINE_CHARS), AfterValidator(_not_blank)]


class MenuRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    # Las líneas que leyó el móvil, de arriba abajo.
    lines: list[Line] = Field(min_length=1, max_length=MAX_LINES)
    # Idioma de la app: a este se traduce la carta.
    language: str = Field(default="en", max_length=16)
    # Idioma del sitio, si la app lo sabe ("ja"): para la frase de "pídelo así".
    place_language: str | None = Field(default=None, max_length=16)

    @model_validator(mode="after")
    def _check(self) -> Self:
        if sum(len(line) for line in self.lines) > MAX_TOTAL_CHARS:
            raise ValueError("carta demasiado larga")
        if not _LANGUAGE.fullmatch(self.language):
            raise ValueError("language no es una etiqueta de idioma")
        if self.place_language is not None and not _LANGUAGE.fullmatch(self.place_language):
            raise ValueError("place_language no es una etiqueta de idioma")
        return self


class Dish(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El nombre tal y como está en la carta ("親子丼").
    original: str
    # Qué es, en tu idioma ("Oyakodon: pollo con huevo sobre arroz").
    name: str
    # Una frase de qué lleva o cómo se hace; vacío si el modelo no lo sabe.
    description: str = ""
    # Aviso de alérgenos frecuentes ("lleva gluten: salsa de soja"); vacío si no.
    allergens: str = ""
    # Cómo pedirlo en el idioma del sitio y cómo se pronuncia.
    order_phrase: str = ""
    order_sounds: str = ""
    # El precio tal y como aparece en la carta ("1.200 円"); vacío si no hay.
    price: str = ""


class MenuReply(BaseModel):
    model_config = ConfigDict(frozen=True)

    dishes: list[Dish] = Field(default_factory=list)
    # Cuántas cartas le quedan hoy a esta persona (cupo diario gratuito).
    remaining_today: int
