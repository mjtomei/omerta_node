"""
Base agent classes and context definitions.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from ..engine import Action, Message


@dataclass
class ActionSpec:
    """Description of an available action."""
    name: str
    description: str
    parameters: Dict[str, str]
    preconditions: List[str]


@dataclass
class AgentContext:
    """State information provided to agent for decision-making."""
    agent_id: str
    role: str
    goal: str
    local_chain: Any
    cached_peer_chains: Dict[str, Any]
    pending_messages: List[Message]
    active_transactions: List[Any]
    current_time: float
    available_actions: List[ActionSpec]
    protocol_rules: str


class Agent(ABC):
    """Base class for simulation agents."""

    def __init__(self, agent_id: str, role: str = "unknown", goal: str = ""):
        self.agent_id = agent_id
        self.role = role
        self.goal = goal
        self.pending_messages: List[Message] = []
        self.message_queue: List[Message] = []

    def receive_message(self, message: Message):
        """Receive a message from the network."""
        self.message_queue.append(message)

    @abstractmethod
    def decide_action(self, context: AgentContext) -> Optional[Action]:
        """Decide what action to take given current context."""
        pass

    def get_pending_messages(self) -> List[Message]:
        """Get and clear pending messages."""
        messages = self.message_queue.copy()
        self.message_queue.clear()
        return messages
