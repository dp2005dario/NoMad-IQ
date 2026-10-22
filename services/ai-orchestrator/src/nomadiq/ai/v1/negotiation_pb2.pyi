from nomadiq.common.v1 import common_pb2 as _common_pb2
from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class NegotiationOutcome(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    NEGOTIATION_OUTCOME_UNSPECIFIED: _ClassVar[NegotiationOutcome]
    NEGOTIATION_OUTCOME_CONSENSUS: _ClassVar[NegotiationOutcome]
    NEGOTIATION_OUTCOME_ARBITRATION: _ClassVar[NegotiationOutcome]
    NEGOTIATION_OUTCOME_NO_FEASIBLE_OPTION: _ClassVar[NegotiationOutcome]
NEGOTIATION_OUTCOME_UNSPECIFIED: NegotiationOutcome
NEGOTIATION_OUTCOME_CONSENSUS: NegotiationOutcome
NEGOTIATION_OUTCOME_ARBITRATION: NegotiationOutcome
NEGOTIATION_OUTCOME_NO_FEASIBLE_OPTION: NegotiationOutcome

class GroupNegotiationRequested(_message.Message):
    __slots__ = ("metadata", "negotiation_id")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    NEGOTIATION_ID_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    negotiation_id: str
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., negotiation_id: _Optional[str] = ...) -> None: ...

class GroupNegotiationConcluded(_message.Message):
    __slots__ = ("metadata", "negotiation_id", "outcome", "chosen_option_id", "rounds", "recipients", "llm_used")
    METADATA_FIELD_NUMBER: _ClassVar[int]
    NEGOTIATION_ID_FIELD_NUMBER: _ClassVar[int]
    OUTCOME_FIELD_NUMBER: _ClassVar[int]
    CHOSEN_OPTION_ID_FIELD_NUMBER: _ClassVar[int]
    ROUNDS_FIELD_NUMBER: _ClassVar[int]
    RECIPIENTS_FIELD_NUMBER: _ClassVar[int]
    LLM_USED_FIELD_NUMBER: _ClassVar[int]
    metadata: _common_pb2.EventMetadata
    negotiation_id: str
    outcome: NegotiationOutcome
    chosen_option_id: str
    rounds: int
    recipients: _containers.RepeatedScalarFieldContainer[str]
    llm_used: bool
    def __init__(self, metadata: _Optional[_Union[_common_pb2.EventMetadata, _Mapping]] = ..., negotiation_id: _Optional[str] = ..., outcome: _Optional[_Union[NegotiationOutcome, str]] = ..., chosen_option_id: _Optional[str] = ..., rounds: _Optional[int] = ..., recipients: _Optional[_Iterable[str]] = ..., llm_used: _Optional[bool] = ...) -> None: ...
