"""API HTTP de la negociación de grupo (se monta dentro de api.create_api).

Flujo para la app:
    1. El organizador crea la negociación con las opciones (destinos con su
       precio por persona) y los miembros del grupo:
           POST /v1/group-negotiations                       -> 201
    2. Cada miembro, desde SU móvil, envía sus preferencias privadas
       (presupuesto, gustos, cosas a evitar, una nota):
           PUT  /v1/group-negotiations/{id}/preferences      -> 200
       Cuando envía el último, la negociación se pone en cola sola.

   Con invitación (lo que usa la app): el organizador crea el viaje SIN
   miembros y recibe un código ("7K2M9QXD") que comparte con su grupo:
           POST /v1/group-negotiations/join  {"code": ...}   -> 200
       Mientras el grupo admite gente, NO arranca sola: el organizador pulsa
       "Empezar" (con al menos dos preferencias enviadas) o vence el plazo:
           POST /v1/group-negotiations/{id}/start            -> 200
    3. Todos consultan cómo va y, al final, el resultado:
           GET  /v1/group-negotiations/{id}                  -> 200
           GET  /v1/group-negotiations                       -> mis negociaciones

Privacidad y control de acceso:
    - Solo los miembros ven una negociación. A quien no lo es se le responde
      404, igual que si no existiera (no revelamos qué ids existen).
    - Cada miembro ve SUS preferencias, nunca las de los demás. De los otros
      solo ve el alias ("Viajero 2") y si ya enviaron las suyas.
    - Nunca se devuelve el user_id de los demás miembros.
    - Cada miembro puede poner un nombre para SU grupo ("Noelia"). Ese
      nombre nunca llega al LLM: los agentes solo ven "Viajero 2".
    - Un código desconocido, caducado o de un grupo ya cerrado responde 404
      o 409 sin dar más pistas.
    - Ningún endpoint llama al LLM: todos responden en milisegundos.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Annotated, Self

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator

from ai_orchestrator.audioguides.domain import SUPPORTED_LANGUAGES
from ai_orchestrator.domain import CurrencyCode
from ai_orchestrator.identity import USER_ID_RE, Principal, current_principal
from ai_orchestrator.negotiation.domain import (
    MAX_MEMBERS,
    MAX_OPTIONS,
    MIN_OPTIONS,
    GroupOption,
    MemberPreferences,
    NegotiationResult,
    Status,
    clean_text,
)
from ai_orchestrator.negotiation.engine import HARD_MAX_ROUNDS
from ai_orchestrator.negotiation.store import (
    NegotiationClosedError,
    NegotiationFullError,
    NegotiationNotFoundError,
    NegotiationRecord,
    NegotiationStore,
    NewNegotiation,
    NotEnoughReadyError,
    NotOrganizerError,
    deadline_after,
    normalize_invite_code,
)

PREFIX = "/v1/group-negotiations"


def _clean_name(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("el nombre no puede quedar vacío")
    return cleaned


# Nombre visible para el grupo: sin caracteres de control, 1-40 letras.
DisplayName = Annotated[str | None, Field(max_length=40), AfterValidator(_clean_name)]


@dataclass(frozen=True, slots=True)
class ApiSettings:
    default_max_rounds: int
    collect_hours: float


class CreateNegotiation(BaseModel):
    """Lo que manda el organizador. ``extra="forbid"``: un campo de más = 400."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    title: str = Field(min_length=1, max_length=120)
    currency: CurrencyCode
    # Idioma de los argumentos de los agentes y de la explicación final.
    language: str = "es"
    options: list[GroupOption] = Field(min_length=MIN_OPTIONS, max_length=MAX_OPTIONS)
    # Los OTROS miembros (el organizador entra solo, en el asiento 1). Vacío
    # = viaje con código de invitación: los demás entran con /join.
    members: list[str] = Field(default_factory=list, max_length=MAX_MEMBERS - 1)
    max_rounds: int | None = Field(default=None, ge=1, le=HARD_MAX_ROUNDS)
    # Cómo quiere el organizador que le vea su grupo.
    my_name: DisplayName = None

    @model_validator(mode="after")
    def _check(self) -> Self:
        if self.language not in SUPPORTED_LANGUAGES:
            raise ValueError(f"language debe ser uno de: {', '.join(SUPPORTED_LANGUAGES)}")
        ids = [o.option_id for o in self.options]
        if len(set(ids)) != len(ids):
            raise ValueError("option_id repetido")
        if len(set(self.members)) != len(self.members):
            raise ValueError("miembro repetido")
        if any(not USER_ID_RE.fullmatch(m) for m in self.members):
            raise ValueError("user_id de miembro con formato inválido")
        return self


class JoinNegotiation(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    code: str = Field(min_length=1, max_length=32)
    my_name: DisplayName = None


class MemberView(BaseModel):
    model_config = ConfigDict(frozen=True)

    alias: str
    # El nombre que ese miembro eligió para su grupo (None = no puso).
    name: str | None
    submitted: bool
    me: bool


class NegotiationView(BaseModel):
    """Lo que ve UN miembro concreto (la vista cambia según quién pregunta)."""

    model_config = ConfigDict(frozen=True)

    negotiation_id: str
    title: str
    status: Status
    currency: str
    language: str
    options: list[GroupOption]
    deadline: datetime
    created_at: datetime
    concluded_at: datetime | None
    members: list[MemberView]
    my_alias: str
    i_organize: bool
    # Código para invitar a más gente. Solo mientras el grupo está abierto.
    invite_code: str | None
    # Solo las suyas; se borran al terminar (minimización de datos).
    my_preferences: MemberPreferences | None
    result: NegotiationResult | None

    @classmethod
    def of(cls, record: NegotiationRecord, user_id: str) -> NegotiationView:
        me = next(m for m in record.members if m.user_id == user_id)
        return cls(
            negotiation_id=record.negotiation_id,
            title=record.title,
            status=record.status,
            currency=record.currency,
            language=record.language,
            options=list(record.options),
            deadline=record.deadline,
            created_at=record.created_at,
            concluded_at=record.concluded_at,
            members=[
                MemberView(
                    alias=m.alias,
                    name=m.display_name,
                    submitted=m.submitted_at is not None,
                    me=m.user_id == user_id,
                )
                for m in record.members
            ],
            my_alias=me.alias,
            i_organize=record.organizer_id == user_id,
            invite_code=record.invite_code if record.status is Status.COLLECTING else None,
            my_preferences=me.preferences,
            result=record.result,
        )


class NegotiationList(BaseModel):
    items: list[NegotiationView]


def negotiation_router(
    store: NegotiationStore,
    settings: ApiSettings,
    *,
    on_outbox: Callable[[], None] | None = None,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    def _kick() -> None:
        if on_outbox is not None:
            on_outbox()

    @router.post("", status_code=201, response_model=NegotiationView)
    async def create_negotiation(
        principal: Annotated[Principal, Depends(current_principal)],
        body: CreateNegotiation,
        response: Response,
    ) -> NegotiationView:
        if principal.user_id in body.members:
            raise HTTPException(
                status_code=400, detail="el organizador ya está incluido: no lo pongas en members"
            )
        record = await store.create(
            NewNegotiation(
                organizer_id=principal.user_id,
                title=body.title,
                currency=body.currency,
                language=body.language,
                options=tuple(body.options),
                member_ids=(principal.user_id, *body.members),
                max_rounds=body.max_rounds or settings.default_max_rounds,
                deadline=deadline_after(clock(), settings.collect_hours),
                invites_open=not body.members,
                organizer_name=body.my_name,
            )
        )
        response.headers["Location"] = f"{PREFIX}/{record.negotiation_id}"
        return NegotiationView.of(record, principal.user_id)

    @router.post("/join", response_model=NegotiationView)
    async def join_negotiation(
        principal: Annotated[Principal, Depends(current_principal)],
        body: JoinNegotiation,
    ) -> NegotiationView:
        code = normalize_invite_code(body.code)
        if code is None:
            raise HTTPException(status_code=404, detail="código no encontrado")
        try:
            record = await store.join(code, principal.user_id, body.my_name)
        except NegotiationNotFoundError:
            raise HTTPException(status_code=404, detail="código no encontrado") from None
        except NegotiationClosedError:
            raise HTTPException(status_code=409, detail="el grupo ya no admite gente") from None
        except NegotiationFullError:
            raise HTTPException(status_code=409, detail="el grupo está completo") from None
        return NegotiationView.of(record, principal.user_id)

    @router.post("/{negotiation_id}/start", response_model=NegotiationView)
    async def start_negotiation(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: Annotated[uuid.UUID, Path()],
    ) -> NegotiationView:
        try:
            record = await store.start(str(negotiation_id), principal.user_id)
        except NegotiationNotFoundError:
            raise HTTPException(status_code=404, detail="negociación no encontrada") from None
        except NotOrganizerError:
            raise HTTPException(status_code=403, detail="solo el organizador puede empezar") from None
        except NegotiationClosedError:
            raise HTTPException(status_code=409, detail="la negociación ya no está esperando") from None
        except NotEnoughReadyError:
            raise HTTPException(
                status_code=409, detail="hacen falta al menos dos personas con sus preferencias enviadas"
            ) from None
        _kick()
        return NegotiationView.of(record, principal.user_id)

    @router.get("", response_model=NegotiationList)
    async def list_negotiations(
        principal: Annotated[Principal, Depends(current_principal)],
        limit: Annotated[int, Query(ge=1, le=50)] = 20,
    ) -> NegotiationList:
        records = await store.list_for_member(principal.user_id, limit=limit)
        return NegotiationList(items=[NegotiationView.of(r, principal.user_id) for r in records])

    @router.get("/{negotiation_id}", response_model=NegotiationView)
    async def get_negotiation(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: Annotated[uuid.UUID, Path()],
    ) -> NegotiationView:
        record = await store.get_for_member(str(negotiation_id), principal.user_id)
        if record is None:
            raise HTTPException(status_code=404, detail="negociación no encontrada")
        return NegotiationView.of(record, principal.user_id)

    @router.put("/{negotiation_id}/preferences", response_model=NegotiationView)
    async def submit_preferences(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: Annotated[uuid.UUID, Path()],
        body: MemberPreferences,
    ) -> NegotiationView:
        try:
            record = await store.submit_preferences(str(negotiation_id), principal.user_id, body)
        except NegotiationNotFoundError:
            raise HTTPException(status_code=404, detail="negociación no encontrada") from None
        except NegotiationClosedError:
            raise HTTPException(
                status_code=409,
                detail="la negociación ya no admite preferencias (en marcha, terminada o fuera de plazo)",
            ) from None
        if record.status is Status.QUEUED:
            # Era el último: la orden de trabajo está en el outbox. Timbre al relé.
            _kick()
        return NegotiationView.of(record, principal.user_id)

    return router
