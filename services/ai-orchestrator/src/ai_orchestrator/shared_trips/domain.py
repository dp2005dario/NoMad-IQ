"""Vocabulario de "Copia este viaje": lo que se comparte y lo que se devuelve.

Un viaje compartido es una lista corta de cosas con su precio ("Vuelo con
escala en Estambul, 690 €"). Flyra lo adapta a otro presupuesto cambiando
algunas por otras más baratas, y aquí están las reglas que impiden que el
modelo haga trampas: nunca sube un precio, nunca cambia el tipo de cosa y
nunca se inventa una línea nueva.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.domain import CurrencyCode
from ai_orchestrator.negotiation.domain import clean_text

# Un viaje de 10 días cabe en 10-15 líneas; 30 es de sobra y limita el coste
# del modelo al adaptarlo.
MAX_ITEMS = 30
# Como mucho 20 viajes compartidos por persona: nadie llena la base de datos.
MAX_PER_OWNER = 20
# 1.000.000 € por línea: más que eso es un error de tecleo.
MAX_PRICE_MINOR = 100_000_000

Kind = Literal["flight", "stay", "transport", "food", "activity", "other"]


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


Title = Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]


class TripItem(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: Kind
    title: Title
    price_minor: int = Field(ge=0, le=MAX_PRICE_MINOR)


class ShareTrip(BaseModel):
    """Lo que manda la app al pulsar "Compartir mi viaje"."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    title: Annotated[str, Field(min_length=1, max_length=60), AfterValidator(_clean)]
    # El nombre que verán los demás ("laura.viaja"): lo elige la persona.
    author: Annotated[str, Field(min_length=1, max_length=30), AfterValidator(_clean)]
    destination: Annotated[str, Field(min_length=1, max_length=60), AfterValidator(_clean)]
    days: int = Field(ge=1, le=60)
    currency: CurrencyCode
    items: list[TripItem] = Field(min_length=1, max_length=MAX_ITEMS)


class SharedTrip(BaseModel):
    """Un viaje compartido tal y como lo ve cualquiera con el código."""

    model_config = ConfigDict(frozen=True)

    code: str
    author: str
    title: str
    destination: str
    days: int
    currency: str
    items: list[TripItem]
    total_minor: int
    # Cuántas personas distintas lo han copiado.
    copies: int
    # True si es tuyo (para enseñar "Dejar de compartir").
    mine: bool
    created_at: datetime


class MySharedTrips(BaseModel):
    items: list[SharedTrip]


class AdaptRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    budget_minor: int = Field(ge=1, le=MAX_PRICE_MINOR * MAX_ITEMS)
    # Idioma de la app: los títulos nuevos vienen en este.
    language: str = Field(default="en", pattern=r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")


class AdaptedItem(BaseModel):
    model_config = ConfigDict(frozen=True)

    kind: Kind
    title: str
    price_minor: int
    # Lo que tenía el viaje original en esta línea.
    was_title: str
    was_price_minor: int

    @property
    def changed(self) -> bool:
        return self.title != self.was_title or self.price_minor != self.was_price_minor


class AdaptReply(BaseModel):
    model_config = ConfigDict(frozen=True)

    items: list[AdaptedItem]
    total_minor: int
    budget_minor: int
    # ¿Cabe en el presupuesto? Si no, la app lo dice en naranja (no lo esconde).
    fits: bool
    # Cuántas adaptaciones le quedan hoy (None si vino de la caché y no gastó).
    remaining_today: int | None = None


def total(items: list[TripItem]) -> int:
    return sum(i.price_minor for i in items)


def apply_alternatives(
    items: list[TripItem], alternatives: dict[int, tuple[str, int]], budget_minor: int
) -> AdaptReply:
    """Junta el viaje original con lo que propone el modelo, con las reglas.

    ``alternatives`` es línea (desde 0) -> (título nuevo, precio nuevo). Una
    propuesta que no es más barata se ignora: adaptar es para gastar menos.
    """
    out: list[AdaptedItem] = []
    for i, item in enumerate(items):
        title, price = item.title, item.price_minor
        alt = alternatives.get(i)
        if alt is not None and 0 <= alt[1] <= item.price_minor and alt[0]:
            title, price = alt
        out.append(
            AdaptedItem(
                kind=item.kind,
                title=title,
                price_minor=price,
                was_title=item.title,
                was_price_minor=item.price_minor,
            )
        )
    spent = sum(i.price_minor for i in out)
    return AdaptReply(items=out, total_minor=spent, budget_minor=budget_minor, fits=spent <= budget_minor)
