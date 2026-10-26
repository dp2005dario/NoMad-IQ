"""API HTTP del chat del viaje (se monta dentro de api.create_api).

    GET  /v1/group-negotiations/{id}/chat?after=N   lo nuevo (sin after: los últimos 50)
    POST /v1/group-negotiations/{id}/chat           escribir (con "@Flyra..." contesta Flyra)
    PUT  /v1/group-negotiations/{id}/chat/kind      tipo de viaje (amigos, pareja, familia)
    PUT  /v1/group-negotiations/{id}/chat/me        tu nombre en el chat ("Mamá")

¿Por qué la app pregunta cada pocos segundos en vez de una conexión abierta
(WebSocket)? Porque una conexión abierta por persona son miles de conexiones
vivas en un servidor gratuito. Preguntar "¿hay algo después del 1234?" es una
consulta de un milisegundo por índice, y la app solo pregunta mientras el
chat está en pantalla. Con la app cerrada, avisa la notificación push.

A quien no es del viaje se le responde 404 (no sabe ni que existe).
"""

from __future__ import annotations

import logging
import re
import unicodedata
import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query
from fastapi.responses import JSONResponse
from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.flyra.domain import MAX_TOTAL_CHARS, ChatRequest, ChatTurn
from ai_orchestrator.flyra.service import FlyraBusyError, FlyraService, QuotaExceededError
from ai_orchestrator.group_chat.domain import (
    FLYRA_CONTEXT,
    KIND_HINTS,
    MAX_TEXT,
    PAGE,
    ChatLimitError,
    ChatPage,
    Message,
    TripKind,
    asks_flyra,
)
from ai_orchestrator.group_chat.store import ChatStore, TripNotFoundError
from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.negotiation.domain import clean_text

log = logging.getLogger(__name__)

PREFIX = "/v1/group-negotiations/{negotiation_id}/chat"
FLYRA_NAME = "Flyra"

# Avisar a los demás de que hay mensajes nuevos: (viaje, user_ids) → nada.
# Lo pone __main__ (push por Kafka); en los tests, uno de mentira o ninguno.
ChatPush = Callable[[str, list[str]], Awaitable[None]]


def _clean_message(value: str) -> str:
    """Fuera caracteres de control, pero los saltos de línea se quedan (es un chat)."""
    kept = "".join(c if c == "\n" or not unicodedata.category(c).startswith("C") else " " for c in value)
    lines = [" ".join(line.split()) for line in kept.split("\n")]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    if not text:
        raise ValueError("mensaje vacío")
    return text


def _clean_name(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("nombre vacío")
    return cleaned


TripId = Annotated[uuid.UUID, Path()]


class NewMessage(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    text: Annotated[str, Field(min_length=1, max_length=MAX_TEXT), AfterValidator(_clean_message)]
    # Idioma de la app: si es para Flyra, contesta en él.
    language: str = Field(default="en", pattern=r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")


class KindBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: TripKind


class NameBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    # null = volver al alias ("Viajero 2").
    name: Annotated[str, Field(min_length=1, max_length=30), AfterValidator(_clean_name)] | None


class MemberView(BaseModel):
    seat: int
    name: str
    me: bool
    active: bool


class MessageView(BaseModel):
    id: int
    # null = Flyra.
    seat: int | None
    name: str
    text: str
    at: datetime
    mine: bool
    flyra: bool


class ChatView(BaseModel):
    negotiation_id: str
    title: str
    kind: TripKind
    members: list[MemberView]
    messages: list[MessageView]


class PostedView(BaseModel):
    # Tu mensaje y, si llamaste a Flyra y pudo, su respuesta.
    messages: list[MessageView]
    # Si llamaste a Flyra y no pudo: "quota" (sin preguntas hoy) o "busy".
    flyra_error: str | None = None


def _names(page: ChatPage) -> dict[int, str]:
    return {m.seat: m.name for m in page.members}


def _view(msg: Message, names: dict[int, str], my_seat: int) -> MessageView:
    return MessageView(
        id=msg.message_id,
        seat=msg.seat,
        name=FLYRA_NAME if msg.seat is None else names.get(msg.seat, "—"),
        text=msg.text,
        at=msg.created_at,
        mine=msg.seat == my_seat,
        flyra=msg.seat is None,
    )


def flyra_request(page: ChatPage, language: str) -> tuple[ChatRequest, str]:
    """Lo que lee Flyra: los últimos mensajes (con el nombre de quién habla) y
    una línea de contexto (tipo de viaje y quiénes sois)."""
    names = _names(page)
    turns: list[ChatTurn] = []
    for m in page.messages[-FLYRA_CONTEXT:]:
        text = clean_text(m.text)
        if m.seat is None:
            turns.append(ChatTurn(role="flyra", text=text))
        else:
            turns.append(ChatTurn(role="user", text=f"{names.get(m.seat, '—')}: {text}"[:2000]))
    # El hilo empieza en una persona y termina en la pregunta (lo pide el modelo).
    while turns and turns[0].role != "user":
        turns.pop(0)
    while sum(len(t.text) for t in turns) > MAX_TOTAL_CHARS and len(turns) > 1:
        turns.pop(0)
    people = ", ".join(m.name for m in page.members if m.active)
    context = (
        f"You are inside the group chat of the trip '{clean_text(page.title)}', with {people}. "
        f"This trip is {KIND_HINTS[page.kind]}. Each traveller's message starts with their name. "
        "Answer the group, briefly."
    )
    return ChatRequest(messages=turns, language=language), context


def chat_router(store: ChatStore, flyra: FlyraService | None, push: ChatPush | None = None) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    @router.get("", response_model=ChatView)
    async def read(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        after: Annotated[int | None, Query(ge=0)] = None,
    ) -> JSONResponse:
        try:
            page = await store.page(str(negotiation_id), principal.user_id, after=after, limit=PAGE)
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc
        names = _names(page)
        view = ChatView(
            negotiation_id=page.negotiation_id,
            title=page.title,
            kind=page.kind,
            members=[
                MemberView(seat=m.seat, name=m.name, me=m.seat == page.my_seat, active=m.active)
                for m in page.members
            ],
            messages=[_view(m, names, page.my_seat) for m in page.messages],
        )
        # Es privado: que ningún proxy lo guarde.
        return JSONResponse(view.model_dump(mode="json"), headers={"Cache-Control": "no-store"})

    @router.post("", status_code=201, response_model=PostedView)
    async def post(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        body: NewMessage,
    ) -> PostedView:
        trip = str(negotiation_id)
        try:
            mine = await store.post(trip, principal.user_id, body.text)
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc
        except ChatLimitError as exc:
            raise HTTPException(status_code=429, detail="demasiados mensajes hoy en este viaje") from exc
        page = await store.page(trip, principal.user_id, after=None, limit=FLYRA_CONTEXT)
        names = _names(page)
        out = [_view(mine, names, page.my_seat)]
        error: str | None = None
        if flyra is not None and asks_flyra(body.text):
            request, context = flyra_request(page, body.language)
            try:
                # El cupo es el de quien pregunta (el mismo que el chat privado).
                reply = await flyra.answer(principal.user_id, request, context=context)
            except QuotaExceededError:
                error = "quota"
            except FlyraBusyError:
                error = "busy"
            else:
                out.append(_view(await store.post_flyra(trip, reply.reply), names, page.my_seat))
        if push is not None:
            try:
                await push(trip, await store.others(trip, principal.user_id))
            except Exception:
                log.warning("no se pudo avisar del chat", exc_info=True)
        return PostedView(messages=out, flyra_error=error)

    @router.put("/kind", status_code=204)
    async def kind(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, body: KindBody
    ) -> None:
        try:
            await store.set_kind(str(negotiation_id), principal.user_id, body.kind)
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc

    @router.put("/me", status_code=204)
    async def me(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, body: NameBody
    ) -> None:
        try:
            await store.set_name(str(negotiation_id), principal.user_id, body.name)
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc

    return router
