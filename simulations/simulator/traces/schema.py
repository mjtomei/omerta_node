"""
Trace schema definitions.
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set

from ..network.regions import Region


@dataclass
class TraceAction:
    """A single action in a trace."""
    time: float
    actor: str
    action: str
    params: Dict[str, Any] = field(default_factory=dict)
    expected_result: Optional[str] = None


@dataclass
class TraceNodeSpec:
    """Specification for a node in a trace."""
    id: str
    region: Region
    connection: str


@dataclass
class TracePartitionSpec:
    """Specification for a network partition."""
    groups: List[Set[str]]
    start_time: float
    duration: float


@dataclass
class TraceNetworkSpec:
    """Network specification for a trace."""
    seed: int
    nodes: List[TraceNodeSpec]
    partitions: List[TracePartitionSpec] = field(default_factory=list)


@dataclass
class TraceChainSpec:
    """Initial chain state for an actor."""
    balance: float = 0.0
    trust: float = 1.0


@dataclass
class TraceRelationship:
    """Pre-established relationship between peers."""
    peers: List[str]
    age_days: int


@dataclass
class TraceSetup:
    """Initial setup for a trace."""
    chains: Dict[str, TraceChainSpec]
    relationships: List[TraceRelationship] = field(default_factory=list)


@dataclass
class TraceAssertion:
    """An assertion to check at the end of a trace."""
    type: str
    description: str
    params: Dict[str, Any] = field(default_factory=dict)


@dataclass
class Trace:
    """A recorded sequence of actions for replay."""
    name: str
    description: str
    network: TraceNetworkSpec
    setup: TraceSetup
    actions: List[TraceAction]
    assertions: List[TraceAssertion]


class ValidationError(Exception):
    """Error during trace validation."""
    pass
