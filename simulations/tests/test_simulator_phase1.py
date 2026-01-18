"""
Phase 1 Tests: Core Infrastructure

Tests for:
- EventQueue and SimulationClock
- Network regions and connections
- Pareto latency sampling
- NetworkModel latency calculation
- Network partitions
- Message delivery system
- Simulation engine
"""

import pytest
import random

from simulations.simulator.engine import (
    Event, EventQueue, SimulationClock, Action, Message, SimulationEngine
)
from simulations.simulator.network import (
    Region, get_inter_region_latency, INTER_REGION_LATENCY_MS,
    ConnectionType, CONNECTION_TYPES,
    NetworkModel, NetworkNode, sample_pareto,
    create_network, create_specific_network,
    MessageDeliverySystem, PartitionManager,
)


# =============================================================================
# EventQueue Tests
# =============================================================================

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

    def test_queue_length(self):
        """Queue length is tracked correctly."""
        q = EventQueue()
        assert len(q) == 0

        q.schedule(time=1.0, event_type="a", payload={})
        q.schedule(time=2.0, event_type="b", payload={})
        assert len(q) == 2

        q.next_event()
        assert len(q) == 1


# =============================================================================
# SimulationClock Tests
# =============================================================================

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

    def test_clock_starts_at_given_time(self):
        """Clock starts at specified time."""
        clock = SimulationClock(start_time=500.0)
        assert clock.current_time == 500.0


# =============================================================================
# Region Tests
# =============================================================================

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

    def test_same_region_generally_faster(self):
        """Intra-region latency is generally less than inter-region (with exceptions)."""
        # Most same-region latencies should be < cross-region
        # Exception: Japan is very fast, so Asia->Japan can be faster than Asia->Asia
        exceptions = {
            (Region.ASIA, Region.JAPAN),  # Japan has excellent infra, close to Asia
        }

        for r in Region:
            intra = get_inter_region_latency(r, r)
            for r2 in Region:
                if r != r2 and (r, r2) not in exceptions:
                    inter = get_inter_region_latency(r, r2)
                    assert intra < inter, f"{r} intra should be < {r}->{r2}"

    def test_known_latency_values(self):
        """Spot check known values from SimBlock paper."""
        assert get_inter_region_latency(Region.NORTH_AMERICA, Region.NORTH_AMERICA) == 32
        assert get_inter_region_latency(Region.EUROPE, Region.EUROPE) == 12
        assert get_inter_region_latency(Region.NORTH_AMERICA, Region.EUROPE) == 124


# =============================================================================
# Connection Type Tests
# =============================================================================

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


# =============================================================================
# NetworkNode Tests
# =============================================================================

class TestNetworkNode:
    def test_node_bandwidth_conversion(self):
        """Node converts Mbps to bps correctly."""
        node = NetworkNode(node_id="test", region=Region.NORTH_AMERICA, connection_type="fiber")
        assert node.upload_bps == 1000 * 1_000_000  # 1 Gbps
        assert node.download_bps == 1000 * 1_000_000

    def test_node_connection_property(self):
        """Node returns correct connection type."""
        node = NetworkNode(node_id="test", region=Region.EUROPE, connection_type="cable")
        assert node.connection.name == "Cable Internet"
        assert node.connection.upload_mbps == 20

    def test_node_online_by_default(self):
        """Nodes are online by default."""
        node = NetworkNode(node_id="test", region=Region.ASIA, connection_type="fiber")
        assert node.is_online is True


# =============================================================================
# Pareto Sampling Tests
# =============================================================================

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


# =============================================================================
# NetworkModel Latency Tests
# =============================================================================

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
        assert latency < 100  # < 100ms for same region DC

    def test_cross_region_slower(self, network):
        """Cross-region is slower than same-region."""
        # Sample multiple times to account for Pareto variance
        same_latencies = []
        cross_latencies = []
        for _ in range(100):
            lat, _ = network.compute_latency("na_dc", "na_cable", 1024)
            same_latencies.append(lat)
            lat, _ = network.compute_latency("na_dc", "eu_fiber", 1024)
            cross_latencies.append(lat)

        # Average cross-region should be higher
        assert sum(cross_latencies) / 100 > sum(same_latencies) / 100

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
        # DSL has higher packet loss (0.5%)
        dropped_count = 0
        for _ in range(1000):
            _, dropped = network.compute_latency("asia_dsl", "na_cable", 1024)
            if dropped:
                dropped_count += 1

        # Should have some drops but not all (expect ~5-10 at 0.5% rate)
        assert 1 <= dropped_count <= 50

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


# =============================================================================
# Network Partition Tests
# =============================================================================

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


# =============================================================================
# Partition Manager Tests
# =============================================================================

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


# =============================================================================
# Message Delivery System Tests
# =============================================================================

class TestMessageDeliverySystem:
    @pytest.fixture
    def system(self):
        net = NetworkModel(seed=42)
        net.add_node(NetworkNode("sender", Region.NORTH_AMERICA, "fiber"))
        net.add_node(NetworkNode("recipient", Region.EUROPE, "fiber"))
        queue = EventQueue()
        return MessageDeliverySystem(net, queue), queue, net

    def test_send_schedules_delivery_event(self, system):
        """Sending a message schedules a delivery event."""
        delivery, queue, net = system
        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)

        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        assert queue.peek_time() is not None
        assert queue.peek_time() > 0  # Some latency

    def test_delivery_latency_realistic(self, system):
        """NA-EU message has realistic latency."""
        delivery, queue, net = system
        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)

        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        delivery_time = queue.peek_time()
        # NA-EU base is 124ms, plus last mile, should be 100-500ms
        assert 0.100 < delivery_time < 0.500  # 100-500ms in seconds

    def test_deliver_message_returns_pending(self, system):
        """deliver_message returns the pending message info."""
        delivery, queue, net = system
        msg = Message(msg_type="TEST", sender="sender", payload={"data": 123}, timestamp=0)

        msg_id = delivery.send_message(msg, "sender", "recipient", current_time=0.0)
        pending = delivery.deliver_message(msg_id)

        assert pending is not None
        assert pending.message.payload["data"] == 123
        assert pending.sender == "sender"
        assert pending.recipient == "recipient"

    def test_deliver_unknown_message_returns_none(self, system):
        """Delivering unknown message ID returns None."""
        delivery, queue, net = system
        assert delivery.deliver_message("unknown_id") is None

    def test_dropped_message_not_scheduled(self, system):
        """Dropped messages don't get delivery events."""
        delivery, queue, net = system

        # Take recipient offline
        net.nodes["recipient"].is_online = False

        msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)
        delivery.send_message(msg, "sender", "recipient", current_time=0.0)

        # No event scheduled
        assert queue.peek_time() is None

        # Message recorded as dropped
        assert len(delivery.dropped_messages) == 1

    def test_delivery_stats(self, system):
        """get_delivery_stats returns correct statistics."""
        delivery, queue, net = system

        # Send some messages
        for i in range(10):
            msg = Message(msg_type="TEST", sender="sender", payload={}, timestamp=0)
            msg_id = delivery.send_message(msg, "sender", "recipient", current_time=0.0)
            delivery.deliver_message(msg_id)

        stats = delivery.get_delivery_stats()
        assert stats["total_sent"] == 10
        assert stats["total_delivered"] == 10
        assert stats["latency_ms"]["avg"] > 0


# =============================================================================
# Simulation Engine Tests
# =============================================================================

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

        engine.run(until_time=100.0)

        assert engine.clock.current_time == 50.0  # Stopped at last event


# =============================================================================
# Network Creation Helpers Tests
# =============================================================================

class TestNetworkCreation:
    def test_create_network_creates_nodes(self):
        """create_network creates specified number of nodes."""
        net = create_network(num_nodes=50, seed=42)
        assert len(net.nodes) == 50

    def test_create_network_deterministic(self):
        """create_network is deterministic with same seed."""
        net1 = create_network(num_nodes=20, seed=42)
        net2 = create_network(num_nodes=20, seed=42)

        for node_id in net1.nodes:
            assert net1.nodes[node_id].region == net2.nodes[node_id].region
            assert net1.nodes[node_id].connection_type == net2.nodes[node_id].connection_type

    def test_create_specific_network(self):
        """create_specific_network creates nodes with exact specs."""
        nodes = [
            ("alice", Region.NORTH_AMERICA, "fiber"),
            ("bob", Region.EUROPE, "datacenter"),
        ]
        net = create_specific_network(nodes, seed=42)

        assert len(net.nodes) == 2
        assert net.nodes["alice"].region == Region.NORTH_AMERICA
        assert net.nodes["bob"].connection_type == "datacenter"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
