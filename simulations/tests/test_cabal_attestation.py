"""
Unit tests for Cabal Attestation Transaction (Step 1)

Tests the generated cabal attestation protocol implementation.
"""

import pytest
from typing import List

from simulations.chain import Network, Chain, BlockType
from simulations.transactions.cabal_attestation_generated import (
    Provider, Witness, Consumer,
    ProviderState, WitnessState, ConsumerState,
    MessageType, Message,
    TerminationReason,
    CONNECTIVITY_THRESHOLD, ATTESTATION_THRESHOLD,
)
from simulations.transactions.simulation_harness import CabalAttestationSimulation


# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture
def network():
    """Create a network with identities."""
    net = Network()
    net.create_identity("consumer", initial_trust=1.0)
    net.create_identity("provider", initial_trust=2.0)
    for i in range(5):
        net.create_identity(f"witness_{i}", initial_trust=2.0)

    # Establish some history
    for _ in range(5):
        net.advance_time(86400)
        net.simulate_keepalives(rounds=3)

    return net


@pytest.fixture
def provider(network):
    """Create a provider actor."""
    chain = network.get_chain("pk_provider")
    return Provider(
        peer_id="pk_provider",
        chain=chain,
        current_time=network.current_time,
    )


@pytest.fixture
def consumer(network):
    """Create a consumer actor."""
    chain = network.get_chain("pk_consumer")
    return Consumer(
        peer_id="pk_consumer",
        chain=chain,
        current_time=network.current_time,
    )


@pytest.fixture
def witnesses(network):
    """Create witness actors."""
    result = []
    for i in range(3):
        chain = network.get_chain(f"pk_witness_{i}")
        w = Witness(
            peer_id=f"pk_witness_{i}",
            chain=chain,
            current_time=network.current_time,
        )
        result.append(w)
    return result


# =============================================================================
# Provider Tests
# =============================================================================

class TestProvider:
    """Tests for Provider attestation actor."""

    def test_provider_initial_state(self, provider):
        """Provider starts in WAITING_FOR_LOCK state."""
        assert provider.state == ProviderState.WAITING_FOR_LOCK

    def test_provider_starts_session(self, provider):
        """Provider transitions to VM_PROVISIONING after start_session."""
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=["pk_witness_0", "pk_witness_1"],
            lock_result={"amount": 10.0},
        )

        assert provider.state == ProviderState.VM_PROVISIONING
        assert provider.load("session_id") == "test_session"
        assert provider.load("consumer") == "pk_consumer"

    def test_provider_allocates_vm(self, provider):
        """Provider transitions to NOTIFYING_CABAL after VM allocation."""
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=["pk_witness_0"],
            lock_result={},
        )

        provider.allocate_vm({
            "wireguard_pubkey": "test_pubkey",
            "consumer_endpoint": "10.0.0.1:51820",
            "cabal_endpoints": ["10.0.0.2:51820"],
        })

        assert provider.state == ProviderState.NOTIFYING_CABAL

    def test_provider_sends_vm_allocated(self, provider, network):
        """Provider sends VM_ALLOCATED message to cabal."""
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=["pk_witness_0", "pk_witness_1"],
            lock_result={},
        )
        provider.allocate_vm({"wireguard_pubkey": "test"})

        outgoing = provider.tick(network.current_time + 1)

        # Should send VM_ALLOCATED to witnesses and VM_READY to consumer
        allocated_msgs = [m for m in outgoing if m.msg_type == MessageType.VM_ALLOCATED]
        ready_msgs = [m for m in outgoing if m.msg_type == MessageType.VM_READY]

        assert len(allocated_msgs) == 2  # One per witness
        assert len(ready_msgs) == 1
        assert provider.state == ProviderState.WAITING_FOR_VERIFICATION

    def test_provider_handles_positive_verification(self, provider, network):
        """Provider transitions to VM_RUNNING when cabal verifies."""
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=["pk_witness_0", "pk_witness_1", "pk_witness_2"],
            lock_result={},
        )
        provider.allocate_vm({})
        provider.tick(network.current_time + 1)

        # Simulate positive connectivity votes
        for i in range(3):
            vote = Message(
                msg_type=MessageType.VM_CONNECTIVITY_VOTE,
                sender=f"pk_witness_{i}",
                payload={
                    "session_id": "test_session",
                    "witness": f"pk_witness_{i}",
                    "can_reach_vm": True,
                    "can_see_consumer_connected": True,
                },
                timestamp=network.current_time,
            )
            provider.receive_message(vote)

        # Process all votes - one per tick
        for _ in range(5):
            provider.tick(network.current_time + 2)

        assert provider.state == ProviderState.VM_RUNNING
        assert provider.load("verification_passed") == True

    def test_provider_handles_cancel_request(self, provider, network):
        """Provider handles cancel request from consumer."""
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=["pk_witness_0"],
            lock_result={},
        )
        provider.allocate_vm({})
        provider.tick(network.current_time + 1)

        # Skip to VM_RUNNING
        provider.state = ProviderState.VM_RUNNING
        provider.store("verification_passed", True)

        # Send cancel request
        cancel = Message(
            msg_type=MessageType.CANCEL_REQUEST,
            sender="pk_consumer",
            payload={"session_id": "test_session"},
            timestamp=network.current_time,
        )
        provider.receive_message(cancel)
        provider.tick(network.current_time + 2)

        assert provider.state in (
            ProviderState.HANDLING_CANCEL,
            ProviderState.SENDING_CANCELLATION,
        )


# =============================================================================
# Witness Tests
# =============================================================================

class TestWitness:
    """Tests for Witness attestation actor."""

    def test_witness_initial_state(self, witnesses):
        """Witness starts in AWAITING_ALLOCATION state."""
        assert all(w.state == WitnessState.AWAITING_ALLOCATION for w in witnesses)

    def test_witness_receives_vm_allocated(self, witnesses, network):
        """Witness transitions to VERIFYING_VM on VM_ALLOCATED."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=["pk_witness_1", "pk_witness_2"],
        )

        allocated = Message(
            msg_type=MessageType.VM_ALLOCATED,
            sender="pk_provider",
            payload={
                "session_id": "test_session",
                "allocated_at": network.current_time,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(allocated)
        witness.tick(network.current_time + 1)

        assert witness.state == WitnessState.VERIFYING_VM

    def test_witness_sends_connectivity_vote(self, witnesses, network):
        """Witness sends VM_CONNECTIVITY_VOTE after verification."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=["pk_witness_1"],
        )

        # Receive allocation
        allocated = Message(
            msg_type=MessageType.VM_ALLOCATED,
            sender="pk_provider",
            payload={"session_id": "test_session", "allocated_at": network.current_time},
            timestamp=network.current_time,
        )
        witness.receive_message(allocated)
        witness.tick(network.current_time + 1)

        # Now in VERIFYING_VM, tick to send vote
        outgoing = witness.tick(network.current_time + 2)

        vote_msgs = [m for m in outgoing if m.msg_type == MessageType.VM_CONNECTIVITY_VOTE]
        assert len(vote_msgs) >= 1
        assert vote_msgs[0].payload["can_reach_vm"] == True  # Default is True
        assert witness.state == WitnessState.COLLECTING_VOTES

    def test_witness_monitors_session(self, witnesses, network):
        """Witness enters MONITORING state after successful verification."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=[],
        )

        # Simulate going through verification successfully
        witness.store("connectivity_verified", True)
        witness.state = WitnessState.MONITORING

        # Should stay in monitoring
        witness.tick(network.current_time + 1)
        assert witness.state == WitnessState.MONITORING

    def test_witness_creates_attestation_on_cancel(self, witnesses, network):
        """Witness creates attestation when session ends."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=[],
        )

        # Set up as if in monitoring
        witness.state = WitnessState.MONITORING
        witness.store("connectivity_verified", True)
        witness.store("vm_allocated_msg", {"session_id": "test_session"})
        witness.store("connectivity_votes", [{"witness": witness.peer_id, "can_reach_vm": True}])

        # Receive cancellation
        cancelled = Message(
            msg_type=MessageType.VM_CANCELLED,
            sender="pk_provider",
            payload={
                "session_id": "test_session",
                "reason": "consumer_request",
                "actual_duration_seconds": 3600,
            },
            timestamp=network.current_time,
        )
        witness.receive_message(cancelled)
        witness.tick(network.current_time + 1)

        assert witness.state == WitnessState.ATTESTING


# =============================================================================
# Consumer Tests
# =============================================================================

class TestConsumer:
    """Tests for Consumer attestation actor."""

    def test_consumer_initial_state(self, consumer):
        """Consumer starts in WAITING_FOR_VM state."""
        assert consumer.state == ConsumerState.WAITING_FOR_VM

    def test_consumer_receives_vm_ready(self, consumer, network):
        """Consumer transitions to CONNECTING on VM_READY."""
        consumer.setup_session("test_session", "pk_provider")

        ready = Message(
            msg_type=MessageType.VM_READY,
            sender="pk_provider",
            payload={"session_id": "test_session", "vm_info": {"endpoint": "10.0.0.1"}},
            timestamp=network.current_time,
        )
        consumer.receive_message(ready)
        consumer.tick(network.current_time + 1)

        assert consumer.state == ConsumerState.CONNECTING

    def test_consumer_connects_to_vm(self, consumer, network):
        """Consumer transitions to CONNECTED after connecting."""
        consumer.setup_session("test_session", "pk_provider")

        # Skip to connecting
        consumer.state = ConsumerState.CONNECTING
        consumer.tick(network.current_time + 1)

        assert consumer.state == ConsumerState.CONNECTED

    def test_consumer_requests_cancel(self, consumer, network):
        """Consumer can request session cancellation."""
        consumer.setup_session("test_session", "pk_provider")
        consumer.state = ConsumerState.CONNECTED

        consumer.request_cancel()

        assert consumer.state == ConsumerState.REQUESTING_CANCEL

        outgoing = consumer.tick(network.current_time + 1)

        cancel_msgs = [m for m in outgoing if m.msg_type == MessageType.CANCEL_REQUEST]
        assert len(cancel_msgs) == 1

    def test_consumer_handles_termination(self, consumer, network):
        """Consumer handles session termination."""
        consumer.setup_session("test_session", "pk_provider")
        consumer.state = ConsumerState.CONNECTED

        terminated = Message(
            msg_type=MessageType.SESSION_TERMINATED,
            sender="pk_provider",
            payload={"session_id": "test_session", "reason": "consumer_request"},
            timestamp=network.current_time,
        )
        consumer.receive_message(terminated)
        consumer.tick(network.current_time + 1)

        assert consumer.state == ConsumerState.SESSION_ENDED


# =============================================================================
# Integration Tests
# =============================================================================

class TestCabalAttestationIntegration:
    """End-to-end tests for cabal attestation protocol."""

    def test_successful_session_flow(self, network):
        """Test complete session flow with successful verification."""
        sim = CabalAttestationSimulation(network)

        # Create actors
        provider = Provider(
            peer_id="pk_provider",
            chain=network.get_chain("pk_provider"),
            current_time=network.current_time,
        )

        consumer = Consumer(
            peer_id="pk_consumer",
            chain=network.get_chain("pk_consumer"),
            current_time=network.current_time,
        )

        witnesses = []
        witness_ids = ["pk_witness_0", "pk_witness_1", "pk_witness_2"]
        for wid in witness_ids:
            w = Witness(
                peer_id=wid,
                chain=network.get_chain(wid),
                current_time=network.current_time,
            )
            other_witnesses = [x for x in witness_ids if x != wid]
            w.setup_session("test_session", "pk_consumer", "pk_provider", other_witnesses)
            witnesses.append(w)

        sim.add_provider(provider)
        sim.add_consumer(consumer)
        for w in witnesses:
            sim.add_witness(w)

        # Start session
        consumer.setup_session("test_session", "pk_provider")
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=witness_ids,
            lock_result={"amount": 10.0},
        )
        provider.allocate_vm({
            "wireguard_pubkey": "test_key",
            "consumer_endpoint": "10.0.0.1:51820",
        })

        # Run until verification complete
        ticks = sim.run_until_stable(max_ticks=50)

        print(f"Completed in {ticks} ticks")
        print(f"Provider state: {provider.state}")
        print(f"Consumer state: {consumer.state}")
        for w in witnesses:
            print(f"Witness {w.peer_id} state: {w.state}")

        # Provider should be in VM_RUNNING
        assert provider.state == ProviderState.VM_RUNNING

        # Consumer should be connected
        assert consumer.state == ConsumerState.CONNECTED

        # Witnesses should be monitoring
        assert all(w.state == WitnessState.MONITORING for w in witnesses)

    def test_session_with_consumer_cancel(self, network):
        """Test session flow with consumer-initiated cancellation."""
        sim = CabalAttestationSimulation(network)

        # Create actors
        provider = Provider(
            peer_id="pk_provider",
            chain=network.get_chain("pk_provider"),
            current_time=network.current_time,
        )

        consumer = Consumer(
            peer_id="pk_consumer",
            chain=network.get_chain("pk_consumer"),
            current_time=network.current_time,
        )

        witness_ids = ["pk_witness_0", "pk_witness_1", "pk_witness_2"]
        witnesses = []
        for wid in witness_ids:
            w = Witness(
                peer_id=wid,
                chain=network.get_chain(wid),
                current_time=network.current_time,
            )
            other_witnesses = [x for x in witness_ids if x != wid]
            w.setup_session("test_session", "pk_consumer", "pk_provider", other_witnesses)
            witnesses.append(w)

        sim.add_provider(provider)
        sim.add_consumer(consumer)
        for w in witnesses:
            sim.add_witness(w)

        # Start session
        consumer.setup_session("test_session", "pk_provider")
        provider.start_session(
            session_id="test_session",
            consumer="pk_consumer",
            witnesses=witness_ids,
            lock_result={"amount": 10.0},
        )
        provider.allocate_vm({})

        # Run until VM is running
        sim.run_until_stable(max_ticks=50)

        if provider.state != ProviderState.VM_RUNNING:
            pytest.skip("Verification did not complete")

        # Consumer requests cancel
        consumer.request_cancel()

        # Run until session ends
        sim.run_until_stable(max_ticks=100)

        # Provider should be in SESSION_COMPLETE or waiting for attestation
        assert provider.state in (
            ProviderState.SESSION_COMPLETE,
            ProviderState.WAITING_FOR_ATTESTATION,
            ProviderState.SENDING_CANCELLATION,
        )


# =============================================================================
# Attestation Tests
# =============================================================================

class TestAttestation:
    """Tests for attestation creation and signing."""

    def test_attestation_contains_required_fields(self, witnesses, network):
        """Attestation includes all required fields."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=[],
        )

        # Set up state for attestation
        witness.state = WitnessState.ATTESTING
        witness.store("vm_allocated_msg", {"session_id": "test_session"})
        witness.store("vm_cancelled_msg", {"reason": "consumer_request"})
        witness.store("connectivity_verified", True)
        witness.store("actual_duration_seconds", 3600)
        witness.store("termination_reason", "consumer_request")
        witness.store("connectivity_votes", [
            {"witness": "pk_witness_0", "can_reach_vm": True}
        ])

        outgoing = witness.tick(network.current_time + 1)

        attestation = witness.load("attestation")
        assert attestation is not None
        assert "session_id" in attestation
        assert "vm_allocated_hash" in attestation
        assert "connectivity_verified" in attestation
        assert "actual_duration_seconds" in attestation
        assert "termination_reason" in attestation
        assert "cabal_votes" in attestation
        assert "cabal_signatures" in attestation

    def test_attestation_recorded_on_chain(self, witnesses, network):
        """Attestation is recorded on witness chain."""
        witness = witnesses[0]
        witness.setup_session(
            session_id="test_session",
            consumer="pk_consumer",
            provider="pk_provider",
            other_witnesses=[],
        )

        # Fast-forward to propagating
        witness.store("attestation", {
            "session_id": "test_session",
            "connectivity_verified": True,
            "actual_duration_seconds": 3600,
            "termination_reason": "consumer_request",
        })
        witness.store("attestation_signatures", [
            {"witness": "pk_witness_0", "signature": "sig1"},
            {"witness": "pk_witness_1", "signature": "sig2"},
            {"witness": "pk_witness_2", "signature": "sig3"},
        ])
        witness.store("consumer", "pk_consumer")
        witness.store("provider", "pk_provider")
        witness.state = WitnessState.PROPAGATING_ATTESTATION

        initial_blocks = len(witness.chain.blocks)
        witness.tick(network.current_time + 1)

        # Should have added attestation block
        assert len(witness.chain.blocks) == initial_blocks + 1
        assert witness.chain.blocks[-1].block_type == BlockType.ATTESTATION


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
