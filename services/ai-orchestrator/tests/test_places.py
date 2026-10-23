"""Tests de las fichas de ciudad: Wikimedia de mentira, caché en memoria."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from conftest import InMemoryStore

from ai_orchestrator.api import create_api
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.places.domain import PlaceCard
from ai_orchestrator.places.service import Missing, PlaceService
from ai_orchestrator.places.wikimedia import (
    RateLimiter,
    WikimediaBusyError,
    WikimediaClient,
    commons_photo,
)

AIRPORTS = Airports.parse(
    "MAD|40.472|-3.561|Madrid|Spain|Europe/Madrid\n"
    "SCL|-33.393|-70.786|Santiago|Chile|America/Santiago\n"
    "XXX|0|0|Nowhere|Nada|UTC\n"
)


def uri(qid: str) -> dict[str, str]:
    return {"type": "uri", "value": f"http://www.wikidata.org/entity/{qid}"}


def lit(value: str) -> dict[str, str]:
    return {"type": "literal", "value": value}


class FakeWikimedia:
    """Contesta como Wikidata/Wikipedia y cuenta las peticiones."""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.status = 200
        self.attractions_status = 200

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = urlparse(str(request.url))
        params = parse_qs(url.query)
        self.calls.append(url.netloc + url.path)
        if self.status != 200:
            return httpx.Response(self.status)
        if url.path == "/w/api.php":
            search = params["search"][0]
            hits = {"Madrid": ["Q2807", "Q5756"], "Santiago": ["Q2887", "Q14317"]}.get(search, [])
            return httpx.Response(200, json={"search": [{"id": h} for h in hits]})
        if url.path == "/sparql":
            query = params["query"][0]
            if "geof:distance" in query:
                # Solo el candidato correcto está cerca de cada aeropuerto.
                if "Q2807" in query:
                    return sparql([{"c": uri("Q2807")}])
                if "Point(-70.7860" in query:
                    return sparql([{"c": uri("Q2887")}])
                return sparql([])
            if "wdt:P131" in query:
                if self.attractions_status != 200:
                    return httpx.Response(self.attractions_status)
                return sparql(
                    [
                        {
                            "item": uri("Q160112"),
                            "itemLabel": lit("Museo del Prado"),
                            "itemDescription": lit("museo de arte"),
                            "image": lit(
                                "http://commons.wikimedia.org/wiki/Special:FilePath/Museo%20del%20Prado.jpg"
                            ),
                            "article": lit("https://es.wikipedia.org/wiki/Museo_del_Prado"),
                        },
                        # Segunda foto del mismo lugar: no debe repetirse.
                        {
                            "item": uri("Q160112"),
                            "itemLabel": lit("Museo del Prado"),
                            "image": lit("http://commons.wikimedia.org/wiki/Special:FilePath/Otra.jpg"),
                        },
                        # Sin nombre en ningún idioma: no se enseña.
                        {"item": uri("Q999"), "itemLabel": lit("Q999")},
                        {"item": uri("Q1"), "itemLabel": lit("Parque del Retiro")},
                    ]
                )
            return sparql(
                [
                    {
                        "cityLabel": lit("Madrid"),
                        "image": lit(
                            "http://commons.wikimedia.org/wiki/Special:FilePath/Madrid%20skyline.jpg"
                        ),
                        "pop": lit("3280782"),
                        "countryLabel": lit("España"),
                        "capitalLabel": lit("Madrid"),
                        "currencyLabel": lit("euro"),
                        "langLabel": lit("español"),
                        "article": lit("https://es.wikipedia.org/wiki/Madrid"),
                        "enArticle": lit("https://en.wikipedia.org/wiki/Madrid"),
                    },
                    {"pop": lit("3100000"), "langLabel": lit("Q12345")},
                ]
            )
        if url.netloc == "es.wikipedia.org" and url.path.endswith("/Madrid"):
            return httpx.Response(200, json={"extract": "Madrid es la capital de España."})
        if url.netloc == "en.wikipedia.org":
            return httpx.Response(200, json={"extract": "Madrid is the capital of Spain."})
        return httpx.Response(404)


def sparql(rows: list[dict[str, Any]]) -> httpx.Response:
    return httpx.Response(200, json={"results": {"bindings": rows}})


class MemoryPlaceCache:
    def __init__(self) -> None:
        self.cards: dict[str, PlaceCard | Missing] = {}
        self.qids: dict[str, str | Missing] = {}
        self.ttls: dict[str, int] = {}

    async def get(self, iata: str, lang: str) -> PlaceCard | Missing | None:
        return self.cards.get(f"{iata}:{lang}")

    async def put(self, card: PlaceCard, *, ttl_seconds: int) -> None:
        self.cards[f"{card.iata}:{card.language}"] = card
        self.ttls[f"{card.iata}:{card.language}"] = ttl_seconds

    async def put_missing(self, iata: str, lang: str, *, ttl_seconds: int) -> None:
        self.cards[f"{iata}:{lang}"] = "missing"

    async def get_qid(self, iata: str) -> str | Missing | None:
        return self.qids.get(iata)

    async def put_qid(self, iata: str, qid: str | None, *, ttl_seconds: int) -> None:
        self.qids[iata] = qid or "missing"


def service(
    fake: FakeWikimedia, cache: MemoryPlaceCache | None = None
) -> tuple[PlaceService, MemoryPlaceCache]:
    cache = cache or MemoryPlaceCache()
    http = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    wiki = WikimediaClient(http, limiter=RateLimiter(1000, 1000))
    return PlaceService(airports=AIRPORTS, wikimedia=wiki, cache=cache), cache


async def test_builds_a_card_from_wikidata_and_wikipedia() -> None:
    fake = FakeWikimedia()
    svc, cache = service(fake)
    card = await svc.get("mad", "es")
    assert card is not None
    assert card.city == "Madrid"
    assert card.wikidata_id == "Q2807"
    assert card.summary == "Madrid es la capital de España."
    assert card.summary_language == "es"
    assert card.population == 3280782  # el mayor de los valores
    assert card.country is not None and card.country.currency == "euro"
    assert card.country.languages == ["español"]  # "Q12345" no es un nombre
    assert [a.name for a in card.attractions] == ["Museo del Prado", "Parque del Retiro"]
    assert card.attractions[0].photo is not None
    assert card.photo is not None and card.photo.url.startswith("https://upload.wikimedia.org/")
    assert "MAD:es" in cache.cards


async def test_second_request_is_served_from_cache() -> None:
    fake = FakeWikimedia()
    svc, _ = service(fake)
    await svc.get("MAD", "es")
    before = len(fake.calls)
    await svc.get("MAD", "es")
    assert len(fake.calls) == before
    # Otro idioma reutiliza la ciudad ya encontrada: sin buscarla otra vez.
    await svc.get("MAD", "fr")
    assert fake.calls[before:].count("www.wikidata.org/w/api.php") == 0


async def test_simultaneous_requests_cost_one_build() -> None:
    fake = FakeWikimedia()
    svc, _ = service(fake)
    cards = await asyncio.gather(*(svc.get("MAD", "es") for _ in range(50)))
    assert all(c is not None for c in cards)
    assert fake.calls.count("www.wikidata.org/w/api.php") == 1


async def test_picks_the_city_near_the_airport() -> None:
    fake = FakeWikimedia()
    svc, cache = service(fake)
    await svc.get("SCL", "en")
    assert cache.qids["SCL"] == "Q2887"


async def test_unknown_language_falls_back_to_english() -> None:
    fake = FakeWikimedia()
    svc, _ = service(fake)
    card = await svc.get("MAD", "xx")
    assert card is not None and card.language == "en"


async def test_unknown_city_is_remembered_as_missing() -> None:
    fake = FakeWikimedia()
    svc, cache = service(fake)
    assert await svc.get("XXX", "en") is None
    assert cache.cards["XXX:en"] == "missing"
    calls = len(fake.calls)
    assert await svc.get("XXX", "en") is None
    assert len(fake.calls) == calls
    # Un código que no es un aeropuerto ni siquiera llama a Wikimedia.
    assert await svc.get("ZZZ", "en") is None
    assert len(fake.calls) == calls


async def test_failed_attractions_still_give_a_short_lived_card() -> None:
    fake = FakeWikimedia()
    fake.attractions_status = 500
    svc, cache = service(fake)
    card = await svc.get("MAD", "es")
    assert card is not None and card.attractions == []
    assert cache.ttls["MAD:es"] == 3600


async def test_rate_limiter_says_busy_instead_of_queueing() -> None:
    limiter = RateLimiter(rate=1, burst=1)
    await limiter.acquire(0)
    with pytest.raises(WikimediaBusyError):
        await limiter.acquire(0.1)


def test_commons_thumbnail_url() -> None:
    photo = commons_photo("http://commons.wikimedia.org/wiki/Special:FilePath/Example.jpg", 500)
    assert photo is not None
    # La carpeta sale del MD5 de "Example.jpg" (a9/a9c…), como en Commons.
    assert (
        photo.url == "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/500px-Example.jpg"
    )
    assert photo.page_url == "https://commons.wikimedia.org/wiki/File:Example.jpg"
    svg = commons_photo("http://commons.wikimedia.org/wiki/Special:FilePath/Flag.svg", 500)
    assert svg is not None and svg.url.endswith("500px-Flag.svg.png")
    assert commons_photo("http://commons.wikimedia.org/wiki/Special:FilePath/Doc.pdf", 500) is None


def test_bundled_airports_match_the_app() -> None:
    airports = Airports.bundled()
    assert len(airports) > 5000
    mad = airports.get("mad")
    assert mad is not None and mad.city == "Madrid"
    # La lista del servidor y la de la app deben ser la misma.
    app_copy = Path(__file__).resolve().parents[3] / "mobile" / "assets" / "geo" / "airports.txt"
    if app_copy.exists():
        server_copy = (
            Path(__file__).resolve().parents[1] / "src" / "ai_orchestrator" / "places" / "airports.txt"
        )
        assert server_copy.read_bytes() == app_copy.read_bytes()


def api(svc: PlaceService) -> httpx.AsyncClient:
    app = create_api(InMemoryStore(), places=svc)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


async def test_api_is_public_and_cacheable() -> None:
    fake = FakeWikimedia()
    svc, _ = service(fake)
    async with api(svc) as c:
        # Sin X-User-ID: también para el modo invitado.
        resp = await c.get("/v1/places/MAD", params={"lang": "es"})
        assert resp.status_code == 200
        assert resp.headers["cache-control"] == "public, max-age=86400"
        assert resp.json()["city"] == "Madrid"
        missing = await c.get("/v1/places/XXX")
        assert missing.status_code == 404
        assert missing.headers["cache-control"] == "public, max-age=3600"
        bad = await c.get("/v1/places/MADRID")
        assert bad.status_code in (400, 404)


async def test_api_says_busy_when_wikimedia_pushes_back() -> None:
    fake = FakeWikimedia()
    fake.status = 429
    svc, _ = service(fake)
    async with api(svc) as c:
        resp = await c.get("/v1/places/MAD")
    assert resp.status_code == 503
    assert resp.headers["retry-after"] == "60"
    assert json.loads(resp.text)["status"] == 503
