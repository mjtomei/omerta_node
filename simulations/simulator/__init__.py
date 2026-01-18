"""
Omerta Chain Simulator

A discrete event simulator with SimBlock-style network modeling.
"""

from .engine import (
    Event,
    EventQueue,
    SimulationClock,
    Action,
    Message,
    SimulationResult,
    SimulationEngine,
)
from .network import (
    Region,
    NetworkModel,
    NetworkNode,
    create_network,
    create_specific_network,
)
from .agents import Agent, AgentContext, ActionSpec, TraceReplayAgent
from .traces import (
    Trace,
    TraceAction,
    TraceAssertion,
    TraceSetup,
    ValidationError,
    parse_trace,
    load_trace,
)

__all__ = [
    # Engine
    "Event",
    "EventQueue",
    "SimulationClock",
    "Action",
    "Message",
    "SimulationResult",
    "SimulationEngine",
    # Network
    "Region",
    "NetworkModel",
    "NetworkNode",
    "create_network",
    "create_specific_network",
    # Agents
    "Agent",
    "AgentContext",
    "ActionSpec",
    "TraceReplayAgent",
    # Traces
    "Trace",
    "TraceAction",
    "TraceAssertion",
    "TraceSetup",
    "ValidationError",
    "parse_trace",
    "load_trace",
]
