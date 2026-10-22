"""Tipos de dominio de las audioguías (validados con Pydantic, inmutables)."""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.domain import UuidStr

# Idiomas en los que sabemos redactar (plantillas del plan B incluidas).
# Códigos ISO 639-1: los mismos que normaliza el geo-engine ("es-ES" -> "es").
SUPPORTED_LANGUAGES: tuple[str, ...] = ("es", "en", "fr", "de", "it", "pt")

# Nombre de un idioma escrito en ese mismo idioma: se lo decimos al LLM
# ("escribe en Deutsch") para que no haya dudas.
LANGUAGE_NAMES: dict[str, str] = {
    "es": "español",
    "en": "English",
    "fr": "français",
    "de": "Deutsch",
    "it": "italiano",
    "pt": "português",
}

LanguageCode = Annotated[str, Field(pattern=r"^[a-z]{2,3}$")]


def resolve_language(requested: str, default: str) -> str:
    """El idioma en el que prepararemos el guion.

    Si la app no indicó idioma, o pidió uno que no sabemos redactar, se usa el
    idioma por defecto. Así la clave de caché solo tiene valores conocidos (y
    nadie puede llenar Redis inventándose miles de idiomas).
    """
    # El geo-engine ya manda solo la parte principal ("es"), pero no nos
    # fiamos a ciegas (Zero Trust): "es-ES" o "es_ES" también valen como "es".
    lang = requested.strip().lower().replace("_", "-").split("-", 1)[0]
    return lang if lang in SUPPORTED_LANGUAGES else default


class ZoneKind(StrEnum):
    """Mismo vocabulario que geo.zones.kind (PostgreSQL) y que el proto."""

    CITY_CENTER = "CITY_CENTER"
    TOURIST_AREA = "TOURIST_AREA"
    AIRPORT = "AIRPORT"
    RESTRICTED = "RESTRICTED"


# Zonas que merecen audioguía. Un aeropuerto o una zona restringida no son
# lugares para "escuchar la historia del sitio": no gastamos GPU en ellos.
NARRATED_KINDS = frozenset({ZoneKind.CITY_CENTER, ZoneKind.TOURIST_AREA})


class ZoneEntry(BaseModel):
    """Alguien (no sabemos quién, a propósito) entró en una zona."""

    model_config = ConfigDict(frozen=True)

    zone_id: UuidStr
    zone_kind: ZoneKind | None
    # Tal como llegó en el evento (puede venir vacío).
    language: str = Field(default="", max_length=8)
    event_id: str = ""


class ZoneFact(BaseModel):
    """Un hecho verificado sobre una zona, escrito y revisado por personas."""

    model_config = ConfigDict(frozen=True)

    # "F1", "F2"... : la etiqueta con la que el LLM debe citarlo.
    fact_id: str = Field(pattern=r"^F[0-9]{1,2}$")
    text: str = Field(min_length=5, max_length=500)
    source: str = Field(default="", max_length=200)


class ZoneFacts(BaseModel):
    """La zona y lo que sabemos de ella con certeza."""

    model_config = ConfigDict(frozen=True)

    zone_id: UuidStr
    slug: str
    name: str
    kind: ZoneKind
    # Idioma en el que están escritos los hechos (puede no ser el pedido si no
    # hay traducción: entonces el LLM los traduce, o el plan B los usa tal cual).
    facts_language: LanguageCode
    facts: tuple[ZoneFact, ...] = ()
    # Versión del contenido de la zona (ai.zone_content), leída en la MISMA
    # consulta que los hechos: así el guion queda marcado con la versión de
    # los hechos con los que de verdad se escribió. 0 = zona sin hechos.
    content_version: int = Field(default=0, ge=0)


class GuideSegment(BaseModel):
    """Un párrafo del guion (unos 20-30 segundos hablado) y los hechos que lo respaldan."""

    model_config = ConfigDict(frozen=True)

    text: str = Field(min_length=1, max_length=800)
    fact_ids: tuple[str, ...] = ()


class AudioguideScript(BaseModel):
    """El guion terminado, tal como se guarda en la caché y lo devuelve la API.

    Es GENÉRICO: el mismo para todas las personas que llegan a esa zona con ese
    idioma. Por eso no lleva ningún dato de usuario y se puede compartir.
    """

    model_config = ConfigDict(frozen=True)

    zone_id: UuidStr
    zone_name: str
    # Idioma pedido (parte de la clave de caché).
    language: LanguageCode
    # Idioma en el que REALMENTE está escrito (el plan B sin traducción puede diferir).
    content_language: LanguageCode
    title: str = Field(min_length=1, max_length=260)
    segments: tuple[GuideSegment, ...] = Field(min_length=1, max_length=12)
    # Los hechos citados, para poder auditar de dónde sale cada frase.
    facts: tuple[ZoneFact, ...] = ()
    source: Literal["llm", "rules"]
    model: str = ""
    # Versión de los hechos con la que se escribió (forma parte de la clave de caché).
    content_version: int = Field(ge=0)
    generated_at: datetime
