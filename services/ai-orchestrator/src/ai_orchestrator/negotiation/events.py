"""Mensajes de Kafka de la negociación: codificar (salida) y decodificar (entrada).

Contratos en proto/nomadiq/ai/v1/negotiation.proto:
    ai.group-negotiation-requests.v1 -> GroupNegotiationRequested (orden de trabajo)
    ai.group-negotiations.v1         -> GroupNegotiationConcluded (resultado)
    ai.group-chat-activity.v1        -> GroupChatActivity (mensajes nuevos en el chat)

Ninguno lleva datos personales: solo el id de la negociación, el resultado y,
como mucho, seudónimos de los miembros (ver pseudonym.py).

Igual que events.py para las alertas, este módulo no habla con Kafka: produce
y lee bytes + cabeceras. Así se prueba sin broker.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime

from google.protobuf.message import DecodeError
from google.protobuf.timestamp_pb2 import Timestamp

from ai_orchestrator.events import (
    CONTENT_TYPE_PROTOBUF,
    HEADER_CONTENT_TYPE,
    HEADER_TYPE,
    Headers,
    InvalidEventError,
)
from ai_orchestrator.negotiation.domain import NegotiationResult, Outcome
from ai_orchestrator.outbox import OutboxMessage
from nomadiq.ai.v1 import negotiation_pb2
from nomadiq.common.v1 import common_pb2

PRODUCER = "ai-orchestrator"
REQUESTED_TYPE = negotiation_pb2.GroupNegotiationRequested.DESCRIPTOR.full_name
CONCLUDED_TYPE = negotiation_pb2.GroupNegotiationConcluded.DESCRIPTOR.full_name
CHAT_ACTIVITY_TYPE = negotiation_pb2.GroupChatActivity.DESCRIPTOR.full_name

_OUTCOMES = {
    Outcome.CONSENSUS: negotiation_pb2.NEGOTIATION_OUTCOME_CONSENSUS,
    Outcome.ARBITRATION: negotiation_pb2.NEGOTIATION_OUTCOME_ARBITRATION,
    Outcome.NO_FEASIBLE_OPTION: negotiation_pb2.NEGOTIATION_OUTCOME_NO_FEASIBLE_OPTION,
}


def _metadata(now: datetime) -> tuple[common_pb2.EventMetadata, str]:
    event_id = str(uuid.uuid4())
    occurred = Timestamp()
    occurred.FromDatetime(now)
    return common_pb2.EventMetadata(event_id=event_id, occurred_at=occurred, producer=PRODUCER), event_id


def _headers(event_type: str, event_id: str, now: datetime) -> tuple[tuple[str, bytes], ...]:
    # Mismas cabeceras estilo CloudEvents que ponen los servicios en Go.
    return (
        (HEADER_CONTENT_TYPE, CONTENT_TYPE_PROTOBUF.encode()),
        ("ce_id", event_id.encode()),
        (HEADER_TYPE, event_type.encode()),
        ("ce_source", PRODUCER.encode()),
        ("ce_time", now.isoformat().encode()),
        ("ce_specversion", b"1.0"),
    )


def request_message(topic: str, negotiation_id: str, now: datetime) -> OutboxMessage:
    """La orden "negocia esto" para ai.group-negotiation-requests.v1."""
    metadata, event_id = _metadata(now)
    evt = negotiation_pb2.GroupNegotiationRequested(metadata=metadata, negotiation_id=negotiation_id)
    return OutboxMessage(
        topic=topic,
        key=negotiation_id.encode(),
        value=evt.SerializeToString(),
        headers=_headers(REQUESTED_TYPE, event_id, now),
    )


def concluded_message(
    topic: str, negotiation_id: str, result: NegotiationResult, recipients: Sequence[str], now: datetime
) -> OutboxMessage:
    """El anuncio "esta negociación terminó así" para ai.group-negotiations.v1."""
    metadata, event_id = _metadata(now)
    evt = negotiation_pb2.GroupNegotiationConcluded(
        metadata=metadata,
        negotiation_id=negotiation_id,
        outcome=_OUTCOMES[result.outcome],
        chosen_option_id=result.chosen_option_id or "",
        rounds=result.rounds,
        recipients=list(recipients),
        llm_used=result.llm_used,
    )
    return OutboxMessage(
        topic=topic,
        key=negotiation_id.encode(),
        value=evt.SerializeToString(),
        headers=_headers(CONCLUDED_TYPE, event_id, now),
    )


def chat_activity_message(
    topic: str, negotiation_id: str, recipients: Sequence[str], now: datetime
) -> OutboxMessage:
    """El aviso "hay mensajes nuevos en el chat" para ai.group-chat-activity.v1.

    Sin texto ni nombres: el viaje y los seudónimos de a quién avisar.
    """
    metadata, event_id = _metadata(now)
    evt = negotiation_pb2.GroupChatActivity(
        metadata=metadata, negotiation_id=negotiation_id, recipients=list(recipients)
    )
    return OutboxMessage(
        topic=topic,
        key=negotiation_id.encode(),
        value=evt.SerializeToString(),
        headers=_headers(CHAT_ACTIVITY_TYPE, event_id, now),
    )


def _header(headers: Headers, key: str) -> str | None:
    for k, v in headers:
        if k == key:
            return v.decode("utf-8", errors="replace")
    return None


def decode_request(value: bytes | None, headers: Headers) -> str:
    """Lee una orden de ai.group-negotiation-requests.v1 y devuelve el negotiation_id."""
    content_type = _header(headers, HEADER_CONTENT_TYPE)
    if content_type is not None and content_type != CONTENT_TYPE_PROTOBUF:
        raise InvalidEventError(f"content-type inesperado {content_type!r}")
    event_type = _header(headers, HEADER_TYPE)
    if event_type is not None and event_type != REQUESTED_TYPE:
        raise InvalidEventError(f"ce_type inesperado {event_type!r}")
    if not value:
        raise InvalidEventError("mensaje vacío")
    evt = negotiation_pb2.GroupNegotiationRequested()
    try:
        evt.ParseFromString(value)
    except DecodeError as exc:
        raise InvalidEventError("protobuf ilegible") from exc
    try:
        # Forma canónica: "ABC..." y "abc..." son la misma negociación.
        return str(uuid.UUID(evt.negotiation_id))
    except ValueError as exc:
        raise InvalidEventError("negotiation_id no es un UUID") from exc
