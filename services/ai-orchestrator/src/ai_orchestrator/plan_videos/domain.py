"""Lo que recibe la app: los vídeos de un sitio."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict


class PlanVideo(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El id de YouTube (11 letras): la app lo reproduce con youtube.com/embed/<id>.
    id: str
    title: str
    channel: str | None = None
    # Miniatura (i.ytimg.com).
    thumb: str | None = None


class PlanVideos(BaseModel):
    model_config = ConfigDict(frozen=True)

    place: str
    videos: list[PlanVideo] = []
