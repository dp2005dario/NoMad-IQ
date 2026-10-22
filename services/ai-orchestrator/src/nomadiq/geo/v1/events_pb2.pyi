from nomadiq.common.v1 import common_pb2 as _common_pb2
from nomadiq.geo.v1 import geo_pb2 as _geo_pb2
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class GeofenceTransitionType(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    GEOFENCE_TRANSITION_TYPE_UNSPECIFIED: _ClassVar[GeofenceTransitionType]
    GEOFENCE_TRANSITION_TYPE_ENTER: _ClassVar[GeofenceTransitionType]
    GEOFENCE_TRANSITION_TYPE_EXIT: _ClassVar[GeofenceTransitionType]
GEOFENCE_TRANSITION_TYPE_UNSPECIFIED: GeofenceTransitionType
GEOFENCE_TRANSITION_TYPE_ENTER: GeofenceTransitionType
GEOFENCE_TRANSITION_TYPE_EXIT: GeofenceTransitionType

class UserPositionReported(_message.Message):
    __slots__ = ("metadata", "user_id", "position", "horizontal_accuracy_meters", "preferred_language")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    USER_ID_FIELD_NUMBER: _ClassVar[int]
    POSITION_FIELD_NUMBER: _ClassVar[int]
    HORIZONTAL_ACCURACY_METERS_FIELD_NUMBER: _ClassVar[int]
    PREFERRED_LANGUAGE_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    user_id: str
    position: _geo_pb2.LatLng
    horizontal_accuracy_meters: float
    preferred_language: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., user_id: _Optional[str] = ..., position: _Optional[_Union[_geo_pb2.LatLng, _Mapping]] = ..., horizontal_accuracy_meters: _Optional[float] = ..., preferred_language: _Optional[str] = ...) -> None: ...

class GeofenceTransitioned(_message.Message):
    __slots__ = ("metadata", "user_id", "transition", "zone_id", "zone_slug", "zone_name", "zone_kind", "position", "position_event_id")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    USER_ID_FIELD_NUMBER: _ClassVar[int]
    TRANSITION_FIELD_NUMBER: _ClassVar[int]
    ZONE_ID_FIELD_NUMBER: _ClassVar[int]
    ZONE_SLUG_FIELD_NUMBER: _ClassVar[int]
    ZONE_NAME_FIELD_NUMBER: _ClassVar[int]
    ZONE_KIND_FIELD_NUMBER: _ClassVar[int]
    POSITION_FIELD_NUMBER: _ClassVar[int]
    POSITION_EVENT_ID_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    user_id: str
    transition: GeofenceTransitionType
    zone_id: str
    zone_slug: str
    zone_name: str
    zone_kind: _geo_pb2.ZoneKind
    position: _geo_pb2.LatLng
    position_event_id: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., user_id: _Optional[str] = ..., transition: _Optional[_Union[GeofenceTransitionType, str]] = ..., zone_id: _Optional[str] = ..., zone_slug: _Optional[str] = ..., zone_name: _Optional[str] = ..., zone_kind: _Optional[_Union[_geo_pb2.ZoneKind, str]] = ..., position: _Optional[_Union[_geo_pb2.LatLng, _Mapping]] = ..., position_event_id: _Optional[str] = ...) -> None: ...

class ZoneEntered(_message.Message):
    __slots__ = ("metadata", "zone_id", "zone_kind", "language")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    ZONE_ID_FIELD_NUMBER: _ClassVar[int]
    ZONE_KIND_FIELD_NUMBER: _ClassVar[int]
    LANGUAGE_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    zone_id: str
    zone_kind: _geo_pb2.ZoneKind
    language: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., zone_id: _Optional[str] = ..., zone_kind: _Optional[_Union[_geo_pb2.ZoneKind, str]] = ..., language: _Optional[str] = ...) -> None: ...
