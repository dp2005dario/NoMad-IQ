from nomadiq.common.v1 import common_pb2 as _common_pb2
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class CabinClass(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    CABIN_CLASS_UNSPECIFIED: _ClassVar[CabinClass]
    CABIN_CLASS_ECONOMY: _ClassVar[CabinClass]
    CABIN_CLASS_PREMIUM_ECONOMY: _ClassVar[CabinClass]
    CABIN_CLASS_BUSINESS: _ClassVar[CabinClass]
    CABIN_CLASS_FIRST: _ClassVar[CabinClass]
CABIN_CLASS_UNSPECIFIED: CabinClass
CABIN_CLASS_ECONOMY: CabinClass
CABIN_CLASS_PREMIUM_ECONOMY: CabinClass
CABIN_CLASS_BUSINESS: CabinClass
CABIN_CLASS_FIRST: CabinClass

class Route(_message.Message):
    __slots__ = ("origin_iata", "destination_iata")
    ORIGIN_IATA_FIELD_NUMBER: _ClassVar[int]
    DESTINATION_IATA_FIELD_NUMBER: _ClassVar[int]
    origin_iata: str
    destination_iata: str
    def __init__(self, origin_iata: _Optional[str] = ..., destination_iata: _Optional[str] = ...) -> None: ...

class RouteWatch(_message.Message):
    __slots__ = ("watch_id", "route", "departure_date", "return_date", "cabin")
    WATCH_ID_FIELD_NUMBER: _ClassVar[int]
    ROUTE_FIELD_NUMBER: _ClassVar[int]
    DEPARTURE_DATE_FIELD_NUMBER: _ClassVar[int]
    RETURN_DATE_FIELD_NUMBER: _ClassVar[int]
    CABIN_FIELD_NUMBER: _ClassVar[int]
    watch_id: str
    route: Route
    departure_date: _common_pb2.Date
    return_date: _common_pb2.Date
    cabin: CabinClass
    def __init__(self, watch_id: _Optional[str] = ..., route: _Optional[_Union[Route, _Mapping]] = ..., departure_date: _Optional[_Union[_common_pb2.Date, _Mapping]] = ..., return_date: _Optional[_Union[_common_pb2.Date, _Mapping]] = ..., cabin: _Optional[_Union[CabinClass, str]] = ...) -> None: ...
