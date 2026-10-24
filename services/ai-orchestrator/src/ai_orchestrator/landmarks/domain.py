"""Lo que manda la app al apuntar a un monumento y lo que le respondemos.

La foto viaja dentro del JSON en base64 (texto que representa bytes). Así
la petición es una sola y pasa por la puerta de entrada como cualquier otra.
Límites: la app la manda ya reducida (unos 100 KB); aquí no aceptamos más de
~450 KB para que nadie nos use de disco duro gratis.
"""

from __future__ import annotations

import base64
import binascii
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

from ai_orchestrator.places.domain import Photo

MAX_IMAGE_B64 = 600_000
# Los primeros bytes de cualquier JPEG ("número mágico"): si no empieza así,
# no es una foto de la cámara y no se la enseñamos al modelo.
_JPEG_MAGIC = b"\xff\xd8\xff"

Status = Literal["recognized", "guess", "none"]


class RecognizeRequest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    lat: float = Field(ge=-85, le=85)
    lon: float = Field(ge=-180, le=180)
    # Lo que dice el GPS de su propia precisión (metros). Con mucho error,
    # ampliamos la búsqueda.
    accuracy_m: float = Field(default=30, ge=0, le=2000)
    # Hacia dónde mira el móvil (brújula): 0 = norte, 90 = este. Opcional.
    heading: float | None = Field(default=None, ge=0, lt=360)
    language: str = Field(default="en", pattern=r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")
    # La foto en JPEG y base64. Opcional: sin foto se decide por GPS y brújula.
    image: str | None = Field(default=None, max_length=MAX_IMAGE_B64)

    @model_validator(mode="after")
    def _check_image(self) -> Self:
        if self.image is not None:
            raw = self.image_bytes()
            if raw is None or not raw.startswith(_JPEG_MAGIC):
                raise ValueError("image debe ser un JPEG en base64")
        return self

    def image_bytes(self) -> bytes | None:
        if self.image is None:
            return None
        try:
            return base64.b64decode(self.image, validate=True)
        except (binascii.Error, ValueError):
            return None


class Candidate(BaseModel):
    """Un lugar de Wikidata cerca de ti (lo que llega de la consulta)."""

    model_config = ConfigDict(frozen=True)

    qid: str
    name: str
    description: str | None = None
    lat: float
    lon: float
    # Año en que se construyó o fundó, si Wikidata lo sabe.
    year: int | None = None
    photo: Photo | None = None
    article_url: str | None = None
    # En cuántas Wikipedias sale: una pista de lo famoso que es.
    sitelinks: int = 0


class Landmark(BaseModel):
    """La ficha que enseña la app (la tarjeta de abajo de la maqueta)."""

    model_config = ConfigDict(frozen=True)

    qid: str
    name: str
    description: str | None = None
    lat: float
    lon: float
    year: int | None = None
    photo: Photo | None = None
    summary: str | None = None
    article_url: str | None = None
    distance_m: int | None = None


class Alternative(BaseModel):
    model_config = ConfigDict(frozen=True)

    qid: str
    name: str
    distance_m: int


class Recognition(BaseModel):
    model_config = ConfigDict(frozen=True)

    # recognized: el modelo de visión lo ha visto en la foto.
    # guess: lo más probable por dónde estás y hacia dónde miras ("¿Es este?").
    # none: no hay nada conocido cerca (o la foto no muestra ninguno).
    status: Status
    landmark: Landmark | None = None
    alternatives: list[Alternative] = []
    attribution: str
