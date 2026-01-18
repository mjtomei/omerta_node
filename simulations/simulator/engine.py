"""
Simulation engine with discrete event simulation.

Contains:
- Event and EventQueue for scheduling
- SimulationClock for time tracking
- SimulationEngine main loop
"""

import heapq
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Callable


@dataclass(order=True)
class Event:
    """An event scheduled to occur at a specific time."""
    time: float
    priority: int = field(compare=True)
    event_type: str = field(compare=False)
    payload: Any = field(compare=False)


class EventQueue:
    """Priority queue of pending events, ordered by time."""

    def __init__(self):
        self._queue: List[Event] = []
        self._counter = 0

    def schedule(self, time: float, event_type: str, payload: Any) -> Event:
        """Schedule an event to occur at the given time."""
        event = Event(time, self._counter, event_type, payload)
        heapq.heappush(self._queue, event)
        self._counter += 1
        return event

    def next_event(self) -> Optional[Event]:
        """Pop and return the next event, or None if queue is empty."""
        if self._queue:
            return heapq.heappop(self._queue)
        return None

    def peek_time(self) -> Optional[float]:
        """Return the time of the next event without removing it."""
        if self._queue:
            return self._queue[0].time
        return None

    def __len__(self) -> int:
        return len(self._queue)

    def is_empty(self) -> bool:
        return len(self._queue) == 0


class SimulationClock:
    """Tracks simulation time and provides timing utilities."""

    def __init__(self, start_time: float = 0.0):
        self.current_time = start_time

    def advance_to(self, time: float):
        """Advance clock to the specified time."""
        assert time >= self.current_time, f"Cannot go backwards in time: {time} < {self.current_time}"
        self.current_time = time

    def elapsed_since(self, past_time: float) -> float:
        """Return time elapsed since a past timestamp."""
        return self.current_time - past_time


@dataclass
class Action:
    """An action taken by an agent."""
    action_type: str
    params: Dict[str, Any] = field(default_factory=dict)


@dataclass
class Message:
    """A message sent between agents."""
    msg_type: str
    sender: str
    payload: Dict[str, Any]
    timestamp: float


@dataclass
class SimulationResult:
    """Results from running a simulation."""
    final_time: float
    event_log: List[Event]
    chain_states: Dict[str, Any]
    message_stats: Dict[str, Any]
    metrics: Dict[str, Any]


class SimulationEngine:
    """Main simulation engine using discrete event simulation."""

    def __init__(self, network: 'NetworkModel', seed: int = 42):
        from .network.model import NetworkModel
        from .network.delivery import MessageDeliverySystem
        from .network.partitions import PartitionManager

        self.network = network
        self.seed = seed
        self.clock = SimulationClock()
        self.event_queue = EventQueue()
        self.message_system = MessageDeliverySystem(network, self.event_queue)
        self.partition_manager = PartitionManager(network, self.event_queue)

        self.agents: Dict[str, Any] = {}
        self.chain_states: Dict[str, Any] = {}
        self.event_log: List[Event] = []
        self.metrics: Dict[str, Any] = {}

        # Event handlers
        self._handlers: Dict[str, Callable] = {
            "message_delivery": self._handle_message_delivery,
            "agent_action": self._handle_agent_action,
            "agent_decision": self._handle_agent_decision,
            "partition_start": self._handle_partition_start,
            "partition_end": self._handle_partition_end,
            "node_offline": self._handle_node_offline,
            "node_online": self._handle_node_online,
        }

    def add_agent(self, agent: Any):
        """Add an agent to the simulation."""
        if agent.agent_id not in self.network.nodes:
            raise ValueError(f"Agent {agent.agent_id} has no corresponding network node")

        self.agents[agent.agent_id] = agent
        self.chain_states[agent.agent_id] = None  # Will be set up by protocol

    def schedule_partition(
        self,
        groups: List[set],
        start_time: float,
        duration: float,
    ):
        """Schedule a network partition."""
        return self.partition_manager.schedule_partition(groups, start_time, duration)

    def schedule_action(self, time: float, agent_id: str, action: Action):
        """Schedule an agent action at a specific time."""
        self.event_queue.schedule(
            time=time,
            event_type="agent_action",
            payload={"agent_id": agent_id, "action": action},
        )

    def run(self, until_time: float) -> SimulationResult:
        """Run simulation until the specified time."""
        while True:
            event = self.event_queue.next_event()

            if event is None:
                break

            if event.time > until_time:
                # Put event back for potential continuation
                self.event_queue.schedule(event.time, event.event_type, event.payload)
                break

            # Advance clock
            self.clock.advance_to(event.time)

            # Process event
            self._process_event(event)

            # Log event
            self.event_log.append(event)

        return SimulationResult(
            final_time=self.clock.current_time,
            event_log=self.event_log,
            chain_states=self.chain_states,
            message_stats=self.message_system.get_delivery_stats(),
            metrics=self.metrics,
        )

    def _process_event(self, event: Event):
        """Process a single event."""
        handler = self._handlers.get(event.event_type)
        if handler:
            handler(event)

    def _handle_message_delivery(self, event: Event):
        """Handle a message being delivered."""
        message_id = event.payload["message_id"]
        pending = self.message_system.deliver_message(message_id)

        if pending:
            # Deliver to recipient agent
            agent = self.agents.get(pending.recipient)
            if agent and hasattr(agent, 'receive_message'):
                agent.receive_message(pending.message)

                # Schedule agent to decide what to do
                self.event_queue.schedule(
                    time=self.clock.current_time,
                    event_type="agent_decision",
                    payload={"agent_id": pending.recipient},
                )

    def _handle_agent_action(self, event: Event):
        """Handle a scheduled agent action."""
        agent_id = event.payload["agent_id"]
        action = event.payload["action"]

        result = self._execute_action(agent_id, action)

        if "actions" not in self.metrics:
            self.metrics["actions"] = []
        self.metrics["actions"].append({
            "time": self.clock.current_time,
            "agent": agent_id,
            "action": action.action_type,
            "result": result,
        })

    def _handle_agent_decision(self, event: Event):
        """Handle an agent deciding what to do."""
        agent_id = event.payload["agent_id"]
        agent = self.agents.get(agent_id)

        if agent and hasattr(agent, 'decide_action'):
            context = self._build_agent_context(agent_id)
            action = agent.decide_action(context)

            if action and action.action_type != "wait":
                self._execute_action(agent_id, action)

    def _handle_partition_start(self, event: Event):
        """Apply a network partition."""
        self.partition_manager.apply_partition(event.payload["partition_id"])

    def _handle_partition_end(self, event: Event):
        """Heal a network partition."""
        self.partition_manager.heal_partition(event.payload["partition_id"])

    def _handle_node_offline(self, event: Event):
        """Take a node offline."""
        node_id = event.payload["node_id"]
        if node_id in self.network.nodes:
            self.network.nodes[node_id].is_online = False

    def _handle_node_online(self, event: Event):
        """Bring a node back online."""
        node_id = event.payload["node_id"]
        if node_id in self.network.nodes:
            self.network.nodes[node_id].is_online = True

    def _execute_action(self, agent_id: str, action: Action) -> Any:
        """Execute an action and return the result."""
        if action.action_type == "send_message":
            message = action.params["message"]
            recipient = action.params["recipient"]

            msg_id = self.message_system.send_message(
                message=message,
                sender=agent_id,
                recipient=recipient,
                current_time=self.clock.current_time,
            )
            return {"status": "sent", "message_id": msg_id}

        elif action.action_type == "broadcast":
            message = action.params["message"]
            recipients = action.params["recipients"]
            msg_ids = []
            for recipient in recipients:
                msg_id = self.message_system.send_message(
                    message=message,
                    sender=agent_id,
                    recipient=recipient,
                    current_time=self.clock.current_time,
                )
                msg_ids.append(msg_id)
            return {"status": "broadcast", "message_ids": msg_ids}

        return {"status": "unknown_action"}

    def _build_agent_context(self, agent_id: str) -> 'AgentContext':
        """Build context for agent decision-making."""
        from .agents.base import AgentContext

        agent = self.agents[agent_id]

        return AgentContext(
            agent_id=agent_id,
            role=getattr(agent, 'role', 'unknown'),
            goal=getattr(agent, 'goal', ''),
            local_chain=self.chain_states.get(agent_id),
            cached_peer_chains={},
            pending_messages=getattr(agent, 'pending_messages', []),
            active_transactions=[],
            current_time=self.clock.current_time,
            available_actions=[],
            protocol_rules="",
        )
