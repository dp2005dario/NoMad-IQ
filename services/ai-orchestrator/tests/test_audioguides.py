"""Tests de las audioguías por zona: anclaje a hechos, caché, estampidas y Kafka.

Todo con dobles en memoria (sin Redis, PostgreSQL, Kafka ni Ollama reales):
cada test tarda milisegundos y da siempre el mismo resultado.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

import httpx
import pytest
from conftest import FIXED_NOW, USER_ID, FakeLLM, InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.audioguides.consumer import ZoneEntryConsumer
from ai_orchestrator.audioguides.domain import (
    AudioguideScript,
    ZoneEntry,
    ZoneFact,
    ZoneFacts,
    ZoneKind,
    resolve_language,
)
from ai_orchestrator.audioguides.events import decode_zone_entry
from ai_orchestrator.audioguides.service import AudioguideService, Outcome, ServiceSettings
from ai_orchestrator.audioguides.versions import ZoneVersionCache
from ai_orchestrator.audioguides.writer import AudioguideWriter, GuideDraft, WriterSettings, guide_problems
from ai_orchestrator.consumer import RetryPolicy
from ai_orchestrator.events import InvalidEventError
from ai_orchestrator.llm.client import LLMUnavailableError
from nomadiq.common.v1 import common_pb2
from nomadiq.geo.v1 import events_pb2, geo_pb2

ZONE_ID = "5f0c8f1e-0b7a-4c1e-9d7e-1a2b3c4d5e6f"
FACTS = (
    ZoneFact(fact_id="F1", text="El Museo del Prado abrió sus puertas al público en 1819."),
    ZoneFact(fact_id="F2", text="El Prado conserva Las Meninas, de Diego Velázquez."),
    ZoneFact(fact_id="F3", text="El Museo Reina Sofía expone el Guernica de Pablo Picasso."),
)


def make_zone(facts: tuple[ZoneFact, ...] = FACTS, language: str = "es", **kw: Any) -> ZoneFacts:
    data: dict[str, Any] = {
        "zone_id": ZONE_ID,
        "slug": "madrid-museos",
        "name": "Madrid · Prado y Reina Sofía",
        "kind": ZoneKind.TOURIST_AREA,
        "facts_language": language,
        "facts": facts,
        "content_version": 1,
    }
    data.update(kw)
    return ZoneFacts(**data)


def draft_json(**overrides: Any) -> str:
    data: dict[str, Any] = {
        "title": "El paseo del arte",
        "segments": [
            {"text": "Estás junto al Prado, que abrió al público en 1819.", "fact_ids": ["F1"]},
            {"text": "Dentro te esperan Las Meninas de Velázquez, una joya.", "fact_ids": ["F2"]},
            {"text": "Y a pocos pasos, en el Reina Sofía, el Guernica de Picasso.", "fact_ids": ["F3"]},
        ],
    }
    data.update(overrides)
    return json.dumps(data, ensure_ascii=False)


def encode_entry(
    zone_id: str = ZONE_ID, kind: int = geo_pb2.ZONE_KIND_TOURIST_AREA, language: str = "es"
) -> bytes:
    return events_pb2.ZoneEntered(
        metadata=common_pb2.EventMetadata(event_id=str(uuid.uuid4()), producer="geo-engine"),
        zone_id=zone_id,
        zone_kind=kind,  # type: ignore[arg-type]
        language=language,
    ).SerializeToString()


HEADERS = [("content-type", b"application/x-protobuf"), ("ce_type", b"nomadiq.geo.v1.ZoneEntered")]


# --- Dobles ---------------------------------------------------------------------


class MemoryCache:
    """ScriptCache en memoria; apunta TTLs y puede fallar a propósito."""

    def __init__(self) -> None:
        self.items: dict[tuple[str, str, int], AudioguideScript] = {}
        self.ttls: dict[tuple[str, str, int], int] = {}
        self.locks: dict[tuple[str, str, int], str] = {}
        self.failures = 0

    def _maybe_fail(self) -> None:
        if self.failures > 0:
            self.failures -= 1
            raise CacheError("redis caído")

    async def get(self, zone_id: str, language: str, version: int) -> AudioguideScript | None:
        self._maybe_fail()
        return self.items.get((zone_id, language, version))

    async def put(self, script: AudioguideScript, *, ttl_seconds: int) -> None:
        key = (script.zone_id, script.language, script.content_version)
        self.items[key] = script
        self.ttls[key] = ttl_seconds

    async def try_lock(self, zone_id: str, language: str, version: int, *, ttl_seconds: int) -> str | None:
        if (zone_id, language, version) in self.locks:
            return None
        self.locks[(zone_id, language, version)] = "token"
        return "token"

    async def unlock(self, zone_id: str, language: str, version: int, token: str) -> None:
        if self.locks.get((zone_id, language, version)) == token:
            del self.locks[(zone_id, language, version)]

    async def ping(self) -> bool:
        return True


class FakeFacts:
    def __init__(self, zone: ZoneFacts | None) -> None:
        self.zone = zone
        self.calls = 0
        self.version_calls = 0

    async def content_version(self, zone_id: str) -> int | None:
        self.version_calls += 1
        await asyncio.sleep(0)  # como una consulta real: cede el turno
        return self.zone.content_version if self.zone and self.zone.zone_id == zone_id else None

    async def load(self, zone_id: str, *, language: str, fallback_language: str) -> ZoneFacts | None:
        self.calls += 1
        return self.zone if self.zone and self.zone.zone_id == zone_id else None

    async def narrated_zone_ids(self) -> list[str]:
        return [self.zone.zone_id] if self.zone else []


class SlowLLM(FakeLLM):
    """LLM que tarda un poco: deja tiempo a que lleguen peticiones "a la vez"."""

    async def chat(self, *args: Any, **kwargs: Any) -> str:
        await asyncio.sleep(0.05)
        return await super().chat(*args, **kwargs)


WRITER = WriterSettings(temperature=0.1, max_output_tokens=900, max_attempts=3, max_words=260)
SERVICE = ServiceSettings(
    default_language="en", llm_ttl_seconds=604800, rules_ttl_seconds=3600, lock_ttl_seconds=210
)


def build_service(
    llm: FakeLLM | None, zone: ZoneFacts | None = None, cache: MemoryCache | None = None
) -> tuple[AudioguideService, MemoryCache, FakeFacts]:
    cache = cache or MemoryCache()
    facts = FakeFacts(zone if zone is not None else make_zone())
    writer = AudioguideWriter(llm=llm, settings=WRITER, clock=lambda: FIXED_NOW)
    versions = ZoneVersionCache(facts, ttl_seconds=60)
    service = AudioguideService(facts=facts, writer=writer, cache=cache, versions=versions, settings=SERVICE)
    return service, cache, facts


# --- Eventos e idiomas -------------------------------------------------------------


def test_decodes_a_zone_entry() -> None:
    entry = decode_zone_entry(encode_entry(), HEADERS)
    assert entry.zone_id == ZONE_ID
    assert entry.zone_kind is ZoneKind.TOURIST_AREA
    assert entry.language == "es"


@pytest.mark.parametrize(
    ("value", "headers"),
    [
        (b"", HEADERS),
        (b"\xff\xff", HEADERS),
        (encode_entry(zone_id="no-es-un-uuid"), HEADERS),
        (encode_entry(), [("ce_type", b"nomadiq.flights.v1.FareAlertTriggered")]),
        (encode_entry(), [("content-type", b"application/json")]),
    ],
)
def test_rejects_broken_entries(value: bytes, headers: list[tuple[str, bytes]]) -> None:
    with pytest.raises(InvalidEventError):
        decode_zone_entry(value, headers)


def test_language_falls_back_to_default() -> None:
    assert resolve_language("es", "en") == "es"
    assert resolve_language(" FR ", "en") == "fr"
    assert resolve_language("", "en") == "en"
    # Un idioma que no sabemos redactar no crea una clave de caché nueva.
    assert resolve_language("tlh", "en") == "en"


# --- Anclaje a hechos ------------------------------------------------------------------


def test_a_well_grounded_draft_passes() -> None:
    draft = GuideDraft.model_validate_json(draft_json())
    assert guide_problems(draft, FACTS, "Prado", 260) == []


@pytest.mark.parametrize(
    ("segments", "expected"),
    [
        # Fecha inventada: 1785 no está en F1.
        ([{"text": "El edificio se proyectó en 1785, nada menos.", "fact_ids": ["F1"]}], "cifras"),
        # El número existe, pero en OTRO hecho que este párrafo no cita.
        ([{"text": "Las Meninas llegaron aquí en 1819, cuentan.", "fact_ids": ["F2"]}], "cifras"),
        ([{"text": "Un párrafo que cita un hecho inexistente.", "fact_ids": ["F9"]}], "no existen"),
        ([{"text": "Más información en https://ejemplo.com ahora.", "fact_ids": ["F2"]}], "enlace"),
    ],
)
def test_ungrounded_drafts_are_rejected(segments: list[dict[str, Any]], expected: str) -> None:
    ok = {"text": "Y el Guernica de Picasso te espera en el Reina Sofía.", "fact_ids": ["F3"]}
    draft = GuideDraft.model_validate_json(draft_json(segments=[*segments, ok]))
    problems = guide_problems(draft, FACTS, "Prado", 260)
    assert any(expected in p for p in problems), problems


def test_too_long_or_single_fact_drafts_are_rejected() -> None:
    long_text = " ".join(["arte"] * 150)
    draft = GuideDraft.model_validate_json(
        draft_json(
            title="Paseo de 1819",
            segments=[
                {"text": long_text[:690], "fact_ids": ["F2"]},
                {"text": long_text[:690], "fact_ids": ["F2"]},
            ],
        )
    )
    problems = guide_problems(draft, FACTS, "Prado", 260)
    assert any("título" in p for p in problems)
    assert any("demasiado largo" in p for p in problems)
    assert any("al menos 2 hechos" in p for p in problems)


# --- Redactor -----------------------------------------------------------------------------


async def test_llm_script_cites_only_used_facts() -> None:
    llm = FakeLLM([draft_json()])
    script = await AudioguideWriter(llm=llm, settings=WRITER, clock=lambda: FIXED_NOW).write(
        make_zone(), "es"
    )
    assert script.source == "llm"
    assert script.model == "fake-model"
    assert [f.fact_id for f in script.facts] == ["F1", "F2", "F3"]
    # Al LLM le llegan los hechos y el idioma, nada sobre el usuario.
    prompt = llm.calls[0]["messages"][1].content
    assert "F1" in prompt and "español" in prompt
    assert llm.calls[0]["json_schema"] == GuideDraft.model_json_schema()


async def test_llm_gets_a_second_chance_then_rules() -> None:
    invented = draft_json(
        segments=[
            {"text": "Se fundó en 1492, en plena época de descubrimientos.", "fact_ids": ["F1"]},
            {"text": "Y aquí están Las Meninas de Velázquez, preciosas.", "fact_ids": ["F2"]},
        ]
    )
    llm = FakeLLM([invented, draft_json()])
    script = await AudioguideWriter(llm=llm, settings=WRITER).write(make_zone(), "es")
    assert script.source == "llm"
    assert len(llm.calls) == 2
    # El segundo intento recibe el motivo del rechazo.
    assert "1492" in llm.calls[1]["messages"][-1].content


async def test_ollama_down_means_rules_with_the_facts_verbatim() -> None:
    llm = FakeLLM([LLMUnavailableError("ollama caído")])
    script = await AudioguideWriter(llm=llm, settings=WRITER).write(make_zone(), "es")
    assert script.source == "rules"
    texts = [s.text for s in script.segments]
    assert texts[0].startswith("Bienvenido a Madrid")
    assert FACTS[0].text in texts  # el hecho tal cual, sin reescribir
    assert texts[-1] == "Disfruta de la visita."


async def test_rules_use_the_facts_language_when_there_is_no_translation() -> None:
    script = await AudioguideWriter(llm=None, settings=WRITER).write(make_zone(language="es"), "de")
    assert (script.language, script.content_language) == ("de", "es")
    script = await AudioguideWriter(llm=None, settings=WRITER).write(make_zone(facts=()), "de")
    assert script.content_language == "de"
    assert script.segments[0].text.startswith("Willkommen")


# --- Single flight y servicio ---------------------------------------------------------------


async def test_single_flight_runs_once_for_concurrent_callers() -> None:
    flight: SingleFlight[int] = SingleFlight()
    calls = 0

    async def work() -> int:
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.02)
        return 42

    results = await asyncio.gather(*(flight.do("k", work) for _ in range(20)))
    assert calls == 1
    assert [r for r, _ in results] == [42] * 20
    assert sum(shared for _, shared in results) == 19
    assert flight.inflight == 0


async def test_single_flight_shares_errors_and_then_retries() -> None:
    flight: SingleFlight[int] = SingleFlight()

    async def boom() -> int:
        await asyncio.sleep(0.01)
        raise CacheError("caído")

    results = await asyncio.gather(*(flight.do("k", boom) for _ in range(3)), return_exceptions=True)
    assert all(isinstance(r, CacheError) for r in results)

    async def ok() -> int:
        return 1

    assert await flight.do("k", ok) == (1, False)


async def test_a_bus_full_of_tourists_triggers_one_generation() -> None:
    llm = SlowLLM([draft_json()] * 5)
    service, cache, facts = build_service(llm)
    entry = ZoneEntry(zone_id=ZONE_ID, zone_kind=ZoneKind.TOURIST_AREA, language="es")
    outcomes = Counter(await asyncio.gather(*(service.ensure(entry) for _ in range(50))))
    assert len(llm.calls) == 1, "50 entradas a la vez = UNA llamada al LLM"
    assert facts.calls == 1
    assert outcomes[Outcome.GENERATED] == 1
    assert outcomes[Outcome.SHARED] == 49
    # Los que lleguen después, directos de la caché.
    assert await service.ensure(entry) is Outcome.CACHED
    assert cache.ttls[(ZONE_ID, "es", 1)] == SERVICE.llm_ttl_seconds


async def test_rules_scripts_expire_sooner() -> None:
    service, cache, _ = build_service(FakeLLM([LLMUnavailableError("caído")]))
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.GENERATED
    assert cache.ttls[(ZONE_ID, "es", 1)] == SERVICE.rules_ttl_seconds


async def test_another_replica_holding_the_lock_is_not_duplicated() -> None:
    llm = FakeLLM([draft_json()])
    service, cache, _ = build_service(llm)
    cache.locks[(ZONE_ID, "es", 1)] = "otra-copia"
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.BUSY_ELSEWHERE
    assert llm.calls == []


async def test_unknown_or_non_narrated_zones() -> None:
    service, cache, _ = build_service(FakeLLM([]), zone=make_zone(kind=ZoneKind.AIRPORT))
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.NOT_NARRATED
    assert await service.ensure_zone(str(uuid.uuid4()), "es") is Outcome.UNKNOWN_ZONE
    airport = ZoneEntry(zone_id=ZONE_ID, zone_kind=ZoneKind.AIRPORT, language="es")
    assert await service.ensure(airport) is Outcome.NOT_NARRATED
    assert cache.items == {}
    assert cache.locks == {}, "el cerrojo siempre se suelta"


async def test_pregenerate_fills_every_language_once() -> None:
    service, cache, _ = build_service(FakeLLM([draft_json()] * 5))
    results = await service.pregenerate(["es", "en", "ES", "xx"])  # xx -> en (por defecto)
    assert results == Counter({Outcome.GENERATED: 2})
    assert set(cache.items) == {(ZONE_ID, "es", 1), (ZONE_ID, "en", 1)}


# --- Consumidor de Kafka ------------------------------------------------------------------


@dataclass
class Record:
    value: bytes | None
    offset: int
    partition: int = 0
    topic: str = "geo.zone-entries.v1"
    key: bytes | None = ZONE_ID.encode()
    headers: list[tuple[str, bytes]] = field(default_factory=lambda: list(HEADERS))


class FakeConsumer:
    def __init__(self, batches: list[dict[Any, list[Record]]]) -> None:
        self._batches = batches
        self.commits = 0
        self.drained = asyncio.Event()

    async def getmany(self, *, timeout_ms: int, max_records: int) -> dict[Any, list[Record]]:
        if self._batches:
            return self._batches.pop(0)
        self.drained.set()
        await asyncio.sleep(0.01)
        return {}

    async def commit(self) -> None:
        self.commits += 1


class FakeProducer:
    def __init__(self) -> None:
        self.sent: list[tuple[str, bytes | None, list[tuple[str, bytes]]]] = []

    async def send_and_wait(
        self, topic: str, *, value: bytes | None, key: bytes | None, headers: list[tuple[str, bytes]]
    ) -> None:
        self.sent.append((topic, value, headers))


def zone_consumer(
    service: AudioguideService, fake: FakeConsumer, producer: FakeProducer
) -> ZoneEntryConsumer:
    return ZoneEntryConsumer(
        fake,
        producer,
        service,
        dlq_topic="geo.zone-entries-dlq.v1",
        max_records=200,
        transient_errors=(CacheError,),
        retry=RetryPolicy(initial_seconds=0.001, max_seconds=0.002),
    )


async def test_batch_groups_the_crowd_and_dead_letters_garbage() -> None:
    llm = FakeLLM([draft_json()] * 5)
    service, cache, _ = build_service(llm)
    producer = FakeProducer()
    records = [Record(encode_entry(), i) for i in range(30)]
    records += [Record(encode_entry(language="es-ES"), 30)]  # mismo guion ("es" tras normalizar)
    records += [Record(encode_entry(kind=geo_pb2.ZONE_KIND_AIRPORT), 31)]
    records += [Record(b"basura", 32)]
    outcomes = await zone_consumer(service, FakeConsumer([]), producer).process_batch(records)
    assert outcomes[Outcome.GENERATED] == 1
    assert outcomes["merged_in_batch"] == 30
    assert outcomes[Outcome.NOT_NARRATED] == 1
    assert outcomes["dead_lettered"] == 1
    assert len(llm.calls) == 1
    topic, value, headers = producer.sent[0]
    assert (topic, value) == ("geo.zone-entries-dlq.v1", b"basura")
    assert ("dlq_source_offset", b"32") in headers
    assert (ZONE_ID, "es", 1) in cache.items


async def test_redis_hiccup_is_retried_before_committing() -> None:
    cache = MemoryCache()
    cache.failures = 2
    service, _, _ = build_service(FakeLLM([draft_json()]), cache=cache)
    fake = FakeConsumer([{"p0": [Record(encode_entry(), 0)]}])
    consumer = zone_consumer(service, fake, FakeProducer())
    task = asyncio.create_task(consumer.run())
    await asyncio.wait_for(fake.drained.wait(), timeout=5)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert fake.commits == 1
    assert (ZONE_ID, "es", 1) in cache.items


# --- API --------------------------------------------------------------------------------------


async def test_api_serves_cached_scripts_only() -> None:
    service, _, _ = build_service(FakeLLM([draft_json()]))
    app = create_api(InMemoryStore(), audioguides=service)
    user = {"X-User-ID": USER_ID, "X-User-Roles": "USER"}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get(f"/v1/audioguides/{ZONE_ID}?lang=es")).status_code == 401
        missing = await c.get(f"/v1/audioguides/{ZONE_ID}?lang=es", headers=user)
        assert missing.status_code == 404
        assert "aún no está lista" in missing.json()["detail"]

        await service.ensure_zone(ZONE_ID, "es")
        ok = await c.get(f"/v1/audioguides/{ZONE_ID}?lang=es", headers=user)
        assert ok.status_code == 200
        body = ok.json()
        assert body["source"] == "llm" and body["language"] == "es"
        assert len(body["segments"]) == 3
        # Idioma con forma inválida: 400, nunca llega a la caché.
        assert (await c.get(f"/v1/audioguides/{ZONE_ID}?lang=es;drop", headers=user)).status_code == 400


# --- Versión del contenido (correcciones de hechos sin esperar al TTL) -------------------


async def test_version_cache_hits_the_database_once_per_zone_and_ttl() -> None:
    facts = FakeFacts(make_zone())
    now = [0.0]
    versions = ZoneVersionCache(facts, ttl_seconds=60, clock=lambda: now[0])
    # Mil turistas a la vez: UNA consulta.
    assert set(await asyncio.gather(*(versions.get(ZONE_ID) for _ in range(1000)))) == {1}
    assert facts.version_calls == 1
    now[0] = 59.0
    await versions.get(ZONE_ID)
    assert facts.version_calls == 1, "aún dentro del TTL: de memoria"
    now[0] = 61.0
    await versions.get(ZONE_ID)
    assert facts.version_calls == 2
    # Una zona inexistente también se recuerda: no se puede martillear PostgreSQL.
    bogus = str(uuid.uuid4())
    for _ in range(5):
        assert await versions.get(bogus) is None
    assert facts.version_calls == 3


async def test_fixing_a_fact_produces_a_new_script_without_waiting_for_the_ttl() -> None:
    llm = FakeLLM([draft_json()] * 5)
    service, cache, facts = build_service(llm)
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.GENERATED
    # Un editor corrige un hecho: el trigger sube la versión a 2.
    facts.zone = make_zone(content_version=2)
    # Mientras la versión vieja siga en memoria, se sirve la vieja (máx. 60 s)...
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.CACHED
    # ...y en cuanto caduca, la clave nueva está vacía y se regenera.
    service._versions.forget(ZONE_ID)
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.GENERATED
    assert {k[2] for k in cache.items} == {1, 2}
    got = await service.get(ZONE_ID, "es")
    assert got is not None and got.content_version == 2
    assert len(llm.calls) == 2


async def test_script_is_stored_with_the_version_it_was_written_from() -> None:
    llm = FakeLLM([draft_json()] * 5)
    service, cache, facts = build_service(llm)
    await service._versions.get(ZONE_ID)  # en memoria: versión 1
    facts.zone = make_zone(content_version=3)  # cambia justo antes de generar
    assert await service.ensure_zone(ZONE_ID, "es") is Outcome.GENERATED
    assert set(cache.items) == {(ZONE_ID, "es", 3)}, "se guarda con la versión REAL de los hechos"
    assert cache.locks == {}
