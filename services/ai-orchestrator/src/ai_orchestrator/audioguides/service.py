"""Junta las piezas: "asegúrate de que existe el guion de esta zona en este idioma".

Orden de las comprobaciones, de la más barata a la más cara:
    1. ¿Es una zona que se narra? (aeropuertos y zonas restringidas, no)
    2. ¿Qué versión de contenido tiene la zona? (en memoria casi siempre, ver
       versions.py: PostgreSQL solo una vez por zona y minuto)
    3. ¿Ya está en la caché el guion de ESA versión? → listo, sin LLM.
    4. ¿Lo está generando otra tarea de este proceso? → esperar su resultado.
    5. ¿Lo está generando otra copia del servicio? (cerrojo de Redis) → no repetir.
    6. Generar: hechos de PostgreSQL → redactor (LLM o reglas) → caché.

Caducidades distintas según quién redactó:
    - Guion del LLM: 24 horas (``llm_ttl_seconds``). Las correcciones de hechos
      ya no esperan al TTL (cambian la versión), pero un día es un buen
      equilibrio para refrescar el texto sin hacer trabajar de más al LLM.
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
from ai_orchestrator.audioguides.versions import ZoneVersionCache
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
        versions: ZoneVersionCache,
        settings: ServiceSettings,
    ) -> None:
        self._facts = facts
        self._versions = versions
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
        version = await self._versions.get(zone_id)
        if version is None:
            return Outcome.UNKNOWN_ZONE
        if await self._cache.get(zone_id, language, version) is not None:
            return Outcome.CACHED
        outcome, shared = await self._flight.do(
            content_key(zone_id, language, version), lambda: self._generate(zone_id, language, version)
        )
        return Outcome.SHARED if shared else outcome

    async def get(self, zone_id: str, language: str) -> AudioguideScript | None:
        """Lo que consulta la API: solo lee la caché, nunca genera (milisegundos)."""
        version = await self._versions.get(zone_id)
        if version is None:
            return None
        return await self._cache.get(
            zone_id, resolve_language(language, self._settings.default_language), version
        )

    async def ensure_script(
        self, zone_id: str, language: str, *, fresh: bool = False
    ) -> tuple[Outcome, AudioguideScript | None]:
        """Asegura el guion y lo devuelve (lo usa el worker de audio).

        ``fresh=True`` olvida antes la versión recordada en memoria: el worker
        acaba de enterarse de que la versión ha cambiado y no puede esperar
        al minuto que tarda en caducar.
        """
        if fresh:
            self._versions.forget(zone_id)
        outcome = await self.ensure_zone(zone_id, language)
        return outcome, await self.get(zone_id, language)

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

    async def _generate(self, zone_id: str, language: str, version: int) -> Outcome:
        token = await self._cache.try_lock(
            zone_id, language, version, ttl_seconds=self._settings.lock_ttl_seconds
        )
        if token is None:
            return Outcome.BUSY_ELSEWHERE
        try:
            # Segunda mirada YA con el cerrojo: otra copia pudo terminar justo
            # entre nuestra primera lectura y el cerrojo.
            if await self._cache.get(zone_id, language, version) is not None:
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
            if zone.content_version != version:
                # Alguien corrigió los hechos hace segundos y nuestra versión
                # en memoria aún es la vieja. El guion se guarda con la versión
                # REAL de los hechos con que se escribe (la nueva) y olvidamos
                # la vieja para que la próxima entrada la vea.
                self._versions.forget(zone_id)
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
                    "content_version": script.content_version,
                    "segments": len(script.segments),
                },
            )
            return Outcome.GENERATED
        finally:
            await self._cache.unlock(zone_id, language, version, token)
