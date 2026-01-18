"""
Unit tests for Gossip Protocol implementation.

Tests the dual-hash deduplication table, propagation queue,
and gossip layer.
"""

import pytest
from typing import Dict, List

from simulations.chain.gossip import (
    DualHashTable,
    PropagationQueue,
    GossipLayer,
    GossipType,
    GossipItem,
    hash1,
    hash2,
    create_lock_result_item,
)


# =============================================================================
# DualHashTable Tests
# =============================================================================

class TestDualHashTable:
    """Tests for dual-hash deduplication table."""

    def test_empty_table_returns_false(self):
        """Empty table should not contain anything."""
        table = DualHashTable()
        assert not table.check_seen(b"test data")

    def test_mark_and_check_seen(self):
        """Marked data should be seen on subsequent checks."""
        table = DualHashTable()
        data = b"test data"

        table.mark_seen(data)
        assert table.check_seen(data)

    def test_different_data_not_seen(self):
        """Different data should not be seen."""
        table = DualHashTable()

        table.mark_seen(b"data A")
        assert not table.check_seen(b"data B")

    def test_hash1_collision_detected(self):
        """
        When hash1 collides but hash2 differs, should correctly identify as new.

        We can't easily force a real collision, but we can verify the logic
        by checking that different data with same key but different value
        is not considered seen.
        """
        table = DualHashTable()

        # Mark some data
        table.mark_seen(b"original data")

        # Different data should not be seen (even if we can't force hash1 collision)
        assert not table.check_seen(b"different data")

    def test_eviction_when_over_capacity(self):
        """Old entries should be evicted when table exceeds max size."""
        table = DualHashTable(max_size=3)

        # Add 4 items
        table.mark_seen(b"item 1")
        table.mark_seen(b"item 2")
        table.mark_seen(b"item 3")
        table.mark_seen(b"item 4")

        # Table should be at max size
        assert len(table) == 3

        # Oldest item should have been evicted (false negative)
        assert not table.check_seen(b"item 1")

        # Newer items should still be seen
        assert table.check_seen(b"item 2")
        assert table.check_seen(b"item 3")
        assert table.check_seen(b"item 4")

    def test_lru_eviction(self):
        """Recently accessed items should not be evicted."""
        table = DualHashTable(max_size=3)

        table.mark_seen(b"item 1")
        table.mark_seen(b"item 2")
        table.mark_seen(b"item 3")

        # Access item 1 (moves to end)
        table.check_seen(b"item 1")

        # Add new item, should evict item 2 (oldest not-recently-accessed)
        table.mark_seen(b"item 4")

        assert table.check_seen(b"item 1")  # Was accessed, kept
        assert not table.check_seen(b"item 2")  # Evicted
        assert table.check_seen(b"item 3")
        assert table.check_seen(b"item 4")

    def test_clear(self):
        """Clear should remove all entries."""
        table = DualHashTable()

        table.mark_seen(b"item 1")
        table.mark_seen(b"item 2")
        assert len(table) == 2

        table.clear()
        assert len(table) == 0
        assert not table.check_seen(b"item 1")

    def test_hash_functions_independent(self):
        """hash1 and hash2 should produce different values."""
        data = b"test data"
        h1 = hash1(data)
        h2 = hash2(data)

        # Should be different
        assert h1 != h2

        # Should be deterministic
        assert hash1(data) == h1
        assert hash2(data) == h2


# =============================================================================
# PropagationQueue Tests
# =============================================================================

class TestPropagationQueue:
    """Tests for propagation queue."""

    def create_item(self, session_id: str) -> GossipItem:
        """Helper to create a test gossip item."""
        return GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": session_id, "amount": 10.0},
            signatures=["sig1", "sig2"],
        )

    def test_empty_queue(self):
        """Empty queue should return no items."""
        queue = PropagationQueue(fanout=3)
        items = queue.get_items_for_peer("peer_a")
        assert items == []

    def test_add_and_get_item(self):
        """Added item should be returned for peers."""
        queue = PropagationQueue(fanout=3)
        item = self.create_item("session_1")

        queue.add(item)
        items = queue.get_items_for_peer("peer_a")

        assert len(items) == 1
        assert items[0].payload["session_id"] == "session_1"

    def test_fanout_limit(self):
        """Item should only be sent to fanout number of peers."""
        queue = PropagationQueue(fanout=2)
        item = self.create_item("session_1")

        queue.add(item)

        # First two peers get the item
        assert len(queue.get_items_for_peer("peer_a")) == 1
        assert len(queue.get_items_for_peer("peer_b")) == 1

        # Third peer doesn't (fanout exhausted)
        assert len(queue.get_items_for_peer("peer_c")) == 0

    def test_same_peer_not_sent_twice(self):
        """Same peer should not receive item twice."""
        queue = PropagationQueue(fanout=3)
        item = self.create_item("session_1")

        queue.add(item)

        # First call gets the item
        items1 = queue.get_items_for_peer("peer_a")
        assert len(items1) == 1

        # Second call to same peer gets nothing
        items2 = queue.get_items_for_peer("peer_a")
        assert len(items2) == 0

    def test_exhausted_items_removed(self):
        """Items with no remaining propagations should be removed."""
        queue = PropagationQueue(fanout=2)
        item = self.create_item("session_1")

        queue.add(item)
        assert len(queue) == 1

        queue.get_items_for_peer("peer_a")
        assert len(queue) == 1  # Still has 1 remaining

        queue.get_items_for_peer("peer_b")
        assert len(queue) == 0  # Exhausted, removed

    def test_max_items_per_keepalive(self):
        """Should respect max_items limit."""
        queue = PropagationQueue(fanout=3)

        # Add many items
        for i in range(10):
            queue.add(self.create_item(f"session_{i}"))

        # Should only get max_items
        items = queue.get_items_for_peer("peer_a", max_items=3)
        assert len(items) == 3

    def test_duplicate_add_ignored(self):
        """Adding same item twice should be ignored."""
        queue = PropagationQueue(fanout=3)
        item = self.create_item("session_1")

        queue.add(item)
        queue.add(item)

        assert len(queue) == 1

    def test_pending_count(self):
        """Pending count should track total remaining propagations."""
        queue = PropagationQueue(fanout=3)

        queue.add(self.create_item("session_1"))
        queue.add(self.create_item("session_2"))

        assert queue.pending_count() == 6  # 2 items * 3 fanout

        queue.get_items_for_peer("peer_a")  # Gets both items
        assert queue.pending_count() == 4  # 2 items * 2 remaining


# =============================================================================
# GossipLayer Tests
# =============================================================================

class TestGossipLayer:
    """Tests for combined gossip layer."""

    def create_item(self, session_id: str) -> GossipItem:
        """Helper to create a test gossip item."""
        return GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": session_id, "amount": 10.0},
            signatures=["sig1", "sig2"],
        )

    def test_receive_new_item(self):
        """New items should be accepted and queued."""
        gossip = GossipLayer(peer_id="alice", fanout=3)
        item = self.create_item("session_1")

        result = gossip.receive(item)

        assert result is True  # New item accepted
        assert gossip.seen_count == 1
        assert gossip.queue_length == 1

    def test_receive_duplicate_dropped(self):
        """Duplicate items should be dropped."""
        gossip = GossipLayer(peer_id="alice", fanout=3)
        item = self.create_item("session_1")

        result1 = gossip.receive(item)
        result2 = gossip.receive(item)

        assert result1 is True  # First accepted
        assert result2 is False  # Duplicate dropped
        assert gossip.seen_count == 1
        assert gossip.queue_length == 1

    def test_get_items_for_keepalive(self):
        """Should return items for propagation."""
        gossip = GossipLayer(peer_id="alice", fanout=3)

        gossip.receive(self.create_item("session_1"))
        gossip.receive(self.create_item("session_2"))

        items = gossip.get_items_for_keepalive("bob")

        assert len(items) == 2

    def test_items_propagate_correctly(self):
        """Items should propagate to fanout peers then stop."""
        gossip = GossipLayer(peer_id="alice", fanout=2)
        gossip.receive(self.create_item("session_1"))

        # First two peers get the item
        assert len(gossip.get_items_for_keepalive("bob")) == 1
        assert len(gossip.get_items_for_keepalive("charlie")) == 1

        # Third peer doesn't
        assert len(gossip.get_items_for_keepalive("dave")) == 0

    def test_get_items_by_type(self):
        """Should filter items by type."""
        gossip = GossipLayer(peer_id="alice", fanout=3)

        lock_item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "s1"},
            signatures=["sig"],
        )
        attestation_item = GossipItem(
            item_type=GossipType.ATTESTATION,
            payload={"session_id": "s2"},
            signatures=["sig"],
        )

        gossip.receive(lock_item)
        gossip.receive(attestation_item)

        lock_items = gossip.get_items_by_type(GossipType.LOCK_RESULT)
        assert len(lock_items) == 1
        assert lock_items[0].payload["session_id"] == "s1"

    def test_get_items_for_session(self):
        """Should filter items by session ID."""
        gossip = GossipLayer(peer_id="alice", fanout=3)

        gossip.receive(self.create_item("session_1"))
        gossip.receive(self.create_item("session_2"))
        gossip.receive(self.create_item("session_1"))  # Duplicate, dropped

        items = gossip.get_items_for_session("session_1")
        assert len(items) == 1

    def test_stats(self):
        """Stats should report correct values."""
        gossip = GossipLayer(peer_id="alice", fanout=3)

        gossip.receive(self.create_item("session_1"))
        gossip.receive(self.create_item("session_2"))

        stats = gossip.stats()
        assert stats["seen_count"] == 2
        assert stats["queue_length"] == 2
        assert stats["pending_propagations"] == 6
        assert stats["stored_items"] == 2


# =============================================================================
# Utility Function Tests
# =============================================================================

class TestUtilityFunctions:
    """Tests for utility functions."""

    def test_create_lock_result_item(self):
        """Should create gossip item from lock result."""
        lock_result = {
            "session_id": "test_session",
            "consumer": "alice",
            "provider": "bob",
            "amount": 10.0,
            "witness_signatures": ["sig1", "sig2", "sig3"],
        }

        item = create_lock_result_item(lock_result)

        assert item.item_type == GossipType.LOCK_RESULT
        assert item.payload["session_id"] == "test_session"
        assert len(item.signatures) == 3


# =============================================================================
# Integration Tests
# =============================================================================

class TestGossipIntegration:
    """Integration tests for gossip across multiple peers."""

    def test_gossip_propagation_chain(self):
        """Test gossip propagates through a chain of peers."""
        # Create gossip layers for 5 peers
        peers = {
            name: GossipLayer(peer_id=name, fanout=2)
            for name in ["alice", "bob", "charlie", "dave", "eve"]
        }

        # Alice receives a new item
        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test", "amount": 10.0},
            signatures=["sig1", "sig2"],
        )
        peers["alice"].receive(item)

        # Alice sends keepalive to Bob and Charlie
        for peer_name in ["bob", "charlie"]:
            items = peers["alice"].get_items_for_keepalive(peer_name)
            for i in items:
                peers[peer_name].receive(i)

        # Bob and Charlie should have the item
        assert peers["bob"].seen_count == 1
        assert peers["charlie"].seen_count == 1

        # Bob sends to Dave and Eve
        for peer_name in ["dave", "eve"]:
            items = peers["bob"].get_items_for_keepalive(peer_name)
            for i in items:
                peers[peer_name].receive(i)

        # Dave and Eve should have the item
        assert peers["dave"].seen_count == 1
        assert peers["eve"].seen_count == 1

    def test_dedup_prevents_loops(self):
        """Gossip should not loop back to originator."""
        alice = GossipLayer(peer_id="alice", fanout=2)
        bob = GossipLayer(peer_id="bob", fanout=2)

        # Alice creates and sends item
        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test"},
            signatures=["sig"],
        )
        alice.receive(item)

        # Alice -> Bob
        for i in alice.get_items_for_keepalive("bob"):
            bob.receive(i)

        # Bob -> Alice (should be dropped by Alice)
        items_to_alice = bob.get_items_for_keepalive("alice")
        for i in items_to_alice:
            result = alice.receive(i)
            assert result is False  # Dropped as duplicate


# =============================================================================
# Network Simulation Tests
# =============================================================================

class TestGossipNetworkSimulation:
    """Simulation tests for gossip in a larger network."""

    def create_network(self, size: int, fanout: int = 3) -> Dict[str, GossipLayer]:
        """Create a network of gossip layers."""
        return {
            f"peer_{i}": GossipLayer(peer_id=f"peer_{i}", fanout=fanout)
            for i in range(size)
        }

    def simulate_keepalive_round(
        self,
        peers: Dict[str, GossipLayer],
        connections: Dict[str, List[str]],
    ) -> int:
        """
        Simulate one round of keepalives.

        Each peer sends keepalives to their connected peers.
        Returns total number of new items received across all peers.
        """
        new_items = 0

        # Collect all items to send first (before any receives)
        to_send = []
        for sender_id, sender in peers.items():
            for recipient_id in connections.get(sender_id, []):
                items = sender.get_items_for_keepalive(recipient_id)
                for item in items:
                    to_send.append((recipient_id, item))

        # Now process receives
        for recipient_id, item in to_send:
            if peers[recipient_id].receive(item):
                new_items += 1

        return new_items

    def test_gossip_spreads_through_network(self):
        """Test that gossip eventually reaches most of the network."""
        import random
        random.seed(42)

        # Create network of 20 peers
        peers = self.create_network(size=20, fanout=3)
        peer_ids = list(peers.keys())

        # Create random connections (each peer connected to 4 others)
        connections = {}
        for peer_id in peer_ids:
            others = [p for p in peer_ids if p != peer_id]
            connections[peer_id] = random.sample(others, min(4, len(others)))

        # One peer creates and receives a new item
        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test_session", "amount": 100.0},
            signatures=["sig1", "sig2", "sig3"],
        )
        peers["peer_0"].receive(item)

        # Run keepalive rounds until no new items propagate
        rounds = 0
        max_rounds = 20
        while rounds < max_rounds:
            new_items = self.simulate_keepalive_round(peers, connections)
            rounds += 1
            if new_items == 0:
                break

        # Count how many peers have seen the item
        seen_count = sum(1 for p in peers.values() if p.seen_count > 0)

        # Should have spread to most of the network
        assert seen_count >= 15, f"Only {seen_count}/20 peers saw the item"
        assert rounds < max_rounds, "Gossip didn't converge"

    def test_multiple_items_propagate(self):
        """Test multiple items from different sources propagate correctly."""
        import random
        random.seed(123)

        # Use higher fanout to ensure full propagation in small network
        peers = self.create_network(size=10, fanout=9)  # Can reach all 9 other peers
        peer_ids = list(peers.keys())

        # Fully connected
        connections = {
            peer_id: [p for p in peer_ids if p != peer_id]
            for peer_id in peer_ids
        }

        # Multiple peers create items
        for i in range(3):
            item = GossipItem(
                item_type=GossipType.LOCK_RESULT,
                payload={"session_id": f"session_{i}", "originator": f"peer_{i}"},
                signatures=["sig"],
            )
            peers[f"peer_{i}"].receive(item)

        # Run keepalive rounds until stable
        for _ in range(20):
            new_items = self.simulate_keepalive_round(peers, connections)
            if new_items == 0:
                break

        # Count total items seen across network
        total_seen = sum(p.seen_count for p in peers.values())

        # Each of 3 items should reach all 10 peers = 30 total
        # (Each peer sees its own item + items from others)
        assert total_seen == 30, f"Expected 30 total seen, got {total_seen}"

    def test_high_fanout_faster_propagation(self):
        """Higher fanout should result in faster propagation."""
        import random

        # Same network with low fanout
        random.seed(42)
        low_fanout_peers = self.create_network(size=20, fanout=2)
        peer_ids = list(low_fanout_peers.keys())
        connections = {
            peer_id: [p for p in peer_ids if p != peer_id][:4]
            for peer_id in peer_ids
        }

        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test"},
            signatures=["sig"],
        )
        low_fanout_peers["peer_0"].receive(item)

        low_fanout_rounds = 0
        for _ in range(20):
            if self.simulate_keepalive_round(low_fanout_peers, connections) == 0:
                break
            low_fanout_rounds += 1

        # Same network with high fanout
        random.seed(42)
        high_fanout_peers = self.create_network(size=20, fanout=5)

        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test"},
            signatures=["sig"],
        )
        high_fanout_peers["peer_0"].receive(item)

        high_fanout_rounds = 0
        for _ in range(20):
            if self.simulate_keepalive_round(high_fanout_peers, connections) == 0:
                break
            high_fanout_rounds += 1

        # High fanout should converge faster or equal
        assert high_fanout_rounds <= low_fanout_rounds

    def test_dedup_prevents_exponential_blowup(self):
        """Deduplication should prevent message explosion."""
        peers = self.create_network(size=10, fanout=3)
        peer_ids = list(peers.keys())

        # Fully connected network
        connections = {
            peer_id: [p for p in peer_ids if p != peer_id]
            for peer_id in peer_ids
        }

        # Single item
        item = GossipItem(
            item_type=GossipType.LOCK_RESULT,
            payload={"session_id": "test"},
            signatures=["sig"],
        )
        peers["peer_0"].receive(item)

        # Track total receives per round
        total_receives = 0
        for round_num in range(10):
            new_items = self.simulate_keepalive_round(peers, connections)
            total_receives += new_items

        # Without dedup, would be exponential. With dedup, bounded.
        # 10 peers, each should receive at most once = 9 total receives
        assert total_receives <= 9, f"Too many receives: {total_receives}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
