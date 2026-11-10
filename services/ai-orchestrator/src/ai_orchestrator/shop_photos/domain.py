"""Lo que recibe la app: la foto de un sitio y a quién hay que citar."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict

# Google pide enseñar de dónde sale la foto y quién la hizo.
ATTRIBUTION = "Google Maps"


class ShopPhoto(BaseModel):
    model_config = ConfigDict(frozen=True)

    # El sitio de OpenStreetMap ("n123"): así la app sabe de qué tarjeta es.
    id: str
    # None = Google no tiene foto de ese sitio (la app deja el dibujo).
    photo_url: str | None = None
    author: str | None = None
    author_url: str | None = None
    attribution: str = ATTRIBUTION
