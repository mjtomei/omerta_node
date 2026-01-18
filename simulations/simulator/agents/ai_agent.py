"""
AI Agent using Anthropic Claude API

This agent uses the Claude API to make decisions based on:
- Current protocol state
- Available actions
- Goal/role description
- Protocol rules

The agent is given a system prompt that includes the protocol rules
and is asked to select actions based on the current context.
"""

import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

try:
    import anthropic
    ANTHROPIC_AVAILABLE = True
except ImportError:
    ANTHROPIC_AVAILABLE = False

from .base import Agent, AgentContext, ActionSpec
from ..engine import Action, Message


# Default model to use
DEFAULT_MODEL = "claude-sonnet-4-20250514"


@dataclass
class AIAgentConfig:
    """Configuration for AI agent."""
    model: str = DEFAULT_MODEL
    max_tokens: int = 1024
    temperature: float = 0.7
    api_key: Optional[str] = None  # Uses ANTHROPIC_API_KEY env var if not provided


@dataclass
class AIAgent(Agent):
    """
    An agent that uses Claude to make decisions.

    The agent is given:
    - A role and goal (e.g., "consumer", "maximize profit while minimizing risk")
    - Protocol rules (injected into system prompt)
    - Current state and available actions

    The AI is asked to select an action or wait.
    """

    agent_id: str
    role: str
    goal: str
    protocol_rules: str
    config: AIAgentConfig = field(default_factory=AIAgentConfig)
    message_queue: List[Message] = field(default_factory=list)
    action_history: List[Dict[str, Any]] = field(default_factory=list)

    # Internal state
    _client: Optional['anthropic.Anthropic'] = field(default=None, repr=False)
    _initialized: bool = False

    def __post_init__(self):
        self._initialize_client()

    def _initialize_client(self):
        """Initialize the Anthropic client."""
        if not ANTHROPIC_AVAILABLE:
            return

        api_key = self.config.api_key or os.environ.get("ANTHROPIC_API_KEY")
        if api_key:
            self._client = anthropic.Anthropic(api_key=api_key)
            self._initialized = True

    @property
    def is_available(self) -> bool:
        """Check if AI agent is available (API key configured)."""
        return self._initialized and self._client is not None

    def receive_message(self, message: Message):
        """Receive a message."""
        self.message_queue.append(message)

    def get_pending_messages(self) -> List[Message]:
        """Get and clear pending messages."""
        messages = self.message_queue.copy()
        self.message_queue.clear()
        return messages

    def decide_action(self, context: AgentContext) -> Optional[Action]:
        """
        Use Claude to decide on an action.

        The AI is given the current context and asked to select
        from available actions or choose to wait.
        """
        if not self.is_available:
            # Fallback to no-op if API not available
            return None

        # Build the prompt
        system_prompt = self._build_system_prompt()
        user_prompt = self._build_user_prompt(context)

        try:
            response = self._client.messages.create(
                model=self.config.model,
                max_tokens=self.config.max_tokens,
                temperature=self.config.temperature,
                system=system_prompt,
                messages=[{"role": "user", "content": user_prompt}],
            )

            # Parse the response to extract action
            action = self._parse_response(response, context)

            # Record action in history
            self.action_history.append({
                "time": context.current_time,
                "action": action.action_type if action else "wait",
                "params": action.params if action else {},
                "context_summary": self._summarize_context(context),
            })

            return action

        except Exception as e:
            # Log error and return None (wait)
            self.action_history.append({
                "time": context.current_time,
                "action": "error",
                "error": str(e),
            })
            return None

    def _build_system_prompt(self) -> str:
        """Build the system prompt with protocol rules."""
        return f"""You are an AI agent participating in a distributed protocol simulation.

## Your Role
{self.role}

## Your Goal
{self.goal}

## Protocol Rules
{self.protocol_rules}

## Instructions
- You will be given the current state and available actions
- Respond with a JSON object containing your chosen action
- If you want to wait (not take any action), respond with: {{"action": "wait"}}
- If you want to take an action, respond with: {{"action": "<action_name>", "params": {{...}}}}
- Always follow the protocol rules
- Consider the current state and your goal when making decisions
- Do not include any text outside the JSON object
"""

    def _build_user_prompt(self, context: AgentContext) -> str:
        """Build the user prompt with current context."""
        # Format available actions
        actions_str = "\n".join([
            f"  - {a.name}: {a.description} (params: {list(a.parameters.keys()) if a.parameters else []})"
            for a in context.available_actions
        ]) if context.available_actions else "  No specific actions available"

        # Format pending messages
        messages_str = "\n".join([
            f"  - From {m.sender}: {m.msg_type} at t={m.timestamp}"
            for m in context.pending_messages
        ]) if context.pending_messages else "  No pending messages"

        # Format active transactions
        transactions_str = "\n".join([
            f"  - {t.get('session_id', 'unknown')}: {t.get('status', 'unknown')}"
            for t in context.active_transactions
        ]) if context.active_transactions else "  No active transactions"

        return f"""## Current State
- Time: {context.current_time}
- Agent ID: {context.agent_id}

## Pending Messages
{messages_str}

## Active Transactions
{transactions_str}

## Available Actions
{actions_str}

## Your Decision
Based on the current state and your goal, what action do you want to take?
Respond with a JSON object: {{"action": "<name>", "params": {{...}}}} or {{"action": "wait"}}
"""

    def _parse_response(
        self,
        response: 'anthropic.types.Message',
        context: AgentContext,
    ) -> Optional[Action]:
        """Parse Claude's response to extract action."""
        import json

        content = response.content[0].text if response.content else ""

        # Try to parse as JSON
        try:
            # Extract JSON from response (handle markdown code blocks)
            json_str = content
            if "```json" in content:
                json_str = content.split("```json")[1].split("```")[0]
            elif "```" in content:
                json_str = content.split("```")[1].split("```")[0]

            data = json.loads(json_str.strip())

            action_name = data.get("action", "wait")
            if action_name == "wait":
                return None

            params = data.get("params", {})
            return Action(action_type=action_name, params=params)

        except (json.JSONDecodeError, IndexError, KeyError):
            # If we can't parse, assume wait
            return None

    def _summarize_context(self, context: AgentContext) -> Dict[str, Any]:
        """Create a summary of the context for logging."""
        return {
            "time": context.current_time,
            "pending_message_count": len(context.pending_messages),
            "active_transaction_count": len(context.active_transactions),
            "available_action_count": len(context.available_actions) if context.available_actions else 0,
        }

    def reset(self):
        """Reset the agent state."""
        self.message_queue.clear()
        self.action_history.clear()


def create_ai_agent(
    agent_id: str,
    role: str,
    goal: str,
    protocol_rules: str,
    model: str = DEFAULT_MODEL,
    api_key: Optional[str] = None,
) -> AIAgent:
    """
    Factory function to create an AI agent.

    Args:
        agent_id: Unique identifier
        role: Description of the agent's role
        goal: What the agent is trying to achieve
        protocol_rules: Protocol rules to follow
        model: Claude model to use
        api_key: Anthropic API key (uses env var if not provided)

    Returns:
        Configured AIAgent instance
    """
    config = AIAgentConfig(model=model, api_key=api_key)
    return AIAgent(
        agent_id=agent_id,
        role=role,
        goal=goal,
        protocol_rules=protocol_rules,
        config=config,
    )


# =============================================================================
# Protocol-Specific AI Agents
# =============================================================================

# Consumer protocol rules
CONSUMER_PROTOCOL_RULES = """
As a consumer in the escrow lock protocol:

1. INITIATE_LOCK: Start a lock with a provider
   - Specify amount and provider
   - Your balance must be sufficient

2. VERIFY_COMMITMENT: Check provider's witness selection
   - Verify provider chain checkpoint
   - Verify witness selection is deterministic

3. SEND_REQUESTS: Send verification requests to witnesses
   - Wait for provider commitment first
   - Send to all selected witnesses

4. SIGN_LOCK: Counter-sign the lock result
   - Only sign if enough witnesses accepted
   - Verify the result matches your request

Your goal is to successfully lock funds while protecting against:
- Incorrect provider chain state
- Malicious witness selection
- Insufficient witness consensus
"""

PROVIDER_PROTOCOL_RULES = """
As a provider in the escrow lock protocol:

1. RECEIVE_INTENT: Accept lock intent from consumer
   - Validate consumer's checkpoint reference
   - Verify amount is reasonable

2. SELECT_WITNESSES: Choose witnesses deterministically
   - Use combined nonces for randomness
   - Select from trusted peers

3. SEND_COMMITMENT: Commit to witness selection
   - Include chain segment for verification
   - Send to consumer

4. WAIT_FOR_LOCK: Wait for lock completion
   - Monitor for lock result
   - Transition to service phase on success

Your goal is to facilitate successful locks while:
- Selecting reputable witnesses
- Providing accurate chain state
- Avoiding lock failures
"""

WITNESS_PROTOCOL_RULES = """
As a witness in the escrow lock protocol:

1. RECEIVE_REQUEST: Accept verification request
   - Check your knowledge of consumer chain
   - Request sync if needed

2. CHECK_BALANCE: Verify consumer has sufficient balance
   - Include locked amounts in calculation
   - Share preliminary verdict with peers

3. VOTE: Submit your final vote
   - Consider peer preliminaries
   - Vote accept only if balance is sufficient

4. SIGN_RESULT: Sign the consensus result
   - Participate in signature collection
   - Propagate to consumer

5. FINALIZE: Record lock on your chain
   - Wait for consumer signature
   - Broadcast balance update

Your goal is to:
- Accurately verify consumer balance
- Reach consensus with peer witnesses
- Prevent double-spend attempts
"""


def create_consumer_ai_agent(
    agent_id: str,
    goal: str = "Successfully lock funds with minimum cost and risk",
    model: str = DEFAULT_MODEL,
    api_key: Optional[str] = None,
) -> AIAgent:
    """Create an AI consumer agent."""
    return create_ai_agent(
        agent_id=agent_id,
        role="Consumer seeking to lock funds with a provider",
        goal=goal,
        protocol_rules=CONSUMER_PROTOCOL_RULES,
        model=model,
        api_key=api_key,
    )


def create_provider_ai_agent(
    agent_id: str,
    goal: str = "Facilitate successful escrow locks and maximize service revenue",
    model: str = DEFAULT_MODEL,
    api_key: Optional[str] = None,
) -> AIAgent:
    """Create an AI provider agent."""
    return create_ai_agent(
        agent_id=agent_id,
        role="Provider facilitating escrow lock for compute services",
        goal=goal,
        protocol_rules=PROVIDER_PROTOCOL_RULES,
        model=model,
        api_key=api_key,
    )


def create_witness_ai_agent(
    agent_id: str,
    goal: str = "Accurately verify balances and reach honest consensus",
    model: str = DEFAULT_MODEL,
    api_key: Optional[str] = None,
) -> AIAgent:
    """Create an AI witness agent."""
    return create_ai_agent(
        agent_id=agent_id,
        role="Witness verifying consumer balance for escrow lock",
        goal=goal,
        protocol_rules=WITNESS_PROTOCOL_RULES,
        model=model,
        api_key=api_key,
    )
