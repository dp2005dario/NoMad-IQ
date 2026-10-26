"""API HTTP de las quedadas (se monta dentro de api.create_api).

    GET    /v1/meetups?city=LIS           las quedadas de una ciudad
    GET    /v1/meetups/mine               a las que voy (y las que propuse)
    POST   /v1/meetups                    proponer una (te apuntas tú solo)
    POST   /v1/meetups/{id}/join          apuntarme
    DELETE /v1/meetups/{id}/join          ya no voy
    DELETE /v1/meetups/{id}               cancelarla (solo quien la propuso)
    POST   /v1/meetups/{id}/report        denunciarla (3 personas = se oculta)

Privacidad: nunca se devuelve un user_id. De cada persona apuntada solo
sale su nombre (si lo dejó visible; si no, null y la app pone "Alguien")
y su país. La ciudad va por código de aeropuerto: el servidor nunca sabe
dónde estás.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query
from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.meetups.domain import (
    MAX_AHEAD,
    Meetup,
    MeetupFullError,
    MeetupKind,
    MeetupLimitError,
    MeetupNotFoundError,
    Member,
)
from ai_orchestrator.meetups.store import MeetupStore
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.places.airports import Airports

PREFIX = "/v1/meetups"


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


def _aware(value: datetime) -> datetime:
    # Sin zona horaria no se sabe a qué hora es de verdad: mejor rechazarla.
    if value.tzinfo is None:
        raise ValueError("la hora necesita zona horaria")
    return value.astimezone(UTC)


MeetupId = Annotated[uuid.UUID, Path()]
Text80 = Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]


class Me(BaseModel):
    """Cómo te ven los demás en esta quedada (lo eliges cada vez)."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    name: Annotated[str, Field(min_length=1, max_length=40), AfterValidator(_clean)]
    country: str | None = Field(default=None, pattern=r"^[A-Z]{2}$")
    visible: bool = True


class NewMeetupBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    city: str = Field(pattern=r"^[A-Z]{3}$")
    kind: MeetupKind
    title: Text80
    # Un sitio público ("Plaza del Comercio, junto a la estatua").
    place: Text80
    starts_at: Annotated[datetime, AfterValidator(_aware)]
    capacity: int = Field(ge=2, le=12)
    me: Me


class JoinBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    me: Me


class PersonView(BaseModel):
    # None = prefirió no enseñar su nombre.
    name: str | None
    country: str | None
    organizer: bool


class MeetupView(BaseModel):
    meetup_id: str
    city: str
    kind: MeetupKind
    title: str
    place: str
    starts_at: datetime
    capacity: int
    going: int
    people: list[PersonView]
    joined: bool
    mine: bool

    @classmethod
    def of(cls, m: Meetup, user_id: str) -> MeetupView:
        return cls(
            meetup_id=m.meetup_id,
            city=m.city,
            kind=m.kind,
            title=m.title,
            place=m.place,
            starts_at=m.starts_at,
            capacity=m.capacity,
            going=len(m.members),
            people=[
                PersonView(
                    name=p.name if p.visible else None,
                    country=p.country,
                    organizer=p.user_id == m.creator_id,
                )
                for p in m.members
            ],
            joined=m.member(user_id) is not None,
            mine=m.creator_id == user_id,
        )


class MeetupList(BaseModel):
    meetups: list[MeetupView]


def _member(user_id: str, me: Me) -> Member:
    return Member(user_id=user_id, name=me.name, country=me.country, visible=me.visible)


def meetup_router(
    store: MeetupStore,
    airports: Airports,
    *,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    def known_city(city: str) -> str:
        # Solo ciudades con aeropuerto: así nadie llena la tabla de "ciudades"
        # inventadas ni usa el campo para mandar texto libre.
        if airports.get(city) is None:
            raise HTTPException(status_code=404, detail="ciudad desconocida")
        return city

    @router.get("", response_model=MeetupList)
    async def city_list(
        principal: Annotated[Principal, Depends(current_principal)],
        city: Annotated[str, Query(pattern=r"^[A-Z]{3}$")],
    ) -> MeetupList:
        found = await store.list_city(known_city(city), clock())
        return MeetupList(meetups=[MeetupView.of(m, principal.user_id) for m in found])

    @router.get("/mine", response_model=MeetupList)
    async def mine(principal: Annotated[Principal, Depends(current_principal)]) -> MeetupList:
        found = await store.mine(principal.user_id, clock())
        return MeetupList(meetups=[MeetupView.of(m, principal.user_id) for m in found])

    @router.post("", status_code=201, response_model=MeetupView)
    async def create(
        principal: Annotated[Principal, Depends(current_principal)], body: NewMeetupBody
    ) -> MeetupView:
        now = clock()
        known_city(body.city)
        if not now < body.starts_at <= now + MAX_AHEAD:
            raise HTTPException(status_code=400, detail="la hora tiene que ser en los próximos 30 días")
        # Aprovechamos para barrer las viejas (un DELETE con índice: barato).
        await store.sweep(now)
        try:
            created = await store.create(principal.user_id, _member(principal.user_id, body.me), body, now)
        except MeetupLimitError as exc:
            raise HTTPException(status_code=409, detail="demasiadas quedadas a la vez") from exc
        return MeetupView.of(created, principal.user_id)

    @router.post("/{meetup_id}/join", response_model=MeetupView)
    async def join(
        principal: Annotated[Principal, Depends(current_principal)], meetup_id: MeetupId, body: JoinBody
    ) -> MeetupView:
        try:
            joined = await store.join(str(meetup_id), _member(principal.user_id, body.me), clock())
        except MeetupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="quedada no encontrada") from exc
        except MeetupFullError as exc:
            raise HTTPException(status_code=409, detail="ya está completa") from exc
        except MeetupLimitError as exc:
            raise HTTPException(status_code=409, detail="demasiadas quedadas a la vez") from exc
        return MeetupView.of(joined, principal.user_id)

    @router.delete("/{meetup_id}/join", response_model=MeetupView)
    async def leave(
        principal: Annotated[Principal, Depends(current_principal)], meetup_id: MeetupId
    ) -> MeetupView:
        try:
            left = await store.leave(str(meetup_id), principal.user_id, clock())
        except MeetupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="quedada no encontrada") from exc
        return MeetupView.of(left, principal.user_id)

    @router.delete("/{meetup_id}", status_code=204)
    async def cancel(
        principal: Annotated[Principal, Depends(current_principal)], meetup_id: MeetupId
    ) -> None:
        try:
            await store.cancel(str(meetup_id), principal.user_id)
        except MeetupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="quedada no encontrada") from exc

    @router.post("/{meetup_id}/report", status_code=204)
    async def report(
        principal: Annotated[Principal, Depends(current_principal)], meetup_id: MeetupId
    ) -> None:
        # Siempre 204 (aunque no exista): no sirve para adivinar ids.
        await store.report(str(meetup_id), principal.user_id)

    return router
