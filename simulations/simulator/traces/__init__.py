"""
Trace module for recording and replaying simulations.
"""

from .schema import (
    Trace, TraceAction, TraceAssertion,
    TraceNetworkSpec, TraceNodeSpec, TracePartitionSpec,
    TraceSetup, TraceChainSpec, TraceRelationship,
    ValidationError,
)
from .parser import parse_trace, load_trace

__all__ = [
    # Schema
    "Trace",
    "TraceAction",
    "TraceAssertion",
    "TraceNetworkSpec",
    "TraceNodeSpec",
    "TracePartitionSpec",
    "TraceSetup",
    "TraceChainSpec",
    "TraceRelationship",
    "ValidationError",
    # Parser
    "parse_trace",
    "load_trace",
]
