"""Tests del audio de las audioguías: rutas inmutables, voz, cola de trabajos y API.

Piper y opusenc se sustituyen por programas de juguete (scripts de Python que
hacen lo mismo por fuera: leen texto y escriben bytes), y PostgreSQL por
dobles en memoria. Así se prueba todo el camino en milisegundos.
"""

from __future__ import annotations

import json
import stat
import sys
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from conftest import USER_ID, FakeLLM, InMemoryStore
from test_audioguides import ZONE_ID, build_service, draft_json, make_zone

from ai_orchestrator.api import create_api
from ai_orchestrator.audioguides.audio_catalog import AudioCatalog
from ai_orchestrator.audioguides.audio_jobs import AudioJob, AudioManifest, AudioPart
from ai_orchestrator.audioguides.audio_store import (
    FilesystemAudioStore,
    audio_key,
    is_valid_key,
    script_digest,
)
from ai_orchestrator.audioguides.audio_worker import AudioWorker, JobOutcome, WorkerSettings
from ai_orchestrator.audioguides.domain import AudioguideScript, ZoneKind
from ai_orchestrator.audioguides.speech import (
    PiperOpusSynthesizer,
    SpeechError,
    SpokenAudio,
    Voice,
    discover_voices,
)
from ai_orchestrator.audioguides.versions import ZoneVersionCache

SLUG = "madrid-museos"
DIGEST = "0123456789abcdef"


# --- Rutas inmutables y almacén -----------------------------------------------------


def test_audio_keys_carry_version_and_digest() -> None:
    assert audio_key(SLUG, "es", 3, DIGEST, 1) == f"{SLUG}/es/v3/{DIGEST}/parte-1.opus"


@pytest.mark.parametrize(
    "key",
    [
        "../../etc/passwd",
        f"{SLUG}/es/v3/{DIGEST}/../../secreto.opus",
        f"{SLUG}/es/v3/{DIGEST}/parte-1.mp3",
        f"/{SLUG}/es/v3/{DIGEST}/parte-1.opus",
        f"{SLUG}/ES/v3/{DIGEST}/parte-1.opus",
        f"{SLUG}/es/v3/{DIGEST.upper()}/parte-1.opus",
    ],
)
def test_suspicious_keys_are_rejected(key: str, tmp_path: Path) -> None:
    assert not is_valid_key(key)
    assert FilesystemAudioStore(tmp_path).local_path(key) is None


@pytest.mark.parametrize(
    ("slug", "language", "version", "digest", "index"),
    [
        ("Madrid", "es", 1, DIGEST, 1),
        (SLUG, "es-ES", 1, DIGEST, 1),
        (SLUG, "es", -1, DIGEST, 1),
        (SLUG, "es", 1, "xyz", 1),
        (SLUG, "es", 1, DIGEST, 0),
    ],
)
def test_invalid_key_parts_raise(slug: str, language: str, version: int, digest: str, index: int) -> None:
    with pytest.raises(ValueError, match="inválid"):
        audio_key(slug, language, version, digest, index)


async def test_filesystem_store_writes_whole_files(tmp_path: Path) -> None:
    store = FilesystemAudioStore(tmp_path)
    key = audio_key(SLUG, "es", 1, DIGEST, 1)
    assert not await store.exists(key)
    await store.put(key, b"OggS-audio")
    assert await store.exists(key)
    path = store.local_path(key)
    assert path is not None and path.read_bytes() == b"OggS-audio"
    # Sin restos de archivos temporales.
    assert [p.name for p in path.parent.iterdir()] == ["parte-1.opus"]


def _script(text: str = "Bienvenido al Prado.", source: str = "llm", version: int = 1) -> AudioguideScript:
    from datetime import UTC, datetime

    return AudioguideScript.model_validate(
        {
            "zone_id": ZONE_ID,
            "zone_name": "Prado",
            "language": "es",
            "content_language": "es",
            "title": "El Prado",
            "segments": [{"text": text}, {"text": "Hasta pronto."}],
            "source": source,
            "content_version": version,
            "generated_at": datetime(2026, 10, 22, tzinfo=UTC),
        }
    )


def test_digest_only_depends_on_what_is_spoken() -> None:
    a = script_digest(_script())
    assert a == script_digest(_script(source="rules", version=7))
    assert a != script_digest(_script(text="Bienvenido al Museo del Prado."))
    assert len(a) == 16


# --- Voces y síntesis (Piper/opusenc de juguete) --------------------------------------


def _voice_dir(root: Path, language: str, name: str, *, config: bool = True) -> Path:
    folder = root / language
    folder.mkdir(parents=True)
    (folder / f"{name}.onnx").write_bytes(b"modelo")
    if config:
        (folder / f"{name}.onnx.json").write_text(json.dumps({"audio": {"sample_rate": 16000}}))
    return folder


def test_voices_are_discovered_one_per_language(tmp_path: Path) -> None:
    _voice_dir(tmp_path, "es", "es-carlfm-x-low")
    _voice_dir(tmp_path, "xx", "xx-desconocida")
    voices = discover_voices(tmp_path)
    assert list(voices) == ["es"]
    assert voices["es"].name == "es-carlfm-x-low" and voices["es"].sample_rate == 16000


def test_two_voices_for_one_language_is_an_error(tmp_path: Path) -> None:
    folder = _voice_dir(tmp_path, "es", "uno")
    (folder / "dos.onnx").write_bytes(b"modelo")
    with pytest.raises(SpeechError, match="deja solo una"):
        discover_voices(tmp_path)


def test_a_voice_without_config_is_an_error(tmp_path: Path) -> None:
    _voice_dir(tmp_path, "es", "es-sin-config", config=False)
    with pytest.raises(SpeechError, match="válido"):
        discover_voices(tmp_path)


def _program(path: Path, body: str) -> str:
    path.write_text(f"#!{sys.executable}\nimport os, sys, time\n{body}\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


# Piper de juguete: 1 segundo de "sonido" (16000 muestras de 2 bytes) por
# cada 10 caracteres. Además se chiva por stderr si ve contraseñas en su entorno.
FAKE_PIPER = """
text = sys.stdin.read()
if "PGPASSWORD" in os.environ:
    sys.stderr.write("fuga de secretos"); sys.exit(3)
if "FALLA" in text:
    sys.stderr.write("modelo roto\\n"); sys.exit(1)
if "LENTO" in text:
    time.sleep(5)
sys.stdout.buffer.write(b"\\x00\\x01" * 16000 * max(1, len(text.strip()) // 10))
"""
FAKE_OPUSENC = """
data = sys.stdin.buffer.read()
sys.stdout.buffer.write(b"OggS" + data[:16])
"""


def _synth(tmp_path: Path, *, timeout: float = 5.0, piper: str = FAKE_PIPER) -> PiperOpusSynthesizer:
    return PiperOpusSynthesizer(
        {},
        piper_bin=_program(tmp_path / "piper", piper),
        opusenc_bin=_program(tmp_path / "opusenc", FAKE_OPUSENC),
        bitrate_kbps=24,
        timeout_seconds=timeout,
    )


VOICE = Voice(language="es", name="es-test", model=Path("/voces/es.onnx"), sample_rate=16000)


async def test_speech_pipes_piper_into_opusenc(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # El entorno del worker tiene contraseñas: el programa NO debe verlas.
    monkeypatch.setenv("PGPASSWORD", "secreto")
    spoken = await _synth(tmp_path).speak("Bienvenido al\nMuseo del Prado.", VOICE)
    assert spoken.data.startswith(b"OggS")
    # "Bienvenido al Museo del Prado." = 30 caracteres → 3 s.
    assert spoken.duration_seconds == 3.0


async def test_speech_failures_are_reported(tmp_path: Path) -> None:
    synth = _synth(tmp_path, timeout=0.5)
    with pytest.raises(SpeechError, match="modelo roto"):
        await synth.speak("FALLA a propósito", VOICE)
    with pytest.raises(SpeechError, match="tardó más"):
        await synth.speak("LENTO a propósito", VOICE)


async def test_empty_audio_is_an_error(tmp_path: Path) -> None:
    synth = _synth(tmp_path, piper="sys.stdin.read()")
    with pytest.raises(SpeechError, match="vacío"):
        await synth.speak("Hola, hola, hola.", VOICE)


def test_missing_programs_are_detected_at_startup() -> None:
    with pytest.raises(SpeechError, match="no se encuentran"):
        PiperOpusSynthesizer(
            {},
            piper_bin="no-existe-piper",
            opusenc_bin="no-existe-opusenc",
            bitrate_kbps=24,
            timeout_seconds=1,
        )


# --- Worker de audio ------------------------------------------------------------------------


class FakeJobs:
    def __init__(self, jobs: list[AudioJob] | None = None) -> None:
        self.pending = list(jobs or [])
        self.events: list[tuple[str, AudioJob, float | str | None]] = []

    async def claim(self, *, lease_seconds: int) -> AudioJob | None:
        return self.pending.pop(0) if self.pending else None

    async def complete(self, job: AudioJob) -> None:
        self.events.append(("complete", job, None))

    async def retry(self, job: AudioJob, *, delay_seconds: float, error: str) -> None:
        self.events.append(("retry", job, delay_seconds))

    async def reschedule(self, job: AudioJob, *, delay_seconds: float) -> None:
        self.events.append(("reschedule", job, delay_seconds))

    async def give_up(self, job: AudioJob, *, error: str) -> None:
        self.events.append(("give_up", job, error))

    async def enqueue_missing(self) -> int:
        return 0


class FakeManifests:
    def __init__(self) -> None:
        self.saved: list[AudioManifest] = []

    async def exists(self, slug: str, language: str, version: int, digest: str) -> bool:
        return any(
            (m.zone_slug, m.language, m.content_version, m.script_digest) == (slug, language, version, digest)
            for m in self.saved
        )

    async def save(self, manifest: AudioManifest) -> None:
        self.saved.append(manifest)

    async def latest(self, zone_id: str, language: str, max_version: int) -> AudioManifest | None:
        found = [m for m in self.saved if m.language == language and m.content_version <= max_version]
        return max(found, key=lambda m: m.content_version, default=None)


class MemoryAudioStore:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    async def exists(self, key: str) -> bool:
        return key in self.files

    async def put(self, key: str, data: bytes) -> None:
        self.files[key] = data

    def local_path(self, key: str) -> Path | None:
        return None


class FakeSynth:
    def __init__(self, languages: tuple[str, ...] = ("es",), *, fail: bool = False) -> None:
        self.languages = languages
        self.fail = fail
        self.spoken: list[tuple[str, str]] = []

    def voice_for(self, language: str) -> Voice | None:
        return (
            replace(VOICE, language=language, name=f"{language}-voz") if language in self.languages else None
        )

    async def speak(self, text: str, voice: Voice) -> SpokenAudio:
        if self.fail:
            raise SpeechError("piper caído")
        self.spoken.append((voice.language, text))
        return SpokenAudio(data=b"OggS" + text.encode(), duration_seconds=2.5)


def make_job(version: int = 1, current: int | None = None, attempt: int = 1, **kw: object) -> AudioJob:
    data: dict[str, object] = {
        "zone_slug": SLUG,
        "content_version": version,
        "attempt": attempt,
        "zone_id": ZONE_ID,
        "zone_kind": ZoneKind.TOURIST_AREA,
        "zone_active": True,
        "current_version": version if current is None else current,
    }
    data.update(kw)
    return AudioJob(**data)  # type: ignore[arg-type]


def build_worker(
    *,
    llm: FakeLLM | None = None,
    synth: FakeSynth | None = None,
    languages: tuple[str, ...] = ("es",),
    llm_enabled: bool = True,
    zone_version: int = 1,
) -> tuple[AudioWorker, FakeJobs, FakeManifests, MemoryAudioStore, FakeSynth]:
    service, _, _ = build_service(llm, make_zone(content_version=zone_version))
    jobs, manifests, store = FakeJobs(), FakeManifests(), MemoryAudioStore()
    synth = synth or FakeSynth()
    worker = AudioWorker(
        jobs=jobs,
        manifests=manifests,
        store=store,
        synthesizer=synth,
        audioguides=service,
        settings=WorkerSettings(languages=languages, llm_enabled=llm_enabled, upgrade_delay_seconds=3600),
    )
    return worker, jobs, manifests, store, synth


async def test_worker_records_every_paragraph_under_immutable_paths() -> None:
    worker, jobs, manifests, store, synth = build_worker(llm=FakeLLM([draft_json()]))
    assert await worker.process(make_job()) is JobOutcome.DONE
    [manifest] = manifests.saved
    assert manifest.source == "llm" and manifest.voice == "es-voz" and len(manifest.parts) == 3
    assert [p.key for p in manifest.parts] == [
        f"{SLUG}/es/v1/{manifest.script_digest}/parte-{i}.opus" for i in (1, 2, 3)
    ]
    assert set(store.files) == {p.key for p in manifest.parts}
    # Cada parte lleva el texto exacto que suena.
    assert [p.text for p in manifest.parts] == [text for _, text in synth.spoken]
    assert jobs.events[-1][0] == "complete"


async def test_same_script_is_not_recorded_twice() -> None:
    worker, _, manifests, _, synth = build_worker(llm=FakeLLM([draft_json()]))
    await worker.process(make_job())
    await worker.process(make_job())
    assert len(manifests.saved) == 1 and len(synth.spoken) == 3


async def test_a_newer_version_supersedes_the_job_without_recording() -> None:
    worker, jobs, manifests, _, synth = build_worker()
    assert await worker.process(make_job(version=1, current=2)) is JobOutcome.SUPERSEDED
    assert manifests.saved == [] and synth.spoken == []
    assert jobs.events[-1][0] == "complete"


async def test_unknown_or_non_narrated_zones_are_skipped() -> None:
    worker, jobs, _, _, _ = build_worker()
    assert await worker.process(make_job(zone_id=None)) is JobOutcome.SKIPPED
    assert await worker.process(make_job(zone_kind=ZoneKind.AIRPORT)) is JobOutcome.SKIPPED
    assert await worker.process(make_job(zone_active=False)) is JobOutcome.SKIPPED
    assert [e[0] for e in jobs.events] == ["complete"] * 3


async def test_rules_audio_is_recorded_and_retried_later_with_the_llm() -> None:
    # Ollama caído: guion por reglas. Se graba igualmente, pero el trabajo se
    # reprograma para volver a probar con el LLM más tarde.
    worker, jobs, manifests, _, _ = build_worker(llm=None)
    assert await worker.process(make_job()) is JobOutcome.RESCHEDULED
    assert manifests.saved[0].source == "rules"
    assert jobs.events[-1][0] == "reschedule" and jobs.events[-1][2] == 3600


async def test_rules_audio_is_final_when_the_llm_is_disabled() -> None:
    worker, jobs, _, _, _ = build_worker(llm=None, llm_enabled=False)
    assert await worker.process(make_job()) is JobOutcome.DONE
    assert jobs.events[-1][0] == "complete"


async def test_languages_without_voice_are_left_to_the_phone() -> None:
    worker, _, manifests, _, _ = build_worker(llm=None, languages=("es", "fr"), synth=FakeSynth(("es",)))
    await worker.process(make_job())
    # El plan B en francés usa los hechos en español → suena con la voz española;
    # no hay ninguna voz francesa que estrenar aquí.
    assert {(m.language, m.content_language) for m in manifests.saved} <= {("es", "es"), ("fr", "es")}
    assert all(m.voice == "es-voz" for m in manifests.saved)


async def test_speech_failures_go_back_to_the_queue_with_growing_delays() -> None:
    worker, jobs, manifests, _, _ = build_worker(llm=None, synth=FakeSynth(fail=True))
    assert await worker.process(make_job(attempt=1)) is JobOutcome.RETRY
    assert await worker.process(make_job(attempt=3)) is JobOutcome.RETRY
    assert [e[2] for e in jobs.events] == [30.0, 120.0]
    assert await worker.process(make_job(attempt=5)) is JobOutcome.GAVE_UP
    assert jobs.events[-1][0] == "give_up" and "piper caído" in str(jobs.events[-1][2])
    # Nada a medias: sin manifiesto si la grabación no terminó.
    assert manifests.saved == []


async def test_a_job_older_than_the_script_is_superseded() -> None:
    # Los hechos ya van por la versión 2 cuando llega el trabajo de la 1.
    worker, _, manifests, _, _ = build_worker(zone_version=2)
    assert await worker.process(make_job(version=1, current=1)) is JobOutcome.SUPERSEDED
    assert manifests.saved == []


# --- API: manifiesto y archivos ---------------------------------------------------------------


def _manifest(version: int, digest: str = DIGEST) -> AudioManifest:
    return AudioManifest(
        zone_slug=SLUG,
        language="es",
        content_language="es",
        content_version=version,
        script_digest=digest,
        source="llm",
        voice="es-carlfm-x-low",
        parts=(
            AudioPart(
                index=1, key=audio_key(SLUG, "es", version, digest, 1), duration_seconds=2.0, text="Hola."
            ),
        ),
    )


async def test_api_serves_the_manifest_and_falls_back_to_the_previous_version(tmp_path: Path) -> None:
    service, _, facts = build_service(None, make_zone(content_version=2))
    manifests = FakeManifests()
    store = FilesystemAudioStore(tmp_path)
    catalog = AudioCatalog(
        versions=ZoneVersionCache(facts, ttl_seconds=60),
        manifests=manifests,
        store=store,
        default_language="en",
        public_base_url="https://cdn.example.com/audio/",
        cache_seconds=60,
    )
    app = create_api(InMemoryStore(), audioguides=service, audio=catalog)
    user = {"X-User-ID": USER_ID, "X-User-Roles": "USER"}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        url = f"/v1/audioguides/{ZONE_ID}/audio?lang=es"
        assert (await c.get(url)).status_code == 401
        missing = await c.get(url, headers=user)
        assert missing.status_code == 404 and "grabado" in missing.json()["detail"]

    # La versión actual (2) aún se está grabando: suena la 1, marcada como "stale".
    manifests.saved.append(_manifest(1))
    catalog = AudioCatalog(
        versions=ZoneVersionCache(facts, ttl_seconds=60),
        manifests=manifests,
        store=store,
        default_language="en",
        public_base_url="https://cdn.example.com/audio/",
        cache_seconds=60,
    )
    app = create_api(InMemoryStore(), audioguides=service, audio=catalog)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        body = (await c.get(url, headers=user)).json()
        assert body["content_version"] == 2 and body["audio_content_version"] == 1 and body["stale"] is True
        assert body["parts"][0]["url"] == f"https://cdn.example.com/audio/{SLUG}/es/v1/{DIGEST}/parte-1.opus"
        assert body["parts"][0]["text"] == "Hola."


async def test_audio_files_are_public_immutable_and_safe(tmp_path: Path) -> None:
    service, _, facts = build_service(None)
    store = FilesystemAudioStore(tmp_path)
    key = audio_key(SLUG, "es", 1, DIGEST, 1)
    await store.put(key, b"OggS-datos")
    catalog = AudioCatalog(
        versions=ZoneVersionCache(facts, ttl_seconds=60),
        manifests=FakeManifests(),
        store=store,
        default_language="en",
        public_base_url="/v1/audio",
        cache_seconds=60,
    )
    app = create_api(InMemoryStore(), audioguides=service, audio=catalog)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        ok = await c.get(f"/v1/audio/{key}")
        assert ok.status_code == 200 and ok.content == b"OggS-datos"
        assert ok.headers["content-type"].startswith("audio/ogg")
        assert ok.headers["cache-control"] == "public, max-age=31536000, immutable"
        assert (await c.get(f"/v1/audio/{SLUG}/es/v1/{DIGEST}/parte-2.opus")).status_code == 404
        assert (await c.get("/v1/audio/..%2F..%2Fetc%2Fpasswd")).status_code == 404
