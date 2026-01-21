# Chain Simulator Design

**See also:**
- [Protocol Format](FORMAT.md) for state machine DSL and primitives
- [Code Generation](GENERATION.md) for how schemas produce executable actor code
- [Design Philosophy](DESIGN_PHILOSOPHY.md) for why we use this approach

## Goals

1. **Realistic transaction simulation** - Execute sequences of protocol transactions with physically accurate network modeling
2. **Agent-based exploration** - AI-backed agents that discover attacks and edge cases through autonomous interaction
3. **Replayable traces** - Deterministic action sequences that can be replayed for testing and debugging
4. **Attack validation** - Verify that defenses in the protocol spec actually work against documented attacks

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Simulation Engine                        │
│  - Discrete event simulation                                    │
│  - Global simulation clock                                      │
│  - Event priority queue                                         │
│  - Deterministic execution (seeded RNG)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│    Agents     │     │   Network     │     │    Traces     │
│               │     │    Model      │     │               │
│ - AI-backed   │     │ (SimBlock)    │     │ - Recorded    │
│   (dynamic)   │     │               │     │   sequences   │
│ - Trace       │     │ - Regions     │     │ - Assertions  │
│   (replay)    │     │ - Bandwidth   │     │ - Metrics     │
│               │     │ - Partitions  │     │               │
└───────────────┘     └───────────────┘     └───────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              ▼
                    ┌───────────────────┐
                    │   Chain State     │
                    │                   │
                    │ - Per-peer chains │
                    │ - Active escrows  │
                    │ - Trust scores    │
                    └───────────────────┘
```

---

## Core Concepts

### Discrete Event Simulation

The simulator uses a discrete event model where time advances from event to event rather than in fixed ticks. This allows efficient simulation of networks with varying latencies.

```python
@dataclass(order=True)
class Event:
    """An event scheduled to occur at a specific time."""
    time: float                          # When this event occurs
    priority: int = field(compare=True)  # Tie-breaker for same-time events
    event_type: str = field(compare=False)
    payload: Any = field(compare=False)

class EventQueue:
    """Priority queue of pending events, ordered by time."""
    def __init__(self):
        self._queue: List[Event] = []
        self._counter = 0  # For stable sorting

    def schedule(self, time: float, event_type: str, payload: Any):
        """Schedule an event to occur at the given time."""
        event = Event(time, self._counter, event_type, payload)
        heapq.heappush(self._queue, event)
        self._counter += 1

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
```

### Simulation Clock

```python
class SimulationClock:
    """Tracks simulation time and provides timing utilities."""
    def __init__(self, start_time: float = 0.0):
        self.current_time = start_time

    def advance_to(self, time: float):
        """Advance clock to the specified time."""
        assert time >= self.current_time, "Cannot go backwards in time"
        self.current_time = time

    def elapsed_since(self, past_time: float) -> float:
        """Return time elapsed since a past timestamp."""
        return self.current_time - past_time
```

---

## Agent Model

There are exactly two types of agents:

### 1. AI-Backed Agents (Dynamic Behavior)

For any simulation requiring dynamic decision-making, agents are backed by an LLM. The AI receives the current state and chooses actions.

```python
@dataclass
class AgentContext:
    """State information provided to AI for decision-making."""
    agent_id: str
    role: str                           # "consumer", "provider", "witness"
    goal: str                           # e.g., "complete transaction honestly", "steal funds"
    local_chain: Chain
    cached_peer_chains: Dict[str, ChainSummary]
    pending_messages: List[Message]
    active_transactions: List[TransactionState]
    current_time: float

    # Protocol knowledge
    available_actions: List[ActionSpec]
    protocol_rules: str                 # Summary of relevant protocol rules

@dataclass
class ActionSpec:
    """Description of an available action."""
    name: str
    description: str
    parameters: Dict[str, str]          # param_name -> description
    preconditions: List[str]            # What must be true to take this action

class AIBackedAgent:
    """Agent that uses an LLM to decide actions."""

    def __init__(
        self,
        agent_id: str,
        role: str,
        goal: str,
        model: str = "claude-sonnet",
        temperature: float = 0.7,
    ):
        self.agent_id = agent_id
        self.role = role
        self.goal = goal
        self.model = model
        self.temperature = temperature
        self.action_history: List[Tuple[AgentContext, Action, str]] = []

    def decide_action(self, context: AgentContext) -> Action:
        """Query LLM to decide next action."""
        prompt = self._build_prompt(context)
        response = call_llm(
            model=self.model,
            prompt=prompt,
            temperature=self.temperature,
        )
        action = self._parse_action(response)
        reasoning = self._extract_reasoning(response)

        # Record for trace extraction
        self.action_history.append((context, action, reasoning))

        return action

    def _build_prompt(self, context: AgentContext) -> str:
        """Build prompt describing state and requesting action."""
        return f"""You are participating in a distributed transaction protocol simulation.

## Your Identity
- Agent ID: {context.agent_id}
- Role: {context.role}
- Goal: {context.goal}

## Current State
- Time: {context.current_time}
- Pending messages: {len(context.pending_messages)}
- Active transactions: {len(context.active_transactions)}

## Your Local Chain
{self._summarize_chain(context.local_chain)}

## Cached Peer Data
{self._summarize_peer_chains(context.cached_peer_chains)}

## Pending Messages
{self._format_messages(context.pending_messages)}

## Active Transactions
{self._format_transactions(context.active_transactions)}

## Available Actions
{self._format_actions(context.available_actions)}

## Protocol Rules
{context.protocol_rules}

## Instructions
Choose an action to take. Consider your goal and the current state.
Respond with:
1. REASONING: Your thought process
2. ACTION: The action name
3. PARAMETERS: JSON object with action parameters

If no action is needed right now, respond with ACTION: wait
"""
```

### 2. Trace Replay Agents (Deterministic Behavior)

For regression testing and attack validation, agents replay recorded action sequences.

```python
@dataclass
class TraceAction:
    """A single action in a trace."""
    time: float                         # When to execute (relative to trace start)
    actor: str                          # Which agent takes this action
    action: str                         # Action type
    params: Dict[str, Any]              # Action parameters
    expected_result: Optional[str] = None  # For validation

@dataclass
class Trace:
    """A recorded sequence of actions."""
    name: str
    description: str
    setup: TraceSetup                   # Initial conditions
    actions: List[TraceAction]          # Sequence of actions
    assertions: List[Assertion]         # What to check at end

class TraceReplayAgent:
    """Agent that replays a recorded action sequence."""

    def __init__(self, agent_id: str, trace: Trace):
        self.agent_id = agent_id
        self.trace = trace
        self.action_index = 0
        self.trace_start_time: Optional[float] = None

    def decide_action(self, context: AgentContext) -> Optional[Action]:
        """Return next action from trace if it's time, else None."""
        if self.trace_start_time is None:
            self.trace_start_time = context.current_time

        # Find next action for this agent
        while self.action_index < len(self.trace.actions):
            trace_action = self.trace.actions[self.action_index]

            if trace_action.actor != self.agent_id:
                # Not our action, skip
                self.action_index += 1
                continue

            action_time = self.trace_start_time + trace_action.time

            if context.current_time >= action_time:
                # Time to execute this action
                self.action_index += 1
                return Action(
                    action_type=trace_action.action,
                    params=trace_action.params,
                )
            else:
                # Not yet time
                return None

        # No more actions
        return None
```

---

## Network Model (SimBlock-Style)

The network model follows the approach used by [SimBlock](https://arxiv.org/abs/1901.09777), a blockchain
network simulator from Tokyo Institute of Technology. This model uses **region-based parameters**
derived from real-world measurements, providing defensible results without requiring per-link
configuration.

### Design Principles

1. **Region-based latency**: Nodes belong to geographic regions with measured inter-region propagation delays
2. **Endpoint bandwidth**: Each node has upload/download bandwidth based on connection type
3. **Statistical variation**: Latency follows Pareto distribution (matching real-world measurements)
4. **No hop-by-hop simulation**: Single delivery event per message (sufficient for protocol-level analysis)
5. **Measured parameters**: All defaults from empirical network measurements

### Delay Formula

```
total_delay = propagation_delay + transmission_delay

where:
  propagation_delay = sample from Pareto(mean=inter_region_latency, variance=20%)
  transmission_delay = message_size_bytes / effective_bandwidth
  effective_bandwidth = min(sender.upload_bps, receiver.download_bps)
```

### Region Configuration

```python
from enum import Enum
from dataclasses import dataclass
from typing import Dict, Optional
import random
import math

class Region(Enum):
    """Geographic regions with measured network parameters.

    Based on SimBlock's region model with parameters from real Bitcoin network measurements.
    """
    NORTH_AMERICA = "north_america"
    EUROPE = "europe"
    ASIA = "asia"
    JAPAN = "japan"
    AUSTRALIA = "australia"
    SOUTH_AMERICA = "south_america"

# Inter-region propagation delays in milliseconds (one-way)
# Source: SimBlock paper, based on Bitcoin network measurements circa 2019
# These represent the BASE latency - actual latency will vary with Pareto distribution
INTER_REGION_LATENCY_MS: Dict[tuple, float] = {
    # Same region
    (Region.NORTH_AMERICA, Region.NORTH_AMERICA): 32,
    (Region.EUROPE, Region.EUROPE): 12,
    (Region.ASIA, Region.ASIA): 70,
    (Region.JAPAN, Region.JAPAN): 2,
    (Region.AUSTRALIA, Region.AUSTRALIA): 56,
    (Region.SOUTH_AMERICA, Region.SOUTH_AMERICA): 85,

    # Cross-region (symmetric)
    (Region.NORTH_AMERICA, Region.EUROPE): 124,
    (Region.NORTH_AMERICA, Region.ASIA): 252,
    (Region.NORTH_AMERICA, Region.JAPAN): 151,
    (Region.NORTH_AMERICA, Region.AUSTRALIA): 189,
    (Region.NORTH_AMERICA, Region.SOUTH_AMERICA): 162,

    (Region.EUROPE, Region.ASIA): 268,
    (Region.EUROPE, Region.JAPAN): 287,
    (Region.EUROPE, Region.AUSTRALIA): 350,
    (Region.EUROPE, Region.SOUTH_AMERICA): 221,

    (Region.ASIA, Region.JAPAN): 42,
    (Region.ASIA, Region.AUSTRALIA): 120,
    (Region.ASIA, Region.SOUTH_AMERICA): 340,

    (Region.JAPAN, Region.AUSTRALIA): 130,
    (Region.JAPAN, Region.SOUTH_AMERICA): 290,

    (Region.AUSTRALIA, Region.SOUTH_AMERICA): 322,
}

def get_inter_region_latency(region_a: Region, region_b: Region) -> float:
    """Get base latency between two regions (symmetric)."""
    key = (region_a, region_b)
    if key in INTER_REGION_LATENCY_MS:
        return INTER_REGION_LATENCY_MS[key]
    # Try reversed
    key = (region_b, region_a)
    if key in INTER_REGION_LATENCY_MS:
        return INTER_REGION_LATENCY_MS[key]
    raise ValueError(f"No latency data for {region_a} <-> {region_b}")
```

### Connection Types

```python
@dataclass
class ConnectionType:
    """Network connection characteristics for a node.

    Bandwidth values based on typical real-world connections.
    """
    name: str
    upload_mbps: float          # Upload bandwidth
    download_mbps: float        # Download bandwidth
    added_latency_ms: float     # Additional latency from last-mile connection
    packet_loss_rate: float     # Probability of message drop

CONNECTION_TYPES: Dict[str, ConnectionType] = {
    # Datacenter / cloud
    "datacenter": ConnectionType(
        name="Datacenter",
        upload_mbps=10000,      # 10 Gbps
        download_mbps=10000,
        added_latency_ms=1,
        packet_loss_rate=0.0001,
    ),

    # Residential fiber
    "fiber": ConnectionType(
        name="Residential Fiber",
        upload_mbps=1000,       # 1 Gbps symmetric
        download_mbps=1000,
        added_latency_ms=2,
        packet_loss_rate=0.0005,
    ),

    # Cable internet (asymmetric)
    "cable": ConnectionType(
        name="Cable Internet",
        upload_mbps=20,         # Typical cable upload
        download_mbps=200,      # Typical cable download
        added_latency_ms=10,
        packet_loss_rate=0.001,
    ),

    # DSL (asymmetric, slower)
    "dsl": ConnectionType(
        name="DSL",
        upload_mbps=5,
        download_mbps=50,
        added_latency_ms=15,
        packet_loss_rate=0.005,
    ),

    # Mobile 4G LTE
    "4g_lte": ConnectionType(
        name="4G LTE",
        upload_mbps=10,
        download_mbps=50,
        added_latency_ms=40,
        packet_loss_rate=0.02,
    ),

    # Mobile 5G
    "5g": ConnectionType(
        name="5G",
        upload_mbps=100,
        download_mbps=500,
        added_latency_ms=10,
        packet_loss_rate=0.005,
    ),

    # Satellite (LEO - Starlink style)
    "satellite_leo": ConnectionType(
        name="LEO Satellite",
        upload_mbps=20,
        download_mbps=100,
        added_latency_ms=25,    # Additional to orbital latency
        packet_loss_rate=0.01,
    ),

    # Satellite (GEO - traditional)
    "satellite_geo": ConnectionType(
        name="GEO Satellite",
        upload_mbps=5,
        download_mbps=25,
        added_latency_ms=600,   # ~36000km orbital latency
        packet_loss_rate=0.02,
    ),
}
```

### Network Node

```python
@dataclass
class NetworkNode:
    """A node in the network with region and connection properties."""
    node_id: str
    region: Region
    connection_type: str            # Key into CONNECTION_TYPES

    # State
    is_online: bool = True          # For simulating node failures

    @property
    def connection(self) -> ConnectionType:
        return CONNECTION_TYPES[self.connection_type]

    @property
    def upload_bps(self) -> float:
        """Upload bandwidth in bits per second."""
        return self.connection.upload_mbps * 1_000_000

    @property
    def download_bps(self) -> float:
        """Download bandwidth in bits per second."""
        return self.connection.download_mbps * 1_000_000
```

### Latency Calculation

```python
def sample_pareto(mean: float, rng: random.Random, shape: float = 5.0) -> float:
    """Sample from Pareto distribution with given mean.

    SimBlock uses Pareto distribution with ~20% variance around the mean.
    Shape parameter of 5 gives variance ≈ mean/4, matching their model.

    Pareto is heavy-tailed, which matches real network latency distributions
    where most packets arrive near the mean but some are significantly delayed.
    """
    # For Pareto with shape α > 1: mean = α * x_min / (α - 1)
    # So x_min = mean * (α - 1) / α
    if shape <= 1:
        shape = 5.0  # Ensure valid shape
    x_min = mean * (shape - 1) / shape

    # Sample using inverse transform
    u = rng.random()
    return x_min / (u ** (1 / shape))

class NetworkModel:
    """SimBlock-style network model with region-based latency."""

    def __init__(self, seed: int = 42):
        self.rng = random.Random(seed)
        self.nodes: Dict[str, NetworkNode] = {}

        # Partition state: set of (node_a, node_b) pairs that cannot communicate
        self.blocked_pairs: set = set()

    def add_node(self, node: NetworkNode):
        """Add a node to the network."""
        self.nodes[node.node_id] = node

    def compute_latency(
        self,
        sender_id: str,
        recipient_id: str,
        message_size_bytes: int,
    ) -> tuple[float, bool]:
        """
        Compute message delivery latency.

        Returns: (latency_ms, was_dropped)
        """
        sender = self.nodes.get(sender_id)
        recipient = self.nodes.get(recipient_id)

        if sender is None or recipient is None:
            return (float('inf'), True)

        if not sender.is_online or not recipient.is_online:
            return (float('inf'), True)

        # Check for partition
        pair = tuple(sorted([sender_id, recipient_id]))
        if pair in self.blocked_pairs:
            return (float('inf'), True)

        # Check for packet loss
        loss_rate = max(sender.connection.packet_loss_rate,
                        recipient.connection.packet_loss_rate)
        if self.rng.random() < loss_rate:
            return (0, True)  # Dropped

        # 1. Propagation delay (inter-region + last-mile)
        base_latency = get_inter_region_latency(sender.region, recipient.region)
        propagation_ms = sample_pareto(base_latency, self.rng)

        # Add last-mile latency from both endpoints
        propagation_ms += sender.connection.added_latency_ms
        propagation_ms += recipient.connection.added_latency_ms

        # 2. Transmission delay = size / bandwidth
        # Bandwidth limited by slowest link (sender upload or receiver download)
        effective_bps = min(sender.upload_bps, recipient.download_bps)
        message_bits = message_size_bytes * 8
        transmission_ms = (message_bits / effective_bps) * 1000

        total_latency_ms = propagation_ms + transmission_ms

        return (total_latency_ms, False)

    def block_communication(self, node_a: str, node_b: str):
        """Block communication between two nodes (for partition simulation)."""
        pair = tuple(sorted([node_a, node_b]))
        self.blocked_pairs.add(pair)

    def unblock_communication(self, node_a: str, node_b: str):
        """Restore communication between two nodes."""
        pair = tuple(sorted([node_a, node_b]))
        self.blocked_pairs.discard(pair)

    def partition_network(self, groups: list[set[str]]):
        """Create a network partition where only nodes in the same group can communicate."""
        # Block all cross-group pairs
        all_nodes = set(self.nodes.keys())
        for i, group_a in enumerate(groups):
            for group_b in groups[i+1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.block_communication(node_a, node_b)

    def heal_partition(self):
        """Remove all partition blocks."""
        self.blocked_pairs.clear()
```

### Node Distribution Templates

```python
# Default node distribution by region (based on Bitcoin network circa 2019)
DEFAULT_REGION_DISTRIBUTION = {
    Region.NORTH_AMERICA: 0.35,
    Region.EUROPE: 0.38,
    Region.ASIA: 0.12,
    Region.JAPAN: 0.05,
    Region.AUSTRALIA: 0.05,
    Region.SOUTH_AMERICA: 0.05,
}

# Default connection type distribution
DEFAULT_CONNECTION_DISTRIBUTION = {
    "datacenter": 0.10,    # 10% are well-connected servers
    "fiber": 0.25,         # 25% have residential fiber
    "cable": 0.40,         # 40% on cable internet
    "dsl": 0.15,           # 15% on DSL
    "4g_lte": 0.08,        # 8% on mobile
    "5g": 0.02,            # 2% on 5G
}

def create_network(
    num_nodes: int,
    region_distribution: Dict[Region, float] = None,
    connection_distribution: Dict[str, float] = None,
    seed: int = 42,
) -> NetworkModel:
    """Create a network with nodes distributed across regions and connection types.

    Args:
        num_nodes: Total number of nodes to create
        region_distribution: Probability of each region (must sum to 1)
        connection_distribution: Probability of each connection type (must sum to 1)
        seed: Random seed for reproducibility

    Returns:
        NetworkModel with nodes created according to distributions
    """
    rng = random.Random(seed)
    network = NetworkModel(seed=seed)

    region_dist = region_distribution or DEFAULT_REGION_DISTRIBUTION
    conn_dist = connection_distribution or DEFAULT_CONNECTION_DISTRIBUTION

    regions = list(region_dist.keys())
    region_weights = list(region_dist.values())

    conn_types = list(conn_dist.keys())
    conn_weights = list(conn_dist.values())

    for i in range(num_nodes):
        # Sample region and connection type
        region = rng.choices(regions, weights=region_weights)[0]
        conn_type = rng.choices(conn_types, weights=conn_weights)[0]

        node = NetworkNode(
            node_id=f"node_{i}",
            region=region,
            connection_type=conn_type,
        )
        network.add_node(node)

    return network

def create_specific_network(
    nodes: list[tuple[str, Region, str]],  # (id, region, connection_type)
    seed: int = 42,
) -> NetworkModel:
    """Create a network with specific node configurations.

    Useful for traces where exact node properties matter.
    """
    network = NetworkModel(seed=seed)

    for node_id, region, conn_type in nodes:
        node = NetworkNode(
            node_id=node_id,
            region=region,
            connection_type=conn_type,
        )
        network.add_node(node)

    return network
```

### Example Latency Values

For reference, here are typical end-to-end latencies for a 1KB message:

| Sender | Recipient | Connection | Expected Latency |
|--------|-----------|------------|------------------|
| NA datacenter | NA datacenter | datacenter-datacenter | ~35ms |
| EU fiber | EU fiber | fiber-fiber | ~18ms |
| NA cable | EU fiber | cable-fiber | ~150ms |
| Asia cable | NA cable | cable-cable | ~280ms |
| NA datacenter | Australia cable | datacenter-cable | ~210ms |

Large messages (1MB+) will be dominated by transmission delay on slow connections:
- 1MB over cable upload (20 Mbps): +400ms
- 1MB over datacenter (10 Gbps): +0.8ms

---

## Message Delivery System

Messages are delivered through the network with realistic timing computed by the NetworkModel.

```python
@dataclass
class PendingMessage:
    """A message in transit through the network."""
    message_id: str
    message: Message
    sender: str
    recipient: str
    send_time: float
    scheduled_delivery_time: float
    latency_ms: float                   # Actual latency for this message
    dropped: bool = False
    drop_reason: Optional[str] = None

class MessageDeliverySystem:
    """Handles message transmission through the SimBlock-style network model."""

    def __init__(
        self,
        network: NetworkModel,
        event_queue: EventQueue,
    ):
        self.network = network
        self.event_queue = event_queue
        self.pending_messages: Dict[str, PendingMessage] = {}
        self.delivered_messages: List[PendingMessage] = []
        self.dropped_messages: List[PendingMessage] = []
        self._message_counter = 0

    def send_message(
        self,
        message: Message,
        sender: str,
        recipient: str,
        current_time: float,
    ) -> str:
        """
        Send a message through the network.

        Computes latency using SimBlock-style model:
        - Propagation delay from inter-region latency (Pareto distributed)
        - Transmission delay from message size and bandwidth
        - Bandwidth = min(sender.upload, recipient.download)

        Returns message_id for tracking.
        """
        message_id = f"msg_{self._message_counter}"
        self._message_counter += 1

        # Compute message size (simplified - could use proper serialization)
        message_size_bytes = len(str(message))

        # Get latency from network model
        latency_ms, dropped = self.network.compute_latency(
            sender, recipient, message_size_bytes
        )

        # Determine drop reason if applicable
        drop_reason = None
        if dropped:
            sender_node = self.network.nodes.get(sender)
            recipient_node = self.network.nodes.get(recipient)
            if sender_node is None or recipient_node is None:
                drop_reason = "unknown_node"
            elif not sender_node.is_online:
                drop_reason = "sender_offline"
            elif not recipient_node.is_online:
                drop_reason = "recipient_offline"
            elif tuple(sorted([sender, recipient])) in self.network.blocked_pairs:
                drop_reason = "network_partition"
            else:
                drop_reason = "packet_loss"

        pending = PendingMessage(
            message_id=message_id,
            message=message,
            sender=sender,
            recipient=recipient,
            send_time=current_time,
            scheduled_delivery_time=current_time + latency_ms / 1000,  # Convert to seconds
            latency_ms=latency_ms,
            dropped=dropped,
            drop_reason=drop_reason,
        )

        if dropped:
            self.dropped_messages.append(pending)
        else:
            self.pending_messages[message_id] = pending
            # Schedule delivery event
            self.event_queue.schedule(
                time=pending.scheduled_delivery_time,
                event_type="message_delivery",
                payload={"message_id": message_id},
            )

        return message_id

    def deliver_message(self, message_id: str) -> Optional[PendingMessage]:
        """
        Complete delivery of a message.
        Called when the delivery event fires.
        """
        if message_id not in self.pending_messages:
            return None

        pending = self.pending_messages.pop(message_id)
        self.delivered_messages.append(pending)
        return pending

    def get_delivery_stats(self) -> Dict[str, Any]:
        """Return statistics about message delivery."""
        delivered_latencies = [m.latency_ms for m in self.delivered_messages]

        # Group by drop reason
        drop_reasons = {}
        for m in self.dropped_messages:
            reason = m.drop_reason or "unknown"
            drop_reasons[reason] = drop_reasons.get(reason, 0) + 1

        return {
            "total_sent": len(self.delivered_messages) + len(self.dropped_messages),
            "total_delivered": len(self.delivered_messages),
            "total_dropped": len(self.dropped_messages),
            "drop_rate": len(self.dropped_messages) / max(1, len(self.delivered_messages) + len(self.dropped_messages)),
            "drop_reasons": drop_reasons,
            "latency_ms": {
                "avg": sum(delivered_latencies) / max(1, len(delivered_latencies)),
                "max": max(delivered_latencies) if delivered_latencies else 0,
                "min": min(delivered_latencies) if delivered_latencies else 0,
                "p50": sorted(delivered_latencies)[len(delivered_latencies)//2] if delivered_latencies else 0,
                "p95": sorted(delivered_latencies)[int(len(delivered_latencies)*0.95)] if delivered_latencies else 0,
            },
        }
```

---

## Network Partitions

Network partitions are managed through scheduled events that modify the NetworkModel's blocked_pairs.

```python
@dataclass
class NetworkPartition:
    """A scheduled network partition."""
    partition_id: str
    groups: List[Set[str]]              # Groups that can communicate internally
    start_time: float
    end_time: float
    is_active: bool = False

class PartitionManager:
    """Manages network partitions over time using scheduled events."""

    def __init__(self, network: NetworkModel, event_queue: EventQueue):
        self.network = network
        self.event_queue = event_queue
        self.partitions: List[NetworkPartition] = []

    def schedule_partition(
        self,
        groups: List[Set[str]],
        start_time: float,
        duration: float,
    ) -> NetworkPartition:
        """Schedule a network partition to occur at a future time.

        Args:
            groups: List of node sets. Nodes within a group can communicate;
                    nodes in different groups cannot.
            start_time: When the partition begins (simulation time)
            duration: How long the partition lasts

        Returns:
            The created NetworkPartition object
        """
        partition = NetworkPartition(
            partition_id=f"partition_{len(self.partitions)}",
            groups=groups,
            start_time=start_time,
            end_time=start_time + duration,
        )
        self.partitions.append(partition)

        # Schedule start and end events
        self.event_queue.schedule(
            time=start_time,
            event_type="partition_start",
            payload={"partition_id": partition.partition_id},
        )
        self.event_queue.schedule(
            time=start_time + duration,
            event_type="partition_end",
            payload={"partition_id": partition.partition_id},
        )

        return partition

    def apply_partition(self, partition_id: str):
        """Apply a partition (called when partition_start event fires)."""
        partition = next((p for p in self.partitions if p.partition_id == partition_id), None)
        if partition is None:
            return

        partition.is_active = True

        # Block all cross-group pairs
        for i, group_a in enumerate(partition.groups):
            for group_b in partition.groups[i+1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.network.block_communication(node_a, node_b)

    def heal_partition(self, partition_id: str):
        """Heal a partition (called when partition_end event fires)."""
        partition = next((p for p in self.partitions if p.partition_id == partition_id), None)
        if partition is None:
            return

        partition.is_active = False

        # Unblock all cross-group pairs
        for i, group_a in enumerate(partition.groups):
            for group_b in partition.groups[i+1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.network.unblock_communication(node_a, node_b)

    def get_active_partitions(self) -> List[NetworkPartition]:
        """Return currently active partitions."""
        return [p for p in self.partitions if p.is_active]
```

---

## Simulation Engine

```python
@dataclass
class SimulationResult:
    """Results from running a simulation."""
    final_time: float
    event_log: List[Event]
    chain_states: Dict[str, Chain]
    message_stats: Dict[str, Any]
    metrics: Dict[str, Any]

class SimulationEngine:
    """Main simulation engine using discrete event simulation with SimBlock-style network."""

    def __init__(
        self,
        network: NetworkModel,
        seed: int = 42,
    ):
        self.network = network
        self.seed = seed
        self.clock = SimulationClock()
        self.event_queue = EventQueue()
        self.message_system = MessageDeliverySystem(network, self.event_queue)
        self.partition_manager = PartitionManager(network, self.event_queue)

        self.agents: Dict[str, Agent] = {}
        self.chain_states: Dict[str, Chain] = {}
        self.event_log: List[Event] = []
        self.metrics: Dict[str, Any] = {}

    def add_agent(self, agent: Agent):
        """Add an agent to the simulation.

        The agent's node must already exist in the network model.
        """
        if agent.agent_id not in self.network.nodes:
            raise ValueError(f"Agent {agent.agent_id} has no corresponding network node")

        self.agents[agent.agent_id] = agent
        # Initialize chain state
        self.chain_states[agent.agent_id] = Chain(agent.agent_id)

    def schedule_partition(
        self,
        groups: List[Set[str]],
        start_time: float,
        duration: float,
    ) -> NetworkPartition:
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
        if event.event_type == "message_delivery":
            self._handle_message_delivery(event)
        elif event.event_type == "agent_action":
            self._handle_agent_action(event)
        elif event.event_type == "agent_decision":
            self._handle_agent_decision(event)
        elif event.event_type == "partition_start":
            self.partition_manager.apply_partition(event.payload["partition_id"])
        elif event.event_type == "partition_end":
            self.partition_manager.heal_partition(event.payload["partition_id"])
        elif event.event_type == "node_offline":
            self._handle_node_offline(event)
        elif event.event_type == "node_online":
            self._handle_node_online(event)

    def _handle_message_delivery(self, event: Event):
        """Handle a message being delivered."""
        message_id = event.payload["message_id"]
        pending = self.message_system.deliver_message(message_id)

        if pending:
            # Deliver to recipient agent
            agent = self.agents.get(pending.recipient)
            if agent:
                agent.receive_message(pending.message)

                # Schedule agent to decide what to do (immediate)
                self.event_queue.schedule(
                    time=self.clock.current_time,
                    event_type="agent_decision",
                    payload={"agent_id": pending.recipient},
                )

    def _handle_agent_action(self, event: Event):
        """Handle a scheduled agent action."""
        agent_id = event.payload["agent_id"]
        action = event.payload["action"]

        # Execute action
        result = self._execute_action(agent_id, action)

        # Record result in metrics
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

        if agent:
            context = self._build_agent_context(agent_id)
            action = agent.decide_action(context)

            if action and action.action_type != "wait":
                self._execute_action(agent_id, action)

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
            # Send a message through the network
            message = action.params["message"]
            recipient = action.params["recipient"]

            msg_id = self.message_system.send_message(
                message=message,
                sender=agent_id,
                recipient=recipient,
                current_time=self.clock.current_time,
            )
            return {"status": "sent", "message_id": msg_id}

        elif action.action_type == "append_block":
            # Append a block to the agent's chain
            block = action.params["block"]
            chain = self.chain_states[agent_id]
            chain.append(block)
            return {"status": "appended", "new_head": chain.head_hash}

        elif action.action_type == "broadcast":
            # Send message to multiple recipients
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

    def _build_agent_context(self, agent_id: str) -> AgentContext:
        """Build context for agent decision-making."""
        agent = self.agents[agent_id]
        node = self.network.nodes.get(agent_id)

        return AgentContext(
            agent_id=agent_id,
            role=agent.role,
            goal=agent.goal,
            local_chain=self.chain_states[agent_id],
            cached_peer_chains={},  # Would be populated from chain state
            pending_messages=agent.pending_messages,
            active_transactions=[],  # Would track active transaction states
            current_time=self.clock.current_time,
            available_actions=self._get_available_actions(agent_id),
            protocol_rules="",  # Would include relevant protocol rules
        )

    def _get_available_actions(self, agent_id: str) -> List[ActionSpec]:
        """Get available actions for an agent based on current state."""
        # Base actions available to all agents
        actions = [
            ActionSpec(
                name="send_message",
                description="Send a message to another node",
                parameters={"recipient": "node_id", "message": "Message object"},
                preconditions=["recipient exists", "sender is online"],
            ),
            ActionSpec(
                name="broadcast",
                description="Send a message to multiple nodes",
                parameters={"recipients": "list of node_ids", "message": "Message object"},
                preconditions=["recipients exist", "sender is online"],
            ),
            ActionSpec(
                name="wait",
                description="Do nothing this turn",
                parameters={},
                preconditions=[],
            ),
        ]
        return actions
```

---

## Trace Format

Traces are recorded action sequences that can be replayed deterministically. The network
configuration uses the SimBlock-style region/connection model.

```yaml
# traces/attacks/double_spend_basic.yaml
name: "double_spend_basic"
description: "Consumer attempts to lock same funds with two providers simultaneously"

# Network setup using SimBlock-style model
network:
  seed: 42  # For reproducible latency sampling
  nodes:
    - id: consumer
      region: north_america
      connection: cable
    - id: provider_a
      region: north_america
      connection: datacenter
    - id: provider_b
      region: europe
      connection: datacenter
    - id: witness_1
      region: north_america
      connection: fiber
    - id: witness_2
      region: europe
      connection: fiber
    - id: witness_3
      region: asia
      connection: cable

  # Optional: scheduled partitions
  partitions:
    - groups: [[consumer, provider_a, witness_1], [provider_b, witness_2, witness_3]]
      start_time: 50.0
      duration: 10.0

# Initial chain state
setup:
  chains:
    consumer:
      balance: 100
      trust: 1.0
    provider_a:
      trust: 2.0
    provider_b:
      trust: 2.0
    witness_1:
      trust: 2.0
    witness_2:
      trust: 2.0
    witness_3:
      trust: 2.0

  # Pre-established relationships (keepalive history)
  relationships:
    - peers: [consumer, provider_a, provider_b]
      age_days: 30
    - peers: [witness_1, witness_2, witness_3, provider_a, provider_b]
      age_days: 100

# Action sequence
actions:
  - time: 0.0
    actor: consumer
    action: initiate_lock
    params:
      provider: provider_a
      amount: 80

  - time: 0.001  # 1ms later - nearly simultaneous
    actor: consumer
    action: initiate_lock
    params:
      provider: provider_b
      amount: 80

  # Let the protocol run...
  # Network latency will cause these to arrive at different times:
  # - consumer -> provider_a: ~35ms (same region, cable to datacenter)
  # - consumer -> provider_b: ~150ms (cross-region NA->EU)

# What to verify at the end
assertions:
  - type: at_most_one_lock
    description: "Only one lock should succeed"
    consumer: consumer

  - type: double_spend_detected
    description: "The double-spend attempt should be detected"
    consumer: consumer

  - type: trust_penalty_applied
    description: "Consumer's trust should decrease"
    consumer: consumer
    min_penalty: 0.5

  - type: message_latency_realistic
    description: "Cross-region messages should have expected latency"
    min_latency_ms: 100   # NA-EU minimum
    max_latency_ms: 500   # With Pareto tail
```

---

## Implementation Plan

Each phase includes specific tests that must pass before proceeding to the next phase.

### Phase 1: Core Infrastructure

**Goal**: Implement the discrete event simulation engine with SimBlock-style network model.

#### 1.1 EventQueue and SimulationClock

- [ ] Implement `EventQueue` with heap-based priority queue
- [ ] Implement `SimulationClock` with time advancement

**Tests (test_event_queue.py)**:

```python
class TestEventQueue:
    def test_events_ordered_by_time(self):
        """Events are returned in time order."""
        q = EventQueue()
        q.schedule(time=10.0, event_type="b", payload={})
        q.schedule(time=5.0, event_type="a", payload={})
        q.schedule(time=15.0, event_type="c", payload={})

        assert q.next_event().event_type == "a"
        assert q.next_event().event_type == "b"
        assert q.next_event().event_type == "c"

    def test_same_time_events_stable_order(self):
        """Events at same time maintain insertion order."""
        q = EventQueue()
        q.schedule(time=10.0, event_type="first", payload={})
        q.schedule(time=10.0, event_type="second", payload={})

        assert q.next_event().event_type == "first"
        assert q.next_event().event_type == "second"

    def test_peek_time_does_not_remove(self):
        """peek_time returns next time without removing event."""
        q = EventQueue()
        q.schedule(time=5.0, event_type="a", payload={})

        assert q.peek_time() == 5.0
        assert q.peek_time() == 5.0  # Still there
        assert q.next_event() is not None

    def test_empty_queue_returns_none(self):
        """Empty queue returns None."""
        q = EventQueue()
        assert q.next_event() is None
        assert q.peek_time() is None

class TestSimulationClock:
    def test_clock_advances(self):
        """Clock advances to specified time."""
        clock = SimulationClock(start_time=0.0)
        clock.advance_to(100.0)
        assert clock.current_time == 100.0

    def test_clock_rejects_backwards(self):
        """Clock cannot go backwards."""
        clock = SimulationClock(start_time=100.0)
        with pytest.raises(AssertionError):
            clock.advance_to(50.0)

    def test_elapsed_since(self):
        """elapsed_since calculates correctly."""
        clock = SimulationClock(start_time=0.0)
        clock.advance_to(150.0)
        assert clock.elapsed_since(100.0) == 50.0
```

#### 1.2 Network Model (Regions and Connections)

- [ ] Implement `Region` enum with 6 geographic regions
- [ ] Implement `INTER_REGION_LATENCY_MS` lookup table
- [ ] Implement `ConnectionType` dataclass
- [ ] Implement `CONNECTION_TYPES` presets
- [ ] Implement `NetworkNode` dataclass

**Tests (test_network_regions.py)**:

```python
class TestRegions:
    def test_all_region_pairs_have_latency(self):
        """Every region pair has a defined latency."""
        for r1 in Region:
            for r2 in Region:
                latency = get_inter_region_latency(r1, r2)
                assert latency > 0
                assert latency < 1000  # Sanity check: < 1 second

    def test_latency_is_symmetric(self):
        """Latency A->B equals B->A."""
        for r1 in Region:
            for r2 in Region:
                assert get_inter_region_latency(r1, r2) == get_inter_region_latency(r2, r1)

    def test_same_region_faster_than_cross_region(self):
        """Intra-region latency is less than inter-region."""
        for r in Region:
            intra = get_inter_region_latency(r, r)
            for r2 in Region:
                if r != r2:
                    inter = get_inter_region_latency(r, r2)
                    assert intra < inter, f"{r} intra should be < {r}->{r2}"

    def test_known_latency_values(self):
        """Spot check known values from SimBlock paper."""
        assert get_inter_region_latency(Region.NORTH_AMERICA, Region.NORTH_AMERICA) == 32
        assert get_inter_region_latency(Region.EUROPE, Region.EUROPE) == 12
        assert get_inter_region_latency(Region.NORTH_AMERICA, Region.EUROPE) == 124

class TestConnectionTypes:
    def test_all_connection_types_exist(self):
        """All expected connection types are defined."""
        expected = ["datacenter", "fiber", "cable", "dsl", "4g_lte", "5g", "satellite_leo", "satellite_geo"]
        for conn in expected:
            assert conn in CONNECTION_TYPES

    def test_datacenter_fastest(self):
        """Datacenter has highest bandwidth."""
        dc = CONNECTION_TYPES["datacenter"]
        for name, conn in CONNECTION_TYPES.items():
            if name != "datacenter":
                assert dc.upload_mbps >= conn.upload_mbps
                assert dc.download_mbps >= conn.download_mbps

    def test_satellite_geo_highest_latency(self):
        """GEO satellite has highest added latency."""
        geo = CONNECTION_TYPES["satellite_geo"]
        for name, conn in CONNECTION_TYPES.items():
            assert geo.added_latency_ms >= conn.added_latency_ms

class TestNetworkNode:
    def test_node_bandwidth_conversion(self):
        """Node converts Mbps to bps correctly."""
        node = NetworkNode(node_id="test", region=Region.NORTH_AMERICA, connection_type="fiber")
        assert node.upload_bps == 1000 * 1_000_000  # 1 Gbps
        assert node.download_bps == 1000 * 1_000_000
```

#### 1.3 Latency Calculation and Pareto Distribution

- [ ] Implement `sample_pareto(mean, rng, shape)` function
- [ ] Implement `NetworkModel.compute_latency()` method

**Tests (test_latency.py)**:

```python
class TestParetoSampling:
    def test_pareto_mean_approximates_input(self):
        """Pareto samples have mean approximately equal to input."""
        rng = random.Random(42)
        samples = [sample_pareto(100.0, rng) for _ in range(10000)]
        mean = sum(samples) / len(samples)
        assert 90.0 < mean < 110.0  # Within 10% of target

    def test_pareto_always_positive(self):
        """Pareto samples are always positive."""
        rng = random.Random(42)
        for _ in range(1000):
            assert sample_pareto(50.0, rng) > 0

    def test_pareto_has_tail(self):
        """Pareto distribution has heavy tail (some values >> mean)."""
        rng = random.Random(42)
        samples = [sample_pareto(100.0, rng) for _ in range(10000)]
        max_sample = max(samples)
        assert max_sample > 150.0  # At least 1.5x mean in tail

    def test_pareto_deterministic_with_seed(self):
        """Same seed produces same samples."""
        samples1 = [sample_pareto(100.0, random.Random(42)) for _ in range(10)]
        samples2 = [sample_pareto(100.0, random.Random(42)) for _ in range(10)]
        assert samples1 == samples2

class TestNetworkModelLatency:
    @pytest.fixture
    def network(self):
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("na_dc", Region.NORTH_AMERICA, "datacenter"))
        net.add_node(NetworkNode("na_cable", Region.NORTH_AMERICA, "cable"))
        net.add_node(NetworkNode("eu_fiber", Region.EUROPE, "fiber"))
        net.add_node(NetworkNode("asia_dsl", Region.ASIA, "dsl"))
        return net

    def test_same_region_datacenter_fast(self, network):
        """Same-region datacenter-to-datacenter is fast."""
        network.add_node(NetworkNode("na_dc2", Region.NORTH_AMERICA, "datacenter"))
        latency, dropped = network.compute_latency("na_dc", "na_dc2", 1024)
        assert not dropped
        assert latency < 50  # < 50ms for same region DC

    def test_cross_region_slower(self, network):
        """Cross-region is slower than same-region."""
        same_region, _ = network.compute_latency("na_dc", "na_cable", 1024)
        cross_region, _ = network.compute_latency("na_dc", "eu_fiber", 1024)
        assert cross_region > same_region

    def test_large_message_bandwidth_limited(self, network):
        """Large messages are limited by bandwidth."""
        small_latency, _ = network.compute_latency("na_cable", "eu_fiber", 1024)  # 1KB
        large_latency, _ = network.compute_latency("na_cable", "eu_fiber", 1024 * 1024)  # 1MB

        # 1MB over 20Mbps upload = ~400ms transmission time
        assert large_latency > small_latency + 300  # At least 300ms more

    def test_unknown_node_returns_dropped(self, network):
        """Unknown node returns infinite latency and dropped=True."""
        latency, dropped = network.compute_latency("na_dc", "unknown", 1024)
        assert dropped
        assert latency == float('inf')

    def test_offline_node_returns_dropped(self, network):
        """Offline node returns dropped=True."""
        network.nodes["na_dc"].is_online = False
        latency, dropped = network.compute_latency("na_dc", "na_cable", 1024)
        assert dropped

    def test_packet_loss_occurs(self, network):
        """Some messages are dropped due to packet loss."""
        # DSL has higher packet loss
        dropped_count = 0
        for _ in range(1000):
            _, dropped = network.compute_latency("asia_dsl", "na_cable", 1024)
            if dropped:
                dropped_count += 1

        # Should have some drops but not all
        assert 1 <= dropped_count <= 100  # ~0.5% expected

    def test_latency_deterministic_with_seed(self, network):
        """Same seed produces same latency sequence."""
        net1 = NetworkModel(seed=42)
        net1.add_node(NetworkNode("a", Region.NORTH_AMERICA, "cable"))
        net1.add_node(NetworkNode("b", Region.EUROPE, "fiber"))

        net2 = NetworkModel(seed=42)
        net2.add_node(NetworkNode("a", Region.NORTH_AMERICA, "cable"))
        net2.add_node(NetworkNode("b", Region.EUROPE, "fiber"))

        latencies1 = [net1.compute_latency("a", "b", 1024)[0] for _ in range(10)]
        latencies2 = [net2.compute_latency("a", "b", 1024)[0] for _ in range(10)]
        assert latencies1 == latencies2
```

#### 1.4 Network Partitions

- [ ] Implement `NetworkModel.block_communication()` and `unblock_communication()`
- [ ] Implement `NetworkModel.partition_network()` and `heal_partition()`

**Tests (test_partitions.py)**:

```python
class TestNetworkPartitions:
    @pytest.fixture
    def network(self):
        net = NetworkModel(seed=42)
        for i in range(6):
            net.add_node(NetworkNode(f"node_{i}", Region.NORTH_AMERICA, "fiber"))
        return net

    def test_block_communication(self, network):
        """Blocked pairs cannot communicate."""
        network.block_communication("node_0", "node_1")

        latency, dropped = network.compute_latency("node_0", "node_1", 1024)
        assert dropped

        # Other pairs still work
        latency, dropped = network.compute_latency("node_0", "node_2", 1024)
        assert not dropped

    def test_block_is_symmetric(self, network):
        """Blocking A-B also blocks B-A."""
        network.block_communication("node_0", "node_1")

        _, dropped1 = network.compute_latency("node_0", "node_1", 1024)
        _, dropped2 = network.compute_latency("node_1", "node_0", 1024)
        assert dropped1 and dropped2

    def test_unblock_restores_communication(self, network):
        """Unblocking restores communication."""
        network.block_communication("node_0", "node_1")
        network.unblock_communication("node_0", "node_1")

        latency, dropped = network.compute_latency("node_0", "node_1", 1024)
        assert not dropped

    def test_partition_network(self, network):
        """partition_network blocks cross-group communication."""
        group_a = {"node_0", "node_1", "node_2"}
        group_b = {"node_3", "node_4", "node_5"}
        network.partition_network([group_a, group_b])

        # Within group works
        _, dropped = network.compute_latency("node_0", "node_1", 1024)
        assert not dropped

        # Cross group blocked
        _, dropped = network.compute_latency("node_0", "node_3", 1024)
        assert dropped

    def test_heal_partition(self, network):
        """heal_partition restores all communication."""
        network.partition_network([{"node_0", "node_1"}, {"node_2", "node_3"}])
        network.heal_partition()

        _, dropped = network.compute_latency("node_0", "node_3", 1024)
        assert not dropped
```

#### 1.5 Message Delivery System

- [ ] Implement `MessageDeliverySystem` class
- [ ] Integrate with EventQueue for scheduled delivery

**Tests (test_message_delivery.py)**:

```python
class TestMessageDeliverySystem:
    @pytest.fixture
    def system(self):
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("sender", Region.NORTH_AMERICA, "fiber"))
        net.add_node(NetworkNode("recipient", Region.EUROPE, "fiber"))
        queue = EventQueue()
        return MessageDeliverySystem(net, queue), queue

    def test_send_schedules_delivery_event(self, system):
        """Sending a message schedules a delivery event."""
        delivery, queue = system
        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)

        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        assert queue.peek_time() is not None
        assert queue.peek_time() > 0  # Some latency

    def test_delivery_latency_realistic(self, system):
        """NA-EU message has realistic latency."""
        delivery, queue = system
        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)

        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        delivery_time = queue.peek_time()
        # NA-EU base is 124ms, plus last mile, should be 100-300ms
        assert 0.100 < delivery_time < 0.500  # 100-500ms in seconds

    def test_deliver_message_returns_pending(self, system):
        """deliver_message returns the pending message info."""
        delivery, queue = system
        msg = Message(msg_type="TEST", sender="sender", payload={"data": 123}, timestamp=0)

        msg_id = delivery.send_message(msg, "sender", "recipient", current_time=0.0)
        pending = delivery.deliver_message(msg_id)

        assert pending is not None
        assert pending.message.payload["data"] == 123
        assert pending.sender == "sender"
        assert pending.recipient == "recipient"

    def test_deliver_unknown_message_returns_none(self, system):
        """Delivering unknown message ID returns None."""
        delivery, _ = system
        assert delivery.deliver_message("unknown_id") is None

    def test_dropped_message_not_scheduled(self, system):
        """Dropped messages don't get delivery events."""
        delivery, queue = system

        # Take recipient offline
        delivery.network.nodes["recipient"].is_online = False

        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)
        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        # No event scheduled
        assert queue.peek_time() is None

        # Message recorded as dropped
        assert len(delivery.dropped_messages) == 1

    def test_delivery_stats(self, system):
        """get_delivery_stats returns correct statistics."""
        delivery, queue = system

        # Send some messages
        for i in range(10):
            msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)
            msg_id = delivery.send_message(msg, "sender", "recipient", current_time=0.0)
            delivery.deliver_message(msg_id)

        stats = delivery.get_delivery_stats()
        assert stats["total_sent"] == 10
        assert stats["total_delivered"] == 10
        assert stats["latency_ms"]["avg"] > 0
```

#### 1.6 Simulation Engine Main Loop

- [ ] Implement `SimulationEngine` class
- [ ] Implement event processing dispatch

**Tests (test_engine.py)**:

```python
class TestSimulationEngine:
    @pytest.fixture
    def engine(self):
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("node_a", Region.NORTH_AMERICA, "fiber"))
        net.add_node(NetworkNode("node_b", Region.EUROPE, "fiber"))
        return SimulationEngine(net, seed=42)

    def test_engine_runs_until_time(self, engine):
        """Engine runs until specified time."""
        result = engine.run(until_time=100.0)
        assert result.final_time <= 100.0

    def test_engine_processes_events_in_order(self, engine):
        """Events are processed in time order."""
        engine.event_queue.schedule(10.0, "test", {"order": 1})
        engine.event_queue.schedule(5.0, "test", {"order": 0})
        engine.event_queue.schedule(15.0, "test", {"order": 2})

        result = engine.run(until_time=20.0)

        orders = [e.payload["order"] for e in result.event_log if e.event_type == "test"]
        assert orders == [0, 1, 2]

    def test_engine_stops_at_time_limit(self, engine):
        """Engine doesn't process events past time limit."""
        engine.event_queue.schedule(50.0, "early", {})
        engine.event_queue.schedule(150.0, "late", {})

        result = engine.run(until_time=100.0)

        event_types = [e.event_type for e in result.event_log]
        assert "early" in event_types
        assert "late" not in event_types

    def test_engine_advances_clock(self, engine):
        """Engine advances clock as it processes events."""
        engine.event_queue.schedule(50.0, "test", {})

        result = engine.run(until_time=100.0)

        assert engine.clock.current_time == 50.0  # Stopped at last event
```

**Phase 1 Completion Criteria**: All tests in `test_event_queue.py`, `test_network_regions.py`, `test_latency.py`, `test_partitions.py`, `test_message_delivery.py`, and `test_engine.py` pass.

---

### Phase 2: Agent Framework

**Goal**: Implement agents that can participate in simulations, starting with trace replay.

#### 2.1 Agent Base Class

- [ ] Define `Agent` abstract base class
- [ ] Define `AgentContext` dataclass
- [ ] Define `Action` dataclass

**Tests (test_agent_base.py)**:

```python
class TestAgentContext:
    def test_context_has_required_fields(self):
        """AgentContext has all required fields."""
        ctx = AgentContext(
            agent_id="test",
            role="consumer",
            goal="test goal",
            local_chain=None,
            cached_peer_chains={},
            pending_messages=[],
            active_transactions=[],
            current_time=0.0,
            available_actions=[],
            protocol_rules="",
        )
        assert ctx.agent_id == "test"
        assert ctx.role == "consumer"

class TestAction:
    def test_action_creation(self):
        """Actions can be created with type and params."""
        action = Action(action_type="send_message", params={"recipient": "bob"})
        assert action.action_type == "send_message"
        assert action.params["recipient"] == "bob"
```

#### 2.2 Trace Replay Agent

- [ ] Implement `TraceReplayAgent` class
- [ ] Implement trace action scheduling

**Tests (test_trace_replay.py)**:

```python
class TestTraceReplayAgent:
    def test_agent_returns_actions_at_correct_time(self):
        """Agent returns actions when their time arrives."""
        trace = Trace(
            name="test",
            description="test trace",
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="alice", action="do_a", params={}),
                TraceAction(time=1.0, actor="alice", action="do_b", params={}),
                TraceAction(time=2.0, actor="alice", action="do_c", params={}),
            ],
            assertions=[],
        )
        agent = TraceReplayAgent("alice", trace)

        ctx = AgentContext(agent_id="alice", current_time=0.0, ...)
        action = agent.decide_action(ctx)
        assert action.action_type == "do_a"

        ctx.current_time = 1.0
        action = agent.decide_action(ctx)
        assert action.action_type == "do_b"

    def test_agent_skips_other_actors_actions(self):
        """Agent only returns its own actions."""
        trace = Trace(
            name="test",
            description="",
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="bob", action="bob_action", params={}),
                TraceAction(time=0.0, actor="alice", action="alice_action", params={}),
            ],
            assertions=[],
        )
        agent = TraceReplayAgent("alice", trace)

        ctx = AgentContext(agent_id="alice", current_time=0.0, ...)
        action = agent.decide_action(ctx)
        assert action.action_type == "alice_action"

    def test_agent_returns_none_when_no_more_actions(self):
        """Agent returns None when trace is exhausted."""
        trace = Trace(
            name="test",
            description="",
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="alice", action="only_action", params={}),
            ],
            assertions=[],
        )
        agent = TraceReplayAgent("alice", trace)

        ctx = AgentContext(agent_id="alice", current_time=0.0, ...)
        agent.decide_action(ctx)  # Consume the action

        ctx.current_time = 1.0
        action = agent.decide_action(ctx)
        assert action is None

    def test_agent_waits_for_action_time(self):
        """Agent returns None if action time hasn't arrived."""
        trace = Trace(
            name="test",
            description="",
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=10.0, actor="alice", action="future_action", params={}),
            ],
            assertions=[],
        )
        agent = TraceReplayAgent("alice", trace)

        ctx = AgentContext(agent_id="alice", current_time=5.0, ...)
        action = agent.decide_action(ctx)
        assert action is None
```

#### 2.3 Trace Parsing

- [ ] Define YAML trace schema
- [ ] Implement trace parser
- [ ] Implement trace validation

**Tests (test_trace_parser.py)**:

```python
class TestTraceParser:
    def test_parse_minimal_trace(self):
        """Can parse minimal valid trace."""
        yaml_content = """
        name: minimal
        description: A minimal trace
        network:
          seed: 42
          nodes:
            - id: alice
              region: north_america
              connection: fiber
        setup:
          chains:
            alice:
              balance: 100
        actions: []
        assertions: []
        """
        trace = parse_trace(yaml_content)
        assert trace.name == "minimal"
        assert len(trace.network.nodes) == 1

    def test_parse_actions(self):
        """Actions are parsed correctly."""
        yaml_content = """
        name: with_actions
        description: ""
        network:
          seed: 42
          nodes:
            - id: alice
              region: north_america
              connection: fiber
        setup:
          chains: {}
        actions:
          - time: 0.0
            actor: alice
            action: initiate_lock
            params:
              provider: bob
              amount: 10
        assertions: []
        """
        trace = parse_trace(yaml_content)
        assert len(trace.actions) == 1
        assert trace.actions[0].action == "initiate_lock"
        assert trace.actions[0].params["amount"] == 10

    def test_parse_network_partitions(self):
        """Network partitions are parsed correctly."""
        yaml_content = """
        name: with_partition
        description: ""
        network:
          seed: 42
          nodes:
            - id: a
              region: north_america
              connection: fiber
            - id: b
              region: europe
              connection: fiber
          partitions:
            - groups: [[a], [b]]
              start_time: 10.0
              duration: 5.0
        setup:
          chains: {}
        actions: []
        assertions: []
        """
        trace = parse_trace(yaml_content)
        assert len(trace.network.partitions) == 1
        assert trace.network.partitions[0].duration == 5.0

    def test_invalid_region_raises_error(self):
        """Invalid region raises validation error."""
        yaml_content = """
        name: invalid
        description: ""
        network:
          seed: 42
          nodes:
            - id: alice
              region: mars  # Invalid!
              connection: fiber
        setup:
          chains: {}
        actions: []
        assertions: []
        """
        with pytest.raises(ValidationError):
            parse_trace(yaml_content)

    def test_invalid_connection_raises_error(self):
        """Invalid connection type raises validation error."""
        yaml_content = """
        name: invalid
        description: ""
        network:
          seed: 42
          nodes:
            - id: alice
              region: north_america
              connection: quantum_entanglement  # Invalid!
        setup:
          chains: {}
        actions: []
        assertions: []
        """
        with pytest.raises(ValidationError):
            parse_trace(yaml_content)
```

#### 2.4 Partition Manager Integration

- [ ] Implement `PartitionManager` with scheduled events
- [ ] Integrate with SimulationEngine

**Tests (test_partition_manager.py)**:

```python
class TestPartitionManager:
    @pytest.fixture
    def setup(self):
        net = NetworkModel(seed=42)
        for i in range(4):
            net.add_node(NetworkNode(f"node_{i}", Region.NORTH_AMERICA, "fiber"))
        queue = EventQueue()
        return PartitionManager(net, queue), net, queue

    def test_schedule_partition_creates_events(self, setup):
        """Scheduling partition creates start and end events."""
        pm, net, queue = setup

        pm.schedule_partition(
            groups=[{"node_0", "node_1"}, {"node_2", "node_3"}],
            start_time=10.0,
            duration=5.0,
        )

        events = []
        while True:
            e = queue.next_event()
            if e is None:
                break
            events.append(e)

        assert len(events) == 2
        assert events[0].event_type == "partition_start"
        assert events[0].time == 10.0
        assert events[1].event_type == "partition_end"
        assert events[1].time == 15.0

    def test_apply_partition_blocks_cross_group(self, setup):
        """apply_partition blocks cross-group communication."""
        pm, net, queue = setup

        partition = pm.schedule_partition(
            groups=[{"node_0", "node_1"}, {"node_2", "node_3"}],
            start_time=0.0,
            duration=10.0,
        )
        pm.apply_partition(partition.partition_id)

        # Cross-group blocked
        _, dropped = net.compute_latency("node_0", "node_2", 1024)
        assert dropped

        # Within group works
        _, dropped = net.compute_latency("node_0", "node_1", 1024)
        assert not dropped

    def test_heal_partition_restores_communication(self, setup):
        """heal_partition restores cross-group communication."""
        pm, net, queue = setup

        partition = pm.schedule_partition(
            groups=[{"node_0", "node_1"}, {"node_2", "node_3"}],
            start_time=0.0,
            duration=10.0,
        )
        pm.apply_partition(partition.partition_id)
        pm.heal_partition(partition.partition_id)

        _, dropped = net.compute_latency("node_0", "node_2", 1024)
        assert not dropped
```

#### 2.5 Happy Path Trace

- [ ] Create `happy_path_escrow_lock.yaml` trace
- [ ] Verify trace runs successfully in simulator

**Tests (test_happy_path.py)**:

```python
class TestHappyPathEscrowLock:
    def test_happy_path_trace_loads(self):
        """Happy path trace file loads without error."""
        trace = load_trace("traces/regression/happy_path_escrow_lock.yaml")
        assert trace.name == "happy_path_escrow_lock"

    def test_happy_path_simulation_completes(self):
        """Happy path simulation runs to completion."""
        trace = load_trace("traces/regression/happy_path_escrow_lock.yaml")
        engine = create_engine_from_trace(trace)

        result = engine.run(until_time=60.0)

        assert result.final_time <= 60.0

    def test_happy_path_lock_succeeds(self):
        """Happy path results in successful lock."""
        trace = load_trace("traces/regression/happy_path_escrow_lock.yaml")
        engine = create_engine_from_trace(trace)

        result = engine.run(until_time=60.0)

        # Check assertion from trace
        for assertion in trace.assertions:
            assert check_assertion(assertion, result)

    def test_happy_path_all_messages_delivered(self):
        """All messages in happy path are delivered (no drops)."""
        trace = load_trace("traces/regression/happy_path_escrow_lock.yaml")
        engine = create_engine_from_trace(trace)

        result = engine.run(until_time=60.0)

        assert result.message_stats["total_dropped"] == 0
```

**Phase 2 Completion Criteria**: All tests in `test_agent_base.py`, `test_trace_replay.py`, `test_trace_parser.py`, `test_partition_manager.py`, and `test_happy_path.py` pass. The `happy_path_escrow_lock.yaml` trace runs successfully.

---

### Phase 3: Protocol Integration

**Goal**: Connect the escrow lock protocol to the simulator.

#### 3.1 Protocol Actor Integration

- [ ] Adapt `Consumer`, `Provider`, `Witness` from escrow_lock_generated.py to work with simulator
- [ ] Implement message routing between protocol actors and simulator

**Tests (test_protocol_integration.py)**:

```python
class TestProtocolActorIntegration:
    def test_consumer_can_send_lock_intent(self):
        """Consumer sends LOCK_INTENT through simulator network."""
        engine = create_test_engine()
        consumer = create_protocol_consumer("alice", engine)
        provider = create_protocol_provider("bob", engine)

        consumer.initiate_lock("bob", 10.0)
        engine.run(until_time=1.0)

        # Provider should have received LOCK_INTENT
        assert len(provider.message_queue) >= 1
        assert provider.message_queue[0].msg_type == MessageType.LOCK_INTENT

    def test_message_has_realistic_latency(self):
        """Messages between protocol actors have realistic latency."""
        # NA consumer to EU provider
        engine = create_test_engine(
            consumer_region=Region.NORTH_AMERICA,
            provider_region=Region.EUROPE,
        )
        consumer = create_protocol_consumer("alice", engine)
        provider = create_protocol_provider("bob", engine)

        consumer.initiate_lock("bob", 10.0)

        # Message shouldn't arrive instantly
        engine.run(until_time=0.050)  # 50ms
        assert len(provider.message_queue) == 0

        # But should arrive within 500ms
        engine.run(until_time=0.500)
        assert len(provider.message_queue) >= 1
```

#### 3.2 Witness Consensus with Network Delays

- [ ] Test witness voting with network delays
- [ ] Verify threshold still reached with realistic timing

**Tests (test_witness_consensus.py)**:

```python
class TestWitnessConsensusWithNetwork:
    def test_consensus_reached_despite_latency(self):
        """Witness consensus is reached despite variable latency."""
        engine = create_global_network_engine()  # Witnesses in different regions

        consumer = create_protocol_consumer("consumer", engine)
        provider = create_protocol_provider("provider", engine)
        witnesses = [create_protocol_witness(f"witness_{i}", engine) for i in range(5)]

        # Give witnesses cached balance info (populates both cached_chains and peer_balances)
        for w in witnesses:
            w.set_cached_chain("consumer", {"balance": 100.0})

        consumer.initiate_lock("provider", 10.0)
        engine.run(until_time=30.0)  # Allow time for cross-region messages

        # Check that lock succeeded or failed definitively (not stuck)
        assert consumer.state in (ConsumerState.LOCKED, ConsumerState.FAILED)

    def test_slow_witness_doesnt_block_consensus(self):
        """A slow witness (satellite connection) doesn't block consensus."""
        engine = create_test_engine()

        # 4 witnesses on fiber, 1 on GEO satellite
        for i in range(4):
            engine.network.add_node(NetworkNode(f"witness_{i}", Region.NORTH_AMERICA, "fiber"))
        engine.network.add_node(NetworkNode("witness_4", Region.NORTH_AMERICA, "satellite_geo"))

        consumer = create_protocol_consumer("consumer", engine)
        provider = create_protocol_provider("provider", engine)
        witnesses = [create_protocol_witness(f"witness_{i}", engine) for i in range(5)]

        for w in witnesses:
            w.set_cached_chain("consumer", {"balance": 100.0})

        consumer.initiate_lock("provider", 10.0)

        # Should complete before satellite witness responds (threshold is 3)
        engine.run(until_time=5.0)

        assert consumer.state == ConsumerState.LOCKED
```

#### 3.3 Double-Spend Detection with Network Timing

- [ ] Test double-spend detection with realistic propagation
- [ ] Verify detection timing depends on network topology

**Tests (test_double_spend.py)**:

```python
class TestDoubleSpendWithNetwork:
    def test_double_spend_detected_same_region(self):
        """Double-spend is detected when both providers in same region."""
        engine = create_test_engine()

        consumer = create_protocol_consumer("consumer", engine)
        provider_a = create_protocol_provider("provider_a", engine)
        provider_b = create_protocol_provider("provider_b", engine)
        witnesses = [create_protocol_witness(f"w_{i}", engine) for i in range(5)]

        for w in witnesses:
            w.set_cached_chain("consumer", {"balance": 50.0})  # Not enough for both

        # Initiate two locks nearly simultaneously
        consumer.initiate_lock("provider_a", 40.0)
        engine.run(until_time=0.001)  # 1ms later
        consumer.initiate_lock("provider_b", 40.0)

        engine.run(until_time=30.0)

        # At most one should succeed
        locks_succeeded = sum(1 for p in [provider_a, provider_b]
                            if p.state == ProviderState.LOCKED)
        assert locks_succeeded <= 1

    def test_double_spend_detection_time_depends_on_network(self):
        """Detection time scales with network diameter."""
        # All same region - fast detection
        fast_engine = create_test_engine(all_same_region=True)
        fast_result = run_double_spend_scenario(fast_engine)

        # Global network - slower detection
        slow_engine = create_test_engine(global_distribution=True)
        slow_result = run_double_spend_scenario(slow_engine)

        # Global network should take longer to detect
        assert slow_result.detection_time > fast_result.detection_time

    def test_partition_enables_temporary_double_spend(self):
        """During partition, double-spend can temporarily succeed on both sides."""
        engine = create_test_engine()

        # Create partition: consumer + provider_a | provider_b
        engine.schedule_partition(
            groups=[{"consumer", "provider_a", "w_0", "w_1", "w_2"},
                   {"provider_b", "w_3", "w_4"}],
            start_time=0.0,
            duration=10.0,
        )

        consumer = create_protocol_consumer("consumer", engine)
        # ... setup ...

        # Both locks initiated during partition
        consumer.initiate_lock("provider_a", 40.0)
        consumer.initiate_lock("provider_b", 40.0)

        engine.run(until_time=5.0)  # Still partitioned

        # Both might succeed temporarily (this is expected!)
        # After partition heals, conflict should be detected
        engine.run(until_time=20.0)  # After partition healed

        # Conflict should now be detected
        assert engine.metrics.get("double_spend_detected", False)
```

**Phase 3 Completion Criteria**: All tests in `test_protocol_integration.py`, `test_witness_consensus.py`, and `test_double_spend.py` pass.

---

### Phase 4: Attack Traces and Validation

**Goal**: Create attack traces from protocol spec, validate defenses work.

#### 4.1 Attack Trace Library

- [ ] Create `double_spend_basic.yaml`
- [ ] Create `double_spend_partition.yaml`
- [ ] Create `witness_bribery.yaml`
- [ ] Create `balance_lie.yaml`
- [ ] Create `replay_attack.yaml`

**Tests (test_attack_traces.py)**:

```python
class TestAttackTraces:
    @pytest.mark.parametrize("trace_file", [
        "traces/attacks/double_spend_basic.yaml",
        "traces/attacks/double_spend_partition.yaml",
        "traces/attacks/witness_bribery.yaml",
        "traces/attacks/balance_lie.yaml",
        "traces/attacks/replay_attack.yaml",
    ])
    def test_attack_trace_loads(self, trace_file):
        """All attack traces load without error."""
        trace = load_trace(trace_file)
        assert trace is not None

    @pytest.mark.parametrize("trace_file", [
        "traces/attacks/double_spend_basic.yaml",
        "traces/attacks/double_spend_partition.yaml",
        "traces/attacks/witness_bribery.yaml",
        "traces/attacks/balance_lie.yaml",
        "traces/attacks/replay_attack.yaml",
    ])
    def test_attack_trace_runs(self, trace_file):
        """All attack traces run to completion."""
        trace = load_trace(trace_file)
        engine = create_engine_from_trace(trace)
        result = engine.run(until_time=300.0)
        assert result is not None

    @pytest.mark.parametrize("trace_file", [
        "traces/attacks/double_spend_basic.yaml",
        "traces/attacks/double_spend_partition.yaml",
        "traces/attacks/witness_bribery.yaml",
        "traces/attacks/balance_lie.yaml",
        "traces/attacks/replay_attack.yaml",
    ])
    def test_attack_is_detected_or_fails(self, trace_file):
        """All attacks are either detected or fail to achieve goal."""
        trace = load_trace(trace_file)
        engine = create_engine_from_trace(trace)
        result = engine.run(until_time=300.0)

        for assertion in trace.assertions:
            passed = check_assertion(assertion, result)
            assert passed, f"Assertion failed: {assertion.description}"
```

#### 4.2 Latency Distribution Validation

- [ ] Validate latency distributions match SimBlock paper
- [ ] Generate latency histograms for comparison

**Tests (test_latency_validation.py)**:

```python
class TestLatencyDistributionValidation:
    def test_intra_region_latency_distribution(self):
        """Intra-region latency matches expected distribution."""
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("a", Region.NORTH_AMERICA, "datacenter"))
        net.add_node(NetworkNode("b", Region.NORTH_AMERICA, "datacenter"))

        latencies = []
        for _ in range(10000):
            lat, _ = net.compute_latency("a", "b", 1024)
            latencies.append(lat)

        mean = sum(latencies) / len(latencies)
        # NA intra-region base is 32ms, plus 2ms added latency each side
        expected_mean = 32 + 1 + 1  # ~34ms

        assert abs(mean - expected_mean) < 5, f"Mean {mean} too far from expected {expected_mean}"

    def test_cross_region_latency_distribution(self):
        """Cross-region latency matches expected distribution."""
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("a", Region.NORTH_AMERICA, "datacenter"))
        net.add_node(NetworkNode("b", Region.EUROPE, "datacenter"))

        latencies = []
        for _ in range(10000):
            lat, _ = net.compute_latency("a", "b", 1024)
            latencies.append(lat)

        mean = sum(latencies) / len(latencies)
        # NA-EU base is 124ms
        expected_mean = 124 + 1 + 1  # ~126ms

        assert abs(mean - expected_mean) < 15, f"Mean {mean} too far from expected {expected_mean}"

    def test_pareto_tail_present(self):
        """Latency distribution has Pareto tail (P99 >> P50)."""
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("a", Region.NORTH_AMERICA, "fiber"))
        net.add_node(NetworkNode("b", Region.EUROPE, "fiber"))

        latencies = []
        for _ in range(10000):
            lat, _ = net.compute_latency("a", "b", 1024)
            latencies.append(lat)

        latencies.sort()
        p50 = latencies[5000]
        p99 = latencies[9900]

        # P99 should be notably higher than P50 (Pareto tail)
        assert p99 > p50 * 1.3, f"P99 ({p99}) not sufficiently larger than P50 ({p50})"
```

#### 4.3 Performance Benchmarking

- [ ] Benchmark simulation speed (events/second)
- [ ] Benchmark memory usage for large networks

**Tests (test_performance.py)**:

```python
class TestPerformance:
    def test_simulation_throughput(self):
        """Simulation processes at least 10k events/second."""
        net = create_network(num_nodes=100)
        engine = SimulationEngine(net, seed=42)

        # Schedule 100k events
        for i in range(100000):
            engine.event_queue.schedule(float(i) / 1000, "test", {})

        import time
        start = time.time()
        engine.run(until_time=100.0)
        elapsed = time.time() - start

        events_per_second = 100000 / elapsed
        assert events_per_second > 10000, f"Only {events_per_second:.0f} events/sec"

    def test_memory_usage_scales_linearly(self):
        """Memory usage scales roughly linearly with node count."""
        import tracemalloc

        tracemalloc.start()
        net_small = create_network(num_nodes=100)
        small_mem = tracemalloc.get_traced_memory()[1]

        tracemalloc.reset_peak()
        net_large = create_network(num_nodes=1000)
        large_mem = tracemalloc.get_traced_memory()[1]
        tracemalloc.stop()

        # 10x nodes should be < 20x memory (allowing for overhead)
        ratio = large_mem / small_mem
        assert ratio < 20, f"Memory scaling ratio {ratio} too high"

    def test_1000_node_simulation_completes(self):
        """1000-node simulation completes in reasonable time."""
        net = create_network(num_nodes=1000)
        engine = SimulationEngine(net, seed=42)

        # Schedule some cross-network messages
        nodes = list(net.nodes.keys())
        import random
        rng = random.Random(42)
        for _ in range(1000):
            sender = rng.choice(nodes)
            recipient = rng.choice(nodes)
            engine.message_system.send_message(
                Message("TEST", sender, {}, 0),
                sender, recipient, 0.0
            )

        import time
        start = time.time()
        result = engine.run(until_time=10.0)
        elapsed = time.time() - start

        assert elapsed < 10.0, f"1000-node simulation took {elapsed:.1f}s (too slow)"
```

**Phase 4 Completion Criteria**: All attack traces pass their assertions (attacks are detected/fail). Latency distributions match SimBlock paper within tolerance. Performance benchmarks meet targets.

---

### Phase 5: AI Agent Integration (Optional)

**Goal**: Enable AI-backed agents for exploratory testing.

#### 5.1 AI Agent Implementation

- [ ] Implement `AIBackedAgent` with LLM API calls
- [ ] Design and iterate on prompts
- [ ] Implement action parsing

#### 5.2 Trace Extraction

- [ ] Extract deterministic traces from AI agent runs
- [ ] Validate extracted traces replay correctly

**Tests (test_ai_agent.py)**:

```python
class TestAIAgent:
    @pytest.mark.slow
    @pytest.mark.requires_api_key
    def test_ai_agent_makes_valid_actions(self):
        """AI agent produces valid actions."""
        agent = AIBackedAgent(
            agent_id="test",
            role="consumer",
            goal="initiate a lock with provider bob",
        )

        ctx = create_test_context()
        action = agent.decide_action(ctx)

        assert action is not None
        assert action.action_type in ["send_message", "wait", "initiate_lock"]

    @pytest.mark.slow
    @pytest.mark.requires_api_key
    def test_extracted_trace_replays_identically(self):
        """Trace extracted from AI run replays with same outcome."""
        # Run with AI agent
        engine1 = create_test_engine()
        ai_agent = AIBackedAgent("alice", "consumer", "complete a lock")
        engine1.add_agent(ai_agent)
        result1 = engine1.run(until_time=60.0)

        # Extract trace
        trace = extract_trace(ai_agent.action_history)

        # Replay trace
        engine2 = create_test_engine()
        replay_agent = TraceReplayAgent("alice", trace)
        engine2.add_agent(replay_agent)
        result2 = engine2.run(until_time=60.0)

        # Outcomes should match
        assert result1.final_state == result2.final_state
```

**Phase 5 Completion Criteria**: AI agent produces valid actions, and extracted traces replay identically.

---

## File Structure

```
simulations/
├── simulator/
│   ├── __init__.py
│   ├── engine.py               # SimulationEngine, EventQueue, Clock
│   ├── agents/
│   │   ├── __init__.py
│   │   ├── base.py             # Agent base class, AgentContext
│   │   ├── ai_backed.py        # AIBackedAgent
│   │   └── trace_replay.py     # TraceReplayAgent
│   ├── network/
│   │   ├── __init__.py
│   │   ├── model.py            # NetworkModel, NetworkNode (SimBlock-style)
│   │   ├── regions.py          # Region enum, inter-region latencies
│   │   ├── connections.py      # ConnectionType, bandwidth presets
│   │   ├── delivery.py         # MessageDeliverySystem
│   │   └── partitions.py       # PartitionManager
│   ├── traces/
│   │   ├── __init__.py
│   │   ├── schema.py           # Trace dataclasses
│   │   └── parser.py           # YAML parsing
│   └── assertions/
│       ├── __init__.py
│       └── checks.py           # Assertion implementations
├── traces/
│   ├── attacks/
│   │   ├── double_spend_basic.yaml
│   │   ├── double_spend_partition.yaml
│   │   └── ...
│   ├── faults/
│   │   ├── witness_crash.yaml
│   │   └── ...
│   └── regression/
│       ├── happy_path_lock.yaml
│       └── ...
└── tests/
    ├── test_network_model.py   # Test latency distributions, bandwidth
    ├── test_engine.py          # Test event processing
    └── test_traces.py          # Test trace parsing and replay
```

---

## Example Usage

### Running a Trace

```python
from simulations.simulator import SimulationEngine, load_trace
from simulations.simulator.network import NetworkModel, NetworkNode, Region
from simulations.simulator.agents import TraceReplayAgent

# Load trace
trace = load_trace("traces/attacks/double_spend_basic.yaml")

# Create network from trace spec
network = NetworkModel(seed=trace.network.seed)
for node_spec in trace.network.nodes:
    network.add_node(NetworkNode(
        node_id=node_spec.id,
        region=Region(node_spec.region),
        connection_type=node_spec.connection,
    ))

# Create engine
engine = SimulationEngine(network, seed=42)

# Schedule any partitions from the trace
for partition in trace.network.partitions:
    engine.schedule_partition(
        groups=partition.groups,
        start_time=partition.start_time,
        duration=partition.duration,
    )

# Create trace replay agents
for actor_spec in trace.setup.actors:
    agent = TraceReplayAgent(
        agent_id=actor_spec.id,
        trace=trace,
    )
    engine.add_agent(agent)

# Run simulation
result = engine.run(until_time=300.0)  # Run for 300 simulated seconds

# Check assertions
for assertion in trace.assertions:
    passed = check_assertion(assertion, result)
    print(f"{assertion.description}: {'PASS' if passed else 'FAIL'}")

# Print latency statistics
stats = result.message_stats
print(f"Average latency: {stats['latency_ms']['avg']:.1f}ms")
print(f"P95 latency: {stats['latency_ms']['p95']:.1f}ms")
```

### Running AI Exploration

```python
from simulations.simulator import SimulationEngine
from simulations.simulator.network import NetworkModel, NetworkNode, Region
from simulations.simulator.agents import AIBackedAgent

# Create a realistic mixed network
network = NetworkModel(seed=42)

# Add datacenter nodes (well-connected)
for i, region in enumerate([Region.NORTH_AMERICA, Region.EUROPE]):
    network.add_node(NetworkNode(
        node_id=f"dc_{i}",
        region=region,
        connection_type="datacenter",
    ))

# Add home users (various regions, cable connections)
for i, region in enumerate([Region.NORTH_AMERICA, Region.EUROPE, Region.ASIA]):
    network.add_node(NetworkNode(
        node_id=f"home_{i}",
        region=region,
        connection_type="cable",
    ))

# Add a mobile user
network.add_node(NetworkNode(
    node_id="mobile_1",
    region=Region.NORTH_AMERICA,
    connection_type="4g_lte",
))

engine = SimulationEngine(network, seed=42)

# Create AI agents with different goals
engine.add_agent(AIBackedAgent(
    agent_id="home_0",
    role="consumer",
    goal="complete a transaction honestly",
))

engine.add_agent(AIBackedAgent(
    agent_id="dc_0",
    role="provider",
    goal="provide service and get paid",
))

engine.add_agent(AIBackedAgent(
    agent_id="home_1",
    role="consumer",
    goal="steal funds by double-spending without being detected",
    model="claude-opus",  # Use more capable model for adversary
))

# Add witnesses
for i in range(5):
    engine.add_agent(AIBackedAgent(
        agent_id=f"witness_{i}" if f"witness_{i}" in network.nodes else f"home_{i}",
        role="witness",
        goal="verify transactions honestly",
    ))

# Run exploration
result = engine.run(until_time=600.0)

# Extract trace from interesting runs
if is_interesting(result):
    trace = extract_trace(result)
    save_trace(trace, "traces/discovered/attack_001.yaml")
```

### Simulating Global Network with Partitions

```python
from simulations.simulator import SimulationEngine
from simulations.simulator.network import NetworkModel, NetworkNode, Region

# Create a global network with nodes in different regions
network = NetworkModel(seed=42)

# Add nodes representing a globally distributed system
nodes_config = [
    ("nyc_dc", Region.NORTH_AMERICA, "datacenter"),
    ("london_dc", Region.EUROPE, "datacenter"),
    ("tokyo_dc", Region.JAPAN, "datacenter"),
    ("sydney_user", Region.AUSTRALIA, "cable"),
    ("berlin_user", Region.EUROPE, "fiber"),
    ("la_user", Region.NORTH_AMERICA, "cable"),
    ("mumbai_user", Region.ASIA, "dsl"),
]

for node_id, region, conn in nodes_config:
    network.add_node(NetworkNode(
        node_id=node_id,
        region=region,
        connection_type=conn,
    ))

engine = SimulationEngine(network, seed=42)

# Simulate a transatlantic cable cut: NA/SA isolated from EU/Asia/Australia
engine.schedule_partition(
    groups=[
        {"nyc_dc", "la_user"},                              # Americas
        {"london_dc", "tokyo_dc", "sydney_user", "berlin_user", "mumbai_user"},  # Rest of world
    ],
    start_time=100.0,
    duration=30.0,  # 30 second partition
)

# Run and observe behavior during partition
result = engine.run(until_time=200.0)

# Analyze results
stats = result.message_stats
print(f"Total messages: {stats['total_sent']}")
print(f"Delivered: {stats['total_delivered']}")
print(f"Dropped: {stats['total_dropped']}")
print(f"Drop reasons: {stats['drop_reasons']}")

# Messages during partition will show "network_partition" as drop reason
```

### Testing Different Connection Types

```python
# Compare latency for same-region communication with different connection types
from simulations.simulator.network import NetworkModel, NetworkNode, Region

network = NetworkModel(seed=42)

# All in North America, but different connection types
network.add_node(NetworkNode("dc", Region.NORTH_AMERICA, "datacenter"))
network.add_node(NetworkNode("fiber_user", Region.NORTH_AMERICA, "fiber"))
network.add_node(NetworkNode("cable_user", Region.NORTH_AMERICA, "cable"))
network.add_node(NetworkNode("mobile_user", Region.NORTH_AMERICA, "4g_lte"))
network.add_node(NetworkNode("satellite_user", Region.NORTH_AMERICA, "satellite_geo"))

# Test 1KB message latency from each to datacenter
message_size = 1024

for sender in ["fiber_user", "cable_user", "mobile_user", "satellite_user"]:
    latencies = []
    for _ in range(100):  # Sample 100 times
        latency, dropped = network.compute_latency(sender, "dc", message_size)
        if not dropped:
            latencies.append(latency)

    avg = sum(latencies) / len(latencies)
    print(f"{sender} -> dc: avg={avg:.1f}ms, min={min(latencies):.1f}ms, max={max(latencies):.1f}ms")

# Expected output (approximate):
# fiber_user -> dc: avg=37ms, min=34ms, max=55ms
# cable_user -> dc: avg=47ms, min=43ms, max=70ms
# mobile_user -> dc: avg=77ms, min=73ms, max=110ms
# satellite_user -> dc: avg=637ms, min=633ms, max=680ms
```

---

## References

### Network Model

The network model is based on **SimBlock**, an open-source blockchain network simulator from
Tokyo Institute of Technology. This approach is well-established in academic blockchain research.

**Primary Reference:**
- Aoki, Y., Otsuki, K., Kaneko, T., Banno, R., & Shudo, K. (2019). "SimBlock: A Blockchain Network
  Simulator." IEEE INFOCOM 2019 - IEEE Conference on Computer Communications Workshops.
  [arXiv:1901.09777](https://arxiv.org/abs/1901.09777)

**Key design decisions from SimBlock:**
- Region-based latency model (6 regions with measured inter-region delays)
- Pareto distribution for latency variance (~20% variance matches real measurements)
- Bandwidth-limited transmission: `bandwidth = min(sender.upload, receiver.download)`
- Event-driven simulation without hop-by-hop packet modeling

### Alternative Approaches Considered

| Simulator | Approach | Why Not Used |
|-----------|----------|--------------|
| ns-3 | Packet-level simulation | Too detailed for protocol-level analysis |
| OMNeT++ | Packet-level with modules | Same - unnecessary complexity |
| BlockSim | Single delay parameter | Too simplified - no bandwidth modeling |
| Shadow | Run real binaries | Requires actual implementation, not design |

### Latency Distribution

Real network latency follows heavy-tailed distributions where most packets arrive near the
mean but some are significantly delayed. The Pareto distribution captures this:

```
P(X > x) = (x_min / x)^α  for x ≥ x_min

With shape α = 5:
  - Mean = α * x_min / (α - 1) = 1.25 * x_min
  - Variance ≈ mean / 4 (matches SimBlock's ~20% variance)
```

### Connection Type Parameters

Bandwidth values based on typical real-world connections:

| Type | Upload | Download | Source |
|------|--------|----------|--------|
| Datacenter | 10 Gbps | 10 Gbps | AWS/GCP specs |
| Fiber | 1 Gbps | 1 Gbps | Typical FTTH |
| Cable | 20 Mbps | 200 Mbps | DOCSIS 3.0 |
| DSL | 5 Mbps | 50 Mbps | VDSL2 |
| 4G LTE | 10 Mbps | 50 Mbps | 3GPP specs |
| LEO Satellite | 20 Mbps | 100 Mbps | Starlink specs |
| GEO Satellite | 5 Mbps | 25 Mbps | Traditional VSAT |

### Related Work

- **VIBES**: Configurable blockchain simulator for large-scale P2P networks
- **BlockSim-Net**: Network-based extension of BlockSim for distributed simulation
- **Cardano IOSim**: Deterministic simulation for Ouroboros protocol testing
- **Bitcoin network measurements**: Neudecker et al. (2016) "Timing Analysis for Inferring
  the Topology of the Bitcoin Peer-to-Peer Network"
