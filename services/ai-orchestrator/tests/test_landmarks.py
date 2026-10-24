"""Pruebas del modo cámara (sin Wikidata, Redis ni Ollama de verdad)."""

from __future__ import annotations

import base64
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from conftest import FakeLLM, InMemoryStore
from pydantic import ValidationError

from ai_orchestrator.api import create_api
from ai_orchestrator.landmarks.domain import Candidate, Landmark, RecognizeRequest
from ai_orchestrator.landmarks.service import (
    LandmarkBusyError,
    LandmarkService,
    LandmarkSettings,
    angle_between,
    bearing,
    distance_m,
    rank,
)
from ai_orchestrator.landmarks.wikidata import item_query, nearby_query, parse_rows
from ai_orchestrator.llm.client import LLMUnavailableError
from ai_orchestrator.places.wikimedia import WikimediaBusyError

USER = "11111111-1111-4111-8111-111111111111"
NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)
# La Puerta del Sol (Madrid): de aquí miramos.
SOL = (40.41690, -3.70360)
JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"0" * 100).decode()

CORREOS = Candidate(
    qid="Q1503138",
    name="Real Casa de Correos",
    description="edificio de Madrid",
    lat=40.41660,
    lon=-3.70360,  # al sur, a ~33 m
    year=1768,
    article_url="https://es.wikipedia.org/wiki/Real_Casa_de_Correos",
    sitelinks=20,
)
OSO = Candidate(qid="Q2633064", name="El Oso y el Madroño", lat=40.41700, lon=-3.70380, sitelinks=15)
PALACIO = Candidate(qid="Q207999", name="Palacio Real", lat=40.41800, lon=-3.71400, sitelinks=90)


class MemoryQuota:
    def __init__(self) -> None:
        self.used = 0

    async def take(self, user_id: str, day: str, limit: int) -> int | None:
        self.used += 1
        return None if self.used > limit else limit - self.used

    async def give_back(self, user_id: str, day: str) -> None:
        self.used -= 1


class MemoryCache:
    def __init__(self) -> None:
        self.near: dict[str, list[Candidate]] = {}
        self.cards: dict[tuple[str, str], Landmark] = {}

    async def get_nearby(self, key: str) -> list[Candidate] | None:
        return self.near.get(key)

    async def put_nearby(self, key: str, items: list[Candidate], *, ttl_seconds: int) -> None:
        self.near[key] = items

    async def get_card(self, qid: str, lang: str) -> Landmark | None:
        return self.cards.get((qid, lang))

    async def put_card(self, card: Landmark, lang: str, *, ttl_seconds: int) -> None:
        self.cards[(card.qid, lang)] = card


class FakeSource:
    def __init__(self, items: list[Candidate], fail: Exception | None = None) -> None:
        self.items = items
        self.fail = fail
        self.calls = 0

    async def nearby(self, lat: float, lon: float, radius_m: int, lang: str) -> list[Candidate]:
        self.calls += 1
        if self.fail:
            raise self.fail
        return self.items

    async def item(self, qid: str, lang: str) -> Candidate | None:
        return next((c for c in self.items if c.qid == qid), None)

    async def summary(self, article_url: str) -> str | None:
        return "Fue la casa de correos de la ciudad."


def service(
    items: list[Candidate] | None = None,
    *,
    vision: Any = None,
    source: FakeSource | None = None,
    quota: MemoryQuota | None = None,
    limit: int = 5,
) -> LandmarkService:
    return LandmarkService(
        source=source or FakeSource(items if items is not None else [CORREOS, OSO, PALACIO]),  # type: ignore[arg-type]
        cache=MemoryCache(),
        quota=quota or MemoryQuota(),
        settings=LandmarkSettings(daily_limit=limit, vision_timeout_seconds=2),
        vision=vision,
        clock=lambda: NOW,
    )


def ask(**extra: Any) -> RecognizeRequest:
    return RecognizeRequest.model_validate({"lat": SOL[0], "lon": SOL[1], "language": "es", **extra})


# --- Geometría ----------------------------------------------------------------------------


def test_geometry() -> None:
    assert 32 < distance_m(*SOL, CORREOS.lat, CORREOS.lon) < 35
    assert abs(bearing(*SOL, CORREOS.lat, CORREOS.lon) - 180) < 1
    assert angle_between(350, 10) == 20
    assert angle_between(0, 180) == 180


def test_heading_beats_closeness() -> None:
    # Mirando al sur gana Correos; al noroeste, el Oso. El Palacio está a 900 m.
    south = rank(ask(heading=180), [OSO, CORREOS, PALACIO])
    assert south[0][0].qid == CORREOS.qid
    northwest = rank(ask(heading=330), [OSO, CORREOS, PALACIO])
    assert northwest[0][0].qid == OSO.qid
    assert CORREOS.qid not in {c.qid for c, _ in northwest}


# --- Petición -------------------------------------------------------------------------------


def test_image_must_be_a_jpeg() -> None:
    assert ask(image=JPEG).image_bytes() is not None
    with pytest.raises(ValidationError):
        ask(image=base64.b64encode(b"GIF89a....").decode())
    with pytest.raises(ValidationError):
        ask(image="esto no es base64!!")
    with pytest.raises(ValidationError):
        ask(lat=91)


# --- Wikidata --------------------------------------------------------------------------------


def test_queries_only_take_validated_values() -> None:
    q = nearby_query(40.4169, -3.7036, 0.35, "es")
    assert "Point(-3.70360 40.41690)" in q and '"0.350"' in q
    with pytest.raises(ValueError):
        item_query("Q1 } DELETE", "es")
    with pytest.raises(ValueError):
        nearby_query(0, 0, 0.3, 'es"')


def test_parse_rows() -> None:
    def row(qid: str, label: str, **more: str) -> dict[str, Any]:
        out = {
            "item": {"value": f"http://www.wikidata.org/entity/{qid}"},
            "itemLabel": {"value": label},
            "loc": {"value": "Point(-3.7036 40.4166)"},
            "sl": {"value": "20"},
        }
        out.update({k: {"value": v} for k, v in more.items()})
        return out

    items = parse_rows(
        [
            row(
                "Q1503138", "Real Casa de Correos", inception="1768-01-01T00:00:00Z", image="http://x/A b.jpg"
            ),
            row("Q1503138", "Real Casa de Correos"),  # segunda foto: se ignora
            row("Q999", "Q999"),  # sin nombre
        ]
    )
    assert [i.qid for i in items] == ["Q1503138"]
    assert items[0].year == 1768
    assert items[0].photo is not None and "upload.wikimedia.org" in items[0].photo.url


# --- Servicio ---------------------------------------------------------------------------------


async def test_guess_without_vision_and_cache() -> None:
    src = FakeSource([CORREOS, OSO, PALACIO])
    svc = service(source=src)
    found = await svc.recognize(USER, ask(heading=180, image=JPEG))
    assert found.status == "guess"
    assert found.landmark is not None and found.landmark.name == "Real Casa de Correos"
    assert found.landmark.year == 1768 and found.landmark.summary
    assert 30 < (found.landmark.distance_m or 0) < 40
    # El Palacio queda a tu espalda (oeste) y el Oso a 20 m: solo sale el Oso.
    assert {a.qid for a in found.alternatives} == {OSO.qid}
    await svc.recognize(USER, ask(heading=180))
    assert src.calls == 1  # la segunda vez, de la caché


async def test_vision_picks_and_sees_the_photo() -> None:
    llm = FakeLLM(['{"match": 1}'])
    found = await service(vision=llm).recognize(USER, ask(image=JPEG))
    assert found.status == "recognized"
    sent = llm.calls[0]["messages"][0]
    assert sent.images == (JPEG,)
    assert "0. " in sent.content and "1. " in sent.content
    assert found.landmark is not None
    # El elegido es el segundo de la lista que se enseñó al modelo.
    assert found.landmark.name in {CORREOS.name, OSO.name, PALACIO.name}


async def test_vision_sees_nothing_offers_alternatives() -> None:
    found = await service(vision=FakeLLM(['{"match": -1}'])).recognize(USER, ask(image=JPEG))
    assert found.status == "none" and found.landmark is None
    assert len(found.alternatives) == 3


async def test_vision_down_falls_back_to_guess() -> None:
    found = await service(vision=FakeLLM([LLMUnavailableError("x")])).recognize(USER, ask(image=JPEG))
    assert found.status == "guess"


async def test_nothing_nearby() -> None:
    found = await service([]).recognize(USER, ask())
    assert found.status == "none" and not found.alternatives


async def test_wikidata_busy_gives_back_the_quota() -> None:
    quota = MemoryQuota()
    svc = service(source=FakeSource([], fail=WikimediaBusyError("429")), quota=quota)
    with pytest.raises(LandmarkBusyError):
        await svc.recognize(USER, ask())
    assert quota.used == 0


# --- API -----------------------------------------------------------------------------------------


def headers() -> dict[str, str]:
    return {"X-User-ID": USER, "X-User-Roles": "USER"}


def client(svc: LandmarkService) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=create_api(InMemoryStore(), landmarks=svc)), base_url="http://t"
    )


async def test_api() -> None:
    body = {"lat": SOL[0], "lon": SOL[1], "heading": 180, "language": "es", "image": JPEG}
    async with client(service(limit=1)) as c:
        assert (await c.post("/v1/landmarks/recognize", json=body)).status_code == 401
        ok = await c.post("/v1/landmarks/recognize", json=body, headers=headers())
        assert ok.status_code == 200
        assert ok.json()["landmark"]["name"] == "Real Casa de Correos"
        assert ok.headers["cache-control"] == "no-store"
        limited = await c.post("/v1/landmarks/recognize", json=body, headers=headers())
        assert limited.status_code == 429 and "retry-after" in limited.headers
        card = await c.get(f"/v1/landmarks/{OSO.qid}", params={"lang": "es"}, headers=headers())
        assert card.status_code == 200 and card.json()["name"] == OSO.name
        assert (await c.get("/v1/landmarks/Q404", headers=headers())).status_code == 404
        assert (await c.get("/v1/landmarks/nope", headers=headers())).status_code in (400, 404)
