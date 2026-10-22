"""Lo que consulta la API para el audio: "¿qué archivos suenan en esta zona?".

Igual que con el texto, la API nunca graba nada: solo busca el manifiesto
más reciente y devuelve las URLs. Y como pueden preguntar miles de personas a
la vez por la misma zona, el manifiesto se recuerda en memoria
(:class:`~ai_orchestrator.audioguides.versions.TtlMemo`), con la versión de
la zona como parte de la clave: cuando la versión sube, se busca de nuevo.

Plan B si la versión actual todavía se está grabando (unos segundos o
minutos tras corregir un hecho): se devuelve el audio de la versión anterior,
marcado con ``stale=true`` y con el texto exacto de cada parte, para que la
app muestre lo que de verdad suena. Si no hay audio de ninguna versión, 404 y
la app puede leer el guion de texto con la voz del propio teléfono.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from ai_orchestrator.audioguides.audio_jobs import AudioManifest, AudioManifests
from ai_orchestrator.audioguides.audio_store import AudioStore, parse_key
from ai_orchestrator.audioguides.domain import resolve_language
from ai_orchestrator.audioguides.versions import TtlMemo, ZoneVersionCache


@dataclass(frozen=True, slots=True)
class Gone:
    """El archivo existió pero el recolector lo borró (ver audio_gc.py)."""

    # Dónde pedir el audio actual de esa zona, o None si la zona ya no existe.
    current_manifest: str | None


@dataclass(frozen=True, slots=True)
class AudioLookup:
    # Versión ACTUAL del contenido de la zona.
    current_version: int
    manifest: AudioManifest

    @property
    def stale(self) -> bool:
        """True si suena una versión anterior porque la actual aún se está grabando."""
        return self.manifest.content_version < self.current_version


class AudioCatalog:
    def __init__(
        self,
        *,
        versions: ZoneVersionCache,
        manifests: AudioManifests,
        store: AudioStore,
        default_language: str,
        public_base_url: str,
        cache_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._versions = versions
        self._manifests = manifests
        self._store = store
        self._default_language = default_language
        self._base = public_base_url.rstrip("/")
        self._memo: TtlMemo[tuple[str, str, int], AudioManifest | None] = TtlMemo(
            ttl_seconds=cache_seconds, clock=clock
        )

    async def lookup(self, zone_id: str, language: str) -> AudioLookup | None:
        version = await self._versions.get(zone_id)
        if version is None:
            return None
        lang = resolve_language(language, self._default_language)
        manifest = await self._memo.get(
            (zone_id, lang, version), lambda: self._manifests.latest(zone_id, lang, version)
        )
        return None if manifest is None else AudioLookup(current_version=version, manifest=manifest)

    def url(self, key: str) -> str:
        """URL pública de una parte (en producción, la de la CDN)."""
        return f"{self._base}/{key}"

    def file(self, key: str) -> Path | None:
        return self._store.local_path(key)

    async def gone(self, key: str) -> Gone | None:
        """Si un archivo que falta fue borrado por el recolector, adónde mandar al móvil.

        Solo se consulta cuando el archivo NO está (caso raro: un móvil muy
        atrasado), así que no añade carga en el camino normal.
        """
        parts = parse_key(key)
        if parts is None:
            return None
        stone = await self._manifests.tombstone(*parts)
        if stone is None:
            return None
        if stone.zone_id is None:
            return Gone(current_manifest=None)
        return Gone(current_manifest=f"/v1/audioguides/{stone.zone_id}/audio?lang={stone.language}")
