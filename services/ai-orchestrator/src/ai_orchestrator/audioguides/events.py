"""Traduce los mensajes de geo.zone-entries.v1 (protobuf) a ``ZoneEntry``.

Es la misma "aduana" que ``ai_orchestrator.events`` para las alertas de
precio: se revisan los papeles y, si algo no cuadra, ``InvalidEventError``
manda el mensaje a la DLQ (reintentarlo no lo arreglaría).
"""

from __future__ import annotations

from google.protobuf.message import DecodeError
from pydantic import ValidationError

from ai_orchestrator.audioguides.domain import ZoneEntry, ZoneKind
from ai_orchestrator.events import (
    CONTENT_TYPE_PROTOBUF,
    HEADER_CONTENT_TYPE,
    HEADER_TYPE,
    Headers,
    InvalidEventError,
)
from nomadiq.geo.v1 import events_pb2, geo_pb2

ZONE_ENTERED_TYPE = events_pb2.ZoneEntered.DESCRIPTOR.full_name

_KINDS = {
    geo_pb2.ZONE_KIND_CITY_CENTER: ZoneKind.CITY_CENTER,
    geo_pb2.ZONE_KIND_TOURIST_AREA: ZoneKind.TOURIST_AREA,
    geo_pb2.ZONE_KIND_AIRPORT: ZoneKind.AIRPORT,
    geo_pb2.ZONE_KIND_RESTRICTED: ZoneKind.RESTRICTED,
}


def _header(headers: Headers, key: str) -> str | None:
    for k, v in headers:
        if k == key:
            return v.decode("utf-8", errors="replace")
    return None


def decode_zone_entry(value: bytes | None, headers: Headers) -> ZoneEntry:
    """Convierte un mensaje de geo.zone-entries.v1 en un ``ZoneEntry`` validado."""
    content_type = _header(headers, HEADER_CONTENT_TYPE)
    if content_type is not None and content_type != CONTENT_TYPE_PROTOBUF:
        raise InvalidEventError(f"content-type inesperado {content_type!r}")
    event_type = _header(headers, HEADER_TYPE)
    if event_type is not None and event_type != ZONE_ENTERED_TYPE:
        raise InvalidEventError(f"ce_type inesperado {event_type!r}")
    if not value:
        raise InvalidEventError("mensaje vacío")

    evt = events_pb2.ZoneEntered()
    try:
        evt.ParseFromString(value)
    except DecodeError as exc:
        raise InvalidEventError("protobuf ilegible") from exc

    try:
        return ZoneEntry(
            zone_id=evt.zone_id,
            # Un tipo desconocido (versión futura del contrato) no es un error:
            # el servicio decidirá que no se narra.
            zone_kind=_KINDS.get(evt.zone_kind),
            language=evt.language,
            event_id=evt.metadata.event_id,
        )
    except (ValidationError, ValueError) as exc:
        raise InvalidEventError(f"entrada a zona inválida: {exc.__class__.__name__}") from exc
