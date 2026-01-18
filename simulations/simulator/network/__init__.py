"""
Network simulation module with SimBlock-style modeling.
"""

from .regions import Region, get_inter_region_latency, INTER_REGION_LATENCY_MS
from .connections import ConnectionType, CONNECTION_TYPES
from .model import (
    NetworkModel,
    NetworkNode,
    sample_pareto,
    create_network,
    create_specific_network,
    DEFAULT_REGION_DISTRIBUTION,
    DEFAULT_CONNECTION_DISTRIBUTION,
)
from .delivery import MessageDeliverySystem, PendingMessage
from .partitions import PartitionManager, NetworkPartition

__all__ = [
    # Regions
    "Region",
    "get_inter_region_latency",
    "INTER_REGION_LATENCY_MS",
    # Connections
    "ConnectionType",
    "CONNECTION_TYPES",
    # Model
    "NetworkModel",
    "NetworkNode",
    "sample_pareto",
    "create_network",
    "create_specific_network",
    "DEFAULT_REGION_DISTRIBUTION",
    "DEFAULT_CONNECTION_DISTRIBUTION",
    # Delivery
    "MessageDeliverySystem",
    "PendingMessage",
    # Partitions
    "PartitionManager",
    "NetworkPartition",
]
