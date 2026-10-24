"""API HTTP de "Cromos con amigos" (se monta dentro de api.create_api).

    POST   /v1/leagues                              crear una liga (te da el código)
    POST   /v1/leagues/join                         entrar con el código de un amigo
    GET    /v1/leagues                              mis ligas
    GET    /v1/leagues/{id}                         clasificación, mis cambios y mis copias
    GET    /v1/leagues/{id}/members/{seat}/cards    los cromos de un amigo (para elegir qué pedirle)
    PUT    /v1/leagues/{id}/me                      subir mis cromos (los del Pasaporte)
    PUT    /v1/leagues/{id}/me/city                 en qué ciudad estoy (o null para dejar de decirlo)
    POST   /v1/leagues/{id}/swaps                   proponer un cambio
    POST   /v1/leagues/{id}/swaps/{swap}/accept     aceptarlo (solo quien lo recibe)
    POST   /v1/leagues/{id}/swaps/{swap}/decline    rechazarlo
    DELETE /v1/leagues/{id}/me                      salir de la liga

Privacidad: nunca se devuelve el user_id de nadie; cada uno es un asiento con
el nombre que eligió. A quien no es de la liga se le responde 404.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.leagues.domain import (
    MAX_CARDS,
    MAX_MEMBERS,
    Card,
    League,
    Swap,
    SwapNotAllowedError,
    SwapStatus,
    points,
    rarity_of,
    received,
)
from ai_orchestrator.leagues.store import (
    LeagueFullError,
    LeagueNotFoundError,
    LeagueStore,
    SwapNotFoundError,
    TooManyPendingError,
)
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.negotiation.store import normalize_invite_code

PREFIX = "/v1/leagues"


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


Name = Annotated[str, Field(min_length=1, max_length=40), AfterValidator(_clean)]
LeagueId = Annotated[uuid.UUID, Path()]
SwapId = Annotated[uuid.UUID, Path()]


class CreateLeague(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    title: Name
    my_name: Name


class JoinLeague(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    code: str = Field(min_length=1, max_length=20)
    my_name: Name


class MyCards(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    cards: list[Card] = Field(max_length=MAX_CARDS)
    countries: int = Field(default=0, ge=0, le=250)


class MyCity(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    # null = dejar de compartir dónde estoy.
    city: Annotated[str, Field(min_length=1, max_length=60), AfterValidator(_clean)] | None


class ProposeSwap(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    to_seat: int = Field(ge=1, le=MAX_MEMBERS)
    give_qid: str = Field(pattern=r"^Q[1-9][0-9]{0,11}$")
    want_qid: str = Field(pattern=r"^Q[1-9][0-9]{0,11}$")


class Standing(BaseModel):
    seat: int
    name: str
    me: bool
    points_month: int
    points_total: int
    cards: int
    legendary: int
    countries: int
    city: str | None
    city_at: datetime | None


class SwapView(BaseModel):
    swap_id: str
    from_seat: int
    to_seat: int
    give: Card
    want: Card
    status: SwapStatus
    created_at: datetime

    @classmethod
    def of(cls, s: Swap) -> SwapView:
        return cls(
            swap_id=s.swap_id,
            from_seat=s.from_seat,
            to_seat=s.to_seat,
            give=s.give,
            want=s.want,
            status=s.status,
            created_at=s.created_at,
        )


class LeagueView(BaseModel):
    league_id: str
    title: str
    invite_code: str
    # La liga del mes ("2026-10"): los puntos de este mes deciden la clasificación.
    month: str
    my_seat: int
    standings: list[Standing]
    # Los cambios en los que estás tú (los de los demás no son cosa tuya).
    swaps: list[SwapView]
    # Las copias que has recibido en cambios aceptados.
    received: list[Card]

    @classmethod
    def of(cls, league: League, user_id: str, month: str) -> LeagueView:
        me = league.member(user_id)
        assert me is not None  # noqa: S101
        rows = [
            Standing(
                seat=m.seat,
                name=m.name,
                me=m.seat == me.seat,
                points_month=points(m.cards, month),
                points_total=points(m.cards),
                cards=len(m.cards),
                legendary=sum(1 for c in m.cards if rarity_of(c.year) == "legendary"),
                countries=m.countries,
                city=m.city,
                city_at=m.city_at,
            )
            for m in league.members
        ]
        rows.sort(key=lambda r: (-r.points_month, -r.points_total, r.seat))
        return cls(
            league_id=league.league_id,
            title=league.title,
            invite_code=league.invite_code,
            month=month,
            my_seat=me.seat,
            standings=rows,
            swaps=[SwapView.of(s) for s in league.swaps if me.seat in (s.from_seat, s.to_seat)],
            received=received(league, me.seat),
        )


class LeagueSummary(BaseModel):
    league_id: str
    title: str
    members: int
    my_position: int


class LeagueList(BaseModel):
    items: list[LeagueSummary]


class CardList(BaseModel):
    seat: int
    name: str
    cards: list[Card]


def league_router(
    store: LeagueStore, *, clock: Callable[[], datetime] = lambda: datetime.now(UTC)
) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    def month() -> str:
        return clock().strftime("%Y-%m")

    async def _league(league_id: uuid.UUID, user_id: str) -> League:
        league = await store.get_for_member(str(league_id), user_id)
        if league is None:
            raise HTTPException(status_code=404, detail="liga no encontrada")
        return league

    @router.post("", status_code=201, response_model=LeagueView)
    async def create(
        principal: Annotated[Principal, Depends(current_principal)], body: CreateLeague
    ) -> LeagueView:
        league = await store.create(principal.user_id, body.my_name, body.title)
        return LeagueView.of(league, principal.user_id, month())

    @router.post("/join", response_model=LeagueView)
    async def join(
        principal: Annotated[Principal, Depends(current_principal)], body: JoinLeague
    ) -> LeagueView:
        code = normalize_invite_code(body.code)
        if code is None:
            raise HTTPException(status_code=404, detail="código no encontrado")
        try:
            league = await store.join(code, principal.user_id, body.my_name)
        except LeagueNotFoundError as exc:
            raise HTTPException(status_code=404, detail="código no encontrado") from exc
        except LeagueFullError as exc:
            raise HTTPException(status_code=409, detail="la liga está llena (30 personas)") from exc
        return LeagueView.of(league, principal.user_id, month())

    @router.get("", response_model=LeagueList)
    async def mine(principal: Annotated[Principal, Depends(current_principal)]) -> LeagueList:
        out: list[LeagueSummary] = []
        for league in await store.list_for_member(principal.user_id):
            view = LeagueView.of(league, principal.user_id, month())
            pos = next(i for i, s in enumerate(view.standings, start=1) if s.me)
            out.append(
                LeagueSummary(
                    league_id=league.league_id,
                    title=league.title,
                    members=len(league.members),
                    my_position=pos,
                )
            )
        return LeagueList(items=out)

    @router.get("/{league_id}", response_model=LeagueView)
    async def get(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId
    ) -> LeagueView:
        return LeagueView.of(await _league(league_id, principal.user_id), principal.user_id, month())

    @router.get("/{league_id}/members/{seat}/cards", response_model=CardList)
    async def cards_of(
        principal: Annotated[Principal, Depends(current_principal)],
        league_id: LeagueId,
        seat: Annotated[int, Path(ge=1, le=MAX_MEMBERS)],
    ) -> CardList:
        league = await _league(league_id, principal.user_id)
        member = league.seat(seat)
        if member is None:
            raise HTTPException(status_code=404, detail="no está en la liga")
        return CardList(seat=member.seat, name=member.name, cards=list(member.cards))

    @router.put("/{league_id}/me", status_code=204)
    async def update_me(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId, body: MyCards
    ) -> Response:
        # Un cromo repetido (mismo monumento) cuenta una vez.
        unique = list({c.qid: c for c in body.cards}.values())
        try:
            await store.update_me(str(league_id), principal.user_id, unique, body.countries)
        except LeagueNotFoundError as exc:
            raise HTTPException(status_code=404, detail="liga no encontrada") from exc
        return Response(status_code=204)

    @router.put("/{league_id}/me/city", status_code=204)
    async def set_city(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId, body: MyCity
    ) -> Response:
        try:
            await store.set_city(str(league_id), principal.user_id, body.city)
        except LeagueNotFoundError as exc:
            raise HTTPException(status_code=404, detail="liga no encontrada") from exc
        return Response(status_code=204)

    @router.post("/{league_id}/swaps", status_code=201, response_model=SwapView)
    async def propose(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId, body: ProposeSwap
    ) -> SwapView:
        try:
            swap = await store.propose(
                str(league_id), principal.user_id, body.to_seat, body.give_qid, body.want_qid
            )
        except LeagueNotFoundError as exc:
            raise HTTPException(status_code=404, detail="liga no encontrada") from exc
        except SwapNotAllowedError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except TooManyPendingError as exc:
            raise HTTPException(status_code=429, detail="demasiados cambios pendientes") from exc
        return SwapView.of(swap)

    async def _decide(user_id: str, league_id: uuid.UUID, swap_id: uuid.UUID, *, accept: bool) -> SwapView:
        try:
            swap = await store.decide(str(league_id), user_id, str(swap_id), accept=accept)
        except (LeagueNotFoundError, SwapNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="cambio no encontrado") from exc
        except SwapNotAllowedError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        return SwapView.of(swap)

    @router.post("/{league_id}/swaps/{swap_id}/accept", response_model=SwapView)
    async def accept(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId, swap_id: SwapId
    ) -> SwapView:
        return await _decide(principal.user_id, league_id, swap_id, accept=True)

    @router.post("/{league_id}/swaps/{swap_id}/decline", response_model=SwapView)
    async def decline(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId, swap_id: SwapId
    ) -> SwapView:
        return await _decide(principal.user_id, league_id, swap_id, accept=False)

    @router.delete("/{league_id}/me", status_code=204)
    async def leave(
        principal: Annotated[Principal, Depends(current_principal)], league_id: LeagueId
    ) -> Response:
        try:
            await store.leave(str(league_id), principal.user_id)
        except LeagueNotFoundError as exc:
            raise HTTPException(status_code=404, detail="liga no encontrada") from exc
        return Response(status_code=204)

    return router
