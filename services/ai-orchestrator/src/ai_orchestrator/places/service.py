"""El servicio de fichas de ciudad: caché primero, Wikimedia solo si hace falta.

Orden de cada petición (de lo más barato a lo más caro):
    1. Redis (``ai:place:v1:<IATA>:<idioma>``): ~1 ms. Casi todas acaban aquí.
    2. Single flight: si ya hay alguien preparando ESA ficha en este
       proceso, se espera su resultado en vez de repetir el trabajo.
    3. Wikimedia (5 peticiones), y se guarda 7 días.

Lo que no existe también se recuerda ("-" durante un día): un aeropuerto
cuya ciudad no está en Wikidata no vuelve a costar peticiones en cada visita.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Literal, Protocol

from pydantic import ValidationError
from redis.asyncio import Redis
from redis.exceptions import RedisError

from ai_orchestrator.audioguides.cache import CacheError, SingleFlight
from ai_orchestrator.places.airports import Airport, Airports
from ai_orchestrator.places.domain import PlaceCard, place_language
from ai_orchestrator.places.wikimedia import WikimediaBusyError, WikimediaClient, WikimediaError

log = logging.getLogger(__name__)

KEY_PREFIX = "ai:place:v1"
QID_PREFIX = "ai:place-qid:v1"
_MISSING = "-"

# Lo que puede devolver la caché: la ficha, "sabemos que no hay" o nada guardado.
Missing = Literal["missing"]


class PlaceCache(Protocol):
    async def get(self, iata: str, lang: str) -> PlaceCard | Missing | None: ...

    async def put(self, card: PlaceCard, *, ttl_seconds: int) -> None: ...

    async def put_missing(self, iata: str, lang: str, *, ttl_seconds: int) -> None: ...

    async def get_qid(self, iata: str) -> str | Missing | None: ...

    async def put_qid(self, iata: str, qid: str | None, *, ttl_seconds: int) -> None: ...


class RedisPlaceCache:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    async def _read(self, key: str) -> str | None:
        try:
            raw = await self._redis.get(key)
        except (RedisError, OSError) as exc:
            raise CacheError(f"leer ficha de Redis: {exc}") from exc
        if raw is None:
            return None
        return raw.decode() if isinstance(raw, bytes) else str(raw)

    async def _write(self, key: str, value: str, ttl_seconds: int) -> None:
        try:
            await self._redis.set(key, value, ex=ttl_seconds)
        except (RedisError, OSError) as exc:
            raise CacheError(f"guardar ficha en Redis: {exc}") from exc

    async def get(self, iata: str, lang: str) -> PlaceCard | Missing | None:
        raw = await self._read(f"{KEY_PREFIX}:{iata}:{lang}")
        if raw is None:
            return None
        if raw == _MISSING:
            return "missing"
        try:
            return PlaceCard.model_validate_json(raw)
        except ValidationError:
            # Algo viejo o roto: como si no estuviera (se rehace).
            return None

    async def put(self, card: PlaceCard, *, ttl_seconds: int) -> None:
        await self._write(f"{KEY_PREFIX}:{card.iata}:{card.language}", card.model_dump_json(), ttl_seconds)

    async def put_missing(self, iata: str, lang: str, *, ttl_seconds: int) -> None:
        await self._write(f"{KEY_PREFIX}:{iata}:{lang}", _MISSING, ttl_seconds)

    async def get_qid(self, iata: str) -> str | Missing | None:
        raw = await self._read(f"{QID_PREFIX}:{iata}")
        if raw is None:
            return None
        return "missing" if raw == _MISSING else raw

    async def put_qid(self, iata: str, qid: str | None, *, ttl_seconds: int) -> None:
        await self._write(f"{QID_PREFIX}:{iata}", qid or _MISSING, ttl_seconds)


class PlaceBusyError(Exception):
    """Demasiadas fichas nuevas a la vez: la app lo reintentará más tarde."""


class PlaceUnavailableError(Exception):
    """Wikimedia no responde ahora mismo."""


@dataclass(frozen=True, slots=True)
class PlaceSettings:
    # Una ficha completa vive 7 días; la ciudad de cada aeropuerto, 30.
    ttl_seconds: int = 7 * 24 * 3600
    qid_ttl_seconds: int = 30 * 24 * 3600
    # "No hay ficha" se recuerda un día (por si alguien la crea en Wikidata).
    missing_ttl_seconds: int = 24 * 3600
    # Si falló una parte (por ejemplo, "lo más visitado"), la ficha incompleta
    # solo se guarda una hora y luego se vuelve a intentar.
    partial_ttl_seconds: int = 3600


class PlaceService:
    def __init__(
        self,
        *,
        airports: Airports,
        wikimedia: WikimediaClient,
        cache: PlaceCache,
        settings: PlaceSettings | None = None,
    ) -> None:
        self._airports = airports
        self._wiki = wikimedia
        self._cache = cache
        self._settings = settings or PlaceSettings()
        self._flight: SingleFlight[PlaceCard | None] = SingleFlight()

    async def get(self, iata: str, lang: str) -> PlaceCard | None:
        """La ficha, o None si el aeropuerto no existe o su ciudad no está en Wikidata."""
        airport = self._airports.get(iata)
        if airport is None:
            return None
        lang = place_language(lang)
        cached = await self._cache.get(airport.iata, lang)
        if cached == "missing":
            return None
        if isinstance(cached, PlaceCard):
            return cached
        try:
            card, _ = await self._flight.do(f"{airport.iata}:{lang}", lambda: self._build(airport, lang))
        except WikimediaBusyError as exc:
            raise PlaceBusyError(str(exc)) from exc
        except WikimediaError as exc:
            log.warning("Wikimedia no disponible", extra={"iata": airport.iata, "error": str(exc)})
            raise PlaceUnavailableError(str(exc)) from exc
        return card

    async def _build(self, airport: Airport, lang: str) -> PlaceCard | None:
        qid = await self._qid(airport)
        if qid is None:
            await self._cache.put_missing(airport.iata, lang, ttl_seconds=self._settings.missing_ttl_seconds)
            return None
        details_task = asyncio.create_task(self._wiki.city_details(qid, lang))
        attractions_task = asyncio.create_task(self._wiki.attractions(qid, lang))
        try:
            details = await details_task
        except BaseException:
            attractions_task.cancel()
            raise
        partial = False
        try:
            attractions = await attractions_task
        except WikimediaError as exc:
            # La consulta de lugares es la más pesada: si falla, la ficha sale
            # igual (sin esa parte) y se reintenta antes.
            log.warning("lugares no disponibles", extra={"iata": airport.iata, "error": str(exc)})
            attractions, partial = [], True

        summary_language: str | None = None
        summary: tuple[str, str] | None = None
        for article, article_lang in ((details.get("article"), lang), (details.get("en_article"), "en")):
            if article:
                summary = await self._wiki.summary(article)
                if summary is not None:
                    summary_language = article_lang
                    break

        card = PlaceCard(
            iata=airport.iata,
            language=lang,
            wikidata_id=qid,
            city=details.get("city") or airport.city,
            summary=summary[0] if summary else None,
            summary_language=summary_language,
            article_url=summary[1] if summary else None,
            photo=self._wiki.city_photo(details.get("image")),
            population=details.get("population"),
            country=self._wiki.country_facts(details),
            attractions=attractions,
        )
        ttl = self._settings.partial_ttl_seconds if partial else self._settings.ttl_seconds
        await self._cache.put(card, ttl_seconds=ttl)
        return card

    async def _qid(self, airport: Airport) -> str | None:
        cached = await self._cache.get_qid(airport.iata)
        if cached == "missing":
            return None
        if cached is not None:
            return cached
        qid = await self._wiki.find_city(airport)
        ttl = self._settings.qid_ttl_seconds if qid else self._settings.missing_ttl_seconds
        await self._cache.put_qid(airport.iata, qid, ttl_seconds=ttl)
        return qid
