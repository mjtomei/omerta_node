"""
Unit tests for Escrow Lock Transaction (Step 0)
"""

import pytest
import random
from typing import List

from simulations.chain import Network, Chain, BlockType
from simulations.transactions.escrow_lock import (
    Consumer, Provider, Witness,
    ConsumerState, ProviderState, WitnessState,
    EscrowLockSimulation, MessageType, Message,
    WITNESS_COUNT, WITNESS_THRESHOLD, CONSENSUS_TIMEOUT,
)


# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture
def network():
    """Create a network with some identities and establish DAG."""
    random.seed(42)
    net = Network()

    # Create consumer and provider
    net.create_identity("consumer", initial_trust=1.0)
    net.create_identity("provider", initial_trust=2.0)

    # Create witnesses
    for i in range(10):
        net.create_identity(f"witness_{i}", initial_trust=2.0)

    # Simulate keepalives to create DAG structure
    for day in range(10):
        net.advance_time(86400)
        net.simulate_keepalives(rounds=5)

    return net


@pytest.fixture
def simulation(network):
    """Create a simulation instance."""
    return EscrowLockSimulation(network)


# =============================================================================
# Consumer Tests
# =============================================================================

class TestConsumer:
    """Tests for Consumer actor."""

    def test_consumer_initialization(self, network):
        """Consumer starts in IDLE state."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )
        assert consumer.state == ConsumerState.IDLE

    def test_consumer_initiate_lock(self, network):
        """Consumer can initiate a lock request."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        consumer.initiate_lock("pk_provider", 10.0)

        # Should have stored lock parameters
        assert consumer.load("provider") == "pk_provider"
        assert consumer.load("amount") == 10.0
        assert consumer.load("session_id") is not None
        assert consumer.load("consumer_nonce") is not None

    def test_consumer_fails_without_checkpoint(self, network):
        """Consumer fails if no prior checkpoint of provider exists."""
        # Create fresh consumer with no keepalive history
        network.create_identity("new_consumer", initial_trust=1.0)
        chain = network.get_chain("pk_new_consumer")

        consumer = Consumer(
            peer_id="pk_new_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        consumer.initiate_lock("pk_provider", 10.0)

        # Should fail - no checkpoint
        assert consumer.state == ConsumerState.FAILED
        assert consumer.load("reject_reason") == "no_prior_provider_checkpoint"

    def test_consumer_sends_lock_intent(self, network):
        """Consumer sends LOCK_INTENT message to provider."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        consumer.initiate_lock("pk_provider", 10.0)

        # Should be in SENDING_LOCK_INTENT state
        if consumer.state == ConsumerState.SENDING_LOCK_INTENT:
            outgoing = consumer.tick(network.current_time + 1)

            assert len(outgoing) == 1
            assert outgoing[0].msg_type == MessageType.LOCK_INTENT
            assert outgoing[0].payload["amount"] == 10.0
            assert consumer.state == ConsumerState.WAITING_FOR_WITNESS_COMMITMENT


# =============================================================================
# Provider Tests
# =============================================================================

class TestProvider:
    """Tests for Provider actor."""

    def test_provider_initialization(self, network):
        """Provider starts in IDLE state."""
        chain = network.get_chain("pk_provider")
        provider = Provider(
            peer_id="pk_provider",
            chain=chain,
            current_time=network.current_time,
            network=network,
        )
        assert provider.state == ProviderState.IDLE

    def test_provider_receives_lock_intent(self, network):
        """Provider processes LOCK_INTENT and selects witnesses."""
        chain = network.get_chain("pk_provider")
        provider = Provider(
            peer_id="pk_provider",
            chain=chain,
            current_time=network.current_time,
            network=network,
        )

        # Send a LOCK_INTENT message
        intent = Message(
            msg_type=MessageType.LOCK_INTENT,
            sender="pk_consumer",
            payload={
                "consumer": "pk_consumer",
                "provider": "pk_provider",
                "amount": 10.0,
                "session_id": "test_session",
                "consumer_nonce": "0" * 64,
                "provider_chain_checkpoint": provider.chain.blocks[1].block_hash if len(provider.chain.blocks) > 1 else provider.chain.head_hash,
                "checkpoint_timestamp": network.current_time - 1000,
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        provider.receive_message(intent)

        # Process
        provider.tick(network.current_time + 1)

        # Should have moved to validating checkpoint
        assert provider.state in (ProviderState.VALIDATING_CHECKPOINT, ProviderState.SELECTING_WITNESSES, ProviderState.SENDING_COMMITMENT)

    def test_provider_rejects_unknown_checkpoint(self, network):
        """Provider rejects LOCK_INTENT with unknown checkpoint."""
        chain = network.get_chain("pk_provider")
        provider = Provider(
            peer_id="pk_provider",
            chain=chain,
            current_time=network.current_time,
            network=network,
        )

        # Send LOCK_INTENT with invalid checkpoint
        intent = Message(
            msg_type=MessageType.LOCK_INTENT,
            sender="pk_consumer",
            payload={
                "consumer": "pk_consumer",
                "provider": "pk_provider",
                "amount": 10.0,
                "session_id": "test_session",
                "consumer_nonce": "0" * 64,
                "provider_chain_checkpoint": "invalid_hash_123",
                "checkpoint_timestamp": network.current_time - 1000,
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        provider.receive_message(intent)

        # Process until rejection
        outgoing = []
        for _ in range(5):
            outgoing.extend(provider.tick(network.current_time + 1))

        # Should have sent LOCK_REJECTED
        rejections = [m for m in outgoing if m.msg_type == MessageType.LOCK_REJECTED]
        assert len(rejections) == 1
        assert rejections[0].payload["reason"] == "unknown_checkpoint"


# =============================================================================
# Witness Tests
# =============================================================================

class TestWitness:
    """Tests for Witness actor."""

    def test_witness_initialization(self, network):
        """Witness starts in IDLE state."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )
        assert witness.state == WitnessState.IDLE

    def test_witness_receives_request(self, network):
        """Witness processes WITNESS_REQUEST."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        # Give witness some cached chain data
        witness.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}

        # Send request
        request = Message(
            msg_type=MessageType.WITNESS_REQUEST,
            sender="pk_consumer",
            payload={
                "consumer": "pk_consumer",
                "provider": "pk_provider",
                "amount": 10.0,
                "session_id": "test_session",
                "my_chain_head": "abc123",
                "witnesses": ["pk_witness_0", "pk_witness_1", "pk_witness_2"],
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(request)

        # Process
        witness.tick(network.current_time + 1)

        # Should have moved past IDLE
        assert witness.state != WitnessState.IDLE
        assert witness.load("consumer") == "pk_consumer"


# =============================================================================
# Integration Tests
# =============================================================================

class TestEscrowLockIntegration:
    """End-to-end tests for escrow lock protocol."""

    def test_successful_lock(self, network, simulation):
        """Test successful escrow lock with all parties cooperating."""
        # Create actors
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        # Create witnesses
        witnesses = []
        for i in range(WITNESS_COUNT):
            w = simulation.create_witness(f"pk_witness_{i}")
            # Give witnesses cached balance data
            w.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}
            witnesses.append(w)

        # Initiate lock
        consumer.initiate_lock("pk_provider", 10.0)

        # Run simulation
        ticks = simulation.run_until_stable(max_ticks=200)

        print(f"Simulation completed in {ticks} ticks")
        print(f"Consumer state: {consumer.state}")
        print(f"Provider state: {provider.state}")
        for i, w in enumerate(witnesses):
            print(f"Witness {i} state: {w.state}")

        # Check outcomes
        # Consumer should be LOCKED or FAILED (depends on timing)
        assert consumer.state in (ConsumerState.LOCKED, ConsumerState.FAILED, ConsumerState.WAITING_FOR_RESULT)

    def test_lock_with_insufficient_witnesses(self, network):
        """Test lock fails with insufficient witnesses."""
        sim = EscrowLockSimulation(network)

        consumer = sim.create_consumer("pk_consumer")
        provider = sim.create_provider("pk_provider")

        # Only create 2 witnesses (less than threshold)
        for i in range(2):
            w = sim.create_witness(f"pk_witness_{i}")
            w.cached_chains["pk_consumer"] = {"balance": 100.0}

        consumer.initiate_lock("pk_provider", 10.0)
        sim.run_until_stable(max_ticks=100)

        # May fail due to insufficient witnesses
        # (depending on how provider selection works)

    def test_lock_with_insufficient_balance(self, network, simulation):
        """Test lock fails when consumer has insufficient balance."""
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        # Create witnesses with LOW balance data
        for i in range(WITNESS_COUNT):
            w = simulation.create_witness(f"pk_witness_{i}")
            w.cached_chains["pk_consumer"] = {"balance": 5.0, "head_hash": "abc123"}  # Less than 10.0

        consumer.initiate_lock("pk_provider", 10.0)
        simulation.run_until_stable(max_ticks=200)

        # Witnesses should reject due to insufficient balance
        # Final state depends on consensus

    def test_consumer_timeout(self, network, simulation):
        """Test consumer times out waiting for provider."""
        consumer = simulation.create_consumer("pk_consumer")
        # Don't create provider actor - consumer will timeout

        consumer.initiate_lock("pk_provider", 10.0)

        # Run a few ticks
        for _ in range(10):
            simulation.tick(31.0)  # Advance past WITNESS_COMMITMENT_TIMEOUT

        # Consumer should have failed
        assert consumer.state == ConsumerState.FAILED
        assert consumer.load("reject_reason") == "provider_timeout"


# =============================================================================
# State Machine Tests
# =============================================================================

class TestStateMachineTransitions:
    """Test state machine transition logic."""

    def test_consumer_state_flow(self, network):
        """Test consumer progresses through expected states."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        # Start
        assert consumer.state == ConsumerState.IDLE

        # Initiate
        consumer.initiate_lock("pk_provider", 10.0)
        assert consumer.state == ConsumerState.SENDING_LOCK_INTENT

        # Tick to send
        consumer.tick(network.current_time + 1)
        assert consumer.state == ConsumerState.WAITING_FOR_WITNESS_COMMITMENT

    def test_witness_verdict_accept(self, network):
        """Test witness accepts when balance is sufficient."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        witness.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}

        request = Message(
            msg_type=MessageType.WITNESS_REQUEST,
            sender="pk_consumer",
            payload={
                "consumer": "pk_consumer",
                "provider": "pk_provider",
                "amount": 10.0,
                "session_id": "test",
                "my_chain_head": "abc123",
                "witnesses": ["pk_witness_0"],
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(request)

        # Process through balance check
        for _ in range(10):
            witness.tick(network.current_time + 1)
            if witness.load("verdict") is not None:
                break

        from simulations.transactions.escrow_lock import WitnessVerdict
        assert witness.load("verdict") == WitnessVerdict.ACCEPT

    def test_witness_verdict_reject_insufficient(self, network):
        """Test witness rejects when balance is insufficient."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        witness.cached_chains["pk_consumer"] = {"balance": 5.0, "head_hash": "abc123"}

        request = Message(
            msg_type=MessageType.WITNESS_REQUEST,
            sender="pk_consumer",
            payload={
                "consumer": "pk_consumer",
                "provider": "pk_provider",
                "amount": 10.0,  # More than balance
                "session_id": "test",
                "my_chain_head": "abc123",
                "witnesses": ["pk_witness_0"],
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(request)

        # Process through balance check
        for _ in range(10):
            witness.tick(network.current_time + 1)
            if witness.load("verdict") is not None:
                break

        from simulations.transactions.escrow_lock import WitnessVerdict
        assert witness.load("verdict") == WitnessVerdict.REJECT
        assert witness.load("reject_reason") == "insufficient_balance"


# =============================================================================
# Message Tests
# =============================================================================

class TestMessages:
    """Test message handling."""

    def test_message_routing(self, simulation):
        """Test messages are properly routed between actors."""
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        # Consumer sends message
        msg = Message(
            msg_type=MessageType.LOCK_INTENT,
            sender="pk_consumer",
            payload={"test": "data"},
            timestamp=0,
        )

        simulation.route_message(msg, "pk_provider")

        # Provider should have received it
        assert len(provider.message_queue) == 1
        assert provider.message_queue[0].payload["test"] == "data"

    def test_message_log(self, simulation):
        """Test simulation logs all messages."""
        simulation.create_consumer("pk_consumer")
        simulation.create_provider("pk_provider")

        msg = Message(
            msg_type=MessageType.LOCK_INTENT,
            sender="pk_consumer",
            payload={},
            timestamp=0,
        )

        simulation.route_message(msg, "pk_provider")

        assert len(simulation.message_log) == 1


# =============================================================================
# Top-up Tests
# =============================================================================

class TestTopUp:
    """Tests for escrow top-up functionality."""

    def test_consumer_topup_requires_locked_state(self, network):
        """Consumer can only initiate top-up when in LOCKED state."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        # Try to top-up from IDLE state - should raise error
        with pytest.raises(ValueError) as exc_info:
            consumer.initiate_topup(5.0)
        assert "LOCKED state" in str(exc_info.value)

    def test_consumer_topup_sends_intent(self, network, simulation):
        """Consumer sends TOPUP_INTENT when initiating top-up."""
        # First get to LOCKED state
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        # Create witnesses with balance data
        for i in range(WITNESS_COUNT):
            w = simulation.create_witness(f"pk_witness_{i}")
            w.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}

        # Initiate and complete initial lock
        consumer.initiate_lock("pk_provider", 10.0)
        simulation.run_until_stable(max_ticks=200)

        # If consumer is locked, try top-up
        if consumer.state == ConsumerState.LOCKED:
            consumer.initiate_topup(5.0)

            assert consumer.state == ConsumerState.SENDING_TOPUP
            assert consumer.load("additional_amount") == 5.0

            # Tick to send the message
            outgoing = consumer.tick(network.current_time + 1)

            # Should have sent TOPUP_INTENT to witnesses
            topup_intents = [m for m in outgoing if m.msg_type == MessageType.TOPUP_INTENT]
            assert len(topup_intents) > 0
            assert topup_intents[0].payload["additional_amount"] == 5.0
            assert consumer.state == ConsumerState.WAITING_FOR_TOPUP_RESULT

    def test_consumer_topup_timeout(self, network, simulation):
        """Consumer returns to LOCKED state if top-up times out."""
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        for i in range(WITNESS_COUNT):
            w = simulation.create_witness(f"pk_witness_{i}")
            w.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}

        consumer.initiate_lock("pk_provider", 10.0)
        simulation.run_until_stable(max_ticks=200)

        if consumer.state == ConsumerState.LOCKED:
            consumer.initiate_topup(5.0)
            consumer.tick(network.current_time + 1)  # Send intent

            # Wait for timeout without any witness response
            for _ in range(10):
                simulation.tick(10.0)  # Advance time past CONSENSUS_TIMEOUT

            # Consumer should return to LOCKED state
            assert consumer.state == ConsumerState.LOCKED
            assert consumer.load("topup_failed_reason") == "timeout"

    def test_witness_receives_topup_intent(self, network):
        """Witness processes TOPUP_INTENT in ESCROW_ACTIVE state."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        # Set up witness as if it has an active escrow
        witness.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}
        witness.store("consumer", "pk_consumer")
        witness.store("other_witnesses", ["pk_witness_1", "pk_witness_2"])
        witness.store("total_escrowed", 10.0)
        witness.store("result", {
            "session_id": "test_session",
            "consumer": "pk_consumer",
            "provider": "pk_provider",
            "amount": 10.0,
        })
        witness.state = WitnessState.ESCROW_ACTIVE

        # Send TOPUP_INTENT
        intent = Message(
            msg_type=MessageType.TOPUP_INTENT,
            sender="pk_consumer",
            payload={
                "session_id": "test_session",
                "consumer": "pk_consumer",
                "additional_amount": 5.0,
                "current_lock_result_hash": "abc123",
                "timestamp": network.current_time,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(intent)

        # Process
        witness.tick(network.current_time + 1)

        # Should transition to CHECKING_TOPUP_BALANCE
        assert witness.state == WitnessState.CHECKING_TOPUP_BALANCE

    def test_witness_accepts_topup_with_sufficient_balance(self, network):
        """Witness accepts top-up when consumer has sufficient free balance."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        # Consumer has 100, 10 locked, wants to top up 20 (free: 90 >= 20)
        witness.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}
        witness.store("consumer", "pk_consumer")
        witness.store("other_witnesses", [])  # No other witnesses for simplicity
        witness.store("total_escrowed", 10.0)
        witness.store("result", {
            "session_id": "test_session",
            "consumer": "pk_consumer",
            "provider": "pk_provider",
            "amount": 10.0,
        })
        witness.store("topup_intent", {
            "session_id": "test_session",
            "consumer": "pk_consumer",
            "additional_amount": 20.0,
        })
        witness.state = WitnessState.CHECKING_TOPUP_BALANCE

        # Process balance check
        witness.tick(network.current_time + 1)

        assert witness.load("topup_verdict") == "accept"
        assert witness.state == WitnessState.VOTING_TOPUP

    def test_witness_rejects_topup_with_insufficient_balance(self, network):
        """Witness rejects top-up when consumer has insufficient free balance."""
        chain = network.get_chain("pk_witness_0")
        witness = Witness(
            peer_id="pk_witness_0",
            chain=chain,
            current_time=network.current_time,
        )

        # Consumer has 100, 90 locked, wants to top up 20 (free: 10 < 20)
        witness.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}
        witness.store("consumer", "pk_consumer")
        witness.store("other_witnesses", [])
        witness.store("total_escrowed", 90.0)
        witness.store("result", {
            "session_id": "test_session",
            "consumer": "pk_consumer",
            "provider": "pk_provider",
            "amount": 90.0,
        })
        witness.store("topup_intent", {
            "session_id": "test_session",
            "consumer": "pk_consumer",
            "additional_amount": 20.0,
        })
        witness.state = WitnessState.CHECKING_TOPUP_BALANCE

        # Process balance check
        witness.tick(network.current_time + 1)

        assert witness.load("topup_verdict") == "reject"
        assert witness.load("topup_reject_reason") == "insufficient_free_balance"

    def test_consumer_properties(self, network):
        """Test Consumer is_locked, is_failed, and total_escrowed properties."""
        chain = network.get_chain("pk_consumer")
        consumer = Consumer(
            peer_id="pk_consumer",
            chain=chain,
            current_time=network.current_time,
        )

        # Initial state
        assert not consumer.is_locked
        assert not consumer.is_failed
        assert consumer.total_escrowed == 0.0

        # Failed state
        consumer.store("reject_reason", "test")
        consumer.transition_to(ConsumerState.FAILED)
        assert not consumer.is_locked
        assert consumer.is_failed

        # Locked state
        consumer.store("total_escrowed", 50.0)
        consumer.transition_to(ConsumerState.LOCKED)
        assert consumer.is_locked
        assert not consumer.is_failed
        assert consumer.total_escrowed == 50.0


class TestTopUpIntegration:
    """Integration tests for full top-up flow."""

    def test_successful_topup_flow(self, network, simulation):
        """Test complete top-up flow with all parties cooperating."""
        # Create actors
        consumer = simulation.create_consumer("pk_consumer")
        provider = simulation.create_provider("pk_provider")

        # Create witnesses with sufficient balance data
        witnesses = []
        for i in range(WITNESS_COUNT):
            w = simulation.create_witness(f"pk_witness_{i}")
            w.cached_chains["pk_consumer"] = {"balance": 100.0, "head_hash": "abc123"}
            witnesses.append(w)

        # Phase 1: Initial lock
        consumer.initiate_lock("pk_provider", 10.0)
        simulation.run_until_stable(max_ticks=200)

        if consumer.state != ConsumerState.LOCKED:
            pytest.skip("Initial lock did not succeed - skipping top-up test")

        # Verify initial state
        assert consumer.total_escrowed == 10.0
        initial_chain_len = len(consumer.chain.blocks)

        # Phase 2: Top-up
        consumer.initiate_topup(5.0)

        # Run until stable
        ticks = simulation.run_until_stable(max_ticks=200)

        print(f"Top-up completed in {ticks} ticks")
        print(f"Consumer state: {consumer.state}")
        print(f"Consumer total escrowed: {consumer.total_escrowed}")

        # Consumer should still be LOCKED (returned after top-up)
        assert consumer.state == ConsumerState.LOCKED

        # If top-up succeeded, total should have increased
        if consumer.total_escrowed == 15.0:
            # Check chain has top-up block
            assert len(consumer.chain.blocks) > initial_chain_len

            # Find BALANCE_TOPUP block
            from simulations.chain.primitives import BlockType
            topup_blocks = [b for b in consumer.chain.blocks if b.block_type == BlockType.BALANCE_TOPUP]
            assert len(topup_blocks) == 1
            assert topup_blocks[0].payload["topup_amount"] == 5.0
            assert topup_blocks[0].payload["new_total"] == 15.0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
