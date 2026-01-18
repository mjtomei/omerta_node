"""
Protocol integration module.

Provides adapters to connect the escrow_lock protocol actors
to the simulator framework.
"""

from .adapters import (
    ProtocolAgent,
    ConsumerAgent,
    ProviderAgent,
    WitnessAgent,
)
from .setup import (
    create_protocol_agents_from_trace,
    create_chain_from_spec,
    setup_relationships,
)

__all__ = [
    # Adapters
    "ProtocolAgent",
    "ConsumerAgent",
    "ProviderAgent",
    "WitnessAgent",
    # Setup
    "create_protocol_agents_from_trace",
    "create_chain_from_spec",
    "setup_relationships",
]
