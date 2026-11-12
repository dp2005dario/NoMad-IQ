"""Lo que recibe la app: los vídeos de un sitio."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict

Source = Literal["youtube", "tiktok", "instagram"]

# El id de cada red: YouTube 11 letras, TikTok un número largo, Instagram
# el código del reel ("C1a2B3c4D5e").
VIDEO_ID = {
    "youtube": re.compile(r"^[A-Za-z0-9_-]{11}$"),
    "tiktok": re.compile(r"^[0-9]{15,25}$"),
    "instagram": re.compile(r"^[A-Za-z0-9_-]{5,40}$"),
}


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
    # ¿Hay búsqueda automática de YouTube? (si no, solo enlaces pegados).
    youtube: bool = True
