"""
SimBlock-style network model with region-based latency.
"""

import random
from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple

from .regions import Region, get_inter_region_latency
from .connections import ConnectionType, CONNECTION_TYPES


def sample_pareto(mean: float, rng: random.Random, shape: float = 5.0) -> float:
    """
    Sample from Pareto distribution with given mean.

    SimBlock uses Pareto distribution with ~20% variance around the mean.
    Shape parameter of 5 gives variance ~ mean/4, matching their model.

    Pareto is heavy-tailed, which matches real network latency distributions
    where most packets arrive near the mean but some are significantly delayed.
    """
    if shape <= 1:
        shape = 5.0
    # For Pareto with shape α > 1: mean = α * x_min / (α - 1)
    # So x_min = mean * (α - 1) / α
    x_min = mean * (shape - 1) / shape

    # Sample using inverse transform
    u = rng.random()
    if u == 0:
        u = 1e-10  # Avoid division by zero
    return x_min / (u ** (1 / shape))


@dataclass
class NetworkNode:
    """A node in the network with region and connection properties."""
    node_id: str
    region: Region
    connection_type: str
    is_online: bool = True

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


class NetworkModel:
    """SimBlock-style network model with region-based latency."""

    def __init__(self, seed: int = 42):
        self.rng = random.Random(seed)
        self.nodes: Dict[str, NetworkNode] = {}
        self.blocked_pairs: Set[Tuple[str, str]] = set()

    def add_node(self, node: NetworkNode):
        """Add a node to the network."""
        self.nodes[node.node_id] = node

    def remove_node(self, node_id: str):
        """Remove a node from the network."""
        if node_id in self.nodes:
            del self.nodes[node_id]
            # Clean up any blocked pairs involving this node
            self.blocked_pairs = {
                pair for pair in self.blocked_pairs
                if node_id not in pair
            }

    def compute_latency(
        self,
        sender_id: str,
        recipient_id: str,
        message_size_bytes: int,
    ) -> Tuple[float, bool]:
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

    def partition_network(self, groups: List[Set[str]]):
        """Create a network partition where only nodes in the same group can communicate."""
        for i, group_a in enumerate(groups):
            for group_b in groups[i + 1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.block_communication(node_a, node_b)

    def heal_partition(self):
        """Remove all partition blocks."""
        self.blocked_pairs.clear()


# Default distributions for creating networks
DEFAULT_REGION_DISTRIBUTION = {
    Region.NORTH_AMERICA: 0.35,
    Region.EUROPE: 0.38,
    Region.ASIA: 0.12,
    Region.JAPAN: 0.05,
    Region.AUSTRALIA: 0.05,
    Region.SOUTH_AMERICA: 0.05,
}

DEFAULT_CONNECTION_DISTRIBUTION = {
    "datacenter": 0.10,
    "fiber": 0.25,
    "cable": 0.40,
    "dsl": 0.15,
    "4g_lte": 0.08,
    "5g": 0.02,
}


def create_network(
    num_nodes: int,
    region_distribution: Dict[Region, float] = None,
    connection_distribution: Dict[str, float] = None,
    seed: int = 42,
) -> NetworkModel:
    """Create a network with nodes distributed across regions and connection types."""
    rng = random.Random(seed)
    network = NetworkModel(seed=seed)

    region_dist = region_distribution or DEFAULT_REGION_DISTRIBUTION
    conn_dist = connection_distribution or DEFAULT_CONNECTION_DISTRIBUTION

    regions = list(region_dist.keys())
    region_weights = list(region_dist.values())

    conn_types = list(conn_dist.keys())
    conn_weights = list(conn_dist.values())

    for i in range(num_nodes):
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
    nodes_or_spec,
    seed: int = 42,
) -> NetworkModel:
    """
    Create a network with specific node configurations.

    Can accept either:
    - List of tuples: [(node_id, Region, conn_type), ...]
    - TraceNetworkSpec object
    """
    network = NetworkModel(seed=seed)

    # Check if it's a TraceNetworkSpec
    if hasattr(nodes_or_spec, 'nodes') and hasattr(nodes_or_spec, 'seed'):
        # It's a TraceNetworkSpec
        for node_spec in nodes_or_spec.nodes:
            node = NetworkNode(
                node_id=node_spec.id,
                region=node_spec.region,
                connection_type=node_spec.connection,
            )
            network.add_node(node)
    else:
        # It's a list of tuples
        for node_id, region, conn_type in nodes_or_spec:
            node = NetworkNode(
                node_id=node_id,
                region=region,
                connection_type=conn_type,
            )
            network.add_node(node)

    return network
