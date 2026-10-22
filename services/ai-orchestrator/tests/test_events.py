"""Tests de la "aduana": de protobuf (Kafka) a FareAlert validado."""

from __future__ import annotations

import pytest
from conftest import ALERT_ID, PROTO_HEADERS, encode_alert_proto, make_alert

from ai_orchestrator.domain import AlertType, Cabin, Money
from ai_orchestrator.events import InvalidEventError, decode_fare_alert, dlq_headers
from nomadiq.common.v1 import common_pb2


def test_decodes_message_from_price_consumer() -> None:
    alert = decode_fare_alert(encode_alert_proto(), PROTO_HEADERS)
    assert alert == make_alert()
    assert alert.alert_type is AlertType.PRICE_DROP
    assert alert.cabin is Cabin.ECONOMY


def test_uuid_is_normalised() -> None:
    raw = encode_alert_proto(alert_id=ALERT_ID.upper())
    assert decode_fare_alert(raw, []).alert_id == ALERT_ID


@pytest.mark.parametrize(
    ("headers", "match"),
    [
        ([("content-type", b"application/json")], "content-type"),
        ([("ce_type", b"nomadiq.flights.v1.FlightPriceObserved")], "ce_type"),
    ],
)
def test_wrong_headers_are_rejected_before_parsing(headers: list[tuple[str, bytes]], match: str) -> None:
    with pytest.raises(InvalidEventError, match=match):
        decode_fare_alert(encode_alert_proto(), headers)


@pytest.mark.parametrize("value", [None, b"", b"\xff\xff\xff basura"])
def test_garbage_is_invalid(value: bytes | None) -> None:
    with pytest.raises(InvalidEventError):
        decode_fare_alert(value, [])


def test_missing_required_field_is_invalid() -> None:
    with pytest.raises(InvalidEventError, match="current_price"):
        decode_fare_alert(encode_alert_proto(current_price=None), [])


def test_business_rules_are_enforced() -> None:
    with pytest.raises(InvalidEventError, match="alerta inválida"):
        decode_fare_alert(encode_alert_proto(alert_id="no-es-un-uuid"), [])
    with pytest.raises(InvalidEventError, match="fecha imposible"):
        bad_date = common_pb2.Date(year=2026, month=2, day=31)
        decode_fare_alert(encode_alert_proto(departure_date=bad_date), [])
    with pytest.raises(InvalidEventError):
        decode_fare_alert(encode_alert_proto(cabin=0), [])  # CABIN_CLASS_UNSPECIFIED


def test_insecure_deep_link_is_rejected() -> None:
    with pytest.raises(InvalidEventError, match="https"):
        decode_fare_alert(encode_alert_proto(booking_deep_link="javascript:alert(1)"), [])


def test_dlq_headers_keep_original_and_add_origin() -> None:
    headers = dlq_headers(PROTO_HEADERS, reason="roto", topic="t", partition=3, offset=42)
    assert headers[: len(PROTO_HEADERS)] == PROTO_HEADERS
    assert ("dlq_source_offset", b"42") in headers
    assert ("dlq_reason", b"roto") in headers


@pytest.mark.parametrize(
    ("money", "text"),
    [
        (Money(currency="EUR", amount_minor=12999), "129,99 EUR"),
        (Money(currency="EUR", amount_minor=123456789), "1.234.567,89 EUR"),
        (Money(currency="JPY", amount_minor=45000), "45.000 JPY"),
    ],
)
def test_money_display(money: Money, text: str) -> None:
    assert money.display() == text
