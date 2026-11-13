"""Lo que recibe la app: los vídeos de un sitio."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict

# De qué red es el vídeo (por ahora solo YouTube Shorts).
Source = Literal["youtube"]

# El id de YouTube: 11 letras.
VIDEO_ID = {"youtube": re.compile(r"^[A-Za-z0-9_-]{11}$")}


class PlanVideo(BaseModel):
    model_config = ConfigDict(frozen=True)

    # De qué red es: la app elige su reproductor oficial con esto.
    source: Source = "youtube"
    id: str
    title: str
    channel: str | None = None
    # Miniatura (solo de los servidores de cada red).
    thumb: str | None = None


class PlanVideos(BaseModel):
    model_config = ConfigDict(frozen=True)

    place: str
    videos: list[PlanVideo] = []
    # ¿Hay búsqueda de YouTube? (sin clave, la lista sale vacía).
    youtube: bool = True
