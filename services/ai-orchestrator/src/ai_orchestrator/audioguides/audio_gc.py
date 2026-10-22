"""El recolector de basura del audio: borra versiones viejas sin romper a ningún móvil.

El problema: cada corrección de hechos deja una grabación completa nueva y la
vieja se queda en el disco. A escala son ~2 GB por versión: sin limpiar, el
almacén crece para siempre. Pero si borramos demasiado pronto, el móvil que
guardó el manifiesto de ayer (o que lo usa sin conexión) pedirá archivos que
ya no existen.

La política, "ventana de gracia + versión de reserva":

1. **Nunca** se borran las 2 grabaciones más recientes de cada zona e idioma
   (la actual, N, y la anterior, N-1): ``keep``.
2. Una grabación sustituida entra en **cuarentena**: la API ya no la anuncia
   (siempre da la más nueva), pero sus archivos siguen ahí durante
   ``grace_days`` (30 días) contados desde que la sustituyeron.
3. Pasada la cuarentena, se borran sus archivos y su fila queda como
   **lápida** (``purged_at``): si alguien pide un archivo borrado, la API
   responde 410 Gone con el enlace al manifiesto actual (ver api.py).
4. **Huérfanos**: archivos que no aparecen en ningún manifiesto vivo (una
   grabación cortada a mitad, temporales de un apagón...). Se borran si
   tienen más de ``orphan_grace_hours`` (24 h), para no tocar nunca una
   grabación que se está haciendo ahora mismo.

Analogía: una biblioteca que retira las ediciones viejas de un libro. No las
tira el día que llega la nueva (alguien puede tenerla prestada): las saca de
la estantería, las guarda un mes en el almacén y luego las recicla, dejando
una ficha que dice "esta edición ya no existe, pide la nueva".

¿Y la CDN? Si guardó un archivo que luego borramos, lo seguirá sirviendo
mientras lo tenga: no es un problema, es justo lo que quiere el móvil
atrasado (el archivo era válido y nunca cambia). Lo que NO debe guardar son
las respuestas de error: por eso los 404/410 de audio van con
``Cache-Control: no-store``.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Protocol

from ai_orchestrator.audioguides.audio_jobs import AudioGcStore
from ai_orchestrator.audioguides.audio_store import is_valid_key

log = logging.getLogger(__name__)


class PrunableStore(Protocol):
    async def delete(self, key: str) -> None: ...

    async def old_files(self, *, older_than_seconds: float) -> list[str]: ...

    async def delete_any(self, relative: str) -> None: ...

    async def prune_empty_dirs(self) -> int: ...


@dataclass(frozen=True, slots=True)
class GcSettings:
    # Grabaciones más recientes que nunca se borran (N y N-1).
    keep: int = 2
    # Días de cuarentena desde que una grabación deja de ser la buena.
    grace_days: float = 30.0
    # Horas que debe tener un archivo huérfano antes de borrarlo.
    orphan_grace_hours: float = 24.0
    # Grabaciones borradas por pasada (para no tener un borrado gigante de golpe).
    batch: int = 500


@dataclass(slots=True)
class GcReport:
    skipped: bool = False
    purged_recordings: int = 0
    deleted_files: int = 0
    deleted_orphans: int = 0
    removed_dirs: int = 0
    zones: set[str] = field(default_factory=set)


class AudioGarbageCollector:
    def __init__(self, *, manifests: AudioGcStore, store: PrunableStore, settings: GcSettings) -> None:
        if settings.keep < 1:
            # Con keep=0 se podría borrar la grabación ACTUAL: nunca.
            raise ValueError("keep debe ser al menos 1")
        self._manifests = manifests
        self._store = store
        self._settings = settings

    async def run_once(self) -> GcReport:
        report = GcReport()
        async with self._manifests.exclusive() as acquired:
            if not acquired:
                # Otro worker está limpiando ahora mismo: no duplicamos el trabajo.
                report.skipped = True
                return report
            await self._purge_expired(report)
            await self._delete_orphans(report)
            report.removed_dirs = await self._store.prune_empty_dirs()
        log.info(
            "recolector de audio",
            extra={
                "purged_recordings": report.purged_recordings,
                "deleted_files": report.deleted_files,
                "deleted_orphans": report.deleted_orphans,
                "removed_dirs": report.removed_dirs,
                "zones": sorted(report.zones)[:20],
            },
        )
        return report

    async def _purge_expired(self, report: GcReport) -> None:
        expired = await self._manifests.expired(
            keep=self._settings.keep, grace_days=self._settings.grace_days, limit=self._settings.batch
        )
        for manifest in expired:
            # Primero los archivos y DESPUÉS la lápida. Si algo se corta a
            # mitad, la grabación sigue "viva" en la base de datos y la
            # próxima pasada vuelve a intentarlo (borrar dos veces es seguro).
            for part in manifest.parts:
                await self._store.delete(part.key)
                report.deleted_files += 1
            await self._manifests.mark_purged(manifest)
            report.purged_recordings += 1
            report.zones.add(manifest.zone_slug)

    async def _delete_orphans(self, report: GcReport) -> None:
        # Orden importante: primero la lista de archivos viejos, DESPUÉS la de
        # archivos vivos. Así, si una grabación termina entre las dos
        # consultas, sus archivos aparecen como vivos y no se tocan.
        candidates = await self._store.old_files(older_than_seconds=self._settings.orphan_grace_hours * 3600)
        alive = await self._manifests.referenced_keys()
        for relative in candidates:
            if is_valid_key(relative) and relative in alive:
                continue
            await self._store.delete_any(relative)
            report.deleted_orphans += 1
