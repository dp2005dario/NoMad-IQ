"""API HTTP de "Sin colas" (se monta dentro de api.create_api).

    GET  /v1/queues/{place}?hour=H   la cola ahora y por horas
    POST /v1/queues/{place}          avisar de cuánta cola hay ahora

{place} es el Wikidata del sitio (Q...). Todo con sesión iniciada (así cada
aviso es de una persona distinta) y nunca se devuelve quién avisó. La hora
la manda el móvil: es la del reloj del sitio, que el servidor no conoce.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query
from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.queues.domain import MAX_WAIT, PlaceQueue, QueueLimitError
from ai_orchestrator.queues.store import QueueStore

PREFIX = "/v1/queues"
Place = Annotated[str, Path(pattern=r"^Q[1-9][0-9]{0,11}$")]


class ReportBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    wait: int = Field(ge=0, le=MAX_WAIT)
    local_hour: int = Field(ge=0, le=23)


def queues_router(store: QueueStore) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    @router.get("/{place}", response_model=PlaceQueue)
    async def place_queue(
        principal: Annotated[Principal, Depends(current_principal)],
        place: Place,
        hour: Annotated[int, Query(ge=0, le=23)],
    ) -> PlaceQueue:
        return await store.place(place, principal.user_id, hour)

    @router.post("/{place}", status_code=204)
    async def report(
        principal: Annotated[Principal, Depends(current_principal)], place: Place, body: ReportBody
    ) -> None:
        try:
            await store.report(place, principal.user_id, body.local_hour, body.wait)
        except QueueLimitError as exc:
            raise HTTPException(status_code=429, detail="demasiados avisos hoy") from exc

    return router
