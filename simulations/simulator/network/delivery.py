"""
Message delivery system with realistic timing.
"""

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..engine import EventQueue, Message


@dataclass
class PendingMessage:
    """A message in transit through the network."""
    message_id: str
    message: Message
    sender: str
    recipient: str
    send_time: float
    scheduled_delivery_time: float
    latency_ms: float
    dropped: bool = False
    drop_reason: Optional[str] = None


class MessageDeliverySystem:
    """Handles message transmission through the SimBlock-style network model."""

    def __init__(self, network: 'NetworkModel', event_queue: EventQueue):
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

        Computes latency using SimBlock-style model.
        Returns message_id for tracking.
        """
        message_id = f"msg_{self._message_counter}"
        self._message_counter += 1

        # Compute message size (simplified - use string length as proxy)
        message_size_bytes = len(str(message.payload)) + 100  # Overhead

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
        drop_reasons: Dict[str, int] = {}
        for m in self.dropped_messages:
            reason = m.drop_reason or "unknown"
            drop_reasons[reason] = drop_reasons.get(reason, 0) + 1

        total = len(self.delivered_messages) + len(self.dropped_messages)

        stats = {
            "total_sent": total,
            "total_delivered": len(self.delivered_messages),
            "total_dropped": len(self.dropped_messages),
            "drop_rate": len(self.dropped_messages) / max(1, total),
            "drop_reasons": drop_reasons,
            "latency_ms": {
                "avg": sum(delivered_latencies) / max(1, len(delivered_latencies)),
                "max": max(delivered_latencies) if delivered_latencies else 0,
                "min": min(delivered_latencies) if delivered_latencies else 0,
                "p50": self._percentile(delivered_latencies, 0.50),
                "p95": self._percentile(delivered_latencies, 0.95),
            },
        }

        return stats

    def _percentile(self, data: List[float], p: float) -> float:
        """Compute percentile of data."""
        if not data:
            return 0
        sorted_data = sorted(data)
        idx = int(len(sorted_data) * p)
        idx = min(idx, len(sorted_data) - 1)
        return sorted_data[idx]
