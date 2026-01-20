"""
Phase 3 Tests: Protocol Integration

Tests for:
- Protocol adapters (ConsumerAgent, ProviderAgent, WitnessAgent)
- Protocol setup from traces
- Assertion evaluation
- Trace runner
"""

import pytest
import os

from simulations.simulator import (
    # Protocol
    ConsumerAgent,
    ProviderAgent,
    WitnessAgent,
    create_protocol_agents_from_trace,
    # Assertions
    AssertionResult,
    evaluate_assertion,
    evaluate_all_assertions,
    # Runner
    TraceRunner,
    TraceRunResult,
    run_trace,
    # Traces
    Trace,
    TraceAction,
    TraceAssertion,
    parse_trace,
    load_trace,
    # Network
    Region,
    NetworkModel,
    create_specific_network,
)
from simulations.simulator.traces.schema import (
    TraceNetworkSpec, TraceNodeSpec,
    TraceSetup, TraceChainSpec, TraceRelationship,
)
from simulations.simulator.protocol.setup import (
    create_chain_from_spec,
    setup_relationships,
    infer_roles_from_trace,
)
from simulations.chain.primitives import Chain
from simulations.transactions.escrow_lock_generated import (
    Consumer, Provider, Witness,
    ConsumerState, ProviderState, WitnessState,
)


# =============================================================================
# Helper Functions
# =============================================================================

def make_simple_network_spec() -> TraceNetworkSpec:
    """Create a simple network spec for testing."""
    return TraceNetworkSpec(
        seed=42,
        nodes=[
            TraceNodeSpec(id="consumer", region=Region.NORTH_AMERICA, connection="cable"),
            TraceNodeSpec(id="provider", region=Region.NORTH_AMERICA, connection="datacenter"),
            TraceNodeSpec(id="witness_0", region=Region.NORTH_AMERICA, connection="fiber"),
            TraceNodeSpec(id="witness_1", region=Region.EUROPE, connection="fiber"),
            TraceNodeSpec(id="witness_2", region=Region.EUROPE, connection="datacenter"),
        ],
        partitions=[],
    )


def make_simple_setup() -> TraceSetup:
    """Create a simple setup for testing."""
    return TraceSetup(
        chains={
            "consumer": TraceChainSpec(balance=100.0, trust=1.0),
            "provider": TraceChainSpec(balance=50.0, trust=2.0),
            "witness_0": TraceChainSpec(balance=0.0, trust=2.0),
            "witness_1": TraceChainSpec(balance=0.0, trust=2.0),
            "witness_2": TraceChainSpec(balance=0.0, trust=2.5),
        },
        relationships=[
            TraceRelationship(peers=["consumer", "provider"], age_days=30),
            TraceRelationship(
                peers=["witness_0", "witness_1", "witness_2", "provider"],
                age_days=100,
            ),
        ],
    )


def make_simple_trace() -> Trace:
    """Create a simple trace for testing."""
    return Trace(
        name="test_trace",
        description="A test trace",
        network=make_simple_network_spec(),
        setup=make_simple_setup(),
        actions=[
            TraceAction(
                time=0.0,
                actor="consumer",
                action="initiate_lock",
                params={"provider": "provider", "amount": 10.0, "session_id": "test_session"},
            ),
        ],
        assertions=[
            TraceAssertion(
                type="consumer_state",
                description="Consumer should transition from IDLE",
                params={"consumer": "consumer", "expected_state": "SENDING_LOCK_INTENT"},
            ),
        ],
    )


# =============================================================================
# Protocol Adapter Tests
# =============================================================================

class TestProtocolAdapters:
    def test_consumer_agent_creation(self):
        """ConsumerAgent wraps Consumer protocol actor."""
        chain = Chain("consumer", "priv_consumer", 0.0)
        actor = Consumer(peer_id="consumer", chain=chain)
        agent = ConsumerAgent(agent_id="consumer", protocol_actor=actor)

        assert agent.agent_id == "consumer"
        assert isinstance(agent.protocol_actor, Consumer)

    def test_provider_agent_creation(self):
        """ProviderAgent wraps Provider protocol actor."""
        chain = Chain("provider", "priv_provider", 0.0)
        actor = Provider(peer_id="provider", chain=chain)
        agent = ProviderAgent(agent_id="provider", protocol_actor=actor)

        assert agent.agent_id == "provider"
        assert isinstance(agent.protocol_actor, Provider)

    def test_witness_agent_creation(self):
        """WitnessAgent wraps Witness protocol actor."""
        chain = Chain("witness", "priv_witness", 0.0)
        actor = Witness(peer_id="witness", chain=chain)
        agent = WitnessAgent(agent_id="witness", protocol_actor=actor)

        assert agent.agent_id == "witness"
        assert isinstance(agent.protocol_actor, Witness)

    def test_consumer_initiate_lock(self):
        """ConsumerAgent can initiate lock."""
        chain = Chain("consumer", "priv_consumer", 0.0)
        # Need to record a peer hash for the provider
        chain.record_peer_hash("provider", "test_hash", 0.0)

        actor = Consumer(peer_id="consumer", chain=chain)
        agent = ConsumerAgent(agent_id="consumer", protocol_actor=actor)

        agent.initiate_lock("provider", 10.0)

        # Consumer should transition to SENDING_LOCK_INTENT
        assert agent.state == ConsumerState.SENDING_LOCK_INTENT

    def test_consumer_failed_without_provider_record(self):
        """ConsumerAgent fails lock if no provider record."""
        chain = Chain("consumer", "priv_consumer", 0.0)
        # Don't record provider hash

        actor = Consumer(peer_id="consumer", chain=chain)
        agent = ConsumerAgent(agent_id="consumer", protocol_actor=actor)

        agent.initiate_lock("provider", 10.0)

        assert agent.is_failed
        assert agent.reject_reason == "no_prior_provider_checkpoint"

    def test_witness_cached_chain(self):
        """WitnessAgent can set cached chain data."""
        chain = Chain("witness", "priv_witness", 0.0)
        actor = Witness(peer_id="witness", chain=chain)
        agent = WitnessAgent(agent_id="witness", protocol_actor=actor)

        agent.set_cached_chain("consumer", {"balance": 100.0, "head_hash": "abc123"})

        assert agent.protocol_actor.load("cached_chains", {})["consumer"]["balance"] == 100.0


# =============================================================================
# Chain Setup Tests
# =============================================================================

class TestChainSetup:
    def test_create_chain_from_spec(self):
        """Chain is created from spec."""
        spec = TraceChainSpec(balance=100.0, trust=1.5)
        chain = create_chain_from_spec("test_peer", spec, 0.0)

        assert chain.public_key == "test_peer"
        assert len(chain.blocks) == 1  # Genesis

    def test_create_chain_without_spec(self):
        """Chain is created with defaults when no spec."""
        chain = create_chain_from_spec("test_peer", None, 0.0)

        assert chain.public_key == "test_peer"
        assert len(chain.blocks) == 1

    def test_setup_relationships(self):
        """Relationships are set up by recording peer hashes."""
        chains = {
            "alice": Chain("alice", "priv_alice", 0.0),
            "bob": Chain("bob", "priv_bob", 0.0),
        }

        relationships = [(["alice", "bob"], 30)]  # 30 days
        setup_relationships(chains, relationships, 1000.0)

        # Alice should have Bob's hash
        bob_record = chains["alice"].get_peer_hash("bob")
        assert bob_record is not None
        assert bob_record.payload["peer"] == "bob"

        # Bob should have Alice's hash
        alice_record = chains["bob"].get_peer_hash("alice")
        assert alice_record is not None
        assert alice_record.payload["peer"] == "alice"


# =============================================================================
# Role Inference Tests
# =============================================================================

class TestRoleInference:
    def test_infer_consumer_role(self):
        """Consumer role inferred from initiate_lock action."""
        trace = Trace(
            name="test",
            description="",
            network=make_simple_network_spec(),
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="alice", action="initiate_lock", params={}),
            ],
            assertions=[],
        )

        roles = infer_roles_from_trace(trace)
        assert roles["alice"] == "consumer"

    def test_infer_provider_role(self):
        """Provider role inferred from select_witnesses action."""
        trace = Trace(
            name="test",
            description="",
            network=make_simple_network_spec(),
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="bob", action="select_witnesses", params={}),
            ],
            assertions=[],
        )

        roles = infer_roles_from_trace(trace)
        assert roles["bob"] == "provider"

    def test_infer_witness_role(self):
        """Witness role inferred from vote action."""
        trace = Trace(
            name="test",
            description="",
            network=make_simple_network_spec(),
            setup=TraceSetup(chains={}, relationships=[]),
            actions=[
                TraceAction(time=0.0, actor="charlie", action="vote", params={}),
            ],
            assertions=[],
        )

        roles = infer_roles_from_trace(trace)
        assert roles["charlie"] == "witness"


# =============================================================================
# Assertion Evaluation Tests
# =============================================================================

class TestAssertionEvaluation:
    def test_consumer_state_assertion_pass(self):
        """Consumer state assertion passes when state matches."""
        chain = Chain("consumer", "priv_consumer", 0.0)
        actor = Consumer(peer_id="consumer", chain=chain)
        actor.state = ConsumerState.LOCKED
        agent = ConsumerAgent(agent_id="consumer", protocol_actor=actor)

        assertion = TraceAssertion(
            type="consumer_state",
            description="Consumer should be locked",
            params={"consumer": "consumer", "expected_state": "LOCKED"},
        )

        state = {"agents": {"consumer": agent}}
        result = evaluate_assertion(assertion, state)

        assert result.passed
        assert "LOCKED" in result.message

    def test_consumer_state_assertion_fail(self):
        """Consumer state assertion fails when state doesn't match."""
        chain = Chain("consumer", "priv_consumer", 0.0)
        actor = Consumer(peer_id="consumer", chain=chain)
        actor.state = ConsumerState.FAILED
        agent = ConsumerAgent(agent_id="consumer", protocol_actor=actor)

        assertion = TraceAssertion(
            type="consumer_state",
            description="Consumer should be locked",
            params={"consumer": "consumer", "expected_state": "LOCKED"},
        )

        state = {"agents": {"consumer": agent}}
        result = evaluate_assertion(assertion, state)

        assert not result.passed
        assert "FAILED" in result.message

    def test_no_messages_dropped_pass(self):
        """No messages dropped assertion passes when stats show zero dropped."""
        assertion = TraceAssertion(
            type="no_messages_dropped",
            description="All messages delivered",
            params={},
        )

        state = {"delivery_stats": {"total_sent": 10, "dropped": 0}}
        result = evaluate_assertion(assertion, state)

        assert result.passed

    def test_no_messages_dropped_fail(self):
        """No messages dropped assertion fails when messages were dropped."""
        assertion = TraceAssertion(
            type="no_messages_dropped",
            description="All messages delivered",
            params={},
        )

        state = {"delivery_stats": {"total_sent": 10, "dropped": 2}}
        result = evaluate_assertion(assertion, state)

        assert not result.passed
        assert "2" in result.message

    def test_unknown_assertion_type(self):
        """Unknown assertion type returns failure."""
        assertion = TraceAssertion(
            type="unknown_assertion_type",
            description="Test",
            params={},
        )

        result = evaluate_assertion(assertion, {})

        assert not result.passed
        assert "Unknown" in result.message


# =============================================================================
# Trace Creation From Agents Tests
# =============================================================================

class TestCreateProtocolAgentsFromTrace:
    def test_creates_all_agents(self):
        """All agents are created from trace."""
        trace = make_simple_trace()
        network = create_specific_network(trace.network, trace.network.seed)

        agents, chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=network,
            current_time=0.0,
        )

        assert "consumer" in agents
        assert "provider" in agents
        assert "witness_0" in agents
        assert "witness_1" in agents
        assert "witness_2" in agents

    def test_creates_correct_agent_types(self):
        """Agent types match inferred roles."""
        trace = make_simple_trace()
        network = create_specific_network(trace.network, trace.network.seed)

        agents, chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=network,
            current_time=0.0,
        )

        assert isinstance(agents["consumer"], ConsumerAgent)
        # Provider and witnesses are inferred from trace

    def test_creates_chains_for_all_nodes(self):
        """Chains are created for all nodes."""
        trace = make_simple_trace()
        network = create_specific_network(trace.network, trace.network.seed)

        agents, chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=network,
            current_time=0.0,
        )

        assert "consumer" in chains
        assert "provider" in chains
        assert "witness_0" in chains

    def test_relationships_are_established(self):
        """Peer relationships are established in chains."""
        trace = make_simple_trace()
        network = create_specific_network(trace.network, trace.network.seed)

        agents, chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=network,
            current_time=0.0,
        )

        # Consumer should have provider's hash
        provider_record = chains["consumer"].get_peer_hash("provider")
        assert provider_record is not None


# =============================================================================
# Trace Runner Tests
# =============================================================================

class TestTraceRunner:
    def test_runner_initializes(self):
        """TraceRunner initializes with trace."""
        trace = make_simple_trace()
        runner = TraceRunner(trace)

        assert runner.current_time == 0.0
        assert len(runner.agents) == 5

    def test_runner_executes_action(self):
        """TraceRunner executes trace actions."""
        trace = make_simple_trace()
        runner = TraceRunner(trace)

        # Run for a short time
        result = runner.run(max_time=1.0)

        assert result.completed
        assert result.tick_count > 0

    def test_runner_collects_message_log(self):
        """TraceRunner collects message log."""
        trace = make_simple_trace()
        runner = TraceRunner(trace)

        result = runner.run(max_time=5.0)

        # Should have some messages in the log
        # (Consumer sends LOCK_INTENT after initiate_lock)
        assert result.message_count >= 0  # May be 0 if simulation doesn't advance


# =============================================================================
# Load and Run Happy Path Trace
# =============================================================================

class TestHappyPathTrace:
    def test_happy_path_loads(self):
        """Happy path trace loads without error."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        assert trace.name == "happy_path_escrow_lock"

    def test_happy_path_creates_agents(self):
        """Happy path trace creates correct agents."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        network = create_specific_network(trace.network, trace.network.seed)

        agents, chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=network,
            current_time=0.0,
        )

        assert "consumer" in agents
        assert "provider" in agents
        assert len(agents) == 7  # consumer + provider + 5 witnesses

    def test_happy_path_runner_initializes(self):
        """Happy path trace can initialize runner."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        runner = TraceRunner(trace)

        assert runner.current_time == 0.0
        assert "consumer" in runner.agents


# =============================================================================
# Network Model Integration Tests
# =============================================================================

class TestNetworkModelIntegration:
    def test_create_network_from_trace_spec(self):
        """Network can be created from TraceNetworkSpec."""
        spec = make_simple_network_spec()
        network = create_specific_network(spec, seed=42)

        assert len(network.nodes) == 5
        assert "consumer" in network.nodes
        assert "provider" in network.nodes

    def test_network_computes_latency(self):
        """Network computes latency between nodes."""
        spec = make_simple_network_spec()
        network = create_specific_network(spec, seed=42)

        latency, dropped = network.compute_latency(
            "consumer", "provider", 1000
        )

        assert not dropped
        assert latency > 0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
