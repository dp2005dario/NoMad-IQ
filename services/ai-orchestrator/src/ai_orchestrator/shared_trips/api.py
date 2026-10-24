"""API HTTP de "Copia este viaje" (se monta dentro de api.create_api).

    POST   /v1/shared-trips                 compartir un viaje (te da el código)
    GET    /v1/shared-trips/mine            los que has compartido tú
    GET    /v1/shared-trips/{code}          ver un viaje con su código
    POST   /v1/shared-trips/{code}/copy     "Copiar a mis viajes" (cuenta una vez por persona)
    POST   /v1/shared-trips/{code}/adapt    Flyra lo adapta a tu presupuesto
    DELETE /v1/shared-trips/{code}          dejar de compartirlo (solo quien lo compartió)

Todo con sesión: así cada cuenta tiene su cupo y nadie puede recorrer los
códigos sin identificarse (además del límite de peticiones del edge).
Nunca se devuelve el user_id de nadie: solo el nombre que eligió.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from fastapi.responses import JSONResponse

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.negotiation.store import normalize_invite_code
from ai_orchestrator.quota import QuotaExceededError
from ai_orchestrator.shared_trips.domain import AdaptReply, AdaptRequest, MySharedTrips, SharedTrip, ShareTrip
from ai_orchestrator.shared_trips.service import AdaptBusyError, TripAdapter
from ai_orchestrator.shared_trips.store import SharedTripStore, TooManySharedError, TripRecord

PREFIX = "/v1/shared-trips"

Code = Annotated[str, Path(min_length=1, max_length=20)]


def view(record: TripRecord, user_id: str) -> SharedTrip:
    return SharedTrip(
        code=record.code,
        author=record.author,
        title=record.title,
        destination=record.destination,
        days=record.days,
        currency=record.currency,
        items=list(record.items),
        total_minor=sum(i.price_minor for i in record.items),
        copies=record.copies,
        mine=record.owner_id == user_id,
        created_at=record.created_at,
    )


def _busy(detail: str, status: int, retry_after: int) -> JSONResponse:
    return JSONResponse(
        {"type": "about:blank", "title": "No disponible", "status": status, "detail": detail},
        status_code=status,
        media_type="application/problem+json",
        headers={"Retry-After": str(retry_after)},
    )


def shared_trip_router(store: SharedTripStore, adapter: TripAdapter | None = None) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    def _code(raw: str) -> str:
        code = normalize_invite_code(raw)
        if code is None:
            raise HTTPException(status_code=404, detail="viaje no encontrado")
        return code

    async def _trip(raw: str) -> TripRecord:
        record = await store.get(_code(raw))
        if record is None:
            raise HTTPException(status_code=404, detail="viaje no encontrado")
        return record

    @router.post("", status_code=201, response_model=SharedTrip)
    async def share(
        principal: Annotated[Principal, Depends(current_principal)], body: ShareTrip
    ) -> SharedTrip:
        try:
            record = await store.share(principal.user_id, body)
        except TooManySharedError as exc:
            raise HTTPException(status_code=409, detail="ya tienes 20 viajes compartidos") from exc
        return view(record, principal.user_id)

    @router.get("/mine", response_model=MySharedTrips)
    async def mine(principal: Annotated[Principal, Depends(current_principal)]) -> MySharedTrips:
        return MySharedTrips(items=[view(r, principal.user_id) for r in await store.mine(principal.user_id)])

    @router.get("/{code}", response_model=SharedTrip)
    async def get_trip(principal: Annotated[Principal, Depends(current_principal)], code: Code) -> SharedTrip:
        return view(await _trip(code), principal.user_id)

    @router.post("/{code}/copy", response_model=SharedTrip)
    async def copy_trip(
        principal: Annotated[Principal, Depends(current_principal)], code: Code
    ) -> SharedTrip:
        record = await store.copy(_code(code), principal.user_id)
        if record is None:
            raise HTTPException(status_code=404, detail="viaje no encontrado")
        return view(record, principal.user_id)

    if adapter is not None:

        @router.post("/{code}/adapt", response_model=AdaptReply)
        async def adapt_trip(
            principal: Annotated[Principal, Depends(current_principal)], code: Code, body: AdaptRequest
        ) -> JSONResponse:
            record = await _trip(code)
            try:
                reply = await adapter.adapt(principal.user_id, record, body.budget_minor, body.language)
            except QuotaExceededError as exc:
                return _busy("ya no quedan adaptaciones por hoy", 429, exc.retry_after)
            except AdaptBusyError:
                return _busy("Flyra está ocupada", 503, 30)
            return JSONResponse(reply.model_dump(mode="json"), headers={"Cache-Control": "no-store"})

    @router.delete("/{code}", status_code=204)
    async def unshare(principal: Annotated[Principal, Depends(current_principal)], code: Code) -> Response:
        if not await store.unshare(_code(code), principal.user_id):
            raise HTTPException(status_code=404, detail="viaje no encontrado")
        return Response(status_code=204)

    return router
