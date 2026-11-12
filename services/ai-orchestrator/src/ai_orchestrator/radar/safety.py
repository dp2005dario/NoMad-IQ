"""Avisos de seguridad de una ciudad (robos, carteristas, timos, zonas...).

De dónde salen: la sección "Stay safe" ("Seguridad", "Sicherheit"...) de la
guía de esa ciudad en Wikivoyage, la guía de viajes libre que escriben
viajeros (licencia CC BY-SA). Gratis y sin clave.

    GET https://{idioma}.wikivoyage.org/w/api.php?action=parse&page=Barcelona

La IA (Gemini) la resume en 3-6 avisos cortos en tu idioma, cada uno con su
tipo (robos, timos, zonas...). REGLA: solo lo que dice el texto; si no hay
IA, se enseñan las frases del texto que hablan de robos o timos, tal cual.

Se guarda 14 días en Redis por ciudad e idioma (una ciudad sin guía, 1 día):
da igual cuánta gente mire la misma ciudad, se pregunta una vez.
"""

from __future__ import annotations

import html
import logging
import re
from collections.abc import Sequence
from typing import Any, Literal, Protocol
from urllib.parse import quote

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.llm.structured import StructuredOutputError, generate_structured

log = logging.getLogger(__name__)

API_URL = "https://{lang}.wikivoyage.org/w/api.php"
PAGE_URL = "https://{lang}.wikivoyage.org/wiki/{title}"
USER_AGENT = "ECLIPTA/1.0 (travel app; city safety tips)"
KEY_PREFIX = "ai:radar:safety:v1"
TTL_FOUND = 14 * 24 * 3600
TTL_MISSING = 24 * 3600
MAX_TEXT = 6000
# Idiomas con Wikivoyage propia (si no, se usa la inglesa).
WIKIVOYAGE_LANGS = frozenset(
    {
        "en",
        "es",
        "de",
        "fr",
        "it",
        "pt",
        "nl",
        "pl",
        "ru",
        "uk",
        "zh",
        "ja",
        "fa",
        "fi",
        "he",
        "el",
        "sv",
        "vi",
        "tr",
        "hi",
        "bn",
    }
)
# Cómo se llama la sección de seguridad en cada idioma.
SAFE_TITLES = re.compile(
    r"stay safe|keep safe|safety|seguridad|mantente seguro|seguran[cç]a|sicherheit|s[ée]curit[ée]"
    r"|sicurezza|veiligheid|bezpiecze[nń]stwo|безопасность|безпека|安全|امنیت|güvenlik|an toàn|सुरक्षा|নিরাপত্তা",
    re.IGNORECASE,
)
# Sin IA: las frases que hablan de esto son las que se enseñan.
RISK_WORDS = re.compile(
    r"pickpocket|theft|thie|steal|stolen|rob|mug|scam|snatch|careful|avoid|danger|"
    r"carterist|robo|hurto|timo|estafa|peligr|cuidado|evita|"
    r"taschendieb|diebstahl|betrug|pickpocket|vol |voleur|arnaque|borseggi|furto|truffa",
    re.IGNORECASE,
)

TipKind = Literal["theft", "scam", "area", "transport", "night", "health", "emergency", "other"]


class SafetyTip(BaseModel):
    model_config = ConfigDict(frozen=True)

    kind: TipKind
    text: str = Field(min_length=3, max_length=220)


class CitySafety(BaseModel):
    model_config = ConfigDict(frozen=True)

    city: str
    tips: list[SafetyTip]
    # La guía de donde sale (para el enlace y la licencia).
    source_url: str | None = None
    source: str = "Wikivoyage (CC BY-SA)"


class _Summary(BaseModel):
    """Lo que se le pide a la IA."""

    tips: list[SafetyTip] = Field(min_length=1, max_length=6)


class SafetyText(BaseModel):
    model_config = ConfigDict(frozen=True)

    text: str
    lang: str
    url: str


def html_to_text(raw: str) -> str:
    """El HTML de una sección → texto plano (sin tablas, notas ni [editar])."""
    raw = re.sub(r"<(script|style|table|sup)[^>]*>.*?</\1>", " ", raw, flags=re.S | re.I)
    raw = re.sub(r"<span class=\"mw-editsection\".*?</span>\s*</span>", " ", raw, flags=re.S)
    raw = re.sub(r"<h\d[^>]*>.*?</h\d>", "\n", raw, flags=re.S | re.I)
    raw = re.sub(r"<(br|/p|/li|/div)[^>]*>", "\n", raw, flags=re.I)
    text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
    lines = [re.sub(r"\s+", " ", ln).strip() for ln in text.splitlines()]
    return "\n".join(ln for ln in lines if len(ln) > 2)[:MAX_TEXT]


def fallback_tips(text: str, limit: int = 4) -> list[SafetyTip]:
    """Sin IA: las frases del texto que hablan de robos, timos o peligro."""
    out: list[SafetyTip] = []
    for sentence in re.split(r"(?<=[.!?])\s+|\n", text):
        s = sentence.strip()
        if 20 <= len(s) <= 220 and RISK_WORDS.search(s):
            out.append(SafetyTip(kind="other", text=s))
            if len(out) == limit:
                break
    return out


class Wikivoyage:
    """Lee la sección de seguridad de la guía de una ciudad."""

    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def _get(self, lang: str, params: dict[str, str]) -> Any:
        try:
            resp = await self._http.get(
                API_URL.format(lang=lang),
                params={**params, "format": "json", "formatversion": "2", "redirects": "1"},
                headers={"User-Agent": USER_AGENT},
            )
            return resp.json() if resp.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            return None

    async def section(self, city: str, language: str) -> SafetyText | None:
        """En tu idioma si su guía tiene la sección; si no, en inglés."""
        langs = [language] if language in WIKIVOYAGE_LANGS else []
        for lang in dict.fromkeys([*langs, "en"]):
            data = await self._get(lang, {"action": "parse", "page": city, "prop": "sections"})
            parsed = data.get("parse") if isinstance(data, dict) else None
            if not isinstance(parsed, dict):
                continue
            sections = parsed.get("sections")
            if not isinstance(sections, list):
                continue
            raw_title = parsed.get("title")
            title = raw_title if isinstance(raw_title, str) else city
            index = next(
                (
                    str(s.get("index"))
                    for s in sections
                    if isinstance(s, dict) and SAFE_TITLES.search(str(s.get("line", "")))
                ),
                None,
            )
            if index is None:
                continue
            body = await self._get(
                lang, {"action": "parse", "page": title, "prop": "text", "section": index, "disabletoc": "1"}
            )
            raw = body.get("parse", {}).get("text") if isinstance(body, dict) else None
            text = html_to_text(raw) if isinstance(raw, str) else ""
            if len(text) >= 40:
                url = PAGE_URL.format(lang=lang, title=quote(title.replace(" ", "_"), safe=""))
                return SafetyText(text=text, lang=lang, url=url)
        return None


class SafetySource(Protocol):
    async def section(self, city: str, language: str) -> SafetyText | None: ...


class SafetyCache(Protocol):
    async def get(self, key: str) -> CitySafety | None: ...

    async def put(self, key: str, value: CitySafety, *, ttl_seconds: int) -> None: ...


class RedisSafetyCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def get(self, key: str) -> CitySafety | None:
        try:
            raw = await self._redis.get(f"{KEY_PREFIX}:{key}")
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer avisos de Redis: {exc}") from exc
        if raw is None:
            return None
        try:
            return CitySafety.model_validate_json(raw)
        except ValidationError:
            return None

    async def put(self, key: str, value: CitySafety, *, ttl_seconds: int) -> None:
        try:
            await self._redis.set(f"{KEY_PREFIX}:{key}", value.model_dump_json(), ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar avisos en Redis: {exc}") from exc


LANG_NAMES = {
    "es": "español", "en": "English", "de": "Deutsch", "fr": "français", "it": "italiano",
    "pt": "português", "nl": "Nederlands", "pl": "polski", "ro": "română", "ru": "русский",
    "uk": "українська", "tr": "Türkçe", "ar": "العربية", "fa": "فارسی", "ur": "اردو",
    "hi": "हिन्दी", "bn": "বাংলা", "id": "Bahasa Indonesia", "ms": "Bahasa Melayu",
    "fil": "Filipino", "th": "ไทย", "vi": "Tiếng Việt", "ja": "日本語", "ko": "한국어", "zh": "中文",
}  # fmt: skip


def _prompt(city: str, language: str, text: str) -> Sequence[ChatMessage]:
    lang = LANG_NAMES.get(language, "English")
    return [
        ChatMessage(
            "system",
            "Eres el radar de seguridad de una app de viajes. Resumes avisos de seguridad para "
            "viajeros. REGLA: usa SOLO lo que dice el texto, sin inventar nada. Cada aviso: una "
            "o dos frases cortas y prácticas (máx. 200 caracteres), en tono tranquilo. Tipos: "
            "theft (robos, carteristas), scam (timos), area (zonas o barrios con cuidado), "
            "transport (taxis, transporte), night (de noche), health (salud, agua, sol), "
            "emergency (teléfonos de emergencia), other.",
        ),
        ChatMessage(
            "user",
            f"Ciudad: {city}. Escribe entre 3 y 6 avisos en {lang}, los más útiles primero "
            f"(robos y timos antes que nada). Texto de Wikivoyage:\n\n{text}",
        ),
    ]


class SafetyService:
    def __init__(
        self,
        source: SafetySource,
        cache: SafetyCache,
        llm: LLMClient | None,
    ) -> None:
        self._source = source
        self._cache = cache
        self._llm = llm
        self._flight: SingleFlight[CitySafety] = SingleFlight()

    async def city(self, city: str, language: str) -> CitySafety:
        key = f"{language}:{city.lower()}"
        try:
            cached = await self._cache.get(key)
        except CacheError:
            cached = None
        if cached is not None:
            return cached
        found, _ = await self._flight.do(key, lambda: self._fresh(city, language, key))
        return found

    async def _fresh(self, city: str, language: str, key: str) -> CitySafety:
        text = await self._source.section(city, language)
        if text is None:
            result = CitySafety(city=city, tips=[])
            await self._save(key, result, TTL_MISSING)
            return result
        tips: list[SafetyTip] = []
        if self._llm is not None:
            try:
                summary = await generate_structured(
                    self._llm,
                    _prompt(city, language, text.text),
                    _Summary,
                    temperature=0.2,
                    max_tokens=900,
                    max_attempts=2,
                )
                tips = list(summary.tips)
            except (LLMError, StructuredOutputError, ValueError) as exc:
                log.warning("resumen de seguridad sin IA", extra={"error": type(exc).__name__})
        llm_ok = bool(tips)
        if not tips:
            tips = fallback_tips(text.text)
        result = CitySafety(city=city, tips=tips, source_url=text.url)
        # Sin IA (o si falló) se guarda poco: así se resume en cuanto vuelva.
        await self._save(key, result, TTL_FOUND if llm_ok else TTL_MISSING)
        return result

    async def _save(self, key: str, value: CitySafety, ttl: int) -> None:
        try:
            await self._cache.put(key, value, ttl_seconds=ttl)
        except CacheError:
            log.warning("no se pudo guardar los avisos de seguridad en Redis")
