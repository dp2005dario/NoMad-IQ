"""El redactor de guiones: hechos verificados → texto para escuchar.

Mismo patrón que el recomendador de vuelos (recommender.py), adaptado:

1. El LLM recibe SOLO los hechos de la zona, cada uno con una etiqueta (F1, F2...).
2. Devuelve un JSON con un título y varios párrafos; cada párrafo dice qué
   hechos usa (``fact_ids``). Pydantic valida la forma.
3. Comprobaciones propias (``guide_problems``): que cite hechos que existen,
   que no escriba cifras que no estén en los hechos que cita (una fecha
   inventada es el error más típico), que no se alargue y que no meta enlaces.
   Si algo falla, se le explica y lo intenta otra vez (máximo N veces).
4. Plan B (reglas): si Ollama no está o no acierta, se monta un guion con
   plantillas fijas leyendo los hechos tal cual. Menos bonito, igual de cierto.

¿Por qué no basta con "pedirle que no invente"? Porque pedir no es comprobar.
Las comprobaciones son código: o pasan, o el texto no sale de aquí.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from ai_orchestrator.audioguides.domain import (
    LANGUAGE_NAMES,
    AudioguideScript,
    GuideSegment,
    ZoneFact,
    ZoneFacts,
)
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.llm.structured import StructuredOutputError, generate_structured

log = logging.getLogger(__name__)

_NUMBER = re.compile(r"\d+")
_WORD = re.compile(r"\w+")


class DraftSegment(BaseModel):
    """Un párrafo tal como lo propone el LLM."""

    model_config = ConfigDict(extra="forbid")

    text: str = Field(min_length=20, max_length=700, description="Párrafo para leer en voz alta")
    fact_ids: list[str] = Field(
        min_length=1, max_length=4, description="Etiquetas (F1, F2...) de los hechos que usa este párrafo"
    )


class GuideDraft(BaseModel):
    """Lo ÚNICO que le pedimos al LLM (su esquema JSON se envía a Ollama)."""

    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=3, max_length=120, description="Título corto de la audioguía")
    segments: list[DraftSegment] = Field(min_length=2, max_length=6)


SYSTEM_PROMPT = """Eres el narrador de audioguías de NomadIQ. Escribes el guion que un viajero \
escuchará al llegar a un lugar, como un pódcast breve y cercano.

Reglas obligatorias:
1. Usa EXCLUSIVAMENTE los hechos de la lista. No añadas fechas, cifras, nombres ni anécdotas \
que no estén en ella.
2. Cada párrafo indica en "fact_ids" las etiquetas (F1, F2...) de los hechos que menciona.
3. No escribas ningún número que no aparezca en los hechos que citas en ese mismo párrafo.
4. Escribe en el idioma indicado, aunque los hechos estén en otro: tradúcelos con fidelidad.
5. Frases cortas, pensadas para oír: sin listas, sin enlaces, sin emojis.
6. Responde SOLO con un objeto JSON con los campos title y segments."""

# Plantillas del plan B. Sin cifras ni datos: solo el nombre de la zona.
_RULES_TEXT: dict[str, dict[str, str]] = {
    "es": {
        "title": "Audioguía: {name}",
        "intro": "Bienvenido a {name}. Te cuento lo esencial de este lugar.",
        "empty": "Bienvenido a {name}. Pronto tendrás aquí su audioguía con información verificada.",
        "closing": "Disfruta de la visita.",
    },
    "en": {
        "title": "Audio guide: {name}",
        "intro": "Welcome to {name}. Here is what you should know about this place.",
        "empty": "Welcome to {name}. Its verified audio guide will be available here soon.",
        "closing": "Enjoy your visit.",
    },
    "fr": {
        "title": "Audioguide : {name}",
        "intro": "Bienvenue à {name}. Voici l'essentiel à savoir sur ce lieu.",
        "empty": "Bienvenue à {name}. Son audioguide vérifié sera bientôt disponible ici.",
        "closing": "Bonne visite.",
    },
    "de": {
        "title": "Audioguide: {name}",
        "intro": "Willkommen in {name}. Hier das Wichtigste über diesen Ort.",
        "empty": "Willkommen in {name}. Der geprüfte Audioguide ist hier bald verfügbar.",
        "closing": "Viel Freude bei Ihrem Besuch.",
    },
    "it": {
        "title": "Audioguida: {name}",
        "intro": "Benvenuto a {name}. Ecco l'essenziale su questo luogo.",
        "empty": "Benvenuto a {name}. La sua audioguida verificata sarà presto disponibile qui.",
        "closing": "Buona visita.",
    },
    "pt": {
        "title": "Audioguia: {name}",
        "intro": "Bem-vindo a {name}. Eis o essencial sobre este lugar.",
        "empty": "Bem-vindo a {name}. O seu audioguia verificado estará disponível aqui em breve.",
        "closing": "Boa visita.",
    },
}


@dataclass(frozen=True, slots=True)
class WriterSettings:
    temperature: float
    max_output_tokens: int
    max_attempts: int
    # ~150 palabras por minuto hablado: 260 palabras ≈ menos de dos minutos.
    max_words: int = 260


def guide_problems(draft: GuideDraft, facts: Sequence[ZoneFact], zone_name: str, max_words: int) -> list[str]:
    """Motivos por los que un borrador NO está bien anclado a los hechos (vacía = OK)."""
    by_id = {f.fact_id: f for f in facts}
    name_numbers = set(_NUMBER.findall(zone_name))
    problems: list[str] = []
    cited: set[str] = set()

    if set(_NUMBER.findall(draft.title)) - name_numbers:
        problems.append("el título no puede llevar cifras")
    for i, seg in enumerate(draft.segments, start=1):
        unknown = sorted(set(seg.fact_ids) - by_id.keys())
        if unknown:
            problems.append(f"el párrafo {i} cita hechos que no existen: {', '.join(unknown)}")
        known = [by_id[f] for f in seg.fact_ids if f in by_id]
        cited.update(f.fact_id for f in known)
        # Cada número del párrafo debe estar, tal cual, en un hecho que cita.
        allowed = name_numbers.union(*(set(_NUMBER.findall(f.text)) for f in known))
        invented = sorted(set(_NUMBER.findall(seg.text)) - allowed)
        if invented:
            problems.append(f"el párrafo {i} usa cifras que no están en sus hechos: {', '.join(invented)}")
        lowered = seg.text.lower()
        if "http" in lowered or "www." in lowered:
            problems.append(f"el párrafo {i} contiene un enlace")

    needed = min(2, len(facts))
    if len(cited) < needed:
        problems.append(f"usa al menos {needed} hechos distintos de la lista")
    words = sum(len(_WORD.findall(s.text)) for s in draft.segments)
    if words > max_words:
        problems.append(f"demasiado largo ({words} palabras, máximo {max_words})")
    return list(dict.fromkeys(problems))


class AudioguideWriter:
    def __init__(
        self,
        *,
        llm: LLMClient | None,
        settings: WriterSettings,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._llm = llm
        self._settings = settings
        self._clock = clock

    async def write(self, zone: ZoneFacts, language: str) -> AudioguideScript:
        """Redacta el guion. Nunca lanza por culpa del LLM: en el peor caso, reglas."""
        # Sin hechos no hay nada que el LLM pueda decir con seguridad.
        if self._llm is None or not zone.facts:
            return self.by_rules(zone, language)
        try:
            draft = await generate_structured(
                self._llm,
                self._prompt(zone, language),
                GuideDraft,
                temperature=self._settings.temperature,
                max_tokens=self._settings.max_output_tokens,
                max_attempts=self._settings.max_attempts,
                checks=lambda d: guide_problems(d, zone.facts, zone.name, self._settings.max_words),
            )
        except (LLMError, StructuredOutputError) as exc:
            log.warning(
                "LLM no disponible o sin guion válido: se usan reglas",
                extra={"zone_id": zone.zone_id, "language": language, "error": str(exc)},
            )
            return self.by_rules(zone, language)

        cited = {f for seg in draft.segments for f in seg.fact_ids}
        try:
            return AudioguideScript(
                zone_id=zone.zone_id,
                zone_name=zone.name,
                language=language,
                content_language=language,
                title=draft.title,
                segments=tuple(GuideSegment(text=s.text, fact_ids=tuple(s.fact_ids)) for s in draft.segments),
                facts=tuple(f for f in zone.facts if f.fact_id in cited),
                source="llm",
                model=self._llm.model,
                content_version=zone.content_version,
                generated_at=self._clock(),
            )
        except ValidationError:
            log.warning("guion del LLM fuera de límites: se usan reglas", extra={"zone_id": zone.zone_id})
            return self.by_rules(zone, language)

    def _prompt(self, zone: ZoneFacts, language: str) -> list[ChatMessage]:
        facts = {f.fact_id: f.text for f in zone.facts}
        user = (
            f"Lugar: {zone.name}\n"
            f"Idioma del guion: {LANGUAGE_NAMES.get(language, language)} ({language})\n"
            f"Longitud máxima: {self._settings.max_words} palabras en total.\n\n"
            "Hechos verificados (etiqueta -> hecho):\n"
            + json.dumps(facts, ensure_ascii=False, indent=1)
            + "\n\nRedacta la audioguía siguiendo las reglas."
        )
        return [ChatMessage("system", SYSTEM_PROMPT), ChatMessage("user", user)]

    def by_rules(self, zone: ZoneFacts, language: str) -> AudioguideScript:
        """Plan B determinista: plantillas + los hechos tal cual están escritos.

        Los hechos están en ``zone.facts_language``; si no coincide con el
        idioma pedido, el guion se escribe entero en el idioma de los hechos
        (mezclar idiomas en una misma frase suena fatal). ``content_language``
        lo indica para que la app pueda avisar.
        """
        content_language = zone.facts_language if zone.facts else language
        texts = _RULES_TEXT.get(content_language, _RULES_TEXT["en"])
        if zone.facts:
            segments = [
                GuideSegment(text=texts["intro"].format(name=zone.name)),
                *(GuideSegment(text=f.text, fact_ids=(f.fact_id,)) for f in zone.facts[:5]),
                GuideSegment(text=texts["closing"]),
            ]
        else:
            segments = [GuideSegment(text=texts["empty"].format(name=zone.name))]
        return AudioguideScript(
            zone_id=zone.zone_id,
            zone_name=zone.name,
            language=language,
            content_language=content_language,
            title=texts["title"].format(name=zone.name),
            segments=tuple(segments),
            facts=tuple(zone.facts[:5]),
            source="rules",
            content_version=zone.content_version,
            generated_at=self._clock(),
        )
