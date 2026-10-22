"""Texto → voz: Piper (síntesis de voz local y gratuita) + Opus (compresión).

Cómo se convierte un párrafo en un archivo de audio, paso a paso:

    texto ──► piper --output-raw ──► sonido "en crudo" (PCM) ──► opusenc ──► .opus
              (la voz: un modelo                                  (lo comprime
               de red neuronal ONNX)                               a 24 kbps)

- **Piper** funciona en la CPU, sin tarjeta gráfica, y cada voz es un único
  archivo ``.onnx`` (unos 20-60 MB). Gratis y sin enviar el texto a nadie.
- **Opus** es el formato de audio de las videollamadas: a 24 kbps una voz se
  entiende perfectamente y un minuto ocupa unos 180 KB (un MP3 normal, 1 MB).
  ``--speech`` le dice al codificador que es voz, no música.

¿Por qué llamamos a Piper como un PROGRAMA aparte (subproceso) en vez de
importarlo como librería de Python?
    1. **Aislamiento**: si una voz se cuelga o se come la memoria, se mata ese
       proceso (hay tiempo máximo) y el worker sigue vivo.
    2. **Licencia**: Piper es GPL-3.0. Usarlo como programa independiente que
       recibe texto y devuelve sonido mantiene nuestro código separado del suyo
       (ver la guía, apartado de licencias).
    3. **Sustituible**: cambiar de motor de voz = cambiar esta clase.

Las voces se descubren solas: una carpeta por idioma con UN modelo dentro,
``<TTS_VOICES_DIR>/es/es-carlfm-x-low.onnx`` (+ su ``.onnx.json``). Lo que no
tenga voz simplemente no se graba (y la app puede leer el texto con la voz del
propio teléfono).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from ai_orchestrator.audioguides.domain import SUPPORTED_LANGUAGES

log = logging.getLogger(__name__)

# Sonido en crudo de Piper: muestras de 16 bits (2 bytes), un solo canal.
_SAMPLE_BYTES = 2


class SpeechError(Exception):
    """La síntesis o la codificación falló (se reintentará más tarde)."""


@dataclass(frozen=True, slots=True)
class Voice:
    language: str
    # Nombre de la voz (el del archivo, sin .onnx): "es-carlfm-x-low".
    name: str
    model: Path
    sample_rate: int


@dataclass(frozen=True, slots=True)
class SpokenAudio:
    data: bytes
    duration_seconds: float


class Synthesizer(Protocol):
    def voice_for(self, language: str) -> Voice | None: ...

    async def speak(self, text: str, voice: Voice) -> SpokenAudio: ...


def discover_voices(voices_dir: Path) -> dict[str, Voice]:
    """Busca ``<dir>/<idioma>/<voz>.onnx`` para cada idioma que sabemos redactar."""
    voices: dict[str, Voice] = {}
    for language in SUPPORTED_LANGUAGES:
        models = sorted((voices_dir / language).glob("*.onnx"))
        if not models:
            continue
        if len(models) > 1:
            raise SpeechError(f"hay {len(models)} voces en {voices_dir / language}: deja solo una")
        model = models[0]
        config = model.with_name(model.name + ".json")
        try:
            sample_rate = int(json.loads(config.read_text(encoding="utf-8"))["audio"]["sample_rate"])
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise SpeechError(f"la voz {model.name} no tiene un {config.name} válido: {exc}") from exc
        if not 8000 <= sample_rate <= 48000:
            raise SpeechError(f"frecuencia de muestreo rara en {config.name}: {sample_rate}")
        voices[language] = Voice(language=language, name=model.stem, model=model, sample_rate=sample_rate)
    return voices


class PiperOpusSynthesizer:
    def __init__(
        self,
        voices: dict[str, Voice],
        *,
        piper_bin: str,
        opusenc_bin: str,
        bitrate_kbps: int,
        timeout_seconds: float,
    ) -> None:
        # Comprobamos al arrancar que los programas existen: mejor un error
        # claro ahora que un fallo en cada trabajo.
        piper = shutil.which(piper_bin)
        opusenc = shutil.which(opusenc_bin)
        if piper is None or opusenc is None:
            missing = [name for name, path in ((piper_bin, piper), (opusenc_bin, opusenc)) if path is None]
            raise SpeechError(f"no se encuentran los programas: {', '.join(missing)}")
        self._voices = voices
        self._piper = piper
        self._opusenc = opusenc
        self._bitrate = bitrate_kbps
        self._timeout = timeout_seconds

    def voice_for(self, language: str) -> Voice | None:
        return self._voices.get(language)

    async def speak(self, text: str, voice: Voice) -> SpokenAudio:
        # Piper lee una frase por línea: lo dejamos todo en una sola línea
        # para obtener UN solo audio por párrafo.
        line = " ".join(text.split()) + "\n"
        pcm = await _run(
            [self._piper, "--model", str(voice.model), "--output-raw"],
            line.encode("utf-8"),
            limit_seconds=self._timeout,
            what="piper",
        )
        if len(pcm) < voice.sample_rate * _SAMPLE_BYTES // 10:
            # Menos de una décima de segundo: algo ha ido mal aunque no lo diga.
            raise SpeechError(f"piper devolvió un audio vacío ({len(pcm)} bytes)")
        opus = await _run(
            [
                self._opusenc,
                "--quiet",
                "--raw",
                "--raw-rate",
                str(voice.sample_rate),
                "--raw-chan",
                "1",
                "--raw-bits",
                "16",
                "--bitrate",
                str(self._bitrate),
                "--speech",
                "-",
                "-",
            ],
            pcm,
            limit_seconds=self._timeout,
            what="opusenc",
        )
        if not opus.startswith(b"OggS"):
            raise SpeechError("opusenc no devolvió un archivo Ogg Opus")
        return SpokenAudio(
            data=opus, duration_seconds=round(len(pcm) / (voice.sample_rate * _SAMPLE_BYTES), 2)
        )


async def _run(argv: list[str], stdin: bytes, *, limit_seconds: float, what: str) -> bytes:
    """Ejecuta un programa SIN shell (nada de inyección de comandos) con tiempo máximo."""
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        # Entorno mínimo: el programa no hereda contraseñas del nuestro
        # (PGPASSWORD, REDIS_PASSWORD...). Mínimo privilegio también aquí.
        env={"PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"},
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(stdin), timeout=limit_seconds)
    except TimeoutError as exc:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
        raise SpeechError(f"{what} tardó más de {limit_seconds:.0f} s") from exc
    except asyncio.CancelledError:
        # Apagado: no dejamos procesos huérfanos.
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise
    if proc.returncode != 0:
        detail = err.decode("utf-8", "replace").strip().splitlines()[-1:] or ["sin detalle"]
        raise SpeechError(f"{what} terminó con código {proc.returncode}: {detail[0][:200]}")
    return out
