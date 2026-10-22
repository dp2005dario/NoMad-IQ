from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class ZoneKind(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    ZONE_KIND_UNSPECIFIED: _ClassVar[ZoneKind]
    ZONE_KIND_CITY_CENTER: _ClassVar[ZoneKind]
    ZONE_KIND_TOURIST_AREA: _ClassVar[ZoneKind]
    ZONE_KIND_AIRPORT: _ClassVar[ZoneKind]
    ZONE_KIND_RESTRICTED: _ClassVar[ZoneKind]
ZONE_KIND_UNSPECIFIED: ZoneKind
ZONE_KIND_CITY_CENTER: ZoneKind
ZONE_KIND_TOURIST_AREA: ZoneKind
ZONE_KIND_AIRPORT: ZoneKind
ZONE_KIND_RESTRICTED: ZoneKind

class LatLng(_message.Message):
    __slots__ = ("latitude", "longitude")
    LATITUDE_FIELD_NUMBER: _ClassVar[int]
    LONGITUDE_FIELD_NUMBER: _ClassVar[int]
    latitude: float
    longitude: float
    def __init__(self, latitude: _Optional[float] = ..., longitude: _Optional[float] = ...) -> None: ...

class Geometry(_message.Message):
    __slots__ = ("wkb",)
    WKB_FIELD_NUMBER: _ClassVar[int]
    wkb: bytes
    def __init__(self, wkb: _Optional[bytes] = ...) -> None: ...

class Airport(_message.Message):
    __slots__ = ("iata_code", "icao_code", "name", "city", "country_code", "location")
    IATA_CODE_FIELD_NUMBER: _ClassVar[int]
    ICAO_CODE_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    CITY_FIELD_NUMBER: _ClassVar[int]
    COUNTRY_CODE_FIELD_NUMBER: _ClassVar[int]
    LOCATION_FIELD_NUMBER: _ClassVar[int]
    iata_code: str
    icao_code: str
    name: str
    city: str
    country_code: str
    location: LatLng
    def __init__(self, iata_code: _Optional[str] = ..., icao_code: _Optional[str] = ..., name: _Optional[str] = ..., city: _Optional[str] = ..., country_code: _Optional[str] = ..., location: _Optional[_Union[LatLng, _Mapping]] = ...) -> None: ...

class Zone(_message.Message):
    __slots__ = ("zone_id", "slug", "name", "kind", "geometry")
    ZONE_ID_FIELD_NUMBER: _ClassVar[int]
    SLUG_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    KIND_FIELD_NUMBER: _ClassVar[int]
    GEOMETRY_FIELD_NUMBER: _ClassVar[int]
    zone_id: str
    slug: str
    name: str
    kind: ZoneKind
    geometry: Geometry
    def __init__(self, zone_id: _Optional[str] = ..., slug: _Optional[str] = ..., name: _Optional[str] = ..., kind: _Optional[_Union[ZoneKind, str]] = ..., geometry: _Optional[_Union[Geometry, _Mapping]] = ...) -> None: ...
