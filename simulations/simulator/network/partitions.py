"""
Network partition manager.
"""

from dataclasses import dataclass, field
from typing import List, Set

from ..engine import EventQueue


@dataclass
class NetworkPartition:
    """A scheduled network partition."""
    partition_id: str
    groups: List[Set[str]]
    start_time: float
    end_time: float
    is_active: bool = False


class PartitionManager:
    """Manages network partitions over time using scheduled events."""

    def __init__(self, network: 'NetworkModel', event_queue: EventQueue):
        self.network = network
        self.event_queue = event_queue
        self.partitions: List[NetworkPartition] = []
        self._partition_counter = 0

    def schedule_partition(
        self,
        groups: List[Set[str]],
        start_time: float,
        duration: float,
    ) -> NetworkPartition:
        """
        Schedule a network partition to occur at a future time.

        Args:
            groups: List of node sets. Nodes within a group can communicate;
                    nodes in different groups cannot.
            start_time: When the partition begins (simulation time)
            duration: How long the partition lasts

        Returns:
            The created NetworkPartition object
        """
        partition_id = f"partition_{self._partition_counter}"
        self._partition_counter += 1

        partition = NetworkPartition(
            partition_id=partition_id,
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
        partition = self._find_partition(partition_id)
        if partition is None:
            return

        partition.is_active = True

        # Block all cross-group pairs
        for i, group_a in enumerate(partition.groups):
            for group_b in partition.groups[i + 1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.network.block_communication(node_a, node_b)

    def heal_partition(self, partition_id: str):
        """Heal a partition (called when partition_end event fires)."""
        partition = self._find_partition(partition_id)
        if partition is None:
            return

        partition.is_active = False

        # Unblock all cross-group pairs
        for i, group_a in enumerate(partition.groups):
            for group_b in partition.groups[i + 1:]:
                for node_a in group_a:
                    for node_b in group_b:
                        self.network.unblock_communication(node_a, node_b)

    def get_active_partitions(self) -> List[NetworkPartition]:
        """Return currently active partitions."""
        return [p for p in self.partitions if p.is_active]

    def _find_partition(self, partition_id: str) -> NetworkPartition:
        """Find a partition by ID."""
        for p in self.partitions:
            if p.partition_id == partition_id:
                return p
        return None
