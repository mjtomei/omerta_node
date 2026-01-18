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
from .agents import (
    Agent, AgentContext, ActionSpec, TraceReplayAgent,
    AIAgent, AIAgentConfig,
    create_ai_agent,
    create_consumer_ai_agent,
    create_provider_ai_agent,
    create_witness_ai_agent,
)
from .traces import (
    Trace,
    TraceAction,
    TraceAssertion,
    TraceSetup,
    ValidationError,
    parse_trace,
    load_trace,
)
from .protocol import (
    ProtocolAgent,
    ConsumerAgent,
    ProviderAgent,
    WitnessAgent,
    create_protocol_agents_from_trace,
)
from .assertions import (
    AssertionResult,
    evaluate_assertion,
    evaluate_all_assertions,
)
from .runner import (
    TraceRunner,
    TraceRunResult,
    run_trace,
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
    # AI Agents
    "AIAgent",
    "AIAgentConfig",
    "create_ai_agent",
    "create_consumer_ai_agent",
    "create_provider_ai_agent",
    "create_witness_ai_agent",
    # Traces
    "Trace",
    "TraceAction",
    "TraceAssertion",
    "TraceSetup",
    "ValidationError",
    "parse_trace",
    "load_trace",
    # Protocol
    "ProtocolAgent",
    "ConsumerAgent",
    "ProviderAgent",
    "WitnessAgent",
    "create_protocol_agents_from_trace",
    # Assertions
    "AssertionResult",
    "evaluate_assertion",
    "evaluate_all_assertions",
    # Runner
    "TraceRunner",
    "TraceRunResult",
    "run_trace",
]
