"""
Phase 2 Tests: Agent Framework

Tests for:
- TraceReplayAgent
- Trace schema and parsing
- Trace validation
"""

import pytest
import os

from simulations.simulator.engine import Action, Message
from simulations.simulator.agents.base import Agent, AgentContext
from simulations.simulator.agents.trace_replay import TraceReplayAgent
from simulations.simulator.traces.schema import (
    Trace, TraceAction, TraceAssertion,
    TraceNetworkSpec, TraceNodeSpec, TracePartitionSpec,
    TraceSetup, TraceChainSpec, TraceRelationship,
    ValidationError,
)
from simulations.simulator.traces.parser import parse_trace, load_trace
from simulations.simulator.network.regions import Region


# =============================================================================
# Helper Functions
# =============================================================================

def make_context(agent_id: str, current_time: float) -> AgentContext:
    """Create a minimal AgentContext for testing."""
    return AgentContext(
        agent_id=agent_id,
        role="test",
        goal="test",
        local_chain=None,
        cached_peer_chains={},
        pending_messages=[],
        active_transactions=[],
        current_time=current_time,
        available_actions=[],
        protocol_rules="",
    )


def make_simple_trace(actions: list) -> Trace:
    """Create a simple trace with given actions."""
    return Trace(
        name="test_trace",
        description="A test trace",
        network=TraceNetworkSpec(
            seed=42,
            nodes=[TraceNodeSpec(id="alice", region=Region.NORTH_AMERICA, connection="fiber")],
            partitions=[],
        ),
        setup=TraceSetup(chains={}, relationships=[]),
        actions=actions,
        assertions=[],
    )


# =============================================================================
# TraceReplayAgent Tests
# =============================================================================

class TestTraceReplayAgent:
    def test_agent_returns_actions_at_correct_time(self):
        """Agent returns actions when their time arrives."""
        trace = make_simple_trace([
            TraceAction(time=0.0, actor="alice", action="do_a", params={}),
            TraceAction(time=1.0, actor="alice", action="do_b", params={}),
            TraceAction(time=2.0, actor="alice", action="do_c", params={}),
        ])
        agent = TraceReplayAgent("alice", trace)

        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action.action_type == "do_a"

        ctx = make_context("alice", 1.0)
        action = agent.decide_action(ctx)
        assert action.action_type == "do_b"

        ctx = make_context("alice", 2.0)
        action = agent.decide_action(ctx)
        assert action.action_type == "do_c"

    def test_agent_skips_other_actors_actions(self):
        """Agent only returns its own actions."""
        trace = make_simple_trace([
            TraceAction(time=0.0, actor="bob", action="bob_action", params={}),
            TraceAction(time=0.0, actor="alice", action="alice_action", params={}),
        ])
        agent = TraceReplayAgent("alice", trace)

        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action.action_type == "alice_action"

    def test_agent_returns_none_when_no_more_actions(self):
        """Agent returns None when trace is exhausted."""
        trace = make_simple_trace([
            TraceAction(time=0.0, actor="alice", action="only_action", params={}),
        ])
        agent = TraceReplayAgent("alice", trace)

        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action is not None

        ctx = make_context("alice", 1.0)
        action = agent.decide_action(ctx)
        assert action is None

    def test_agent_waits_for_action_time(self):
        """Agent returns None if action time hasn't arrived."""
        trace = make_simple_trace([
            TraceAction(time=10.0, actor="alice", action="future_action", params={}),
        ])
        agent = TraceReplayAgent("alice", trace)

        ctx = make_context("alice", 5.0)
        action = agent.decide_action(ctx)
        assert action is None

    def test_agent_preserves_action_params(self):
        """Agent preserves action parameters."""
        trace = make_simple_trace([
            TraceAction(time=0.0, actor="alice", action="do_thing",
                       params={"amount": 10.0, "target": "bob"}),
        ])
        agent = TraceReplayAgent("alice", trace)

        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action.params["amount"] == 10.0
        assert action.params["target"] == "bob"

    def test_agent_reset(self):
        """Agent can be reset to replay trace."""
        trace = make_simple_trace([
            TraceAction(time=0.0, actor="alice", action="do_a", params={}),
        ])
        agent = TraceReplayAgent("alice", trace)

        # First run
        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action is not None

        # Exhausted
        ctx = make_context("alice", 1.0)
        action = agent.decide_action(ctx)
        assert action is None

        # Reset and replay
        agent.reset()
        ctx = make_context("alice", 0.0)
        action = agent.decide_action(ctx)
        assert action.action_type == "do_a"


# =============================================================================
# Trace Schema Tests
# =============================================================================

class TestTraceSchema:
    def test_trace_action_creation(self):
        """TraceAction can be created with required fields."""
        action = TraceAction(time=1.0, actor="alice", action="do_thing")
        assert action.time == 1.0
        assert action.actor == "alice"
        assert action.params == {}

    def test_trace_action_with_params(self):
        """TraceAction can include parameters."""
        action = TraceAction(time=0.0, actor="alice", action="send",
                            params={"to": "bob", "amount": 50})
        assert action.params["to"] == "bob"
        assert action.params["amount"] == 50

    def test_trace_node_spec(self):
        """TraceNodeSpec stores node configuration."""
        node = TraceNodeSpec(id="n1", region=Region.EUROPE, connection="datacenter")
        assert node.id == "n1"
        assert node.region == Region.EUROPE

    def test_trace_partition_spec(self):
        """TracePartitionSpec stores partition configuration."""
        part = TracePartitionSpec(
            groups=[{"a", "b"}, {"c", "d"}],
            start_time=10.0,
            duration=5.0,
        )
        assert len(part.groups) == 2
        assert part.start_time == 10.0
        assert part.duration == 5.0


# =============================================================================
# Trace Parser Tests
# =============================================================================

class TestTraceParser:
    def test_parse_minimal_trace(self):
        """Can parse minimal valid trace."""
        yaml_content = """
name: minimal
description: A minimal trace
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: fiber
setup:
  chains:
    alice:
      balance: 100
actions: []
assertions: []
"""
        trace = parse_trace(yaml_content)
        assert trace.name == "minimal"
        assert len(trace.network.nodes) == 1
        assert trace.network.nodes[0].id == "alice"

    def test_parse_actions(self):
        """Actions are parsed correctly."""
        yaml_content = """
name: with_actions
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: fiber
setup:
  chains: {}
actions:
  - time: 0.0
    actor: alice
    action: initiate_lock
    params:
      provider: bob
      amount: 10
assertions: []
"""
        trace = parse_trace(yaml_content)
        assert len(trace.actions) == 1
        assert trace.actions[0].action == "initiate_lock"
        assert trace.actions[0].params["amount"] == 10

    def test_parse_network_partitions(self):
        """Network partitions are parsed correctly."""
        yaml_content = """
name: with_partition
description: ""
network:
  seed: 42
  nodes:
    - id: a
      region: north_america
      connection: fiber
    - id: b
      region: europe
      connection: fiber
  partitions:
    - groups: [[a], [b]]
      start_time: 10.0
      duration: 5.0
setup:
  chains: {}
actions: []
assertions: []
"""
        trace = parse_trace(yaml_content)
        assert len(trace.network.partitions) == 1
        assert trace.network.partitions[0].duration == 5.0

    def test_parse_setup_chains(self):
        """Chain setup is parsed correctly."""
        yaml_content = """
name: with_chains
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: fiber
setup:
  chains:
    alice:
      balance: 100.0
      trust: 2.5
actions: []
assertions: []
"""
        trace = parse_trace(yaml_content)
        assert "alice" in trace.setup.chains
        assert trace.setup.chains["alice"].balance == 100.0
        assert trace.setup.chains["alice"].trust == 2.5

    def test_parse_assertions(self):
        """Assertions are parsed correctly."""
        yaml_content = """
name: with_assertions
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: fiber
setup:
  chains: {}
actions: []
assertions:
  - type: lock_succeeded
    description: "Lock should succeed"
    session_id: "sess1"
"""
        trace = parse_trace(yaml_content)
        assert len(trace.assertions) == 1
        assert trace.assertions[0].type == "lock_succeeded"
        assert trace.assertions[0].params["session_id"] == "sess1"

    def test_invalid_region_raises_error(self):
        """Invalid region raises validation error."""
        yaml_content = """
name: invalid
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: mars
      connection: fiber
setup:
  chains: {}
actions: []
assertions: []
"""
        with pytest.raises(ValidationError):
            parse_trace(yaml_content)

    def test_invalid_connection_raises_error(self):
        """Invalid connection type raises validation error."""
        yaml_content = """
name: invalid
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: quantum_entanglement
setup:
  chains: {}
actions: []
assertions: []
"""
        with pytest.raises(ValidationError):
            parse_trace(yaml_content)

    def test_missing_required_field_raises_error(self):
        """Missing required field raises validation error."""
        yaml_content = """
name: missing_network
description: ""
setup:
  chains: {}
actions: []
assertions: []
"""
        with pytest.raises(ValidationError):
            parse_trace(yaml_content)

    def test_actions_sorted_by_time(self):
        """Actions are sorted by time after parsing."""
        yaml_content = """
name: unsorted
description: ""
network:
  seed: 42
  nodes:
    - id: alice
      region: north_america
      connection: fiber
setup:
  chains: {}
actions:
  - time: 2.0
    actor: alice
    action: third
  - time: 0.0
    actor: alice
    action: first
  - time: 1.0
    actor: alice
    action: second
assertions: []
"""
        trace = parse_trace(yaml_content)
        assert trace.actions[0].action == "first"
        assert trace.actions[1].action == "second"
        assert trace.actions[2].action == "third"


# =============================================================================
# Load Trace File Tests
# =============================================================================

class TestLoadTraceFile:
    def test_happy_path_trace_loads(self):
        """Happy path trace file loads without error."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        assert trace.name == "happy_path_escrow_lock"

    def test_happy_path_has_expected_nodes(self):
        """Happy path trace has expected network nodes."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)

        node_ids = {n.id for n in trace.network.nodes}
        assert "consumer" in node_ids
        assert "provider" in node_ids
        assert "witness_0" in node_ids

    def test_happy_path_has_actions(self):
        """Happy path trace has actions."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        assert len(trace.actions) > 0

    def test_happy_path_has_assertions(self):
        """Happy path trace has assertions."""
        trace_path = os.path.join(
            os.path.dirname(__file__),
            "..", "traces", "regression", "happy_path_escrow_lock.yaml"
        )
        trace = load_trace(trace_path)
        assert len(trace.assertions) > 0


# =============================================================================
# Agent Receive Message Tests
# =============================================================================

class TestAgentMessages:
    def test_agent_receives_messages(self):
        """Agent can receive messages."""
        trace = make_simple_trace([])
        agent = TraceReplayAgent("alice", trace)

        msg = Message(msg_type="TEST", sender="bob", payload={"data": 123}, timestamp=0)
        agent.receive_message(msg)

        assert len(agent.message_queue) == 1
        assert agent.message_queue[0].payload["data"] == 123

    def test_agent_clears_messages(self):
        """Agent clears messages when retrieved."""
        trace = make_simple_trace([])
        agent = TraceReplayAgent("alice", trace)

        msg = Message(msg_type="TEST", sender="bob", payload={}, timestamp=0)
        agent.receive_message(msg)

        messages = agent.get_pending_messages()
        assert len(messages) == 1
        assert len(agent.message_queue) == 0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
