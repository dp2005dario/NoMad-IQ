"""Dormir barato (maqueta "Hoteles"): ¿y si duermes una o dos paradas más
lejos?

La idea: cerca de lo famoso (Disneyland, el Vaticano, la Sagrada Familia...)
los alojamientos son caros. A unas paradas de tren suele haber muchos más y
más baratos. Esta pantalla encuentra esas ZONAS: estaciones de tren o metro
con alojamientos alrededor, a qué distancia quedan y cuánto se tarda.

¿Y los precios? No hay ninguna fuente gratis y fiable de precios de hotel
para todo el mundo. Así que aquí NO se inventan: cada zona tiene un botón
"Ver precios" que abre Booking.com con esa zona y tus fechas (el precio real,
el de ese día), y la app calcula el "total real" (noches + billetes) con lo
que tú ves allí. Datos: OpenStreetMap (ODbL), gratis.
"""

from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.atms.domain import ATTRIBUTION, LICENSE_URL

# Casillas de 0,02° (~2 km): el sitio al que vas, sin hilar más fino. Así
# miles de personas que van a Disneyland comparten la misma respuesta.
CELL_DEGREES = 0.02
# Radio de búsqueda de estaciones (el anillo "hasta 35 km" de la maqueta).
MAX_KM = 35.0
# "Andando": alojamientos hasta 2 km del sitio.
WALK_KM = 2.0
# Alojamientos que cuentan para una estación: hasta 600 m de ella.
STATION_RADIUS_M = 600
# Dos estaciones a menos de esto son "la misma zona" (nos quedamos con la mejor).
SAME_AREA_KM = 1.2
# Zonas por anillo (2, 15 y 35 km) y en total.
PER_RING = 4
RINGS_KM = (WALK_KM, 15.0, MAX_KM)

StayBy = Literal["walk", "train"]


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    return (
        round(round(lat / CELL_DEGREES) * CELL_DEGREES, 2),
        round(round(lon / CELL_DEGREES) * CELL_DEGREES, 2),
    )


def km_between(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distancia en línea recta (fórmula del haversine), en km."""
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(min(1.0, a)))


def minutes_for(km: float, by: StayBy) -> int:
    """Minutos ESTIMADOS hasta el sitio. Andando, 5 km/h. En tren, ~37 km/h
    de media más 6 min de espera y andar a la estación. Es una estimación
    (la app lo dice): los horarios reales los da el operador."""
    if by == "walk":
        return max(1, round(km * 12))
    return round(6 + km * 1.6)


class Lodging(BaseModel):
    """Un alojamiento de OpenStreetMap (solo lo que hace falta)."""

    model_config = ConfigDict(frozen=True)

    id: str
    lat: float
    lon: float
    name: str | None = None
    # hotel · hostel · guest_house · motel · apartment
    kind: str
    stars: int | None = None


class Station(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    lat: float
    lon: float
    name: str


class StayZone(BaseModel):
    model_config = ConfigDict(frozen=True)

    # "walk" = el propio sitio; si no, el id de la estación.
    id: str
    # Nombre de la estación (o null en la zona "andando").
    name: str | None
    lat: float
    lon: float
    km: float
    minutes: int
    by: StayBy
    lodgings: int
    # Cuántos son albergues o pensiones (suelen ser lo más barato).
    budget: int
    # Hasta 3 nombres de ejemplo.
    examples: list[str] = Field(default_factory=list)


class StayArea(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla consultada.
    lat: float
    lon: float
    zones: list[StayZone] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL


_BUDGET = {"hostel", "guest_house", "motel"}


def build_zones(lat: float, lon: float, stations: list[Station], lodgings: list[Lodging]) -> list[StayZone]:
    """Junta estaciones y alojamientos en zonas y elige las mejores de cada anillo."""
    zones: list[StayZone] = []
    near = [x for x in lodgings if km_between(lat, lon, x.lat, x.lon) <= WALK_KM]
    if near:
        zones.append(
            StayZone(
                id="walk",
                name=None,
                lat=lat,
                lon=lon,
                km=0.0,
                minutes=minutes_for(1.0, "walk"),
                by="walk",
                lodgings=len(near),
                budget=sum(1 for x in near if x.kind in _BUDGET),
                examples=[x.name for x in near if x.name][:3],
            )
        )
    candidates: list[StayZone] = []
    for st in stations:
        km = km_between(lat, lon, st.lat, st.lon)
        if km <= WALK_KM * 0.75 or km > MAX_KM:
            continue  # pegada al sitio (ya está en "andando") o demasiado lejos
        around = [x for x in lodgings if km_between(st.lat, st.lon, x.lat, x.lon) * 1000 <= STATION_RADIUS_M]
        if len(around) < 2:
            continue
        candidates.append(
            StayZone(
                id=st.id,
                name=st.name,
                lat=st.lat,
                lon=st.lon,
                km=round(km, 1),
                minutes=minutes_for(km, "train"),
                by="train",
                lodgings=len(around),
                budget=sum(1 for x in around if x.kind in _BUDGET),
                examples=[x.name for x in around if x.name][:3],
            )
        )
    # Por anillo, las que más alojamientos tienen (más donde elegir = mejor
    # precio), sin repetir el mismo barrio con dos estaciones.
    previous = WALK_KM * 0.75
    for limit in RINGS_KM[1:]:
        ring = sorted(
            (z for z in candidates if previous < z.km <= limit),
            key=lambda z: (-z.lodgings, z.km),
        )
        chosen: list[StayZone] = []
        for z in ring:
            if any(km_between(z.lat, z.lon, c.lat, c.lon) < SAME_AREA_KM for c in chosen):
                continue
            chosen.append(z)
            if len(chosen) == PER_RING:
                break
        zones.extend(sorted(chosen, key=lambda z: z.km))
        previous = limit
    return zones
