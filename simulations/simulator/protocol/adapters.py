"""
Protocol Adapters

Wraps escrow_lock protocol actors (Consumer, Provider, Witness) to work
with the simulator's Agent interface.

The key difference:
- Protocol actors use: tick(current_time) -> List[Message]
- Simulator agents use: decide_action(context) -> Optional[Action]

These adapters bridge that gap by:
1. Converting protocol messages to simulator actions
2. Translating simulator messages to protocol messages
3. Managing the protocol actor's lifecycle
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from ..agents.base import Agent, AgentContext
from ..engine import Action, Message

# Import protocol actors from generated code
from ...transactions.escrow_lock_generated import (
    Actor as ProtocolActor,
    Consumer, Provider, Witness,
    ConsumerState, ProviderState, WitnessState,
    MessageType as ProtocolMessageType,
    Message as ProtocolMessage,
)
from ...chain.primitives import Chain


@dataclass
class ProtocolAgent(Agent):
    """
    Base adapter that wraps a protocol Actor for use in the simulator.

    Translates between:
    - Protocol messages (ProtocolMessage) <-> Simulator messages (Message)
    - Protocol tick() -> Simulator decide_action()
    """

    agent_id: str
    protocol_actor: ProtocolActor
    message_queue: List[Message] = field(default_factory=list)

    # Track outgoing messages from last tick for routing
    _pending_outgoing: List[ProtocolMessage] = field(default_factory=list)

    def receive_message(self, message: Message):
        """Receive a simulator message and queue it."""
        self.message_queue.append(message)

        # Also translate and forward to protocol actor
        protocol_msg = self._to_protocol_message(message)
        if protocol_msg:
            self.protocol_actor.receive_message(protocol_msg)

    def get_pending_messages(self) -> List[Message]:
        """Get and clear pending simulator messages."""
        messages = self.message_queue.copy()
        self.message_queue.clear()
        return messages

    def decide_action(self, context: AgentContext) -> Optional[Action]:
        """
        Run one tick of the protocol actor and convert to simulator action.

        Returns an Action that encapsulates the protocol messages to send.
        """
        # Run protocol tick
        outgoing = self.protocol_actor.tick(context.current_time)

        if not outgoing:
            return None

        # Store outgoing messages for routing
        self._pending_outgoing = outgoing

        # Return action that represents sending these messages
        return Action(
            action_type="protocol_messages",
            params={
                "messages": [self._from_protocol_message(m) for m in outgoing],
                "actor_state": self._get_state_name(),
            }
        )

    def get_outgoing_protocol_messages(self) -> List[ProtocolMessage]:
        """Get the protocol messages from the last tick."""
        messages = self._pending_outgoing.copy()
        self._pending_outgoing = []
        return messages

    def _to_protocol_message(self, msg: Message) -> Optional[ProtocolMessage]:
        """Convert simulator message to protocol message."""
        # Map simulator message types to protocol message types
        try:
            msg_type = ProtocolMessageType[msg.msg_type]
        except KeyError:
            # Unknown message type
            return None

        return ProtocolMessage(
            msg_type=msg_type,
            sender=msg.sender,
            payload=msg.payload,
            timestamp=msg.timestamp,
        )

    def _from_protocol_message(self, msg: ProtocolMessage) -> Dict[str, Any]:
        """Convert protocol message to serializable dict for Action."""
        return {
            "msg_type": msg.msg_type.name,
            "sender": msg.sender,
            "payload": msg.payload,
            "timestamp": msg.timestamp,
        }

    def _get_state_name(self) -> str:
        """Get the current state name of the protocol actor."""
        if self.protocol_actor.state:
            return self.protocol_actor.state.name
        return "UNKNOWN"

    @property
    def state(self):
        """Get the protocol actor's current state."""
        return self.protocol_actor.state

    def reset(self):
        """Reset the agent state."""
        self.message_queue.clear()
        self._pending_outgoing = []


@dataclass
class ConsumerAgent(ProtocolAgent):
    """Adapter for Consumer protocol actor."""

    def __post_init__(self):
        if not isinstance(self.protocol_actor, Consumer):
            raise TypeError("ConsumerAgent requires a Consumer protocol actor")

    def initiate_lock(self, provider: str, amount: float):
        """Initiate an escrow lock with the provider."""
        self.protocol_actor.initiate_lock(provider, amount)

    @property
    def is_locked(self) -> bool:
        """Check if consumer is in LOCKED state."""
        return self.protocol_actor.state == ConsumerState.LOCKED

    @property
    def is_failed(self) -> bool:
        """Check if consumer is in FAILED state."""
        return self.protocol_actor.state == ConsumerState.FAILED

    @property
    def reject_reason(self) -> Optional[str]:
        """Get the rejection reason if failed."""
        return self.protocol_actor.load("reject_reason")

    @property
    def session_id(self) -> Optional[str]:
        """Get the session ID."""
        return self.protocol_actor.load("session_id")


@dataclass
class ProviderAgent(ProtocolAgent):
    """Adapter for Provider protocol actor."""

    def __post_init__(self):
        if not isinstance(self.protocol_actor, Provider):
            raise TypeError("ProviderAgent requires a Provider protocol actor")

    @property
    def is_in_service_phase(self) -> bool:
        """Check if provider has moved to service phase."""
        return self.protocol_actor.state == ProviderState.SERVICE_PHASE

    @property
    def selected_witnesses(self) -> List[str]:
        """Get the witnesses selected by this provider."""
        return self.protocol_actor.load("witnesses", [])


@dataclass
class WitnessAgent(ProtocolAgent):
    """Adapter for Witness protocol actor."""

    def __post_init__(self):
        if not isinstance(self.protocol_actor, Witness):
            raise TypeError("WitnessAgent requires a Witness protocol actor")

    def set_cached_chain(self, peer_id: str, chain_data: Dict[str, Any]):
        """Set cached chain data for a peer.

        Updates both cached_chains (for chain data) and peer_balances (for balance lookup).
        """
        cached_chains = self.protocol_actor.load("cached_chains", {})
        cached_chains[peer_id] = chain_data
        self.protocol_actor.store("cached_chains", cached_chains)
        # Also update peer_balances for generated code compatibility
        peer_balances = self.protocol_actor.load("peer_balances", {})
        if "balance" in chain_data:
            peer_balances[peer_id] = chain_data["balance"]
            self.protocol_actor.store("peer_balances", peer_balances)

    @property
    def is_escrow_active(self) -> bool:
        """Check if witness has active escrow."""
        return self.protocol_actor.state == WitnessState.ESCROW_ACTIVE

    @property
    def verdict(self) -> Optional[str]:
        """Get the witness's verdict."""
        v = self.protocol_actor.load("verdict")
        return v.value if v else None

    @property
    def observed_balance(self) -> Optional[float]:
        """Get the balance observed by this witness."""
        return self.protocol_actor.load("observed_balance")


def create_protocol_agent(
    agent_id: str,
    role: str,
    chain: Chain,
) -> ProtocolAgent:
    """
    Factory function to create the appropriate protocol agent.

    Args:
        agent_id: Unique identifier for the agent
        role: One of "consumer", "provider", "witness"
        chain: The agent's local chain

    Returns:
        The appropriate ProtocolAgent subclass
    """
    role = role.lower()

    if role == "consumer":
        actor = Consumer(peer_id=agent_id, chain=chain)
        return ConsumerAgent(agent_id=agent_id, protocol_actor=actor)

    elif role == "provider":
        actor = Provider(peer_id=agent_id, chain=chain)
        return ProviderAgent(agent_id=agent_id, protocol_actor=actor)

    elif role == "witness":
        actor = Witness(peer_id=agent_id, chain=chain)
        return WitnessAgent(agent_id=agent_id, protocol_actor=actor)

    else:
        raise ValueError(f"Unknown role: {role}. Must be consumer, provider, or witness")
