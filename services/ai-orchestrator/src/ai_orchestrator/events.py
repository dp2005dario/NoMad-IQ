"""Traduce los mensajes de Kafka (protobuf binario) a tipos de dominio.

Analogía: es la aduana. Lo que llega por Kafka viene "en otro idioma"
(protobuf binario). Aquí se traduce al idioma interno (domain.FareAlert) y se
revisan los papeles. Si algo no cuadra, se lanza InvalidEventError: reintentar
ese mensaje no lo arreglaría, así que irá a la DLQ (buzón de devoluciones).

Este módulo no habla con Kafka: recibe bytes y cabeceras. Así se prueba sin broker.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, date

from google.protobuf.message import DecodeError
from pydantic import ValidationError

from ai_orchestrator.domain import AlertType, Cabin, FareAlert, Money
from nomadiq.common.v1 import common_pb2
from nomadiq.flights.v1 import events_pb2, flights_pb2

# Cabeceras estilo CloudEvents que pone el price-consumer (ver events.go).
HEADER_CONTENT_TYPE = "content-type"
HEADER_TYPE = "ce_type"
CONTENT_TYPE_PROTOBUF = "application/x-protobuf"
FARE_ALERT_TYPE = events_pb2.FareAlertTriggered.DESCRIPTOR.full_name

# Cabeceras que añadimos al mandar algo a la DLQ (mismos nombres que en Go).
HEADER_DLQ_REASON = "dlq_reason"
HEADER_DLQ_TOPIC = "dlq_source_topic"
HEADER_DLQ_PARTITION = "dlq_source_partition"
HEADER_DLQ_OFFSET = "dlq_source_offset"

Headers = Sequence[tuple[str, bytes]]

_CABINS = {
    flights_pb2.CABIN_CLASS_ECONOMY: Cabin.ECONOMY,
    flights_pb2.CABIN_CLASS_PREMIUM_ECONOMY: Cabin.PREMIUM_ECONOMY,
    flights_pb2.CABIN_CLASS_BUSINESS: Cabin.BUSINESS,
    flights_pb2.CABIN_CLASS_FIRST: Cabin.FIRST,
}
_ALERT_TYPES = {
    events_pb2.FARE_ALERT_TYPE_PRICE_DROP: AlertType.PRICE_DROP,
    events_pb2.FARE_ALERT_TYPE_ERROR_FARE: AlertType.ERROR_FARE,
    events_pb2.FARE_ALERT_TYPE_TARGET_REACHED: AlertType.TARGET_REACHED,
}


class InvalidEventError(ValueError):
    """El mensaje está mal formado: no tiene sentido reintentarlo."""


def _header(headers: Headers, key: str) -> str | None:
    for k, v in headers:
        if k == key:
            return v.decode("utf-8", errors="replace")
    return None


def _date(field: str, d: common_pb2.Date) -> date:
    try:
        return date(d.year, d.month, d.day)
    except ValueError as exc:
        raise InvalidEventError(f"{field}: fecha imposible {d.year}-{d.month}-{d.day}") from exc


def decode_fare_alert(value: bytes | None, headers: Headers) -> FareAlert:
    """Convierte un mensaje de flights.fare-alerts.v1 en un FareAlert validado."""
    # Si el productor dice qué contiene, lo comprobamos ANTES de deserializar:
    # un mensaje de otro tipo publicado por error no se malinterpreta.
    content_type = _header(headers, HEADER_CONTENT_TYPE)
    if content_type is not None and content_type != CONTENT_TYPE_PROTOBUF:
        raise InvalidEventError(f"content-type inesperado {content_type!r}")
    event_type = _header(headers, HEADER_TYPE)
    if event_type is not None and event_type != FARE_ALERT_TYPE:
        raise InvalidEventError(f"ce_type inesperado {event_type!r}")
    if not value:
        raise InvalidEventError("mensaje vacío")

    evt = events_pb2.FareAlertTriggered()
    try:
        evt.ParseFromString(value)
    except DecodeError as exc:
        raise InvalidEventError("protobuf ilegible") from exc

    # En proto3, un campo ausente vale "0" o "vacío". HasField distingue
    # "no vino" de "vino a cero" en los campos que son mensajes.
    for field in ("metadata", "route", "departure_date", "reference_price", "current_price"):
        if not evt.HasField(field):
            raise InvalidEventError(f"falta el campo obligatorio {field}")
    if not evt.metadata.HasField("occurred_at"):
        raise InvalidEventError("falta metadata.occurred_at")

    cabin = _CABINS.get(evt.cabin)
    if cabin is None:
        raise InvalidEventError(f"cabina desconocida {evt.cabin}")
    alert_type = _ALERT_TYPES.get(evt.alert_type)
    if alert_type is None:
        raise InvalidEventError(f"tipo de alerta desconocido {evt.alert_type}")

    try:
        return FareAlert(
            alert_id=evt.alert_id,
            user_id=evt.user_id,
            alert_type=alert_type,
            watch_id=evt.watch_id,
            origin=evt.route.origin_iata,
            destination=evt.route.destination_iata,
            departure_date=_date("departure_date", evt.departure_date),
            cabin=cabin,
            reference_price=Money(
                currency=evt.reference_price.currency_code, amount_minor=evt.reference_price.amount_minor
            ),
            current_price=Money(
                currency=evt.current_price.currency_code, amount_minor=evt.current_price.amount_minor
            ),
            drop_basis_points=evt.drop_basis_points,
            booking_deep_link=evt.booking_deep_link,
            correlation_id=evt.metadata.correlation_id,
            occurred_at=evt.metadata.occurred_at.ToDatetime(tzinfo=UTC),
        )
    except (ValidationError, ValueError) as exc:
        # Pydantic explica qué campo falló; lo resumimos en una línea.
        raise InvalidEventError(f"alerta inválida: {_short(exc)}") from exc


def dlq_headers(
    original: Headers, *, reason: str, topic: str, partition: int, offset: int
) -> list[tuple[str, bytes]]:
    """Cabeceras para la DLQ: las originales intactas + motivo y procedencia."""
    return [
        *original,
        (HEADER_DLQ_REASON, reason[:500].encode()),
        (HEADER_DLQ_TOPIC, topic.encode()),
        (HEADER_DLQ_PARTITION, str(partition).encode()),
        (HEADER_DLQ_OFFSET, str(offset).encode()),
    ]


def _short(exc: Exception) -> str:
    if isinstance(exc, ValidationError):
        return "; ".join(f"{'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors()[:5])
    return str(exc)
