"""El worker de audio: recoge trabajos de la cola y graba las audioguías con Piper.

Va en un proceso (y un contenedor) APARTE de la API: sintetizar voz gasta
mucha CPU durante segundos, y no queremos que eso frene las respuestas a los
usuarios. Analogía: la cocina de un restaurante no está en el comedor.

Qué hace con cada trabajo "zona X, versión N":
    1. Si la zona ya no existe, no se narra o ya hay una versión más nueva
       → se cierra sin grabar nada (el trabajo nuevo ya está en la cola).
    2. Para cada idioma con voz: pide el guion de texto de ESA versión al
       servicio de audioguías (lo genera si hace falta, con todas sus
       protecciones: caché, single flight, cerrojo, anclaje a hechos).
    3. Si ese guion ya está grabado (misma huella), no repite el trabajo.
    4. Graba cada párrafo (Piper → Opus), lo guarda con su ruta inmutable y,
       AL FINAL, guarda el manifiesto. El orden importa: el manifiesto solo
       aparece cuando todos sus archivos existen, así la API nunca anuncia
       un archivo que todavía no está.
    5. Si algo falla, el trabajo vuelve a la cola con espera creciente
       (30 s, 1 min, 2 min...). Tras ``max_attempts`` fallos se abandona y
       queda apuntado el error para revisarlo.

Además, cada ``gc_interval_seconds`` pasa el recolector de basura
(audio_gc.py), que borra las grabaciones viejas con su ventana de gracia.

Si el guion salió del plan B (reglas) porque el LLM no estaba, se graba
igualmente (mejor eso que nada) y el trabajo se reprograma para más tarde:
cuando el LLM vuelva, el guion nuevo tendrá otra huella y se grabará en rutas
nuevas sin pisar las anteriores.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from ai_orchestrator.audioguides.audio_gc import AudioGarbageCollector
from ai_orchestrator.audioguides.audio_jobs import (
    AudioJob,
    AudioJobQueue,
    AudioManifest,
    AudioManifests,
    AudioPart,
)
from ai_orchestrator.audioguides.audio_store import AudioStore, AudioStoreError, audio_key, script_digest
from ai_orchestrator.audioguides.domain import NARRATED_KINDS, AudioguideScript
from ai_orchestrator.audioguides.service import AudioguideService
from ai_orchestrator.audioguides.speech import Synthesizer
from ai_orchestrator.store import StoreError

log = logging.getLogger(__name__)


class JobOutcome(StrEnum):
    # Grabado (o ya estaba grabado) en todos los idiomas con voz.
    DONE = "done"
    # Hay una versión más nueva: este trabajo ya no hace falta.
    SUPERSEDED = "superseded"
    # La zona no existe, está desactivada o no se narra.
    SKIPPED = "skipped"
    # Grabado con el plan B: se repetirá más tarde por si el LLM ya responde.
    RESCHEDULED = "rescheduled"
    # Falló: vuelve a la cola con espera.
    RETRY = "retry"
    # Falló demasiadas veces seguidas: se abandona.
    GAVE_UP = "gave_up"


class _NotReady(Exception):
    """El guion de texto aún no está (lo genera otra copia, o la versión no se ve todavía)."""


@dataclass(frozen=True, slots=True)
class WorkerSettings:
    # Idiomas que se graban (los que tienen voz instalada).
    languages: tuple[str, ...]
    # Lo que puede tardar un trabajo completo (LLM + voz en todos los idiomas) + margen.
    lease_seconds: int = 900
    # Cada cuánto se mira la cola aunque nadie toque el timbre (red de seguridad).
    poll_seconds: float = 30.0
    # Cada cuánto se buscan zonas sin ningún trabajo apuntado.
    sweep_seconds: float = 600.0
    max_attempts: int = 5
    retry_initial_seconds: float = 30.0
    retry_max_seconds: float = 3600.0
    # Si el guion salió del plan B, cuándo volver a intentarlo con el LLM.
    upgrade_delay_seconds: float = 3600.0
    llm_enabled: bool = True
    # Cada cuánto pasa el recolector de basura (si hay uno).
    gc_interval_seconds: float = 6 * 3600.0


class AudioWorker:
    def __init__(
        self,
        *,
        jobs: AudioJobQueue,
        manifests: AudioManifests,
        store: AudioStore,
        synthesizer: Synthesizer,
        audioguides: AudioguideService,
        settings: WorkerSettings,
        gc: AudioGarbageCollector | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._jobs = jobs
        self._manifests = manifests
        self._store = store
        self._synth = synthesizer
        self._audioguides = audioguides
        self._settings = settings
        self._gc = gc
        self._clock = clock
        self._running = False

    @property
    def running(self) -> bool:
        return self._running

    async def run(self, wake: asyncio.Event) -> None:
        """Bucle principal. ``wake`` se activa con cada aviso de pg_notify."""
        self._running = True
        next_sweep = 0.0
        next_gc = 0.0
        try:
            while True:
                # Se borra ANTES de mirar la cola: si llega un aviso mientras
                # miramos, el evento queda activado y no lo perdemos.
                wake.clear()
                try:
                    if self._clock() >= next_sweep:
                        added = await self._jobs.enqueue_missing()
                        if added:
                            log.info("zonas sin audio apuntadas en la cola", extra={"jobs": added})
                        next_sweep = self._clock() + self._settings.sweep_seconds
                    if self._gc is not None and self._clock() >= next_gc:
                        next_gc = self._clock() + self._settings.gc_interval_seconds
                        await self._collect_garbage()
                    job = await self._jobs.claim(lease_seconds=self._settings.lease_seconds)
                    if job is not None:
                        await self.process(job)
                        continue
                except StoreError as exc:
                    # PostgreSQL caído: esperamos y volvemos a probar. Si
                    # teníamos un trabajo prestado, su préstamo caducará solo.
                    log.warning("cola de audio no disponible", extra={"error": str(exc)})
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(wake.wait(), timeout=self._settings.poll_seconds)
        finally:
            self._running = False

    async def _collect_garbage(self) -> None:
        assert self._gc is not None  # noqa: S101 (lo comprueba quien llama)
        try:
            await self._gc.run_once()
        except AudioStoreError as exc:
            # Un disco con problemas no debe parar la grabación: se reintentará
            # en la siguiente pasada.
            log.warning("el recolector de audio falló", extra={"error": str(exc)})

    async def process(self, job: AudioJob) -> JobOutcome:
        if job.zone_id is None or not job.zone_active or job.zone_kind not in NARRATED_KINDS:
            await self._jobs.complete(job)
            return self._log(job, JobOutcome.SKIPPED)
        if job.current_version > job.content_version:
            await self._jobs.complete(job)
            return self._log(job, JobOutcome.SUPERSEDED)
        try:
            outcome = await self._record_all(job, job.zone_id)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # Cualquier fallo (voz, disco, Redis, PostgreSQL... o un error de
            # programación) devuelve el trabajo a la cola. Un trabajo "venenoso"
            # no tumba el worker en bucle: tras max_attempts se abandona.
            error = f"{type(exc).__name__}: {exc}"
            if not isinstance(exc, (_NotReady, StoreError)):
                log.exception("fallo grabando audio", extra={"zone": job.zone_slug})
            if job.attempt >= self._settings.max_attempts:
                await self._jobs.give_up(job, error=error)
                return self._log(job, JobOutcome.GAVE_UP, error=error)
            delay = min(
                self._settings.retry_max_seconds,
                self._settings.retry_initial_seconds * 2 ** (job.attempt - 1),
            )
            await self._jobs.retry(job, delay_seconds=delay, error=error)
            return self._log(job, JobOutcome.RETRY, error=error)
        if outcome is JobOutcome.RESCHEDULED:
            await self._jobs.reschedule(job, delay_seconds=self._settings.upgrade_delay_seconds)
        else:
            await self._jobs.complete(job)
        return self._log(job, outcome)

    async def _record_all(self, job: AudioJob, zone_id: str) -> JobOutcome:
        needs_upgrade = False
        for language in self._settings.languages:
            outcome, script = await self._audioguides.ensure_script(zone_id, language, fresh=True)
            if script is None:
                raise _NotReady(f"guion de {language} no disponible todavía ({outcome})")
            if script.content_version > job.content_version:
                # Alguien corrigió los hechos mientras tanto: lo grabará el trabajo nuevo.
                return JobOutcome.SUPERSEDED
            if script.content_version < job.content_version:
                raise _NotReady(f"el guion de {language} aún es de la versión {script.content_version}")
            if script.source == "rules" and self._settings.llm_enabled:
                needs_upgrade = True
            await self._record(job, language, script)
        return JobOutcome.RESCHEDULED if needs_upgrade else JobOutcome.DONE

    async def _record(self, job: AudioJob, language: str, script: AudioguideScript) -> None:
        # La voz va con el idioma en el que ESTÁ escrito el texto (el plan B
        # sin traducción puede estar en otro idioma que el pedido).
        voice = self._synth.voice_for(script.content_language)
        if voice is None:
            log.info(
                "sin voz para este idioma: la app usará la voz del teléfono",
                extra={"zone": job.zone_slug, "language": script.content_language},
            )
            return
        digest = script_digest(script)
        if await self._manifests.exists(job.zone_slug, language, job.content_version, digest):
            return
        started = self._clock()
        parts: list[AudioPart] = []
        for index, segment in enumerate(script.segments, start=1):
            key = audio_key(job.zone_slug, language, job.content_version, digest, index)
            spoken = await self._synth.speak(segment.text, voice)
            await self._store.put(key, spoken.data)
            parts.append(
                AudioPart(index=index, key=key, duration_seconds=spoken.duration_seconds, text=segment.text)
            )
        # El manifiesto, el último: solo cuando todos los archivos existen.
        await self._manifests.save(
            AudioManifest(
                zone_slug=job.zone_slug,
                language=language,
                content_language=script.content_language,
                content_version=job.content_version,
                script_digest=digest,
                source=script.source,
                voice=voice.name,
                parts=tuple(parts),
            )
        )
        log.info(
            "audioguía grabada",
            extra={
                "zone": job.zone_slug,
                "language": language,
                "content_version": job.content_version,
                "parts": len(parts),
                "audio_seconds": round(sum(p.duration_seconds for p in parts), 1),
                "render_seconds": round(self._clock() - started, 1),
                "voice": voice.name,
            },
        )

    def _log(self, job: AudioJob, outcome: JobOutcome, *, error: str | None = None) -> JobOutcome:
        extra: dict[str, object] = {
            "zone": job.zone_slug,
            "content_version": job.content_version,
            "attempt": job.attempt,
            "outcome": outcome.value,
        }
        if error:
            extra["error"] = error[:300]
        level = logging.WARNING if outcome in {JobOutcome.RETRY, JobOutcome.GAVE_UP} else logging.INFO
        log.log(level, "trabajo de audio terminado", extra=extra)
        return outcome
