"""Los datos de un cajero, tal y como los recibe la app."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

# Lo que hay que mostrar con los datos (lo pide la licencia ODbL de OSM).
ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
LICENSE_URL = "https://www.openstreetmap.org/copyright"

# Tamaño de cada casilla en grados (0,01° ≈ 1,1 km de norte a sur).
CELL_DEGREES = 0.01


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    """El centro de la casilla de ~1 km donde cae un punto.

    Analogía: en vez de decir tu portal, dices "estoy por Shibuya". Basta
    para buscar cajeros y protege tu sitio exacto.
    """
    return (
        round(round(lat / CELL_DEGREES) * CELL_DEGREES, 2),
        round(round(lon / CELL_DEGREES) * CELL_DEGREES, 2),
    )


class Atm(BaseModel):
    model_config = ConfigDict(frozen=True)

    # "n123" (un punto de OSM) o "w456" (un edificio): sirve para el enlace.
    id: str
    lat: float
    lon: float
    # El nombre que pone en el cartel, el banco que lo lleva y la marca.
    name: str | None = None
    operator: str | None = None
    # El horario tal cual lo escribe OSM ("24/7", "Mo-Fr 08:00-21:00").
    opening_hours: str | None = None
    # True si abre siempre (horario "24/7").
    open_24h: bool = False
    # ¿Cobra comisión? True = sí, False = no, None = no se sabe.
    fee: bool | None = None
    # True si es el cajero de dentro de una oficina de banco.
    in_bank: bool = False
    # Monedas que da, si OSM lo dice (por ejemplo ["JPY", "USD"]).
    currencies: list[str] = Field(default_factory=list)


class Atms(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla consultada (no el punto exacto de nadie).
    lat: float
    lon: float
    atms: list[Atm] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL
