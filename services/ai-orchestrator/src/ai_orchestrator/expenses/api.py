"""API HTTP de los gastos compartidos (se monta dentro de api.create_api).

    POST /v1/expense-groups                          crear un bote (te da el código)
    POST /v1/expense-groups/join                     entrar con el código de un amigo
    GET  /v1/expense-groups                          mis botes, con mi saldo
    GET  /v1/expense-groups/{id}                     todo: gastos, pagos, saldos y quién paga a quién
    POST /v1/expense-groups/{id}/expenses            apuntar un gasto (a partes iguales o por platos)
    PUT  /v1/expense-groups/{id}/expenses/{e}/items/{i}/claim   "me lo pedí yo" (o ya no)
    DELETE /v1/expense-groups/{id}/expenses/{e}      borrar un gasto (quien lo apuntó o lo pagó)
    POST /v1/expense-groups/{id}/payments            "Saldar": apuntar que le pagaste a alguien

Privacidad: nunca se devuelve el user_id de nadie; cada uno es un asiento con
el nombre que eligió. A quien no es del bote se le responde 404.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Self

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator

from ai_orchestrator.domain import CurrencyCode
from ai_orchestrator.expenses.domain import MAX_ITEMS, Item, Split, balances, settle, shares
from ai_orchestrator.expenses.store import (
    ExpenseNotFoundError,
    ExpenseRecord,
    ExpenseStore,
    GroupFullError,
    GroupNotFoundError,
    GroupRecord,
    NewExpense,
    NotAllowedError,
    PaymentRecord,
    TooManyExpensesError,
)
from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.negotiation.store import normalize_invite_code

PREFIX = "/v1/expense-groups"
MAX_MINOR = 100_000_000_000


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


Name = Annotated[str, Field(min_length=1, max_length=40), AfterValidator(_clean)]
Title = Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]
Seat = Annotated[int, Field(ge=1, le=20)]
Minor = Annotated[int, Field(ge=1, le=MAX_MINOR)]


class CreateGroup(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    title: Annotated[str, Field(min_length=1, max_length=60), AfterValidator(_clean)]
    currency: CurrencyCode
    my_name: Name


class JoinGroup(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    code: str = Field(min_length=1, max_length=20)
    my_name: Name


class ItemIn(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    name: Annotated[str, Field(min_length=1, max_length=60), AfterValidator(_clean)]
    qty: int = Field(default=1, ge=1, le=999)
    price_minor: int = Field(ge=0, le=MAX_MINOR)
    claimed_by: list[Seat] = Field(default_factory=list, max_length=20)


class CreateExpense(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    title: Title
    amount_minor: Minor
    payer_seat: Seat
    split: Split = "equal"
    participants: list[Seat] = Field(min_length=1, max_length=20)
    items: list[ItemIn] = Field(default_factory=list, max_length=MAX_ITEMS)
    spent_on: date
    original_minor: Minor | None = None
    original_currency: CurrencyCode | None = None

    @model_validator(mode="after")
    def _check(self) -> Self:
        if (self.original_minor is None) != (self.original_currency is None):
            raise ValueError("original_minor y original_currency van juntos")
        if len(set(self.participants)) != len(self.participants):
            raise ValueError("participantes repetidos")
        return self


class Claim(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    claimed: bool


class CreatePayment(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    to_seat: Seat
    amount_minor: Minor


class MemberView(BaseModel):
    seat: int
    name: str
    me: bool


class ItemView(BaseModel):
    name: str
    qty: int
    price_minor: int
    claimed_by: list[int]


class ShareView(BaseModel):
    seat: int
    amount_minor: int


class ExpenseView(BaseModel):
    expense_id: str
    title: str
    amount_minor: int
    payer_seat: int
    split: Split
    participants: list[int]
    items: list[ItemView]
    shares: list[ShareView]
    spent_on: date
    created_by: int
    created_at: datetime
    original_minor: int | None
    original_currency: str | None

    @classmethod
    def of(cls, e: ExpenseRecord) -> ExpenseView:
        return cls(
            expense_id=e.expense_id,
            title=e.title,
            amount_minor=e.amount_minor,
            payer_seat=e.payer_seat,
            split=e.split,
            participants=list(e.participants),
            items=[
                ItemView(name=i.name, qty=i.qty, price_minor=i.price_minor, claimed_by=list(i.claimed_by))
                for i in e.items
            ],
            shares=[ShareView(seat=s, amount_minor=a) for s, a in sorted(shares(e.as_expense()).items())],
            spent_on=e.spent_on,
            created_by=e.created_by,
            created_at=e.created_at,
            original_minor=e.original_minor,
            original_currency=e.original_currency,
        )


class PaymentView(BaseModel):
    payment_id: str
    from_seat: int
    to_seat: int
    amount_minor: int
    created_at: datetime

    @classmethod
    def of(cls, p: PaymentRecord) -> PaymentView:
        return cls(
            payment_id=p.payment_id,
            from_seat=p.from_seat,
            to_seat=p.to_seat,
            amount_minor=p.amount_minor,
            created_at=p.created_at,
        )


class BalanceView(BaseModel):
    seat: int
    # Positivo = le deben; negativo = debe.
    balance_minor: int


class TransferView(BaseModel):
    from_seat: int
    to_seat: int
    amount_minor: int


class GroupView(BaseModel):
    group_id: str
    title: str
    currency: str
    invite_code: str
    my_seat: int
    members: list[MemberView]
    expenses: list[ExpenseView]
    payments: list[PaymentView]
    balances: list[BalanceView]
    transfers: list[TransferView]
    total_minor: int

    @classmethod
    def of(cls, g: GroupRecord, user_id: str) -> GroupView:
        me = g.seat_of(user_id)
        assert me is not None  # noqa: S101 (el store solo devuelve botes donde estás)
        bal = balances(
            [m.seat for m in g.members],
            [e.as_expense() for e in g.expenses],
            [p.as_payment() for p in g.payments],
        )
        return cls(
            group_id=g.group_id,
            title=g.title,
            currency=g.currency,
            invite_code=g.invite_code,
            my_seat=me,
            members=[MemberView(seat=m.seat, name=m.name, me=m.seat == me) for m in g.members],
            expenses=[ExpenseView.of(e) for e in g.expenses],
            payments=[PaymentView.of(p) for p in g.payments],
            balances=[BalanceView(seat=s, balance_minor=b) for s, b in sorted(bal.items())],
            transfers=[
                TransferView(from_seat=t.from_seat, to_seat=t.to_seat, amount_minor=t.amount_minor)
                for t in settle(bal)
            ],
            total_minor=sum(e.amount_minor for e in g.expenses),
        )


class GroupSummary(BaseModel):
    group_id: str
    title: str
    currency: str
    members: int
    my_balance_minor: int
    total_minor: int


class GroupList(BaseModel):
    items: list[GroupSummary]


GroupId = Annotated[uuid.UUID, Path()]


def expense_router(store: ExpenseStore) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    async def _group(group_id: uuid.UUID, user_id: str) -> GroupRecord:
        record = await store.get_for_member(str(group_id), user_id)
        if record is None:
            raise HTTPException(status_code=404, detail="bote no encontrado")
        return record

    @router.post("", status_code=201, response_model=GroupView)
    async def create_group(
        principal: Annotated[Principal, Depends(current_principal)], body: CreateGroup
    ) -> GroupView:
        record = await store.create(principal.user_id, body.my_name, body.title, body.currency)
        return GroupView.of(record, principal.user_id)

    @router.post("/join", response_model=GroupView)
    async def join_group(
        principal: Annotated[Principal, Depends(current_principal)], body: JoinGroup
    ) -> GroupView:
        code = normalize_invite_code(body.code)
        if code is None:
            raise HTTPException(status_code=404, detail="código no encontrado")
        try:
            record = await store.join(code, principal.user_id, body.my_name)
        except GroupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="código no encontrado") from exc
        except GroupFullError as exc:
            raise HTTPException(status_code=409, detail="el bote está lleno (20 personas)") from exc
        return GroupView.of(record, principal.user_id)

    @router.get("", response_model=GroupList)
    async def list_groups(principal: Annotated[Principal, Depends(current_principal)]) -> GroupList:
        out: list[GroupSummary] = []
        for g in await store.list_for_member(principal.user_id, limit=50):
            view = GroupView.of(g, principal.user_id)
            mine = next(b.balance_minor for b in view.balances if b.seat == view.my_seat)
            out.append(
                GroupSummary(
                    group_id=g.group_id,
                    title=g.title,
                    currency=g.currency,
                    members=len(g.members),
                    my_balance_minor=mine,
                    total_minor=view.total_minor,
                )
            )
        return GroupList(items=out)

    @router.get("/{group_id}", response_model=GroupView)
    async def get_group(
        principal: Annotated[Principal, Depends(current_principal)], group_id: GroupId
    ) -> GroupView:
        return GroupView.of(await _group(group_id, principal.user_id), principal.user_id)

    @router.post("/{group_id}/expenses", status_code=201, response_model=ExpenseView)
    async def add_expense(
        principal: Annotated[Principal, Depends(current_principal)], group_id: GroupId, body: CreateExpense
    ) -> ExpenseView:
        new = NewExpense(
            title=body.title,
            amount_minor=body.amount_minor,
            payer_seat=body.payer_seat,
            split=body.split,
            participants=tuple(body.participants),
            spent_on=body.spent_on,
            items=tuple(
                Item(i.name, i.qty, i.price_minor, tuple(dict.fromkeys(i.claimed_by))) for i in body.items
            ),
            original_minor=body.original_minor,
            original_currency=body.original_currency,
        )
        try:
            return ExpenseView.of(await store.add_expense(str(group_id), principal.user_id, new))
        except GroupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="bote no encontrado") from exc
        except TooManyExpensesError as exc:
            raise HTTPException(status_code=409, detail="este bote ya tiene 1.000 gastos") from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @router.put("/{group_id}/expenses/{expense_id}/items/{index}/claim", response_model=ExpenseView)
    async def claim_item(
        principal: Annotated[Principal, Depends(current_principal)],
        group_id: GroupId,
        expense_id: Annotated[uuid.UUID, Path()],
        index: Annotated[int, Path(ge=0, lt=MAX_ITEMS)],
        body: Claim,
    ) -> ExpenseView:
        try:
            record = await store.claim(str(group_id), str(expense_id), principal.user_id, index, body.claimed)
        except (GroupNotFoundError, ExpenseNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="gasto no encontrado") from exc
        except NotAllowedError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        return ExpenseView.of(record)

    @router.delete("/{group_id}/expenses/{expense_id}", status_code=204)
    async def delete_expense(
        principal: Annotated[Principal, Depends(current_principal)],
        group_id: GroupId,
        expense_id: Annotated[uuid.UUID, Path()],
    ) -> Response:
        try:
            await store.delete_expense(str(group_id), str(expense_id), principal.user_id)
        except (GroupNotFoundError, ExpenseNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="gasto no encontrado") from exc
        except NotAllowedError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        return Response(status_code=204)

    @router.post("/{group_id}/payments", status_code=201, response_model=PaymentView)
    async def add_payment(
        principal: Annotated[Principal, Depends(current_principal)], group_id: GroupId, body: CreatePayment
    ) -> PaymentView:
        try:
            record = await store.add_payment(
                str(group_id), principal.user_id, body.to_seat, body.amount_minor
            )
        except GroupNotFoundError as exc:
            raise HTTPException(status_code=404, detail="bote no encontrado") from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return PaymentView.of(record)

    return router
