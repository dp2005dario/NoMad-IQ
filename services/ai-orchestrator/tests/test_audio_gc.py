"""Tests del recolector de basura del audio (con un almacén real en una carpeta temporal).

La política "qué grabaciones están caducadas" vive en SQL (la prueban los tests
de integración contra PostgreSQL). Aquí se prueba el resto: el orden de
borrado, el cerrojo, los huérfanos y el 410 de la API.
"""

from __future__ import annotations

import os
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import pytest
from conftest import InMemoryStore
from test_audio import DIGEST, SLUG, FakeManifests, _manifest
from test_audioguides import ZONE_ID, build_service

from ai_orchestrator.api import create_api
from ai_orchestrator.audioguides.audio_catalog import AudioCatalog
from ai_orchestrator.audioguides.audio_gc import AudioGarbageCollector, GcSettings
from ai_orchestrator.audioguides.audio_jobs import AudioManifest
from ai_orchestrator.audioguides.audio_store import FilesystemAudioStore, audio_key
from ai_orchestrator.audioguides.versions import ZoneVersionCache

OLD = time.time() - 3 * 86400


class FakeGcStore:
    def __init__(self, expired: list[AudioManifest], alive: set[str], *, lock: bool = True) -> None:
        self._expired = expired
        self.alive = alive
        self.lock = lock
        self.purged: list[AudioManifest] = []
        self.calls: list[str] = []

    @asynccontextmanager
    async def exclusive(self) -> AsyncIterator[bool]:
        yield self.lock

    async def expired(self, *, keep: int, grace_days: float, limit: int) -> list[AudioManifest]:
        self.calls.append(f"expired keep={keep} grace={grace_days}")
        return self._expired

    async def mark_purged(self, manifest: AudioManifest) -> None:
        self.purged.append(manifest)

    async def referenced_keys(self) -> set[str]:
        self.calls.append("referenced")
        return self.alive


async def _put(store: FilesystemAudioStore, root: Path, key: str, *, mtime: float = OLD) -> Path:
    await store.put(key, b"OggS")
    path = root / key
    os.utime(path, (mtime, mtime))
    return path


async def test_expired_recordings_lose_their_files_and_keep_a_tombstone(tmp_path: Path) -> None:
    store = FilesystemAudioStore(tmp_path)
    old = _manifest(1)
    path = await _put(store, tmp_path, old.parts[0].key)
    gc_store = FakeGcStore([old], alive=set())
    report = await AudioGarbageCollector(manifests=gc_store, store=store, settings=GcSettings()).run_once()
    assert not path.exists()
    assert gc_store.purged == [old]
    assert report.purged_recordings == 1 and report.deleted_files == 1
    # Las carpetas que se quedan vacías también se van.
    assert os.listdir(tmp_path) == []
    assert gc_store.calls[0] == "expired keep=2 grace=30.0"


async def test_only_one_worker_collects_at_a_time(tmp_path: Path) -> None:
    store = FilesystemAudioStore(tmp_path)
    old = _manifest(1)
    path = await _put(store, tmp_path, old.parts[0].key)
    gc_store = FakeGcStore([old], alive=set(), lock=False)
    report = await AudioGarbageCollector(manifests=gc_store, store=store, settings=GcSettings()).run_once()
    assert report.skipped and path.exists() and gc_store.purged == []


async def test_orphans_are_removed_only_when_old_and_unreferenced(tmp_path: Path) -> None:
    store = FilesystemAudioStore(tmp_path)
    alive_key = audio_key(SLUG, "es", 2, DIGEST, 1)
    orphan_key = audio_key(SLUG, "es", 2, DIGEST, 2)
    recent_key = audio_key(SLUG, "es", 3, DIGEST, 1)
    alive = await _put(store, tmp_path, alive_key)
    orphan = await _put(store, tmp_path, orphan_key)
    # Una grabación en curso: sin manifiesto todavía, pero recién escrita.
    recent = await _put(store, tmp_path, recent_key, mtime=time.time())
    # Un temporal que dejó un apagón a mitad de escribir.
    leftover = tmp_path / SLUG / "es" / "v2" / DIGEST / ".parte-9.opus.abcd.tmp"
    leftover.write_bytes(b"medio archivo")
    os.utime(leftover, (OLD, OLD))

    gc_store = FakeGcStore([], alive={alive_key})
    report = await AudioGarbageCollector(manifests=gc_store, store=store, settings=GcSettings()).run_once()
    assert alive.exists() and recent.exists()
    assert not orphan.exists() and not leftover.exists()
    assert report.deleted_orphans == 2
    # Primero se listan los archivos viejos y DESPUÉS los vivos (ver audio_gc.py).
    assert gc_store.calls[-1] == "referenced"


def test_the_current_recording_can_never_be_collected() -> None:
    with pytest.raises(ValueError, match="al menos 1"):
        AudioGarbageCollector(manifests=FakeGcStore([], set()), store=None, settings=GcSettings(keep=0))  # type: ignore[arg-type]


async def test_purged_audio_answers_410_with_a_link_to_the_current_manifest(tmp_path: Path) -> None:
    service, _, facts = build_service(None)
    manifests = FakeManifests()
    manifests.purged.add((SLUG, "es", 1, DIGEST))
    catalog = AudioCatalog(
        versions=ZoneVersionCache(facts, ttl_seconds=60),
        manifests=manifests,
        store=FilesystemAudioStore(tmp_path),
        default_language="en",
        public_base_url="/v1/audio",
        cache_seconds=60,
    )
    app = create_api(InMemoryStore(), audioguides=service, audio=catalog)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        gone = await c.get(f"/v1/audio/{audio_key(SLUG, 'es', 1, DIGEST, 1)}")
        assert gone.status_code == 410
        assert gone.headers["cache-control"] == "no-store"
        current = f"/v1/audioguides/{ZONE_ID}/audio?lang=es"
        assert gone.json()["current_manifest"] == current
        assert gone.headers["link"] == f'<{current}>; rel="latest-version"'
