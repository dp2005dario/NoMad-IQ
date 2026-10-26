"""Radar local: lo que se guarda y lo que se enseña.

REGLA: nada inventado. Los avisos y los precios los ponen viajeros de
verdad, y solo se enseñan cuando hay suficientes para no depender de una
sola persona (ni de un troll).
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict

ScamCategory = Literal[
    "street_touts",  # captadores que te llevan a un bar o tienda carísimos
    "taxi",  # taxi sin taxímetro o con vuelta larga
    "fake_police",  # falsos policías que piden la cartera
    "bracelet",  # pulseras, flores o firmas "regaladas" que luego se cobran
    "atm",  # cajeros manipulados o "ayudantes" en el cajero
    "pickpockets",  # carteristas
    "fake_tickets",  # entradas o billetes falsos en la calle
    "exchange",  # casas de cambio con comisiones abusivas
]
PriceItem = Literal["coffee", "beer", "water", "simple_meal", "taxi_short"]

# Cuántas personas distintas hacen falta para enseñar algo.
MIN_SCAM_REPORTERS = 3
MIN_PRICE_REPORTERS = 5
# Cuánto tiempo cuenta un aviso o un precio.
SCAM_DAYS = 90
PRICE_DAYS = 365
# Para no llenar la base: cosas que una persona puede apuntar al día.
MAX_POSTS_PER_DAY = 30


class ScamCount(BaseModel):
    model_config = ConfigDict(frozen=True)

    category: ScamCategory
    reporters: int


class PriceRange(BaseModel):
    model_config = ConfigDict(frozen=True)

    item: PriceItem
    currency: str
    reporters: int
    # Percentiles 25, 50 y 75 de lo que han pagado (el "rango normal").
    low: float
    median: float
    high: float


class CityRadar(BaseModel):
    model_config = ConfigDict(frozen=True)

    city: str
    scams: list[ScamCount]
    prices: list[PriceRange]
    # Lo que tú ya avisaste (para marcar el botón).
    my_scams: list[ScamCategory]


class RadarLimitError(Exception):
    """Demasiadas cosas apuntadas hoy."""
