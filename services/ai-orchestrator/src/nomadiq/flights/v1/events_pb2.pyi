import datetime

from google.protobuf import timestamp_pb2 as _timestamp_pb2
from nomadiq.common.v1 import common_pb2 as _common_pb2
from nomadiq.flights.v1 import flights_pb2 as _flights_pb2
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class FareAlertType(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    FARE_ALERT_TYPE_UNSPECIFIED: _ClassVar[FareAlertType]
    FARE_ALERT_TYPE_PRICE_DROP: _ClassVar[FareAlertType]
    FARE_ALERT_TYPE_ERROR_FARE: _ClassVar[FareAlertType]
    FARE_ALERT_TYPE_TARGET_REACHED: _ClassVar[FareAlertType]
FARE_ALERT_TYPE_UNSPECIFIED: FareAlertType
FARE_ALERT_TYPE_PRICE_DROP: FareAlertType
FARE_ALERT_TYPE_ERROR_FARE: FareAlertType
FARE_ALERT_TYPE_TARGET_REACHED: FareAlertType

class FlightPriceObserved(_message.Message):
    __slots__ = ("metadata", "watch_id", "route", "departure_date", "return_date", "cabin", "price", "provider", "carrier_iata", "observed_at", "booking_deep_link")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    WATCH_ID_FIELD_NUMBER: _ClassVar[int]
    ROUTE_FIELD_NUMBER: _ClassVar[int]
    DEPARTURE_DATE_FIELD_NUMBER: _ClassVar[int]
    RETURN_DATE_FIELD_NUMBER: _ClassVar[int]
    CABIN_FIELD_NUMBER: _ClassVar[int]
    PRICE_FIELD_NUMBER: _ClassVar[int]
    PROVIDER_FIELD_NUMBER: _ClassVar[int]
    CARRIER_IATA_FIELD_NUMBER: _ClassVar[int]
    OBSERVED_AT_FIELD_NUMBER: _ClassVar[int]
    BOOKING_DEEP_LINK_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    watch_id: str
    route: _flights_pb2.Route
    departure_date: _common_pb2.Date
    return_date: _common_pb2.Date
    cabin: _flights_pb2.CabinClass
    price: _common_pb2.Money
    provider: str
    carrier_iata: str
    observed_at: _timestamp_pb2.Timestamp
    booking_deep_link: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., watch_id: _Optional[str] = ..., route: _Optional[_Union[_flights_pb2.Route, _Mapping]] = ..., departure_date: _Optional[_Union[_common_pb2.Date, _Mapping]] = ..., return_date: _Optional[_Union[_common_pb2.Date, _Mapping]] = ..., cabin: _Optional[_Union[_flights_pb2.CabinClass, str]] = ..., price: _Optional[_Union[_common_pb2.Money, _Mapping]] = ..., provider: _Optional[str] = ..., carrier_iata: _Optional[str] = ..., observed_at: _Optional[_Union[datetime.datetime, _timestamp_pb2.Timestamp, _Mapping]] = ..., booking_deep_link: _Optional[str] = ...) -> None: ...

class FareAlertTriggered(_message.Message):
    __slots__ = ("metadata", "alert_id", "user_id", "alert_type", "watch_id", "route", "departure_date", "cabin", "reference_price", "current_price", "drop_basis_points", "booking_deep_link")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    ALERT_ID_FIELD_NUMBER: _ClassVar[int]
    USER_ID_FIELD_NUMBER: _ClassVar[int]
    ALERT_TYPE_FIELD_NUMBER: _ClassVar[int]
    WATCH_ID_FIELD_NUMBER: _ClassVar[int]
    ROUTE_FIELD_NUMBER: _ClassVar[int]
    DEPARTURE_DATE_FIELD_NUMBER: _ClassVar[int]
    CABIN_FIELD_NUMBER: _ClassVar[int]
    REFERENCE_PRICE_FIELD_NUMBER: _ClassVar[int]
    CURRENT_PRICE_FIELD_NUMBER: _ClassVar[int]
    DROP_BASIS_POINTS_FIELD_NUMBER: _ClassVar[int]
    BOOKING_DEEP_LINK_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    alert_id: str
    user_id: str
    alert_type: FareAlertType
    watch_id: str
    route: _flights_pb2.Route
    departure_date: _common_pb2.Date
    cabin: _flights_pb2.CabinClass
    reference_price: _common_pb2.Money
    current_price: _common_pb2.Money
    drop_basis_points: int
    booking_deep_link: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., alert_id: _Optional[str] = ..., user_id: _Optional[str] = ..., alert_type: _Optional[_Union[FareAlertType, str]] = ..., watch_id: _Optional[str] = ..., route: _Optional[_Union[_flights_pb2.Route, _Mapping]] = ..., departure_date: _Optional[_Union[_common_pb2.Date, _Mapping]] = ..., cabin: _Optional[_Union[_flights_pb2.CabinClass, str]] = ..., reference_price: _Optional[_Union[_common_pb2.Money, _Mapping]] = ..., current_price: _Optional[_Union[_common_pb2.Money, _Mapping]] = ..., drop_basis_points: _Optional[int] = ..., booking_deep_link: _Optional[str] = ...) -> None: ...
