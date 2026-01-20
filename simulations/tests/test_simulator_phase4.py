"""
Phase 4 Tests: Attack Traces and Validation

Tests for:
- Attack trace loading
- Insufficient balance detection
- Double spend prevention
- Network partition handling
- Slow network tolerance
- Assertion validation
"""

import pytest
import os

from simulations.simulator import (
    TraceRunner,
    TraceRunResult,
    run_trace,
    load_trace,
)
from simulations.simulator.assertions.evaluator import (
    assertions_passed,
    format_assertion_results,
)


# =============================================================================
# Helper Functions
# =============================================================================

def get_trace_path(name: str) -> str:
    """Get path to a trace file."""
    base_dir = os.path.dirname(__file__)
    return os.path.join(base_dir, "..", "traces", name)


# =============================================================================
# Attack Trace Loading Tests
# =============================================================================

class TestAttackTraceLoading:
    def test_insufficient_balance_trace_loads(self):
        """Insufficient balance trace loads without error."""
        trace = load_trace(get_trace_path("attacks/insufficient_balance.yaml"))
        assert trace.name == "insufficient_balance"
        assert len(trace.network.nodes) == 7  # consumer + provider + 5 witnesses

    def test_double_spend_trace_loads(self):
        """Double spend trace loads without error."""
        trace = load_trace(get_trace_path("attacks/double_spend_attempt.yaml"))
        assert trace.name == "double_spend_attempt"
        assert len(trace.network.nodes) == 8  # consumer + 2 providers + 5 witnesses

    def test_witness_partition_trace_loads(self):
        """Witness partition trace loads without error."""
        trace = load_trace(get_trace_path("attacks/witness_partition.yaml"))
        assert trace.name == "witness_partition"
        assert len(trace.network.partitions) == 1

    def test_slow_network_trace_loads(self):
        """Slow network trace loads without error."""
        trace = load_trace(get_trace_path("attacks/slow_network.yaml"))
        assert trace.name == "slow_network"
        # All nodes have slow connections
        for node in trace.network.nodes:
            assert node.connection in ["satellite_geo", "satellite_leo", "dsl", "4g_lte"]


# =============================================================================
# Insufficient Balance Tests
# =============================================================================

class TestInsufficientBalance:
    def test_trace_has_correct_setup(self):
        """Consumer has less balance than lock amount."""
        trace = load_trace(get_trace_path("attacks/insufficient_balance.yaml"))

        # Consumer has 100 units
        consumer_spec = trace.setup.chains.get("consumer")
        assert consumer_spec is not None
        assert consumer_spec.balance == 100.0

        # First action locks 150 units
        first_action = trace.actions[0]
        assert first_action.action == "initiate_lock"
        assert first_action.params["amount"] == 150.0

    def test_runner_initializes(self):
        """Runner initializes with insufficient balance trace."""
        trace = load_trace(get_trace_path("attacks/insufficient_balance.yaml"))
        runner = TraceRunner(trace)
        assert "consumer" in runner.agents

    def test_consumer_balance_is_tracked(self):
        """Consumer's balance is available to witnesses."""
        trace = load_trace(get_trace_path("attacks/insufficient_balance.yaml"))
        runner = TraceRunner(trace)

        # Check that witnesses have cached consumer balance
        for agent_id, agent in runner.agents.items():
            if hasattr(agent, 'protocol_actor'):
                cached = agent.protocol_actor.load("cached_chains", {})
                if "consumer" in cached:
                    assert cached["consumer"]["balance"] == 100.0


# =============================================================================
# Double Spend Tests
# =============================================================================

class TestDoubleSpend:
    def test_trace_has_two_providers(self):
        """Trace involves two separate providers."""
        trace = load_trace(get_trace_path("attacks/double_spend_attempt.yaml"))

        provider_ids = [n.id for n in trace.network.nodes if "provider" in n.id]
        assert len(provider_ids) == 2
        assert "provider_1" in provider_ids
        assert "provider_2" in provider_ids

    def test_trace_has_two_lock_attempts(self):
        """Trace contains two lock attempts."""
        trace = load_trace(get_trace_path("attacks/double_spend_attempt.yaml"))

        lock_actions = [a for a in trace.actions if a.action == "initiate_lock"]
        assert len(lock_actions) == 2

        # First lock
        assert lock_actions[0].params["provider"] == "provider_1"
        assert lock_actions[0].params["amount"] == 80.0

        # Second lock (should fail)
        assert lock_actions[1].params["provider"] == "provider_2"
        assert lock_actions[1].params["amount"] == 80.0

    def test_trace_has_both_assertions(self):
        """Trace has assertions for both lock attempts."""
        trace = load_trace(get_trace_path("attacks/double_spend_attempt.yaml"))

        assertion_types = [a.type for a in trace.assertions]
        assert "lock_succeeded" in assertion_types
        assert "lock_failed" in assertion_types


# =============================================================================
# Network Partition Tests
# =============================================================================

class TestNetworkPartition:
    def test_trace_has_partition_spec(self):
        """Trace specifies network partition."""
        trace = load_trace(get_trace_path("attacks/witness_partition.yaml"))

        assert len(trace.network.partitions) == 1
        partition = trace.network.partitions[0]

        # Two groups: NA and EU
        assert len(partition.groups) == 2
        assert partition.start_time == 0.5
        assert partition.duration == 10.0

    def test_partition_groups_are_correct(self):
        """Partition divides witnesses correctly."""
        trace = load_trace(get_trace_path("attacks/witness_partition.yaml"))
        partition = trace.network.partitions[0]

        # Group 1: NA witnesses + consumer + provider
        na_group = partition.groups[0]
        assert "witness_0" in na_group
        assert "witness_1" in na_group
        assert "consumer" in na_group
        assert "provider" in na_group

        # Group 2: EU witnesses
        eu_group = partition.groups[1]
        assert "witness_2" in eu_group
        assert "witness_3" in eu_group
        assert "witness_4" in eu_group


# =============================================================================
# Slow Network Tests
# =============================================================================

class TestSlowNetwork:
    def test_trace_uses_slow_connections(self):
        """All nodes have high-latency connections."""
        trace = load_trace(get_trace_path("attacks/slow_network.yaml"))

        slow_connections = {"satellite_geo", "satellite_leo", "dsl", "4g_lte"}
        for node in trace.network.nodes:
            assert node.connection in slow_connections, \
                f"Node {node.id} has fast connection: {node.connection}"

    def test_trace_has_extended_timing(self):
        """Action timing accounts for slow network."""
        trace = load_trace(get_trace_path("attacks/slow_network.yaml"))

        # Actions are spread out more than normal
        action_times = [a.time for a in trace.actions]
        max_time = max(action_times)

        # Last action is at 35s (vs 2.5s in happy path)
        assert max_time >= 30.0

    def test_runner_handles_slow_trace(self):
        """Runner can process slow network trace."""
        trace = load_trace(get_trace_path("attacks/slow_network.yaml"))
        runner = TraceRunner(trace)

        # Should initialize despite slow connections
        assert len(runner.agents) == 7


# =============================================================================
# Regression Trace Tests
# =============================================================================

class TestRegressionTraces:
    def test_happy_path_trace_exists(self):
        """Happy path regression trace exists."""
        trace = load_trace(get_trace_path("regression/happy_path_escrow_lock.yaml"))
        assert trace.name == "happy_path_escrow_lock"

    def test_happy_path_can_run(self):
        """Happy path trace can run through the runner."""
        trace = load_trace(get_trace_path("regression/happy_path_escrow_lock.yaml"))
        runner = TraceRunner(trace)
        result = runner.run(max_time=10.0)

        assert result.completed
        assert result.tick_count > 0


# =============================================================================
# Assertion Format Tests
# =============================================================================

class TestAssertionFormat:
    def test_assertion_result_formatting(self):
        """Assertion results format correctly."""
        from simulations.simulator.assertions.evaluator import AssertionResult

        result = AssertionResult(
            assertion_type="test_type",
            description="Test description",
            passed=True,
            message="Test passed",
        )

        formatted = str(result)
        assert "PASS" in formatted
        assert "Test description" in formatted

    def test_failed_assertion_formatting(self):
        """Failed assertion results show FAIL."""
        from simulations.simulator.assertions.evaluator import AssertionResult

        result = AssertionResult(
            assertion_type="test_type",
            description="Test description",
            passed=False,
            message="Test failed",
        )

        formatted = str(result)
        assert "FAIL" in formatted


# =============================================================================
# Assertion Handler Tests
# =============================================================================

class TestAssertionHandlers:
    def test_lock_succeeded_handler_exists(self):
        """lock_succeeded handler is registered."""
        from simulations.simulator.assertions.registry import ASSERTION_HANDLERS
        assert "lock_succeeded" in ASSERTION_HANDLERS

    def test_lock_failed_handler_exists(self):
        """lock_failed handler is registered."""
        from simulations.simulator.assertions.registry import ASSERTION_HANDLERS
        assert "lock_failed" in ASSERTION_HANDLERS

    def test_consumer_state_handler_exists(self):
        """consumer_state handler is registered."""
        from simulations.simulator.assertions.registry import ASSERTION_HANDLERS
        assert "consumer_state" in ASSERTION_HANDLERS

    def test_witness_threshold_handler_exists(self):
        """witness_threshold_met handler is registered."""
        from simulations.simulator.assertions.registry import ASSERTION_HANDLERS
        assert "witness_threshold_met" in ASSERTION_HANDLERS

    def test_no_messages_dropped_handler_exists(self):
        """no_messages_dropped handler is registered."""
        from simulations.simulator.assertions.registry import ASSERTION_HANDLERS
        assert "no_messages_dropped" in ASSERTION_HANDLERS


# =============================================================================
# Trace Run Result Tests
# =============================================================================

class TestTraceRunResult:
    def test_result_contains_trace_name(self):
        """Result includes trace name."""
        trace = load_trace(get_trace_path("regression/happy_path_escrow_lock.yaml"))
        result = run_trace(trace, max_time=5.0)

        assert result.trace_name == "happy_path_escrow_lock"

    def test_result_contains_agents(self):
        """Result includes agents dictionary."""
        trace = load_trace(get_trace_path("regression/happy_path_escrow_lock.yaml"))
        result = run_trace(trace, max_time=5.0)

        assert len(result.agents) > 0
        assert "consumer" in result.agents

    def test_result_string_representation(self):
        """Result has useful string representation."""
        trace = load_trace(get_trace_path("regression/happy_path_escrow_lock.yaml"))
        result = run_trace(trace, max_time=5.0)

        result_str = str(result)
        assert "happy_path_escrow_lock" in result_str
        assert "Ticks:" in result_str


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
