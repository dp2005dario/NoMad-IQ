"""El clima medio de un sitio, tal y como lo recibe la app."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

ATTRIBUTION = "NASA POWER (Langley Research Center), dominio público"
SOURCE_URL = "https://power.larc.nasa.gov/"

# Tamaño de cada casilla en grados (0,5° ≈ 55 km): la resolución de los
# propios datos de la NASA, así que no se pierde nada al redondear.
CELL_DEGREES = 0.5


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    """El centro de la casilla de 0,5° donde cae un punto."""
    return (
        round(round(lat / CELL_DEGREES) * CELL_DEGREES, 1),
        round(round(lon / CELL_DEGREES) * CELL_DEGREES, 1),
    )


class MonthClimate(BaseModel):
    model_config = ConfigDict(frozen=True)

    # 1 = enero ... 12 = diciembre.
    month: int = Field(ge=1, le=12)
    # Temperatura media del día y media de las máximas (°C).
    temp_c: float
    temp_max_c: float
    # Lluvia del mes entero (mm). 0-30 seco, 30-100 normal, >150 muy lluvioso.
    rain_mm: float = Field(ge=0)


class Climate(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla (no el punto exacto de nadie).
    lat: float
    lon: float
    months: list[MonthClimate] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    source_url: str = SOURCE_URL
