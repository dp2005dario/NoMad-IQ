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
"""

from __future__ import annotations

import logging
import re
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict
from starlette.exceptions import HTTPException as StarletteHTTPException

from ai_orchestrator.domain import Recommendation, Verdict
from ai_orchestrator.store import RecommendationStore, StoreError

log = logging.getLogger(__name__)

HEADER_USER_ID = "X-User-ID"
HEADER_USER_ROLES = "X-User-Roles"
# Rol mínimo para usar la API (el auth-gateway emite USER y ADMIN).
REQUIRED_ROLE = "USER"

_USER_ID = re.compile(r"^[A-Za-z0-9._:@-]{1,128}$")
_ROLE = re.compile(r"^[A-Z_]{1,32}$")


@dataclass(frozen=True, slots=True)
class Principal:
    """Quién hace la petición (ya autenticado por el auth-gateway)."""

    user_id: str
    roles: frozenset[str]


def _problem(status: int, title: str, detail: str | None = None) -> JSONResponse:
    body: dict[str, Any] = {"type": "about:blank", "title": title, "status": status}
    if detail:
        body["detail"] = detail
    return JSONResponse(body, status_code=status, media_type="application/problem+json")


async def current_principal(
    user_id: Annotated[str | None, Header(alias=HEADER_USER_ID)] = None,
    roles: Annotated[str | None, Header(alias=HEADER_USER_ROLES)] = None,
) -> Principal:
    """Lee la identidad de las cabeceras y la valida con reglas estrictas."""
    if user_id is None or not _USER_ID.fullmatch(user_id):
        raise HTTPException(status_code=401, detail="identidad ausente o inválida")
    parsed = frozenset(r.strip() for r in (roles or "").split(",") if r.strip())
    if any(not _ROLE.fullmatch(r) for r in parsed):
        raise HTTPException(status_code=401, detail="roles inválidos")
    # Control de acceso por roles (RBAC): sin el rol USER, no hay acceso.
    if REQUIRED_ROLE not in parsed:
        raise HTTPException(status_code=403, detail="se necesita el rol USER")
    return Principal(user_id=user_id, roles=parsed)


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


def create_api(store: RecommendationStore, *, expose_docs: bool = False) -> FastAPI:
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
        titles = {401: "No autenticado", 403: "Prohibido", 404: "No encontrado", 405: "Método no permitido"}
        return _problem(exc.status_code, titles.get(exc.status_code, "Error"), str(exc.detail))

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = ", ".join(".".join(map(str, e["loc"])) for e in exc.errors()[:5])
        return _problem(400, "Petición inválida", f"revisa: {fields}")

    @app.exception_handler(StoreError)
    async def _store_error(_: Request, exc: StoreError) -> JSONResponse:
        log.error("base de datos no disponible", extra={"error": str(exc)})
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
