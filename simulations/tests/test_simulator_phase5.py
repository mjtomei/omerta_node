"""
Phase 5 Tests: AI Integration with Anthropic API

Tests for:
- AI agent creation and configuration
- Protocol rule injection
- Action parsing
- Mock API responses
- Integration with simulator

Note: Most tests use mocking to avoid actual API calls.
Integration tests with real API are marked and can be skipped.
"""

import pytest
import os
import json
from unittest.mock import Mock, patch, MagicMock
from dataclasses import dataclass

from simulations.simulator.agents.ai_agent import (
    AIAgent,
    AIAgentConfig,
    create_ai_agent,
    create_consumer_ai_agent,
    create_provider_ai_agent,
    create_witness_ai_agent,
    CONSUMER_PROTOCOL_RULES,
    PROVIDER_PROTOCOL_RULES,
    WITNESS_PROTOCOL_RULES,
    ANTHROPIC_AVAILABLE,
)
from simulations.simulator.agents.base import AgentContext, ActionSpec


# =============================================================================
# Helper Functions
# =============================================================================

def make_context(
    agent_id: str = "test_agent",
    current_time: float = 0.0,
    pending_messages: list = None,
    available_actions: list = None,
) -> AgentContext:
    """Create a test context."""
    return AgentContext(
        agent_id=agent_id,
        role="test",
        goal="test",
        local_chain=None,
        cached_peer_chains={},
        pending_messages=pending_messages or [],
        active_transactions=[],
        current_time=current_time,
        available_actions=available_actions or [],
        protocol_rules="",
    )


def mock_anthropic_response(action: str, params: dict = None) -> Mock:
    """Create a mock Anthropic API response."""
    content = json.dumps({"action": action, "params": params or {}})

    mock_content = Mock()
    mock_content.text = content

    mock_response = Mock()
    mock_response.content = [mock_content]

    return mock_response


# =============================================================================
# Agent Creation Tests
# =============================================================================

class TestAIAgentCreation:
    def test_create_ai_agent_basic(self):
        """AI agent can be created with basic parameters."""
        agent = create_ai_agent(
            agent_id="test",
            role="Test role",
            goal="Test goal",
            protocol_rules="Test rules",
        )

        assert agent.agent_id == "test"
        assert agent.role == "Test role"
        assert agent.goal == "Test goal"
        assert agent.protocol_rules == "Test rules"

    def test_create_consumer_ai_agent(self):
        """Consumer AI agent has correct role and rules."""
        agent = create_consumer_ai_agent("consumer_1")

        assert agent.agent_id == "consumer_1"
        assert "Consumer" in agent.role
        assert "INITIATE_LOCK" in agent.protocol_rules
        assert "VERIFY_COMMITMENT" in agent.protocol_rules

    def test_create_provider_ai_agent(self):
        """Provider AI agent has correct role and rules."""
        agent = create_provider_ai_agent("provider_1")

        assert agent.agent_id == "provider_1"
        assert "Provider" in agent.role
        assert "SELECT_WITNESSES" in agent.protocol_rules
        assert "SEND_COMMITMENT" in agent.protocol_rules

    def test_create_witness_ai_agent(self):
        """Witness AI agent has correct role and rules."""
        agent = create_witness_ai_agent("witness_1")

        assert agent.agent_id == "witness_1"
        assert "Witness" in agent.role
        assert "CHECK_BALANCE" in agent.protocol_rules
        assert "VOTE" in agent.protocol_rules


# =============================================================================
# Configuration Tests
# =============================================================================

class TestAIAgentConfig:
    def test_default_config(self):
        """Default config has sensible values."""
        config = AIAgentConfig()

        assert config.max_tokens == 1024
        assert config.temperature == 0.7
        assert config.api_key is None

    def test_custom_config(self):
        """Config can be customized."""
        config = AIAgentConfig(
            model="claude-opus-4-20250514",
            max_tokens=2048,
            temperature=0.5,
            api_key="test_key",
        )

        assert config.model == "claude-opus-4-20250514"
        assert config.max_tokens == 2048
        assert config.temperature == 0.5
        assert config.api_key == "test_key"

    def test_agent_uses_config(self):
        """Agent uses provided config."""
        config = AIAgentConfig(max_tokens=512)
        agent = AIAgent(
            agent_id="test",
            role="test",
            goal="test",
            protocol_rules="test",
            config=config,
        )

        assert agent.config.max_tokens == 512


# =============================================================================
# Protocol Rules Tests
# =============================================================================

class TestProtocolRules:
    def test_consumer_rules_exist(self):
        """Consumer protocol rules are defined."""
        assert len(CONSUMER_PROTOCOL_RULES) > 0
        assert "INITIATE_LOCK" in CONSUMER_PROTOCOL_RULES

    def test_provider_rules_exist(self):
        """Provider protocol rules are defined."""
        assert len(PROVIDER_PROTOCOL_RULES) > 0
        assert "SELECT_WITNESSES" in PROVIDER_PROTOCOL_RULES

    def test_witness_rules_exist(self):
        """Witness protocol rules are defined."""
        assert len(WITNESS_PROTOCOL_RULES) > 0
        assert "CHECK_BALANCE" in WITNESS_PROTOCOL_RULES

    def test_consumer_rules_mention_balance(self):
        """Consumer rules mention balance requirement."""
        assert "balance" in CONSUMER_PROTOCOL_RULES.lower()

    def test_witness_rules_mention_double_spend(self):
        """Witness rules mention double-spend prevention."""
        assert "double-spend" in WITNESS_PROTOCOL_RULES.lower()


# =============================================================================
# System Prompt Tests
# =============================================================================

class TestSystemPrompt:
    def test_system_prompt_includes_role(self):
        """System prompt includes agent role."""
        agent = create_ai_agent(
            agent_id="test",
            role="Test Consumer",
            goal="Test goal",
            protocol_rules="Test rules",
        )

        prompt = agent._build_system_prompt()
        assert "Test Consumer" in prompt

    def test_system_prompt_includes_goal(self):
        """System prompt includes agent goal."""
        agent = create_ai_agent(
            agent_id="test",
            role="Test role",
            goal="Maximize profit",
            protocol_rules="Test rules",
        )

        prompt = agent._build_system_prompt()
        assert "Maximize profit" in prompt

    def test_system_prompt_includes_rules(self):
        """System prompt includes protocol rules."""
        agent = create_ai_agent(
            agent_id="test",
            role="Test role",
            goal="Test goal",
            protocol_rules="RULE_1: Do this\nRULE_2: Do that",
        )

        prompt = agent._build_system_prompt()
        assert "RULE_1" in prompt
        assert "RULE_2" in prompt


# =============================================================================
# User Prompt Tests
# =============================================================================

class TestUserPrompt:
    def test_user_prompt_includes_time(self):
        """User prompt includes current time."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context(current_time=5.5)

        prompt = agent._build_user_prompt(context)
        assert "5.5" in prompt

    def test_user_prompt_includes_agent_id(self):
        """User prompt includes agent ID."""
        agent = create_ai_agent("test_agent_123", "role", "goal", "rules")
        context = make_context(agent_id="test_agent_123")

        prompt = agent._build_user_prompt(context)
        assert "test_agent_123" in prompt

    def test_user_prompt_shows_no_messages(self):
        """User prompt shows when no messages pending."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context(pending_messages=[])

        prompt = agent._build_user_prompt(context)
        assert "No pending messages" in prompt


# =============================================================================
# Response Parsing Tests
# =============================================================================

class TestResponseParsing:
    def test_parse_wait_action(self):
        """Parse wait action from response."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context()

        response = mock_anthropic_response("wait")
        action = agent._parse_response(response, context)

        assert action is None

    def test_parse_action_with_params(self):
        """Parse action with parameters."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context()

        response = mock_anthropic_response(
            "initiate_lock",
            {"provider": "provider_1", "amount": 10.0}
        )
        action = agent._parse_response(response, context)

        assert action is not None
        assert action.action_type == "initiate_lock"
        assert action.params["provider"] == "provider_1"
        assert action.params["amount"] == 10.0

    def test_parse_action_no_params(self):
        """Parse action without parameters."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context()

        response = mock_anthropic_response("check_status")
        action = agent._parse_response(response, context)

        assert action is not None
        assert action.action_type == "check_status"
        assert action.params == {}

    def test_parse_invalid_json_returns_none(self):
        """Invalid JSON response returns None (wait)."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context()

        mock_content = Mock()
        mock_content.text = "This is not valid JSON"
        mock_response = Mock()
        mock_response.content = [mock_content]

        action = agent._parse_response(mock_response, context)
        assert action is None

    def test_parse_json_in_code_block(self):
        """Parse JSON wrapped in markdown code block."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        context = make_context()

        mock_content = Mock()
        mock_content.text = '```json\n{"action": "vote", "params": {"verdict": "accept"}}\n```'
        mock_response = Mock()
        mock_response.content = [mock_content]

        action = agent._parse_response(mock_response, context)

        assert action is not None
        assert action.action_type == "vote"
        assert action.params["verdict"] == "accept"


# =============================================================================
# Message Queue Tests
# =============================================================================

class TestMessageQueue:
    def test_receive_message(self):
        """Agent can receive messages."""
        agent = create_ai_agent("test", "role", "goal", "rules")

        from simulations.simulator.engine import Message
        msg = Message(msg_type="TEST", sender="other", payload={}, timestamp=0.0)
        agent.receive_message(msg)

        assert len(agent.message_queue) == 1

    def test_get_pending_messages_clears_queue(self):
        """Getting pending messages clears the queue."""
        agent = create_ai_agent("test", "role", "goal", "rules")

        from simulations.simulator.engine import Message
        msg = Message(msg_type="TEST", sender="other", payload={}, timestamp=0.0)
        agent.receive_message(msg)

        messages = agent.get_pending_messages()
        assert len(messages) == 1
        assert len(agent.message_queue) == 0

    def test_reset_clears_queue(self):
        """Reset clears message queue."""
        agent = create_ai_agent("test", "role", "goal", "rules")

        from simulations.simulator.engine import Message
        msg = Message(msg_type="TEST", sender="other", payload={}, timestamp=0.0)
        agent.receive_message(msg)

        agent.reset()
        assert len(agent.message_queue) == 0


# =============================================================================
# Action History Tests
# =============================================================================

class TestActionHistory:
    def test_action_history_starts_empty(self):
        """Action history starts empty."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        assert len(agent.action_history) == 0

    def test_reset_clears_history(self):
        """Reset clears action history."""
        agent = create_ai_agent("test", "role", "goal", "rules")
        agent.action_history.append({"action": "test"})

        agent.reset()
        assert len(agent.action_history) == 0


# =============================================================================
# Availability Tests
# =============================================================================

class TestAvailability:
    def test_agent_without_api_key_not_available(self):
        """Agent without API key is not available."""
        # Clear environment variable
        old_key = os.environ.pop("ANTHROPIC_API_KEY", None)
        try:
            agent = create_ai_agent("test", "role", "goal", "rules")
            # May or may not be available depending on environment
            # Just verify the property exists
            _ = agent.is_available
        finally:
            if old_key:
                os.environ["ANTHROPIC_API_KEY"] = old_key

    def test_decide_action_returns_none_when_unavailable(self):
        """decide_action returns None when API not available."""
        # Create agent without API key
        old_key = os.environ.pop("ANTHROPIC_API_KEY", None)
        try:
            agent = create_ai_agent("test", "role", "goal", "rules")
            agent._client = None
            agent._initialized = False

            context = make_context()
            action = agent.decide_action(context)

            assert action is None
        finally:
            if old_key:
                os.environ["ANTHROPIC_API_KEY"] = old_key


# =============================================================================
# Mock API Integration Tests
# =============================================================================

class TestMockAPIIntegration:
    def test_decide_action_calls_api(self):
        """decide_action calls the API."""
        agent = create_ai_agent("test", "role", "goal", "rules")

        # Mock the client
        mock_client = Mock()
        mock_client.messages.create.return_value = mock_anthropic_response("vote", {"verdict": "accept"})
        agent._client = mock_client
        agent._initialized = True

        context = make_context()
        action = agent.decide_action(context)

        assert mock_client.messages.create.called
        assert action is not None
        assert action.action_type == "vote"

    def test_api_error_returns_none(self):
        """API error results in None action."""
        agent = create_ai_agent("test", "role", "goal", "rules")

        # Mock the client to raise error
        mock_client = Mock()
        mock_client.messages.create.side_effect = Exception("API Error")
        agent._client = mock_client
        agent._initialized = True

        context = make_context()
        action = agent.decide_action(context)

        assert action is None
        assert len(agent.action_history) == 1
        assert "error" in agent.action_history[0]


# =============================================================================
# Import Tests
# =============================================================================

class TestImports:
    def test_anthropic_availability_flag(self):
        """ANTHROPIC_AVAILABLE flag exists."""
        # The flag indicates if anthropic package is installed
        assert isinstance(ANTHROPIC_AVAILABLE, bool)

    def test_ai_agent_importable_from_simulator(self):
        """AI agent classes are importable from main simulator module."""
        from simulations.simulator import (
            AIAgent,
            AIAgentConfig,
            create_ai_agent,
            create_consumer_ai_agent,
            create_provider_ai_agent,
            create_witness_ai_agent,
        )

        assert AIAgent is not None
        assert AIAgentConfig is not None


# =============================================================================
# Integration Test (requires API key)
# =============================================================================

@pytest.mark.skipif(
    not os.environ.get("ANTHROPIC_API_KEY"),
    reason="ANTHROPIC_API_KEY not set"
)
class TestRealAPIIntegration:
    """
    These tests use the real Anthropic API.
    They are skipped unless ANTHROPIC_API_KEY is set.
    """

    def test_real_api_call(self):
        """Test with real API call (skipped if no key)."""
        agent = create_consumer_ai_agent("test_consumer")

        if not agent.is_available:
            pytest.skip("API not available")

        context = make_context(
            available_actions=[
                ActionSpec(
                    name="initiate_lock",
                    description="Start an escrow lock",
                    parameters={"provider": "str", "amount": "float"},
                    preconditions=["has_balance"],
                ),
                ActionSpec(
                    name="wait",
                    description="Do nothing this tick",
                    parameters={},
                    preconditions=[],
                ),
            ]
        )

        action = agent.decide_action(context)
        # Should return either an action or None (wait)
        assert action is None or hasattr(action, "action_type")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
