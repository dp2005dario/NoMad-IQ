"""Junta las piezas: "asegúrate de que existe el guion de esta zona en este idioma".

Orden de las comprobaciones, de la más barata a la más cara:
    1. ¿Es una zona que se narra? (aeropuertos y zonas restringidas, no)
    2. ¿Ya está en la caché? → listo, sin tocar la base de datos ni el LLM.
    3. ¿Lo está generando otra tarea de este proceso? → esperar su resultado.
    4. ¿Lo está generando otra copia del servicio? (cerrojo de Redis) → no repetir.
    5. Generar: hechos de PostgreSQL → redactor (LLM o reglas) → caché.

Caducidades distintas según quién redactó:
    - Guion del LLM: días (``llm_ttl_seconds``). El sitio no cambia cada hora.
    - Guion de reglas: poco (``rules_ttl_seconds``). Es el plan B: en cuanto
      caduque y vuelva a entrar alguien, se intentará de nuevo con el LLM.
"""

from __future__ import annotations

import logging
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum

from ai_orchestrator.audioguides.cache import ScriptCache, SingleFlight, content_key
from ai_orchestrator.audioguides.domain import (
    NARRATED_KINDS,
    AudioguideScript,
    ZoneEntry,
    resolve_language,
)
from ai_orchestrator.audioguides.facts import ZoneFactsSource
from ai_orchestrator.audioguides.writer import AudioguideWriter

log = logging.getLogger(__name__)


class Outcome(StrEnum):
    # Ya estaba en la caché.
    CACHED = "cached"
    # Lo hemos generado ahora.
    GENERATED = "generated"
    # Otra tarea de este proceso lo estaba generando: compartimos su resultado.
    SHARED = "shared"
    # Otra copia del servicio tiene el cerrojo: ya se está generando.
    BUSY_ELSEWHERE = "busy_elsewhere"
    # Tipo de zona sin audioguía (aeropuerto, zona restringida...).
    NOT_NARRATED = "not_narrated"
    # La zona no existe (o está desactivada) en geo.zones.
    UNKNOWN_ZONE = "unknown_zone"


@dataclass(frozen=True, slots=True)
class ServiceSettings:
    default_language: str
    llm_ttl_seconds: int
    rules_ttl_seconds: int
    # Debe superar lo que puede tardar una generación completa (con reintentos):
    # si caducase antes, otra copia empezaría la misma generación.
    lock_ttl_seconds: int


class AudioguideService:
    def __init__(
        self,
        *,
        facts: ZoneFactsSource,
        writer: AudioguideWriter,
        cache: ScriptCache,
        settings: ServiceSettings,
    ) -> None:
        self._facts = facts
        self._writer = writer
        self._cache = cache
        self._settings = settings
        self._flight: SingleFlight[Outcome] = SingleFlight()

    def target(self, entry: ZoneEntry) -> tuple[str, str] | None:
        """(zone_id, idioma) del guion que necesita esta entrada, o None si no se narra."""
        if entry.zone_kind not in NARRATED_KINDS:
            return None
        return entry.zone_id, resolve_language(entry.language, self._settings.default_language)

    async def ensure(self, entry: ZoneEntry) -> Outcome:
        target = self.target(entry)
        if target is None:
            return Outcome.NOT_NARRATED
        return await self.ensure_zone(*target)

    async def ensure_zone(self, zone_id: str, language: str) -> Outcome:
        if await self._cache.get(zone_id, language) is not None:
            return Outcome.CACHED
        outcome, shared = await self._flight.do(
            content_key(zone_id, language), lambda: self._generate(zone_id, language)
        )
        return Outcome.SHARED if shared else outcome

    async def get(self, zone_id: str, language: str) -> AudioguideScript | None:
        """Lo que consulta la API: solo lee la caché, nunca genera (milisegundos)."""
        return await self._cache.get(zone_id, resolve_language(language, self._settings.default_language))

    async def pregenerate(self, languages: Sequence[str]) -> Counter[Outcome]:
        """Prepara por adelantado los guiones de todas las zonas narrables.

        Así el primer turista del día ya lo encuentra hecho. Es seguro lanzarlo
        mientras el servicio funciona: el cerrojo evita trabajo duplicado.
        """
        results: Counter[Outcome] = Counter()
        for zone_id in await self._facts.narrated_zone_ids():
            for language in dict.fromkeys(
                resolve_language(lang, self._settings.default_language) for lang in languages
            ):
                results[await self.ensure_zone(zone_id, language)] += 1
        return results

    async def _generate(self, zone_id: str, language: str) -> Outcome:
        token = await self._cache.try_lock(zone_id, language, ttl_seconds=self._settings.lock_ttl_seconds)
        if token is None:
            return Outcome.BUSY_ELSEWHERE
        try:
            # Segunda mirada YA con el cerrojo: otra copia pudo terminar justo
            # entre nuestra primera lectura y el cerrojo.
            if await self._cache.get(zone_id, language) is not None:
                return Outcome.CACHED
            zone = await self._facts.load(
                zone_id, language=language, fallback_language=self._settings.default_language
            )
            if zone is None:
                log.info("entrada en una zona desconocida", extra={"zone_id": zone_id})
                return Outcome.UNKNOWN_ZONE
            # Manda lo que diga la base de datos, no el evento.
            if zone.kind not in NARRATED_KINDS:
                return Outcome.NOT_NARRATED
            script = await self._writer.write(zone, language)
            ttl = (
                self._settings.llm_ttl_seconds if script.source == "llm" else self._settings.rules_ttl_seconds
            )
            await self._cache.put(script, ttl_seconds=ttl)
            log.info(
                "audioguía generada",
                extra={
                    "zone_id": zone_id,
                    "language": language,
                    "source": script.source,
                    "segments": len(script.segments),
                },
            )
            return Outcome.GENERATED
        finally:
            await self._cache.unlock(zone_id, language, token)
