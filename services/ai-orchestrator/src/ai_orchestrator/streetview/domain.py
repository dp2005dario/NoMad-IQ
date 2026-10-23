"""Los datos de las fotos de calle, tal y como los recibe la app."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

# Lo que hay que mostrar junto a cada foto (lo pide su licencia).
ATTRIBUTION = "Mapillary (CC BY-SA 4.0)"
LICENSE_URL = "https://creativecommons.org/licenses/by-sa/4.0/"

# Tamaño de cada casilla en grados (0,001° ≈ 111 m de norte a sur).
CELL_DEGREES = 0.001


def cell_of(lat: float, lon: float) -> tuple[float, float]:
    """El centro de la casilla de ~100 m donde cae un punto.

    Analogía: en vez de dar tu portal exacto, dices "por la manzana de la
    Plaza Mayor". Basta para enseñar fotos de la calle y protege tu sitio.
    """
    return (
        round(round(lat / CELL_DEGREES) * CELL_DEGREES, 3),
        round(round(lon / CELL_DEGREES) * CELL_DEGREES, 3),
    )


class StreetPhoto(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    lat: float
    lon: float
    # Cuándo se hizo (para que la app diga "foto de 2023").
    captured_at: datetime | None = None
    # Hacia dónde miraba la cámara (0 = norte, 90 = este).
    compass_angle: float | None = None
    # Las panorámicas de 360° se ven arrastrando el dedo.
    is_pano: bool = False
    # Miniatura (256 px) para la tira y foto grande (1024 px) al tocarla.
    thumb_url: str
    image_url: str
    # Quién la hizo (la licencia pide citarlo) y su página en Mapillary.
    creator: str | None = None
    page_url: str


class StreetPhotos(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El centro de la casilla consultada (no el punto exacto de nadie).
    lat: float
    lon: float
    photos: list[StreetPhoto] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
    license_url: str = LICENSE_URL
