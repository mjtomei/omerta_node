"""
Agent module for simulation.
"""

from .base import Agent, AgentContext, ActionSpec
from .trace_replay import TraceReplayAgent
from .ai_agent import (
    AIAgent,
    AIAgentConfig,
    create_ai_agent,
    create_consumer_ai_agent,
    create_provider_ai_agent,
    create_witness_ai_agent,
    CONSUMER_PROTOCOL_RULES,
    PROVIDER_PROTOCOL_RULES,
    WITNESS_PROTOCOL_RULES,
)

__all__ = [
    # Base
    "Agent",
    "AgentContext",
    "ActionSpec",
    # Trace Replay
    "TraceReplayAgent",
    # AI Agent
    "AIAgent",
    "AIAgentConfig",
    "create_ai_agent",
    "create_consumer_ai_agent",
    "create_provider_ai_agent",
    "create_witness_ai_agent",
    "CONSUMER_PROTOCOL_RULES",
    "PROVIDER_PROTOCOL_RULES",
    "WITNESS_PROTOCOL_RULES",
]
