"""El modo cámara: ¿qué monumento tienes delante?

Paso a paso, de lo más barato a lo más caro:
    1. Cupo diario de la persona (Redis). Sin cupo -> 429 "vuelve mañana".
    2. Lugares conocidos cerca (Wikidata), guardados en caché por casilla de
       ~100 m: los de la Puerta del Sol se piden UNA vez a la semana aunque
       los miren mil turistas.
    3. Se ordenan por distancia, por hacia dónde mira el móvil (brújula) y
       por lo famosos que son. Ejemplo: si estás en la Puerta del Sol mirando
       al sur, gana la Real Casa de Correos aunque el Oso esté más cerca.
    4. Si hay modelo de visión (Ollama), se le enseña la foto con los 5
       primeros nombres y elige cuál ve. Es el "RECONOCIDO" de la maqueta.
       Sin modelo, o si tarda, la app dice "¿Es este?" con el más probable.
    5. La ficha (año, foto, resumen de Wikipedia en tu idioma) también va en
       caché 7 días.

Privacidad: la foto solo se usa para esa pregunta. No se guarda en ningún
sitio y ni la foto ni tus coordenadas se escriben en los logs.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import math
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

from pydantic import BaseModel, ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.landmarks.domain import (
    Alternative,
    Candidate,
    Landmark,
    Recognition,
    RecognizeRequest,
)
from ai_orchestrator.landmarks.wikidata import LandmarkSource
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.places.domain import ATTRIBUTION, place_language
from ai_orchestrator.places.wikimedia import WikimediaBusyError, WikimediaError
from ai_orchestrator.quota import (
    Quota,
    QuotaExceededError,
    QuotaUnavailableError,
    day_key,
    seconds_to_midnight,
)

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:landmarks:v1"
QUOTA_PREFIX = "ai:landmarks:quota:v1"
# Tamaño de la casilla de la caché (grados): 0.001° ≈ 110 m.
CELL = 0.001
# Cuántos nombres le enseñamos al modelo de visión.
MAX_SHOWN = 5


class LandmarkBusyError(Exception):
    """Wikidata o Redis no responden ahora mismo (temporal)."""


class _Cached(BaseModel):
    items: list[Candidate]


class LandmarkCache(Protocol):
    async def get_nearby(self, key: str) -> list[Candidate] | None: ...

    async def put_nearby(self, key: str, items: list[Candidate], *, ttl_seconds: int) -> None: ...

    async def get_card(self, qid: str, lang: str) -> Landmark | None: ...

    async def put_card(self, card: Landmark, lang: str, *, ttl_seconds: int) -> None: ...


class RedisLandmarkCache:
    """Si Redis falla, la caché "no tiene nada" (se pregunta a Wikidata)."""

    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def _read(self, key: str) -> str | None:
        try:
            raw = await self._redis.get(key)
        except (RedisError, OSError):
            log.warning("caché de monumentos no disponible")
            return None
        return raw.decode() if isinstance(raw, bytes) else raw

    async def _write(self, key: str, value: str, ttl: int) -> None:
        try:
            await self._redis.set(key, value, ex=ttl)
        except (RedisError, OSError):
            log.warning("no se pudo guardar en la caché de monumentos")

    async def get_nearby(self, key: str) -> list[Candidate] | None:
        raw = await self._read(f"{KEY_PREFIX}:near:{key}")
        if raw is None:
            return None
        try:
            return _Cached.model_validate_json(raw).items
        except ValidationError:
            return None

    async def put_nearby(self, key: str, items: list[Candidate], *, ttl_seconds: int) -> None:
        await self._write(f"{KEY_PREFIX}:near:{key}", _Cached(items=items).model_dump_json(), ttl_seconds)

    async def get_card(self, qid: str, lang: str) -> Landmark | None:
        raw = await self._read(f"{KEY_PREFIX}:card:{lang}:{qid}")
        if raw is None:
            return None
        try:
            return Landmark.model_validate_json(raw)
        except ValidationError:
            return None

    async def put_card(self, card: Landmark, lang: str, *, ttl_seconds: int) -> None:
        await self._write(f"{KEY_PREFIX}:card:{lang}:{card.qid}", card.model_dump_json(), ttl_seconds)


@dataclass(frozen=True, slots=True)
class LandmarkSettings:
    daily_limit: int
    vision_timeout_seconds: float
    ttl_seconds: int = 7 * 24 * 3600


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distancia sobre la Tierra (fórmula del haversine), en metros."""
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Hacia dónde queda el punto 2 visto desde el 1 (0 = norte, 90 = este)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def angle_between(a: float, b: float) -> float:
    """Diferencia entre dos rumbos (0..180): 350° y 10° están a 20°."""
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d


def rank(request: RecognizeRequest, items: list[Candidate]) -> list[tuple[Candidate, int]]:
    """Ordena los lugares de más a menos probable: (lugar, metros)."""
    scored: list[tuple[float, Candidate, int]] = []
    for item in items:
        dist = distance_m(request.lat, request.lon, item.lat, item.lon)
        # Lo famoso suma (pero poco a poco: el log aplana a los gigantes).
        score = math.log1p(item.sitelinks) - dist / 120
        if request.heading is not None and dist > 25:
            off = angle_between(request.heading, bearing(request.lat, request.lon, item.lat, item.lon))
            if off > 75:
                continue  # está a tu espalda o a un lado: no lo estás mirando
            score -= (off / 30) ** 2 * 0.8
        scored.append((score, item, round(dist)))
    scored.sort(key=lambda s: s[0], reverse=True)
    return [(item, dist) for _, item, dist in scored]


def search_radius(accuracy_m: float) -> int:
    """Lo que buscamos alrededor: 350 m, más si el GPS va mal (máx. 800)."""
    return int(min(800, 350 + accuracy_m))


def cell_key(lat: float, lon: float, radius_m: int, lang: str) -> str:
    return f"{lang}:{radius_m}:{round(lat / CELL) * CELL:.3f}:{round(lon / CELL) * CELL:.3f}"


VISION_PROMPT = """Look at the photo.
Which of these places is the main building, monument or landmark visible in it?
{options}
Answer with the number of the place, or -1 if none of them is visible."""

VISION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"match": {"type": "integer", "minimum": -1, "maximum": MAX_SHOWN}},
    "required": ["match"],
}


class LandmarkService:
    def __init__(
        self,
        *,
        source: LandmarkSource,
        cache: LandmarkCache,
        quota: Quota,
        settings: LandmarkSettings,
        vision: LLMClient | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._source = source
        self._cache = cache
        self._quota = quota
        self._settings = settings
        self._vision = vision
        self._clock = clock

    async def recognize(self, user_id: str, request: RecognizeRequest) -> Recognition:
        now = self._clock()
        try:
            left = await self._quota.take(user_id, day_key(now), self._settings.daily_limit)
        except QuotaUnavailableError as exc:
            raise LandmarkBusyError(str(exc)) from exc
        if left is None:
            raise QuotaExceededError(retry_after=seconds_to_midnight(now))
        lang = place_language(request.language.split("-")[0])
        try:
            ranked = rank(request, await self._nearby(request, lang))
        except LandmarkBusyError:
            await self._quota.give_back(user_id, day_key(now))
            raise
        if not ranked:
            return Recognition(status="none", attribution=ATTRIBUTION)
        shown = ranked[:MAX_SHOWN]
        picked = await self._look(request, [c for c, _ in shown])
        if picked == -1:
            # El modelo mira la foto y no ve ninguno: "¿Es alguno de estos?".
            return Recognition(
                status="none",
                alternatives=[Alternative(qid=c.qid, name=c.name, distance_m=d) for c, d in shown],
                attribution=ATTRIBUTION,
            )
        index = picked if picked is not None else 0
        chosen, dist = shown[index]
        card = await self._card(chosen, lang)
        return Recognition(
            status="recognized" if picked is not None else "guess",
            landmark=card.model_copy(update={"distance_m": dist}),
            alternatives=[
                Alternative(qid=c.qid, name=c.name, distance_m=d)
                for i, (c, d) in enumerate(shown)
                if i != index
            ],
            attribution=ATTRIBUTION,
        )

    async def landmark(self, qid: str, language: str) -> Landmark | None:
        """La ficha de un lugar concreto (al elegir otro en "¿Es este?")."""
        lang = place_language(language.split("-")[0])
        cached = await self._cache.get_card(qid, lang)
        if cached is not None:
            return cached
        try:
            item = await self._source.item(qid, lang)
        except (WikimediaBusyError, WikimediaError) as exc:
            raise LandmarkBusyError(str(exc)) from exc
        return None if item is None else await self._card(item, lang)

    async def _nearby(self, request: RecognizeRequest, lang: str) -> list[Candidate]:
        radius = search_radius(request.accuracy_m)
        key = cell_key(request.lat, request.lon, radius, lang)
        cached = await self._cache.get_nearby(key)
        if cached is not None:
            return cached
        try:
            items = await self._source.nearby(request.lat, request.lon, radius, lang)
        except (WikimediaBusyError, WikimediaError) as exc:
            raise LandmarkBusyError(str(exc)) from exc
        await self._cache.put_nearby(key, items, ttl_seconds=self._settings.ttl_seconds)
        return items

    async def _look(self, request: RecognizeRequest, shown: list[Candidate]) -> int | None:
        """Índice que elige el modelo de visión, -1 si no ve ninguno, None si no hay modelo."""
        raw = request.image_bytes()
        if self._vision is None or raw is None:
            return None
        options = "\n".join(
            f"{i}. {c.name}" + (f" ({c.description})" if c.description else "") for i, c in enumerate(shown)
        )
        try:
            text = await asyncio.wait_for(
                self._vision.chat(
                    [
                        ChatMessage(
                            role="user",
                            content=VISION_PROMPT.format(options=options),
                            images=(base64.b64encode(raw).decode(),),
                        )
                    ],
                    json_schema=VISION_SCHEMA,
                    temperature=0.0,
                    max_tokens=20,
                ),
                timeout=self._settings.vision_timeout_seconds,
            )
        except (LLMError, TimeoutError):
            log.info("modelo de visión no disponible: se decide por GPS y brújula")
            return None
        try:
            match = json.loads(text)["match"]
        except (ValueError, KeyError, TypeError):
            return None
        if not isinstance(match, int) or match < -1 or match >= len(shown):
            return None
        return match

    async def _card(self, item: Candidate, lang: str) -> Landmark:
        cached = await self._cache.get_card(item.qid, lang)
        if cached is not None:
            return cached
        summary = None
        if item.article_url:
            try:
                summary = await self._source.summary(item.article_url)
            except (WikimediaBusyError, WikimediaError):
                summary = None  # la ficha sale igual, sin el texto
        card = Landmark(
            qid=item.qid,
            name=item.name,
            description=item.description,
            lat=item.lat,
            lon=item.lon,
            year=item.year,
            photo=item.photo,
            summary=summary,
            article_url=item.article_url,
        )
        if summary is not None or not item.article_url:
            await self._cache.put_card(card, lang, ttl_seconds=self._settings.ttl_seconds)
        return card
