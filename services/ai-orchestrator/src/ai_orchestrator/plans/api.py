"""API HTTP de "Elegid planes" (se monta dentro de api.create_api).

    GET    /v1/group-negotiations/{id}/plans                 los planes y cómo van
    POST   /v1/group-negotiations/{id}/plans                 añadir planes (1-10 de golpe)
    PUT    /v1/group-negotiations/{id}/plans/{plan}/vote     votar sí o no

Además de los planes de siempre ("plan"), el mismo tablero guarda los
sitios de "¿Qué os apetece?" ("crave": Me apetece = sí, Paso = no) y las
zonas de "Votad dónde dormir" ("sleep"). Cada uno lleva su "kind".
    DELETE /v1/group-negotiations/{id}/plans/{plan}          quitar un plan (solo quien lo puso)

Todas devuelven el tablero entero, ya con tu voto: la app no tiene que
hacer otra llamada para pintar la siguiente tarjeta.

Privacidad: de cada plan solo se dice cuántos sí hay y cuántos han votado,
nunca quién. A quien no es del viaje se le responde 404.
"""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.plans.domain import (
    ARTICLE_RE,
    PHOTO_RE,
    Board,
    NotMatchError,
    PlanLimitError,
    has_voted,
    is_match,
    match_with,
)
from ai_orchestrator.plans.store import PlanNotFoundError, PlanStore, TripNotFoundError

PREFIX = "/v1/group-negotiations/{negotiation_id}/plans"


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


def _photo(value: str | None) -> str | None:
    if value is not None and not PHOTO_RE.fullmatch(value):
        raise ValueError("la foto tiene que ser de upload.wikimedia.org")
    return value


def _article(value: str | None) -> str | None:
    if value is not None and not ARTICLE_RE.fullmatch(value):
        raise ValueError("el artículo tiene que ser de wikipedia.org")
    return value


TripId = Annotated[uuid.UUID, Path()]
PlanId = Annotated[uuid.UUID, Path()]


class NewPlanBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    title: Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]
    note: Annotated[str, Field(min_length=1, max_length=140), AfterValidator(_clean)] | None = None
    wikidata_id: str | None = Field(default=None, pattern=r"^Q[1-9][0-9]{0,11}$")
    photo_url: Annotated[str | None, Field(default=None, max_length=500), AfterValidator(_photo)] = None
    article_url: Annotated[str | None, Field(default=None, max_length=500), AfterValidator(_article)] = None
    # "plan" de siempre; "crave" = sitio de "¿Qué os apetece?"; "sleep" =
    # zona para dormir. Los dos últimos no se repiten (por nombre).
    kind: Literal["plan", "crave", "sleep"] = "plan"


class AddPlans(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    plans: list[NewPlanBody] = Field(min_length=1, max_length=10)


class Vote(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    yes: bool


class PlanView(BaseModel):
    plan_id: str
    title: str
    note: str | None
    wikidata_id: str | None
    photo_url: str | None
    article_url: str | None
    mine: bool
    # None = aún no has votado este plan.
    my_vote: bool | None
    yes: int
    voted: int
    match: bool
    # Con quién coincides (solo si tú dijiste sí y hay match; si no, vacío).
    match_with: list[str]
    # Ya está en el plan del grupo.
    planned: bool
    kind: str = "plan"


class PersonView(BaseModel):
    """Una persona del viaje, para las caras de arriba ("ya votó")."""

    name: str
    me: bool
    voted: bool


class BoardView(BaseModel):
    negotiation_id: str
    members: int
    people: list[PersonView]
    plans: list[PlanView]

    @classmethod
    def of(cls, board: Board) -> BoardView:
        active = board.active_seats
        return cls(
            negotiation_id=board.negotiation_id,
            members=len(active),
            people=[
                PersonView(
                    name=board.names.get(seat, f"Viajero {seat}"),
                    me=seat == board.my_seat,
                    voted=has_voted(seat, board),
                )
                for seat in sorted(active)
            ],
            plans=[
                PlanView(
                    plan_id=p.plan_id,
                    title=p.title,
                    note=p.note,
                    wikidata_id=p.wikidata_id,
                    photo_url=p.photo_url,
                    article_url=p.article_url,
                    mine=p.added_by_seat == board.my_seat,
                    my_vote=p.votes.get(board.my_seat),
                    # Solo cuentan los asientos activos (no los de cuentas borradas).
                    yes=sum(1 for s, v in p.votes.items() if v and s in active),
                    voted=sum(1 for s in p.votes if s in active),
                    match=is_match(p, active),
                    match_with=match_with(p, board),
                    planned=p.planned,
                    kind=p.kind,
                )
                for p in board.plans
            ],
        )


def plan_router(store: PlanStore) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    @router.get("", response_model=BoardView)
    async def board(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId
    ) -> BoardView:
        try:
            return BoardView.of(await store.board(str(negotiation_id), principal.user_id))
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc

    @router.post("", status_code=201, response_model=BoardView)
    async def add(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, body: AddPlans
    ) -> BoardView:
        try:
            return BoardView.of(await store.add(str(negotiation_id), principal.user_id, list(body.plans)))
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc
        except PlanLimitError as exc:
            raise HTTPException(status_code=409, detail="demasiados planes en este viaje") from exc

    @router.put("/{plan_id}/vote", response_model=BoardView)
    async def vote(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        plan_id: PlanId,
        body: Vote,
    ) -> BoardView:
        try:
            board = await store.vote(str(negotiation_id), principal.user_id, str(plan_id), yes=body.yes)
        except (TripNotFoundError, PlanNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="plan no encontrado") from exc
        return BoardView.of(board)

    @router.put("/{plan_id}/planned", response_model=BoardView)
    async def planned(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        plan_id: PlanId,
    ) -> BoardView:
        """ "Añadir al plan": mete un match en el plan del grupo."""
        try:
            board = await store.plan(str(negotiation_id), principal.user_id, str(plan_id))
        except (TripNotFoundError, PlanNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="plan no encontrado") from exc
        except NotMatchError as exc:
            raise HTTPException(
                status_code=409, detail="solo se añade un match en el que dijiste sí"
            ) from exc
        return BoardView.of(board)

    @router.delete("/{plan_id}", response_model=BoardView)
    async def delete(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        plan_id: PlanId,
    ) -> BoardView:
        try:
            board = await store.delete(str(negotiation_id), principal.user_id, str(plan_id))
        except (TripNotFoundError, PlanNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="plan no encontrado") from exc
        return BoardView.of(board)

    return router
