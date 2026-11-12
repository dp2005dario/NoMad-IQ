"""Tests de los avisos de seguridad de una ciudad (Wikivoyage de mentira)."""

from __future__ import annotations

import json
from typing import Any

import httpx
from conftest import FakeLLM, InMemoryStore
from test_radar import AIRPORTS, MemoryRadar, h

from ai_orchestrator.api import create_api
from ai_orchestrator.radar.api import radar_router
from ai_orchestrator.radar.safety import (
    CitySafety,
    SafetyService,
    Wikivoyage,
    fallback_tips,
    html_to_text,
)

SECTION_HTML = (
    '<h2>Stay safe<span class="mw-editsection"><span>[edit]</span></span></h2>'
    "<p>Tokyo is very safe. Pickpockets work the crowded trains at rush hour, keep bags in front.</p>"
    "<p>In Kabukicho, touts lure people into bars that charge huge bills: avoid them.</p>"
    "<table><tr><td>ignorar tabla</td></tr></table><p>Call 110 for police.</p>"
)


def wikivoyage(calls: list[str], *, has_es: bool = False) -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        lang = request.url.host.split(".")[0]
        params = dict(request.url.params)
        calls.append(f"{lang}:{params.get('prop')}")
        if lang == "es" and not has_es:
            return httpx.Response(200, json={"error": {"code": "missingtitle"}})
        if params.get("prop") == "sections":
            sections: list[dict[str, Any]] = [
                {"line": "Get in", "index": "1"},
                {"line": "Seguridad" if lang == "es" else "Stay safe", "index": "7"},
            ]
            return httpx.Response(200, json={"parse": {"title": "Tokyo", "sections": sections}})
        assert params.get("section") == "7"
        return httpx.Response(200, json={"parse": {"text": SECTION_HTML}})

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class MemoryCache:
    def __init__(self) -> None:
        self.items: dict[str, tuple[CitySafety, int]] = {}

    async def get(self, key: str) -> CitySafety | None:
        found = self.items.get(key)
        return found[0] if found else None

    async def put(self, key: str, value: CitySafety, *, ttl_seconds: int) -> None:
        self.items[key] = (value, ttl_seconds)


def test_html_to_text_drops_tables_and_edit_links() -> None:
    text = html_to_text(SECTION_HTML)
    assert "Pickpockets" in text
    assert "[edit]" not in text and "ignorar tabla" not in text and "Stay safe" not in text


def test_fallback_keeps_only_risk_sentences() -> None:
    tips = fallback_tips(html_to_text(SECTION_HTML))
    assert [t.text[:11] for t in tips] == ["Pickpockets", "In Kabukich"]


async def test_safety_summarised_in_your_language_and_cached() -> None:
    calls: list[str] = []
    llm = FakeLLM(
        [
            json.dumps(
                {
                    "tips": [
                        {"kind": "theft", "text": "Carteristas en los trenes llenos: la mochila delante."},
                        {"kind": "scam", "text": "En Kabukicho, evita a los captadores de bares."},
                        {"kind": "emergency", "text": "Policía: 110."},
                    ]
                }
            )
        ]
    )
    cache = MemoryCache()
    service = SafetyService(Wikivoyage(wikivoyage(calls)), cache, llm)
    got = await service.city("Tokyo", "es")
    assert [t.kind for t in got.tips] == ["theft", "scam", "emergency"]
    assert got.source_url == "https://en.wikivoyage.org/wiki/Tokyo"
    # Sin guía en español, se usa la inglesa; la IA escribe en español.
    assert calls == ["es:sections", "en:sections", "en:text"]
    assert "español" in llm.calls[0]["messages"][1].content
    assert "Pickpockets" in llm.calls[0]["messages"][1].content
    assert cache.items["es:tokyo"][1] == 14 * 24 * 3600
    # La segunda vez sale de la caché: ni Wikivoyage ni IA.
    again = await service.city("Tokyo", "es")
    assert again == got
    assert len(calls) == 3


async def test_without_ai_shows_the_guide_sentences() -> None:
    calls: list[str] = []
    cache = MemoryCache()
    service = SafetyService(Wikivoyage(wikivoyage(calls, has_es=True)), cache, None)
    got = await service.city("Tokyo", "es")
    assert calls == ["es:sections", "es:text"]
    assert got.tips[0].kind == "other"
    assert got.tips[0].text.startswith("Pickpockets")
    assert got.source_url == "https://es.wikivoyage.org/wiki/Tokyo"
    assert cache.items["es:tokyo"][1] == 24 * 3600


async def test_safety_api() -> None:
    calls: list[str] = []
    service = SafetyService(Wikivoyage(wikivoyage(calls)), MemoryCache(), None)
    app = create_api(InMemoryStore(), radar=radar_router(MemoryRadar(), AIRPORTS, service))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/v1/radar/NRT/safety?lang=en", headers=h("a"))
        assert r.status_code == 200
        assert r.json()["city"] == "Tokyo"
        assert r.json()["tips"][0]["text"].startswith("Pickpockets")
        assert (await c.get("/v1/radar/XXX/safety", headers=h("a"))).status_code == 404
        assert (await c.get("/v1/radar/NRT/safety?lang=<b>", headers=h("a"))).status_code in (400, 422)
    off = create_api(InMemoryStore(), radar=radar_router(MemoryRadar(), AIRPORTS))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=off), base_url="http://t") as c:
        assert (await c.get("/v1/radar/NRT/safety", headers=h("a"))).status_code == 503
