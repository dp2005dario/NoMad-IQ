"""API HTTP del reparto de tareas (se monta dentro de api.create_api)."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.negotiation.domain import clean_text
from ai_orchestrator.trip_tasks.store import (
    NotAllowedError,
    TaskLimitError,
    TaskList,
    TaskNotFoundError,
    TaskStore,
    TripNotFoundError,
)

PREFIX = "/v1/group-negotiations/{negotiation_id}/tasks"
TripId = Annotated[uuid.UUID, Path()]
TaskId = Annotated[uuid.UUID, Path()]


def _clean(value: str) -> str:
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError("texto vacío")
    return cleaned


class NewTask(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    label: Annotated[str, Field(min_length=1, max_length=80), AfterValidator(_clean)]


class Done(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    done: bool


class TaskView(BaseModel):
    task_id: str
    label: str
    # Quién se encarga (el nombre que eligió para el grupo) o None.
    owner: str | None
    mine: bool  # me encargo yo
    added_by_me: bool
    done: bool


class TaskListView(BaseModel):
    negotiation_id: str
    tasks: list[TaskView]

    @classmethod
    def of(cls, lst: TaskList) -> TaskListView:
        return cls(
            negotiation_id=lst.negotiation_id,
            tasks=[
                TaskView(
                    task_id=t.task_id,
                    label=t.label,
                    owner=lst.names.get(t.owner_seat) if t.owner_seat is not None else None,
                    mine=t.owner_seat == lst.my_seat,
                    added_by_me=t.added_by_seat == lst.my_seat,
                    done=t.done,
                )
                for t in lst.tasks
            ],
        )


def task_router(store: TaskStore) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    @router.get("", response_model=TaskListView)
    async def tasks(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId
    ) -> TaskListView:
        try:
            return TaskListView.of(await store.list(str(negotiation_id), principal.user_id))
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc

    @router.post("", status_code=201, response_model=TaskListView)
    async def add(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, body: NewTask
    ) -> TaskListView:
        try:
            return TaskListView.of(await store.add(str(negotiation_id), principal.user_id, body.label))
        except TripNotFoundError as exc:
            raise HTTPException(status_code=404, detail="viaje no encontrado") from exc
        except TaskLimitError as exc:
            raise HTTPException(status_code=409, detail="demasiadas tareas en este viaje") from exc

    @router.put("/{task_id}/take", response_model=TaskListView)
    async def take(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, task_id: TaskId
    ) -> TaskListView:
        try:
            return TaskListView.of(await store.take(str(negotiation_id), principal.user_id, str(task_id)))
        except (TripNotFoundError, TaskNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="tarea no encontrada") from exc

    @router.put("/{task_id}/done", response_model=TaskListView)
    async def done(
        principal: Annotated[Principal, Depends(current_principal)],
        negotiation_id: TripId,
        task_id: TaskId,
        body: Done,
    ) -> TaskListView:
        try:
            lst = await store.done(str(negotiation_id), principal.user_id, str(task_id), done=body.done)
        except (TripNotFoundError, TaskNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="tarea no encontrada") from exc
        return TaskListView.of(lst)

    @router.delete("/{task_id}", response_model=TaskListView)
    async def delete(
        principal: Annotated[Principal, Depends(current_principal)], negotiation_id: TripId, task_id: TaskId
    ) -> TaskListView:
        try:
            return TaskListView.of(await store.delete(str(negotiation_id), principal.user_id, str(task_id)))
        except (TripNotFoundError, TaskNotFoundError) as exc:
            raise HTTPException(status_code=404, detail="tarea no encontrada") from exc
        except NotAllowedError as exc:
            raise HTTPException(status_code=403, detail="solo quien la puso o el organizador") from exc

    return router
