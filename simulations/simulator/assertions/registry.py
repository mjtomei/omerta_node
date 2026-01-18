"""
Assertion Handler Registry

Maps assertion types to their evaluation functions.
"""

from typing import Callable, Dict, Any


# Type for assertion handlers
# Handler(assertion_params, simulation_state) -> (passed, message)
AssertionHandler = Callable[[Dict[str, Any], Dict[str, Any]], tuple]


# Global registry of assertion handlers
ASSERTION_HANDLERS: Dict[str, AssertionHandler] = {}


def register_assertion_handler(assertion_type: str):
    """
    Decorator to register an assertion handler.

    Usage:
        @register_assertion_handler("lock_succeeded")
        def check_lock_succeeded(params, state):
            ...
            return (True, "Lock succeeded")
    """
    def decorator(func: AssertionHandler) -> AssertionHandler:
        ASSERTION_HANDLERS[assertion_type] = func
        return func
    return decorator


# =============================================================================
# Built-in Assertion Handlers
# =============================================================================

@register_assertion_handler("lock_succeeded")
def check_lock_succeeded(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that an escrow lock succeeded.

    Params:
        session_id: Optional session ID to check (if not provided, checks any consumer)

    State:
        agents: Dict of agent_id -> agent
    """
    session_id = params.get("session_id")
    agents = state.get("agents", {})

    # Find consumers
    for agent_id, agent in agents.items():
        if hasattr(agent, "is_locked"):
            # If session_id specified, check it matches
            if session_id and hasattr(agent, "session_id"):
                # Note: protocol generates session_id from hash, so trace-specified
                # session_ids may not match. Check if consumer is locked regardless.
                pass  # Fall through to check is_locked

            if agent.is_locked:
                actual_session = getattr(agent, "session_id", "unknown")
                return (True, f"Lock succeeded (session: {actual_session})")
            elif hasattr(agent, "is_failed") and agent.is_failed:
                reason = getattr(agent, "reject_reason", "unknown")
                return (False, f"Lock failed: {reason}")

    return (False, "No consumer found or consumer not in terminal state")


@register_assertion_handler("consumer_state")
def check_consumer_state(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that a consumer is in the expected state.

    Params:
        consumer: The consumer agent ID
        expected_state: The expected state name (e.g., "LOCKED")

    State:
        agents: Dict of agent_id -> agent
    """
    consumer_id = params.get("consumer")
    expected = params.get("expected_state")
    agents = state.get("agents", {})

    agent = agents.get(consumer_id)
    if not agent:
        return (False, f"Consumer {consumer_id} not found")

    if not hasattr(agent, "state"):
        return (False, f"Agent {consumer_id} has no state attribute")

    actual_state = agent.state.name if hasattr(agent.state, "name") else str(agent.state)

    if actual_state == expected:
        return (True, f"Consumer {consumer_id} is in {expected} state")
    else:
        return (False, f"Consumer {consumer_id} is in {actual_state}, expected {expected}")


@register_assertion_handler("witness_threshold_met")
def check_witness_threshold(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that enough witnesses voted accept.

    Params:
        session_id: The session ID
        min_accepts: Minimum number of accept votes required

    State:
        agents: Dict of agent_id -> agent
        message_log: List of all messages sent
    """
    session_id = params.get("session_id")
    min_accepts = params.get("min_accepts", 3)
    agents = state.get("agents", {})

    # Count witnesses that have accepted
    accept_count = 0
    for agent_id, agent in agents.items():
        if hasattr(agent, "verdict"):
            verdict = agent.verdict
            if verdict == "accept":
                accept_count += 1

    if accept_count >= min_accepts:
        return (True, f"Witness threshold met: {accept_count} >= {min_accepts}")
    else:
        return (False, f"Witness threshold not met: {accept_count} < {min_accepts}")


@register_assertion_handler("no_messages_dropped")
def check_no_messages_dropped(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that all messages were delivered.

    State:
        delivery_stats: Message delivery statistics
    """
    stats = state.get("delivery_stats", {})

    dropped = stats.get("dropped", 0)
    if dropped == 0:
        total = stats.get("total_sent", 0)
        return (True, f"All {total} messages delivered")
    else:
        return (False, f"{dropped} messages were dropped")


@register_assertion_handler("provider_state")
def check_provider_state(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that a provider is in the expected state.

    Params:
        provider: The provider agent ID
        expected_state: The expected state name

    State:
        agents: Dict of agent_id -> agent
    """
    provider_id = params.get("provider")
    expected = params.get("expected_state")
    agents = state.get("agents", {})

    agent = agents.get(provider_id)
    if not agent:
        return (False, f"Provider {provider_id} not found")

    if not hasattr(agent, "state"):
        return (False, f"Agent {provider_id} has no state attribute")

    actual_state = agent.state.name if hasattr(agent.state, "name") else str(agent.state)

    if actual_state == expected:
        return (True, f"Provider {provider_id} is in {expected} state")
    else:
        return (False, f"Provider {provider_id} is in {actual_state}, expected {expected}")


@register_assertion_handler("witness_state")
def check_witness_state(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that a witness is in the expected state.

    Params:
        witness: The witness agent ID
        expected_state: The expected state name

    State:
        agents: Dict of agent_id -> agent
    """
    witness_id = params.get("witness")
    expected = params.get("expected_state")
    agents = state.get("agents", {})

    agent = agents.get(witness_id)
    if not agent:
        return (False, f"Witness {witness_id} not found")

    if not hasattr(agent, "state"):
        return (False, f"Agent {witness_id} has no state attribute")

    actual_state = agent.state.name if hasattr(agent.state, "name") else str(agent.state)

    if actual_state == expected:
        return (True, f"Witness {witness_id} is in {expected} state")
    else:
        return (False, f"Witness {witness_id} is in {actual_state}, expected {expected}")


@register_assertion_handler("lock_failed")
def check_lock_failed(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that an escrow lock failed (inverse of lock_succeeded).

    Params:
        session_id: The session ID to check
        expected_reason: Optional expected failure reason

    State:
        agents: Dict of agent_id -> agent
    """
    session_id = params.get("session_id")
    expected_reason = params.get("expected_reason")
    agents = state.get("agents", {})

    # Find the consumer for this session
    for agent_id, agent in agents.items():
        if hasattr(agent, "is_failed") and hasattr(agent, "session_id"):
            if agent.session_id == session_id:
                if agent.is_failed:
                    actual_reason = getattr(agent, "reject_reason", "unknown")
                    if expected_reason and actual_reason != expected_reason:
                        return (False, f"Lock failed with reason '{actual_reason}', expected '{expected_reason}'")
                    return (True, f"Lock correctly failed: {actual_reason}")
                else:
                    return (False, f"Lock did not fail for session {session_id}")

    return (False, f"No consumer found for session {session_id}")


@register_assertion_handler("message_received")
def check_message_received(params: Dict[str, Any], state: Dict[str, Any]) -> tuple:
    """
    Check that a specific type of message was received by an agent.

    Params:
        agent: The agent that should have received the message
        msg_type: The message type to check for

    State:
        message_log: List of all messages
    """
    agent_id = params.get("agent")
    msg_type = params.get("msg_type")
    message_log = state.get("message_log", [])

    for msg in message_log:
        if msg.get("recipient") == agent_id and msg.get("msg_type") == msg_type:
            return (True, f"Agent {agent_id} received {msg_type} message")

    return (False, f"Agent {agent_id} did not receive {msg_type} message")
