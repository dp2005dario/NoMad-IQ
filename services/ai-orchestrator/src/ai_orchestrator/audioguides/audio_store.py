"""Dónde se guardan los archivos de audio y cómo se llaman.

La regla de oro: **una ruta, una vez publicada, nunca cambia de contenido**
(URLs inmutables). La ruta lleva todo lo que puede cambiar el audio:

    <zona>/<idioma>/v<versión>/<huella del guion>/parte-<n>.opus
    madrid-centro/es/v3/9f2c4a1b7e3d5f60/parte-1.opus

- Si alguien corrige un hecho, sube la versión → ruta nueva.
- Si el texto del guion cambia sin cambiar los hechos (el plan B por reglas
  se sustituye por el guion del LLM), cambia la huella → ruta nueva.

¿Y para qué tanto? Para que una CDN (la red de servidores que reparte
archivos cerca del usuario) y el propio móvil puedan guardar cada archivo
"para siempre" (``Cache-Control: immutable``) sin tener que purgar nada
nunca. Analogía: en vez de borrar la pizarra y escribir encima (y que haya
quien lea la versión a medio borrar), se cuelga un cartel nuevo con otro
número y se avisa de cuál es el bueno (el "manifiesto", ver audio_jobs.py).

Hoy el almacén es una carpeta (un volumen de Docker). En producción sería un
almacén de objetos compatible con S3 con capa gratuita: basta con otra clase
que cumpla el mismo protocolo :class:`AudioStore`.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
from pathlib import Path
from typing import Protocol

from ai_orchestrator.audioguides.domain import AudioguideScript

# Así es una clave válida. Se comprueba al crearla Y al servirla: nadie puede
# pedir "../../etc/passwd" porque no encaja en este patrón.
_KEY = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z]{2,3}/v[0-9]{1,12}/[0-9a-f]{16}/parte-[0-9]{1,2}\.opus$")
_SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_LANGUAGE = re.compile(r"^[a-z]{2,3}$")
_DIGEST = re.compile(r"^[0-9a-f]{16}$")


class AudioStoreError(Exception):
    """No se pudo leer o escribir en el almacén (disco lleno, permisos...)."""


def script_digest(script: AudioguideScript) -> str:
    """Huella (16 caracteres hex) de lo que se va a decir en voz alta.

    Solo entra lo que suena: el idioma real y los textos. Si dos guiones dicen
    exactamente lo mismo, tienen la misma huella y el audio no se repite.
    """
    payload = json.dumps(
        {"lang": script.content_language, "segments": [s.text for s in script.segments]},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def audio_key(slug: str, language: str, version: int, digest: str, index: int) -> str:
    """La clave (ruta relativa) de una parte. Lanza ValueError si algo no encaja."""
    if not _SLUG.fullmatch(slug) or len(slug) > 100:
        raise ValueError(f"slug de zona inválido: {slug!r}")
    if not _LANGUAGE.fullmatch(language):
        raise ValueError(f"idioma inválido: {language!r}")
    if version < 0 or not _DIGEST.fullmatch(digest) or not 1 <= index <= 99:
        raise ValueError("versión, huella o número de parte inválidos")
    key = f"{slug}/{language}/v{version}/{digest}/parte-{index}.opus"
    if not is_valid_key(key):
        raise ValueError(f"clave de audio inválida: {key!r}")
    return key


def is_valid_key(key: str) -> bool:
    return _KEY.fullmatch(key) is not None


class AudioStore(Protocol):
    async def exists(self, key: str) -> bool: ...

    async def put(self, key: str, data: bytes) -> None:
        """Guarda el archivo de forma atómica: o está entero, o no está."""
        ...

    def local_path(self, key: str) -> Path | None:
        """Ruta en disco para servirlo, o None si no existe (o la clave no vale)."""
        ...


class FilesystemAudioStore:
    """Almacén en una carpeta (en Docker, un volumen compartido)."""

    def __init__(self, root: Path) -> None:
        self._root = root.resolve()

    def _path(self, key: str) -> Path:
        if not is_valid_key(key):
            raise ValueError(f"clave de audio inválida: {key!r}")
        path = (self._root / key).resolve()
        # Doble cinturón: aunque el patrón ya lo impide, comprobamos que la
        # ruta final sigue DENTRO de la carpeta del almacén.
        if not path.is_relative_to(self._root):
            raise ValueError(f"clave de audio fuera del almacén: {key!r}")
        return path

    async def exists(self, key: str) -> bool:
        return await asyncio.to_thread(self._path(key).is_file)

    async def put(self, key: str, data: bytes) -> None:
        path = self._path(key)
        try:
            await asyncio.to_thread(_write_atomically, path, data)
        except OSError as exc:
            raise AudioStoreError(f"guardar {key}: {exc}") from exc

    def local_path(self, key: str) -> Path | None:
        if not is_valid_key(key):
            return None
        path = self._path(key)
        return path if path.is_file() else None


def _write_atomically(path: Path, data: bytes) -> None:
    # Se escribe en un archivo temporal de la MISMA carpeta y luego se
    # renombra. Renombrar es atómico: quien lea el archivo lo verá completo o
    # no lo verá, nunca a medias (aunque se vaya la luz a mitad de escribir).
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    try:
        with tmp.open("wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
