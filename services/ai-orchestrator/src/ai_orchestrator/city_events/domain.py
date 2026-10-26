"""Los eventos de una ciudad en unas fechas, tal y como los recibe la app.

REGLA: solo datos REALES de una fuente con nombre (festivos oficiales de
Nager.Date y eventos de Ticketmaster). Nada de "los hoteles suben un 55 %":
no hay datos gratis y comprobados para decir eso, y no se inventa.
"""

from __future__ import annotations

from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

EventKind = Literal["holiday", "music", "sports", "arts", "family", "other"]

# Como mucho un mes por pregunta, y hasta un año vista (más allá casi no
# hay eventos publicados y así la caché tiene un tamaño fijo).
MAX_DAYS = 31
HORIZON_DAYS = 366


class CityEvent(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    kind: EventKind
    name: str = Field(max_length=120)
    date: date
    # Hora local de inicio ("21:00"), si el organizador la publica.
    time: str | None = None
    venue: str | None = None
    # La web del evento (siempre https) para ver entradas.
    url: str | None = None
    # Precios publicados por el organizador (no estimados).
    price_min: float | None = None
    price_max: float | None = None
    currency: str | None = None
    # Festivo solo en una región del país (no en todo).
    regional: bool = False


class CityEvents(BaseModel):
    model_config = ConfigDict(frozen=True)

    iata: str
    city: str
    country: str | None
    start: date
    end: date
    events: list[CityEvent]
    # De dónde salen los datos de ESTA respuesta (para la atribución).
    sources: list[str]
