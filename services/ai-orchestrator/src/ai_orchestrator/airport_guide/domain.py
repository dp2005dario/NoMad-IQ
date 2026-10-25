"""Los sitios del aeropuerto, tal y como los recibe la app."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.atms.domain import ATTRIBUTION, LICENSE_URL

# Qué tipos de sitio enseña la app (y nada más: así la respuesta es pequeña).
SpotKind = Literal[
    "gate",
    "toilets",
    "cafe",
    "food",
    "pharmacy",
    "atm",
    "water",
    "info",
    "charging",
    "lounge",
    # Las "salidas" del aeropuerto (pantalla Moverte): estaciones y paradas
    # dentro del recinto o a menos de TRANSIT_AROUND_M.
    "train",
    "metro",
    "tram",
    "bus",
    "taxi",
]

# Hasta dónde se buscan estaciones alrededor del recinto: muchas están justo
# fuera del dibujo del aeropuerto (unos cientos de metros, con pasarela).
TRANSIT_AROUND_M = 1200

# Etiqueta de OpenStreetMap → nuestro tipo.
AMENITY_KINDS: dict[str, SpotKind] = {
    "toilets": "toilets",
    "cafe": "cafe",
    "restaurant": "food",
    "fast_food": "food",
    "pharmacy": "pharmacy",
    "atm": "atm",
    "drinking_water": "water",
    "charging_station": "charging",
}
AEROWAY_KINDS: dict[str, SpotKind] = {"gate": "gate", "lounge": "lounge"}


class AirportSpot(BaseModel):
    model_config = ConfigDict(frozen=True)

    # "n123" (un punto de OSM) o "w456" (un local dibujado).
    id: str
    kind: SpotKind
    lat: float
    lon: float
    # El número de la puerta ("K42") o el nombre del sitio ("Starbucks").
    ref: str | None = None
    name: str | None = None
    # La planta, si OSM la sabe ("0", "1", "-1").
    level: str | None = None


class AirportGuide(BaseModel):
    model_config = ConfigDict(frozen=True)

    iata: str
    # El punto del aeropuerto en nuestra lista (para centrar el mapa).
    lat: float
    lon: float
    spots: list[AirportSpot] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL
