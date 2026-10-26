"""Lo que recibe la app en el modo coche."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.atms.domain import ATTRIBUTION, LICENSE_URL

# Casillas de 0,05° (~5,5 km). Con el anillo de vecinas, un cuadrado de ~16 km.
CELL_DEGREES = 0.05

# fuel: gasolinera · parking: aparcamiento público · ev: cargador de coche
# eléctrico · lez: zona de bajas emisiones / tráfico limitado (ZTL, ZBE...).
DriveKind = Literal["fuel", "parking", "ev", "lez"]


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    """El centro de la casilla de ~5 km donde cae un punto."""
    return (
        round(round(lat / CELL_DEGREES) * CELL_DEGREES, 2),
        round(round(lon / CELL_DEGREES) * CELL_DEGREES, 2),
    )


class DriveSpot(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    kind: DriveKind
    lat: float
    lon: float
    name: str | None = None
    # La marca de la gasolinera ("Repsol") o el operador del cargador.
    brand: str | None = None
    opening_hours: str | None = None
    # ¿Cuesta dinero? (aparcamientos). None = no se sabe.
    fee: bool | None = None
    # Plazas totales (no libres: eso no lo sabe nadie gratis).
    capacity: int | None = None
    # La web oficial de una zona de bajas emisiones (solo https).
    website: str | None = None


class DriveArea(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla consultada (no el punto exacto de nadie).
    lat: float
    lon: float
    spots: list[DriveSpot] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL
