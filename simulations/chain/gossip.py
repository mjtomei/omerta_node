"""
Gossip Protocol Implementation

Handles propagation of multi-signed results through the network.
Uses dual-hash deduplication to eliminate false positives.

See: docs/protocol/GOSSIP.md
"""

import hashlib
import json
from collections import OrderedDict
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Any, Dict, List, Optional, Set, Tuple


# =============================================================================
# Gossip Item Types
# =============================================================================

class GossipType(Enum):
    """Types of items that can be gossiped."""
    LOCK_RESULT = auto()
    TOPUP_RESULT = auto()
    SETTLEMENT_RESULT = auto()
    ATTESTATION = auto()


@dataclass
class GossipItem:
    """A gossip-able piece of information."""
    item_type: GossipType
    payload: dict
    signatures: List[str]  # Multi-sig from witnesses/cabal

    def to_bytes(self) -> bytes:
        """Serialize for hashing."""
        data = {
            "type": self.item_type.value,
            "payload": self.payload,
            "signatures": sorted(self.signatures),
        }
        return json.dumps(data, sort_keys=True, separators=(',', ':')).encode()


# =============================================================================
# Dual-Hash Deduplication Table
# =============================================================================

def hash1(data: bytes) -> str:
    """First hash function for dedup table key."""
    return hashlib.sha256(data).hexdigest()[:16]


def hash2(data: bytes) -> str:
    """Second hash function for dedup table value."""
    # Use different algorithm or prefix to ensure independence
    return hashlib.blake2b(data, digest_size=8).hexdigest()


class DualHashTable:
    """
    Deduplication table using dual-hash approach.

    Maps hash1(data) -> hash2(data) to eliminate false positives.
    False negatives only occur from eviction (harmless for gossip).
    """

    def __init__(self, max_size: int = 100_000):
        self.max_size = max_size
        # Use OrderedDict for LRU eviction
        self._table: OrderedDict[str, str] = OrderedDict()

    def check_seen(self, data: bytes) -> bool:
        """
        Check if data has been seen before.

        Returns True only if hash1 key exists AND hash2 value matches.
        This eliminates false positives (would require collision in both hashes).
        """
        key = hash1(data)
        expected = hash2(data)

        if key not in self._table:
            return False

        # Move to end (most recently accessed) for LRU
        self._table.move_to_end(key)
        return self._table[key] == expected

    def mark_seen(self, data: bytes):
        """Mark data as seen."""
        key = hash1(data)
        value = hash2(data)

        # If key exists, update and move to end
        if key in self._table:
            self._table.move_to_end(key)

        self._table[key] = value

        # Evict oldest if over capacity
        while len(self._table) > self.max_size:
            self._table.popitem(last=False)

    def __len__(self) -> int:
        return len(self._table)

    def clear(self):
        """Clear all entries."""
        self._table.clear()


# =============================================================================
# Propagation Queue
# =============================================================================

@dataclass
class PropagationEntry:
    """An item queued for propagation."""
    item: GossipItem
    remaining_count: int
    peers_sent_to: Set[str] = field(default_factory=set)


class PropagationQueue:
    """
    Queue of items waiting to be propagated.

    Each item is sent to N peers, then removed from queue.
    """

    def __init__(self, fanout: int = 3):
        self.fanout = fanout
        self._queue: Dict[str, PropagationEntry] = {}

    def add(self, item: GossipItem):
        """Add an item to the propagation queue."""
        item_id = hash1(item.to_bytes())

        if item_id in self._queue:
            # Already queued, don't add again
            return

        self._queue[item_id] = PropagationEntry(
            item=item,
            remaining_count=self.fanout,
        )

    def get_items_for_peer(self, peer_id: str, max_items: int = 5) -> List[GossipItem]:
        """
        Get items to send to a specific peer.

        Returns items that haven't been sent to this peer yet.
        Updates remaining counts and marks as sent.
        """
        items = []

        for item_id, entry in list(self._queue.items()):
            if len(items) >= max_items:
                break

            if peer_id in entry.peers_sent_to:
                # Already sent to this peer
                continue

            if entry.remaining_count <= 0:
                # Exhausted, shouldn't happen but safety check
                continue

            items.append(entry.item)
            entry.peers_sent_to.add(peer_id)
            entry.remaining_count -= 1

        # Clean up exhausted entries
        self._cleanup()

        return items

    def _cleanup(self):
        """Remove entries with no remaining propagations."""
        exhausted = [
            item_id for item_id, entry in self._queue.items()
            if entry.remaining_count <= 0
        ]
        for item_id in exhausted:
            del self._queue[item_id]

    def __len__(self) -> int:
        return len(self._queue)

    def pending_count(self) -> int:
        """Total remaining propagations across all items."""
        return sum(e.remaining_count for e in self._queue.values())


# =============================================================================
# Gossip Layer
# =============================================================================

class GossipLayer:
    """
    Combines deduplication and propagation for a peer.

    Usage:
        gossip = GossipLayer(peer_id="alice")

        # When receiving gossip
        for item in received_items:
            gossip.receive(item)

        # During keepalive
        items_to_send = gossip.get_items_for_keepalive(peer_id="bob")
    """

    def __init__(
        self,
        peer_id: str,
        fanout: int = 3,
        max_seen: int = 100_000,
        max_items_per_keepalive: int = 5,
    ):
        self.peer_id = peer_id
        self.fanout = fanout
        self.max_items_per_keepalive = max_items_per_keepalive

        self._seen = DualHashTable(max_size=max_seen)
        self._queue = PropagationQueue(fanout=fanout)

        # Storage for received items (for retrieval by session_id, etc.)
        self._items: Dict[str, GossipItem] = {}

    def receive(self, item: GossipItem) -> bool:
        """
        Process a received gossip item.

        Returns True if this is new (will be propagated).
        Returns False if already seen (dropped).
        """
        data = item.to_bytes()

        if self._seen.check_seen(data):
            return False  # Already seen, drop

        # New item
        self._seen.mark_seen(data)
        self._queue.add(item)

        # Store for later retrieval
        item_id = hash1(data)
        self._items[item_id] = item

        return True

    def get_items_for_keepalive(self, peer_id: str) -> List[GossipItem]:
        """Get gossip items to include in keepalive to peer."""
        return self._queue.get_items_for_peer(
            peer_id,
            max_items=self.max_items_per_keepalive,
        )

    def get_item(self, item_id: str) -> Optional[GossipItem]:
        """Retrieve a stored item by ID."""
        return self._items.get(item_id)

    def get_items_by_type(self, item_type: GossipType) -> List[GossipItem]:
        """Get all stored items of a specific type."""
        return [
            item for item in self._items.values()
            if item.item_type == item_type
        ]

    def get_items_for_session(self, session_id: str) -> List[GossipItem]:
        """Get all stored items for a specific session."""
        return [
            item for item in self._items.values()
            if item.payload.get("session_id") == session_id
        ]

    @property
    def seen_count(self) -> int:
        """Number of items in dedup table."""
        return len(self._seen)

    @property
    def queue_length(self) -> int:
        """Number of items in propagation queue."""
        return len(self._queue)

    @property
    def pending_propagations(self) -> int:
        """Total remaining propagations."""
        return self._queue.pending_count()

    def stats(self) -> dict:
        """Get statistics about gossip state."""
        return {
            "seen_count": self.seen_count,
            "queue_length": self.queue_length,
            "pending_propagations": self.pending_propagations,
            "stored_items": len(self._items),
        }


# =============================================================================
# Utility Functions
# =============================================================================

def create_lock_result_item(lock_result: dict) -> GossipItem:
    """Create a gossip item from a LOCK_RESULT."""
    return GossipItem(
        item_type=GossipType.LOCK_RESULT,
        payload=lock_result,
        signatures=lock_result.get("witness_signatures", []),
    )


def create_topup_result_item(topup_result: dict) -> GossipItem:
    """Create a gossip item from a TOPUP_RESULT."""
    return GossipItem(
        item_type=GossipType.TOPUP_RESULT,
        payload=topup_result,
        signatures=topup_result.get("witness_signatures", []),
    )


def create_attestation_item(attestation: dict) -> GossipItem:
    """Create a gossip item from an ATTESTATION."""
    return GossipItem(
        item_type=GossipType.ATTESTATION,
        payload=attestation,
        signatures=attestation.get("signatures", []),
    )
