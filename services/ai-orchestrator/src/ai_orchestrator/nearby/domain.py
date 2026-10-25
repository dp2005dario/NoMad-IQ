"""Los sitios de "Cerca de ti", tal y como los recibe la app."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.atms.domain import ATTRIBUTION, CELL_DEGREES, LICENSE_URL, cell_of

__all__ = ["ATTRIBUTION", "CELL_DEGREES", "LICENSE_URL", "Nearby", "NearbySpot", "SpotKind", "cell_of"]

# water: agua potable · toilets: baños · wifi: wifi gratis · charging: cargar
# el móvil · sight: algo que ver (monumento, mirador, museo...).
SpotKind = Literal["water", "toilets", "wifi", "charging", "sight"]


class NearbySpot(BaseModel):
    model_config = ConfigDict(frozen=True)

    # "n123" (un punto de OSM) o "w456" (un edificio).
    id: str
    kind: SpotKind
    lat: float
    lon: float
    name: str | None = None
    # El horario tal cual lo escribe OSM ("Mo-Su 08:00-22:00").
    opening_hours: str | None = None
    # ¿Cuesta dinero? True = sí, False = no, None = no se sabe.
    fee: bool | None = None
    # Para los sitios que ver: su Wikidata (así la app enseña la ficha).
    wikidata_id: str | None = None


class Nearby(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla consultada (no el punto exacto de nadie).
    lat: float
    lon: float
    spots: list[NearbySpot] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL
