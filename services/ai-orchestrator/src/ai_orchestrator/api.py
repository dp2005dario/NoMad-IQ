"""API HTTP (FastAPI): el usuario consulta sus recomendaciones.

Seguridad Zero Trust, explicada:
    Esta API NO valida tokens JWT. De eso se encarga el auth-gateway: el proxy
    de borde le pregunta "¿este token es bueno?" y, si lo es, nos reenvía la
    petición con las cabeceras X-User-ID y X-User-Roles ya verificadas.

    ¿Y si alguien de dentro de la red se inventa X-User-ID? No puede llegar
    hasta aquí: el puerto de la API exige mTLS, es decir, que el que llama
    presente un certificado firmado por nuestra autoridad interna. Solo el
    proxy de borde lo tiene. Analogía: el portero (gateway) comprueba el DNI
    en la entrada y te pone una pulsera; aquí dentro solo se fían de la
    pulsera porque la puerta de este pasillo solo la abre el personal.

Además:
    - Cada usuario solo ve SUS recomendaciones (el filtro va en la consulta SQL).
    - Si pides una que no es tuya, respondemos 404 igual que si no existiera:
      así no revelamos qué identificadores existen.
    - Los errores siguen RFC 9457 (application/problem+json), sin trazas internas.
    - Ningún endpoint llama al LLM: responden en milisegundos.
    - Las audioguías (/v1/audioguides) son GENÉRICAS por zona e idioma: no
      dependen de quién pregunta. Aun así exigen identidad (solo usuarios de
      NomadIQ), y quien las pide nunca deja rastro de su ubicación aquí.
    - Los archivos de audio (/v1/audio/...) son contenido público e
      inmutable, como las imágenes de una web: no llevan datos de nadie, así
      que se sirven sin identidad para que una CDN pueda guardarlos y
      repartirlos. Lo que exige identidad es el manifiesto que dice qué
      archivos tocan en cada zona.
    - Las fichas de ciudad (/v1/places) también son públicas: son datos de
      Wikipedia iguales para todos, y así el modo invitado las ve. Solo se
      aceptan códigos de aeropuerto reales, nunca texto libre.
    - Las fotos de calle (/v1/streetview) son públicas por lo mismo. La app
      manda el punto ya redondeado a ~100 m y aquí se vuelve a redondear: el
      servidor nunca guarda ni registra dónde está nadie.
"""

from __future__ import annotations

import logging
import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Path, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from ai_orchestrator.atms.domain import Atms
from ai_orchestrator.atms.service import AtmBusyError, AtmService, AtmUnavailableError
from ai_orchestrator.audioguides.audio_catalog import AudioCatalog, AudioLookup
from ai_orchestrator.audioguides.cache import CacheError
from ai_orchestrator.audioguides.domain import AudioguideScript
from ai_orchestrator.audioguides.service import AudioguideService
from ai_orchestrator.domain import Recommendation, Verdict
from ai_orchestrator.flyra.domain import ChatReply, ChatRequest
from ai_orchestrator.flyra.service import FlyraBusyError, FlyraService
from ai_orchestrator.fx.service import FxRates, FxService, FxUnavailableError
from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.landmarks.domain import Landmark, Recognition, RecognizeRequest
from ai_orchestrator.landmarks.service import LandmarkBusyError, LandmarkService
from ai_orchestrator.places.domain import PlaceCard
from ai_orchestrator.places.service import PlaceBusyError, PlaceService, PlaceUnavailableError
from ai_orchestrator.quota import QuotaExceededError
from ai_orchestrator.store import RecommendationStore, StoreError
from ai_orchestrator.streetview.domain import StreetPhotos
from ai_orchestrator.streetview.service import StreetBusyError, StreetUnavailableError, StreetViewService

log = logging.getLogger(__name__)


def _problem(status: int, title: str, detail: str | None = None) -> JSONResponse:
    body: dict[str, Any] = {"type": "about:blank", "title": title, "status": status}
    if detail:
        body["detail"] = detail
    return JSONResponse(body, status_code=status, media_type="application/problem+json")


class RecommendationView(BaseModel):
    """Lo que devolvemos al cliente (no exponemos user_id ni correlation_id)."""

    model_config = ConfigDict(frozen=True)

    alert_id: str
    verdict: Verdict
    headline: str
    body: str
    source: str
    facts: dict[str, str]
    booking_deep_link: str
    alert_occurred_at: datetime
    created_at: datetime

    @classmethod
    def of(cls, rec: Recommendation) -> RecommendationView:
        return cls(
            alert_id=rec.alert_id,
            verdict=rec.verdict,
            headline=rec.headline,
            body=rec.body,
            source=rec.source,
            facts=rec.facts,
            booking_deep_link=rec.booking_deep_link,
            alert_occurred_at=rec.alert_occurred_at,
            created_at=rec.created_at,
        )


class RecommendationList(BaseModel):
    items: list[RecommendationView]


class AudioPartView(BaseModel):
    model_config = ConfigDict(frozen=True)

    index: int
    url: str
    duration_seconds: float
    text: str


class AudioguideAudioView(BaseModel):
    """El manifiesto de audio: qué archivos reproducir, en orden."""

    model_config = ConfigDict(frozen=True)

    zone_id: str
    language: str
    content_language: str
    # Versión actual del contenido de la zona...
    content_version: int
    # ...y la versión de la que es este audio. Si es menor, "stale" = true: la
    # versión nueva aún se está grabando y, mientras, suena la anterior.
    audio_content_version: int
    stale: bool
    source: str
    voice: str
    total_seconds: float
    parts: list[AudioPartView] = Field(min_length=1)

    @classmethod
    def of(cls, zone_id: str, found: AudioLookup, catalog: AudioCatalog) -> AudioguideAudioView:
        m = found.manifest
        return cls(
            zone_id=zone_id,
            language=m.language,
            content_language=m.content_language,
            content_version=found.current_version,
            audio_content_version=m.content_version,
            stale=found.stale,
            source=m.source,
            voice=m.voice,
            total_seconds=round(sum(p.duration_seconds for p in m.parts), 1),
            parts=[
                AudioPartView(
                    index=p.index, url=catalog.url(p.key), duration_seconds=p.duration_seconds, text=p.text
                )
                for p in m.parts
            ],
        )


async def _missing_audio(audio: AudioCatalog, key: str) -> JSONResponse:
    """Un archivo de audio que no está: 410 si lo borró el recolector, 404 si nunca existió.

    Con 410 Gone ("existió y ya no volverá") la app sabe que no debe
    reintentar, sino pedir el manifiesto actual, que va en el cuerpo y en la
    cabecera Link. Ninguna de las dos respuestas se guarda en la CDN
    (no-store): si mañana existiera, no queremos un error cacheado un año.
    """
    gone = await audio.gone(key)
    if gone is None:
        response = _problem(404, "No encontrado", "archivo de audio no encontrado")
    else:
        body: dict[str, Any] = {
            "type": "about:blank",
            "title": "Ya no existe",
            "status": 410,
            "detail": "esta versión del audio se retiró: pide el manifiesto actual",
        }
        if gone.current_manifest:
            body["current_manifest"] = gone.current_manifest
        response = JSONResponse(body, status_code=410, media_type="application/problem+json")
        if gone.current_manifest:
            response.headers["Link"] = f'<{gone.current_manifest}>; rel="latest-version"'
    response.headers["Cache-Control"] = "no-store"
    return response


# Un archivo de audio nunca cambia (su ruta lleva versión y huella): se puede
# guardar un año entero en la CDN y en el móvil sin volver a preguntar.
IMMUTABLE_CACHE = "public, max-age=31536000, immutable"

# Una ficha de ciudad cambia poco: el móvil y la CDN pueden guardarla un día.
PLACE_CACHE = "public, max-age=86400"
# Las fotos de calle: una hora (sus direcciones caducan a los pocos días).
STREET_CACHE = "public, max-age=3600"
# Los tipos de cambio cambian una vez al día: una hora en cachés intermedias.
FX_CACHE = "public, max-age=3600"
# Los cajeros casi nunca cambian: seis horas en el móvil y en la CDN.
ATM_CACHE = "public, max-age=21600"
# "Esta ciudad no tiene ficha" se recuerda menos (por si aparece).
PLACE_MISSING_CACHE = "public, max-age=3600"


def create_api(
    store: RecommendationStore,
    *,
    audioguides: AudioguideService | None = None,
    audio: AudioCatalog | None = None,
    negotiations: APIRouter | None = None,
    expenses: APIRouter | None = None,
    places: PlaceService | None = None,
    streetview: StreetViewService | None = None,
    flyra: FlyraService | None = None,
    landmarks: LandmarkService | None = None,
    fx: FxService | None = None,
    atms: AtmService | None = None,
    expose_docs: bool = False,
) -> FastAPI:
    """Crea la API pública (puerto con mTLS)."""
    app = FastAPI(
        title="NomadIQ ai-orchestrator",
        version="0.1.0",
        # La documentación interactiva describe toda la API: en producción
        # no se la regalamos a nadie.
        docs_url="/docs" if expose_docs else None,
        redoc_url=None,
        openapi_url="/openapi.json" if expose_docs else None,
    )

    # StarletteHTTPException es la "madre" de HTTPException: así también
    # cubrimos los 404/405 de rutas inexistentes con el mismo formato.
    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        titles = {
            401: "No autenticado",
            403: "Prohibido",
            404: "No encontrado",
            405: "Método no permitido",
            409: "Conflicto",
        }
        return _problem(exc.status_code, titles.get(exc.status_code, "Error"), str(exc.detail))

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = ", ".join(".".join(map(str, e["loc"])) for e in exc.errors()[:5])
        return _problem(400, "Petición inválida", f"revisa: {fields}")

    @app.exception_handler(StoreError)
    async def _store_error(_: Request, exc: StoreError) -> JSONResponse:
        log.error("base de datos no disponible", extra={"error": str(exc)})
        return _problem(503, "Servicio no disponible temporalmente")

    @app.exception_handler(CacheError)
    async def _cache_error(_: Request, exc: CacheError) -> JSONResponse:
        log.error("caché de audioguías no disponible", extra={"error": str(exc)})
        return _problem(503, "Servicio no disponible temporalmente")

    @app.exception_handler(Exception)
    async def _unexpected(_: Request, exc: Exception) -> JSONResponse:
        # El detalle va al log, nunca al cliente (podría revelar cosas internas).
        log.exception("error inesperado en la API")
        return _problem(500, "Error interno")

    @app.get("/v1/recommendations", response_model=RecommendationList)
    async def list_recommendations(
        principal: Annotated[Principal, Depends(current_principal)],
        limit: Annotated[int, Query(ge=1, le=50)] = 20,
    ) -> RecommendationList:
        recs = await store.list_for_user(principal.user_id, limit=limit)
        return RecommendationList(items=[RecommendationView.of(r) for r in recs])

    @app.get("/v1/recommendations/{alert_id}", response_model=RecommendationView)
    async def get_recommendation(
        principal: Annotated[Principal, Depends(current_principal)],
        alert_id: Annotated[uuid.UUID, Path()],
    ) -> RecommendationView:
        rec = await store.get_for_user(principal.user_id, str(alert_id))
        if rec is None:
            raise HTTPException(status_code=404, detail="recomendación no encontrada")
        return RecommendationView.of(rec)

    if audioguides is not None:

        @app.get("/v1/audioguides/{zone_id}", response_model=AudioguideScript)
        async def get_audioguide(
            _: Annotated[Principal, Depends(current_principal)],
            zone_id: Annotated[uuid.UUID, Path()],
            # Idioma ISO 639-1 ("es"). Vacío o desconocido = idioma por defecto.
            lang: Annotated[str, Query(pattern=r"^([A-Za-z]{2,3})?$")] = "",
        ) -> AudioguideScript:
            # Solo lee la caché: si el guion aún no está, 404 y la app
            # vuelve a preguntar en unos segundos (nunca esperamos al LLM aquí).
            script = await audioguides.get(str(zone_id), lang)
            if script is None:
                raise HTTPException(status_code=404, detail="la audioguía de esta zona aún no está lista")
            return script

    if audio is not None:

        @app.get("/v1/audioguides/{zone_id}/audio", response_model=AudioguideAudioView)
        async def get_audioguide_audio(
            _: Annotated[Principal, Depends(current_principal)],
            zone_id: Annotated[uuid.UUID, Path()],
            lang: Annotated[str, Query(pattern=r"^([A-Za-z]{2,3})?$")] = "",
        ) -> AudioguideAudioView:
            found = await audio.lookup(str(zone_id), lang)
            if found is None:
                # La app puede leer el guion de texto con la voz del teléfono.
                raise HTTPException(status_code=404, detail="el audio de esta zona aún no está grabado")
            return AudioguideAudioView.of(str(zone_id), found, audio)

        @app.get("/v1/audio/{key:path}", include_in_schema=False, response_model=None)
        async def get_audio_file(key: str) -> FileResponse | JSONResponse:
            # local_path valida la clave con un patrón estricto: nada de "../".
            path = audio.file(key)
            if path is None:
                return await _missing_audio(audio, key)
            # FileResponse admite peticiones por rangos (Range): el móvil puede
            # empezar a reproducir sin descargar el archivo entero.
            return FileResponse(
                path,
                media_type="audio/ogg",
                headers={"Cache-Control": IMMUTABLE_CACHE, "X-Content-Type-Options": "nosniff"},
            )

    if places is not None:

        @app.get("/v1/places/{iata}", response_model=PlaceCard)
        async def get_place(
            iata: Annotated[str, Path(pattern=r"^[A-Za-z]{3}$")],
            lang: Annotated[str, Query(pattern=r"^([A-Za-z]{2,3})?$")] = "",
        ) -> JSONResponse:
            try:
                card = await places.get(iata.upper(), lang)
            except (PlaceBusyError, PlaceUnavailableError):
                # La app simplemente no enseña la ficha y lo intenta otro día.
                resp = _problem(503, "Servicio no disponible temporalmente", "fichas de ciudad ocupadas")
                resp.headers["Retry-After"] = "60"
                return resp
            if card is None:
                resp = _problem(404, "No encontrado", "no hay ficha para esta ciudad")
                resp.headers["Cache-Control"] = PLACE_MISSING_CACHE
                return resp
            return JSONResponse(card.model_dump(mode="json"), headers={"Cache-Control": PLACE_CACHE})

    if streetview is not None:

        @app.get("/v1/streetview", response_model=StreetPhotos)
        async def get_streetview(
            lat: Annotated[float, Query(ge=-85, le=85)],
            lon: Annotated[float, Query(ge=-180, le=180)],
        ) -> JSONResponse:
            try:
                photos = await streetview.near(lat, lon)
            except (StreetBusyError, StreetUnavailableError):
                resp = _problem(503, "Servicio no disponible temporalmente", "fotos de calle ocupadas")
                resp.headers["Retry-After"] = "60"
                return resp
            # Sin fotos también es 200 (lista vacía): la app lo explica.
            return JSONResponse(photos.model_dump(mode="json"), headers={"Cache-Control": STREET_CACHE})

    if atms is not None:

        @app.get("/v1/atms", response_model=Atms)
        async def get_atms(
            lat: Annotated[float, Query(ge=-85, le=85)],
            lon: Annotated[float, Query(ge=-180, le=180)],
        ) -> JSONResponse:
            try:
                found = await atms.near(lat, lon)
            except (AtmBusyError, AtmUnavailableError):
                resp = _problem(503, "Servicio no disponible temporalmente", "cajeros ocupados")
                resp.headers["Retry-After"] = "60"
                return resp
            # Sin cajeros también es 200 (lista vacía): la app lo explica.
            return JSONResponse(found.model_dump(mode="json"), headers={"Cache-Control": ATM_CACHE})

    if fx is not None:

        @app.get("/v1/fx/rates", response_model=FxRates)
        async def get_fx_rates() -> JSONResponse:
            # Pública (también para invitados): son datos oficiales y gratuitos.
            try:
                rates = await fx.rates()
            except FxUnavailableError:
                resp = _problem(503, "Servicio no disponible temporalmente", "tipos de cambio no disponibles")
                resp.headers["Retry-After"] = "300"
                return resp
            return JSONResponse(rates.model_dump(mode="json"), headers={"Cache-Control": FX_CACHE})

    if flyra is not None:

        @app.post("/v1/flyra/chat", response_model=ChatReply)
        async def flyra_chat(
            principal: Annotated[Principal, Depends(current_principal)],
            body: ChatRequest,
        ) -> JSONResponse:
            # Solo con sesión iniciada: así cada persona tiene su cupo diario y
            # nadie puede gastar la máquina del modelo de forma anónima.
            try:
                reply = await flyra.answer(principal.user_id, body)
            except QuotaExceededError as exc:
                resp = _problem(429, "Demasiadas peticiones", "ya no quedan preguntas a Flyra por hoy")
                resp.headers["Retry-After"] = str(exc.retry_after)
                return resp
            except FlyraBusyError:
                resp = _problem(503, "Servicio no disponible temporalmente", "Flyra está ocupada")
                resp.headers["Retry-After"] = "30"
                return resp
            # Las respuestas son personales: que ningún proxy las guarde.
            return JSONResponse(reply.model_dump(mode="json"), headers={"Cache-Control": "no-store"})

    if landmarks is not None:

        @app.post("/v1/landmarks/recognize", response_model=Recognition)
        async def recognize_landmark(
            principal: Annotated[Principal, Depends(current_principal)],
            body: RecognizeRequest,
        ) -> JSONResponse:
            # Con sesión: cada cuenta tiene sus usos diarios del modo cámara.
            try:
                found = await landmarks.recognize(principal.user_id, body)
            except QuotaExceededError as exc:
                resp = _problem(429, "Demasiadas peticiones", "ya no quedan usos de la cámara por hoy")
                resp.headers["Retry-After"] = str(exc.retry_after)
                return resp
            except LandmarkBusyError:
                resp = _problem(503, "Servicio no disponible temporalmente", "monumentos ocupados")
                resp.headers["Retry-After"] = "30"
                return resp
            # Depende de dónde estás: que ningún proxy lo guarde.
            return JSONResponse(found.model_dump(mode="json"), headers={"Cache-Control": "no-store"})

        @app.get("/v1/landmarks/{qid}", response_model=Landmark)
        async def get_landmark(
            _: Annotated[Principal, Depends(current_principal)],
            qid: Annotated[str, Path(pattern=r"^Q[1-9][0-9]{0,11}$")],
            lang: Annotated[str, Query(pattern=r"^([A-Za-z]{2,3})?$")] = "",
        ) -> JSONResponse:
            try:
                card = await landmarks.landmark(qid, lang or "en")
            except LandmarkBusyError:
                resp = _problem(503, "Servicio no disponible temporalmente", "monumentos ocupados")
                resp.headers["Retry-After"] = "30"
                return resp
            if card is None:
                return _problem(404, "No encontrado", "no hay ficha para este lugar")
            return JSONResponse(
                card.model_dump(mode="json"), headers={"Cache-Control": "private, max-age=86400"}
            )

    if expenses is not None:
        # Las rutas /v1/expense-groups viven en expenses/api.py.
        app.include_router(expenses)

    if negotiations is not None:
        # Las rutas /v1/group-negotiations viven en negotiation/api.py.
        app.include_router(negotiations)

    return app


def create_management_api(readiness: Callable[[], Awaitable[dict[str, bool]]]) -> FastAPI:
    """API de salud (puerto interno sin mTLS, solo para Docker/Kubernetes)."""
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        # "¿Está vivo el proceso?" Si no responde, hay que reiniciarlo.
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz() -> JSONResponse:
        # "¿Puede trabajar?" Si no, no se le envía tráfico (pero no se reinicia).
        checks = await readiness()
        ok = all(checks.values())
        return JSONResponse(
            {"status": "ok" if ok else "unavailable", "checks": checks}, status_code=200 if ok else 503
        )

    return app
