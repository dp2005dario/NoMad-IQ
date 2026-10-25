"""Los datos de una ficha de ciudad, tal y como los recibe la app."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

# Los idiomas de la app (mobile/lib/l10n). Wikipedia existe en todos.
PLACE_LANGUAGES: tuple[str, ...] = ("en", "es", "fr", "de", "it", "pt", "ar", "zh", "ja", "hi")
DEFAULT_LANGUAGE = "en"

# Lo que hay que mostrar junto a los textos y fotos (lo piden sus licencias).
ATTRIBUTION = "Wikipedia (CC BY-SA 4.0) · Wikidata (CC0) · Wikimedia Commons"


def place_language(lang: str) -> str:
    """El idioma pedido si lo tenemos; si no, inglés."""
    lang = lang.lower()
    return lang if lang in PLACE_LANGUAGES else DEFAULT_LANGUAGE


class Photo(BaseModel):
    model_config = ConfigDict(frozen=True)

    # La imagen ya reducida (servida por Wikimedia, no por nosotros).
    url: str
    # La página de la foto en Commons: autor y licencia exacta.
    page_url: str


class Attraction(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str
    description: str | None = None
    photo: Photo | None = None
    article_url: str | None = None
    # "Q193208": sirve para no repetir la misma atracción (p. ej. en los
    # planes del grupo). Las fichas guardadas antes en caché no lo traen.
    wikidata_id: str | None = None


class CountryFacts(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str
    capital: str | None = None
    currency: str | None = None
    languages: list[str] = Field(default_factory=list)


class PlaceCard(BaseModel):
    model_config = ConfigDict(frozen=True)

    iata: str
    language: str
    wikidata_id: str
    city: str
    # "Por qué es famosa": el resumen de Wikipedia. Puede venir en inglés si
    # no hay artículo en el idioma pedido (summary_language lo dice).
    summary: str | None = None
    summary_language: str | None = None
    article_url: str | None = None
    photo: Photo | None = None
    population: int | None = None
    country: CountryFacts | None = None
    attractions: list[Attraction] = Field(default_factory=list)
    attribution: str = ATTRIBUTION
