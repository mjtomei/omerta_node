"""
Trace Runner

Orchestrates running a trace through the simulator.
This is the main integration point that ties together:
- Trace parsing
- Network setup
- Agent creation
- Simulation execution
- Assertion evaluation
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .engine import SimulationEngine, SimulationResult, Message, EventQueue
from .network.model import NetworkModel, create_specific_network
from .network.delivery import MessageDeliverySystem
from .traces.schema import Trace, TraceAction
from .protocol.setup import (
    create_protocol_agents_from_trace,
    infer_roles_from_trace,
)
from .protocol.adapters import (
    ConsumerAgent, ProviderAgent, WitnessAgent,
)
from .assertions.evaluator import (
    AssertionResult,
    evaluate_all_assertions,
    assertions_passed,
    format_assertion_results,
)


@dataclass
class TraceRunResult:
    """Result of running a trace."""
    trace_name: str
    completed: bool
    final_time: float
    assertion_results: List[AssertionResult]
    all_passed: bool
    message_count: int
    tick_count: int
    agents: Dict[str, Any] = field(default_factory=dict)
    message_log: List[Dict[str, Any]] = field(default_factory=list)
    error: Optional[str] = None

    def __str__(self) -> str:
        status = "PASSED" if self.all_passed else "FAILED"
        return (
            f"Trace '{self.trace_name}': {status}\n"
            f"  Ticks: {self.tick_count}, Messages: {self.message_count}\n"
            f"  Final time: {self.final_time:.2f}s\n"
            f"  Assertions: {sum(1 for a in self.assertion_results if a.passed)}/{len(self.assertion_results)} passed"
        )


class TraceRunner:
    """
    Runs traces through the simulator.

    Handles:
    - Setting up the network from trace spec
    - Creating protocol agents
    - Executing trace actions
    - Routing messages between agents
    - Evaluating assertions
    """

    def __init__(self, trace: Trace, time_step: float = 0.1):
        self.trace = trace
        self.time_step = time_step

        # Create network model
        self.network = create_specific_network(trace.network, trace.network.seed)

        # Create agents
        self.agents, self.chains = create_protocol_agents_from_trace(
            trace=trace,
            network_model=self.network,
            current_time=0.0,
        )

        # Note: We handle message routing directly in the runner
        # rather than using MessageDeliverySystem, which requires event-driven delivery
        # For trace-based simulation, we synchronously route messages each tick

        # State tracking
        self.current_time = 0.0
        self.action_index = 0
        self.message_log: List[Dict[str, Any]] = []
        self.tick_count = 0

    def run(self, max_time: float = 100.0) -> TraceRunResult:
        """
        Run the trace to completion.

        Args:
            max_time: Maximum simulation time

        Returns:
            TraceRunResult with all results
        """
        try:
            # Execute until done or timeout
            while self.current_time < max_time:
                # Check if we have more actions to execute
                has_more_actions = self.action_index < len(self.trace.actions)

                # Get next action time if any
                if has_more_actions:
                    next_action = self.trace.actions[self.action_index]
                    next_action_time = next_action.time
                else:
                    next_action_time = float('inf')

                # Advance time
                if next_action_time <= self.current_time:
                    # Execute action at current time
                    self._execute_trace_action(next_action)
                    self.action_index += 1
                else:
                    # Tick all agents and advance time
                    self._tick_all_agents()
                    self.current_time += self.time_step
                    self.tick_count += 1

                # Check if simulation is stable
                if not has_more_actions and self._is_stable():
                    break

            # Evaluate assertions
            state = self._get_state()
            assertion_results = evaluate_all_assertions(
                self.trace.assertions,
                state,
            )

            return TraceRunResult(
                trace_name=self.trace.name,
                completed=True,
                final_time=self.current_time,
                assertion_results=assertion_results,
                all_passed=assertions_passed(assertion_results),
                message_count=len(self.message_log),
                tick_count=self.tick_count,
                agents=self.agents,
                message_log=self.message_log,
            )

        except Exception as e:
            return TraceRunResult(
                trace_name=self.trace.name,
                completed=False,
                final_time=self.current_time,
                assertion_results=[],
                all_passed=False,
                message_count=len(self.message_log),
                tick_count=self.tick_count,
                agents=self.agents,
                message_log=self.message_log,
                error=str(e),
            )

    def _execute_trace_action(self, action: TraceAction):
        """Execute a trace action."""
        actor = action.actor
        action_name = action.action
        params = action.params

        agent = self.agents.get(actor)
        if not agent:
            raise ValueError(f"Unknown actor: {actor}")

        # Handle different action types
        if action_name == "initiate_lock":
            if isinstance(agent, ConsumerAgent):
                provider = params.get("provider")
                amount = params.get("amount", 10.0)
                agent.initiate_lock(provider, amount)

        elif action_name == "select_witnesses":
            # Provider selects witnesses - handled by protocol state machine
            pass

        elif action_name == "send_witness_commitment":
            # Provider sends commitment - handled by protocol state machine
            pass

        elif action_name == "send_witness_requests":
            # Consumer sends requests - handled by protocol state machine
            pass

        elif action_name == "vote":
            # Witness votes - handled by protocol state machine
            # But we may need to set up the witness's verdict
            if isinstance(agent, WitnessAgent):
                # The actual voting is done by the state machine
                # We just ensure the agent is ready to vote
                pass

        elif action_name == "sign_lock":
            # Consumer signs lock - handled by protocol state machine
            pass

        elif action_name == "finalize_lock":
            # Provider finalizes - handled by protocol state machine
            pass

        else:
            # Unknown action - try to handle generically
            pass

    def _tick_all_agents(self):
        """Tick all agents and route messages."""
        from ..transactions.escrow_lock import MessageType as ProtocolMessageType

        # Collect outgoing messages from all agents
        all_outgoing = []

        for agent_id, agent in self.agents.items():
            # Create context
            from .agents.base import AgentContext
            context = AgentContext(
                agent_id=agent_id,
                role="",
                goal="",
                local_chain=self.chains.get(agent_id),
                cached_peer_chains={},
                pending_messages=[],
                active_transactions=[],
                current_time=self.current_time,
                available_actions=[],
                protocol_rules="",
            )

            # Get action (which runs the protocol tick)
            action = agent.decide_action(context)

            # Collect outgoing protocol messages
            outgoing = agent.get_outgoing_protocol_messages()
            for msg in outgoing:
                all_outgoing.append((agent_id, msg))

        # Route messages to recipients
        for sender_id, msg in all_outgoing:
            self._route_message(sender_id, msg)

    def _route_message(self, sender_id: str, msg):
        """Route a protocol message to the appropriate recipient(s)."""
        from ..transactions.escrow_lock import MessageType as ProtocolMessageType

        # Log the message
        self.message_log.append({
            "sender": sender_id,
            "msg_type": msg.msg_type.name,
            "timestamp": msg.timestamp,
            "payload": msg.payload,
        })

        # Determine recipients based on message type
        recipients = []

        if msg.msg_type == ProtocolMessageType.BALANCE_UPDATE_BROADCAST:
            # Broadcast to all
            recipients = [aid for aid in self.agents if aid != sender_id]

        elif msg.msg_type == ProtocolMessageType.LOCK_INTENT:
            # To provider
            provider = msg.payload.get("provider")
            if provider:
                recipients = [provider]

        elif msg.msg_type == ProtocolMessageType.WITNESS_SELECTION_COMMITMENT:
            # To consumer
            consumer = msg.payload.get("consumer") or self._find_consumer()
            if consumer:
                recipients = [consumer]

        elif msg.msg_type == ProtocolMessageType.WITNESS_REQUEST:
            # To witnesses (from payload)
            witnesses = msg.payload.get("witnesses", [])
            recipients = witnesses

        elif msg.msg_type in (
            ProtocolMessageType.WITNESS_PRELIMINARY,
            ProtocolMessageType.WITNESS_FINAL_VOTE,
            ProtocolMessageType.WITNESS_CHAIN_SYNC_REQUEST,
            ProtocolMessageType.WITNESS_CHAIN_SYNC_RESPONSE,
        ):
            # Between witnesses - send to all other witnesses
            for aid, agent in self.agents.items():
                if isinstance(agent, WitnessAgent) and aid != sender_id:
                    recipients.append(aid)

        elif msg.msg_type == ProtocolMessageType.LOCK_RESULT_FOR_SIGNATURE:
            # Could be witness -> consumer or witness -> other witnesses
            # Check sender's state to determine routing
            from ..transactions.escrow_lock import WitnessState
            sender_agent = self.agents.get(sender_id)
            if isinstance(sender_agent, WitnessAgent):
                sender_state = sender_agent.state
                if sender_state in (WitnessState.SIGNING_RESULT, WitnessState.COLLECTING_SIGNATURES):
                    # During signature collection, only send to other witnesses
                    for aid, agent in self.agents.items():
                        if isinstance(agent, WitnessAgent) and aid != sender_id:
                            recipients.append(aid)
                elif sender_state == WitnessState.PROPAGATING:
                    # After collecting signatures, send to consumer
                    consumer = self._find_consumer()
                    if consumer:
                        recipients = [consumer]
                else:
                    # Default: send to all non-senders
                    for aid in self.agents:
                        if aid != sender_id:
                            recipients.append(aid)
            else:
                # Non-witness sender, send to all
                for aid in self.agents:
                    if aid != sender_id:
                        recipients.append(aid)

        elif msg.msg_type == ProtocolMessageType.CONSUMER_SIGNED_LOCK:
            # To witnesses
            for aid, agent in self.agents.items():
                if isinstance(agent, WitnessAgent):
                    recipients.append(aid)

        else:
            # Default: broadcast to all except sender
            recipients = [aid for aid in self.agents if aid != sender_id]

        # Deliver to recipients
        for recipient_id in recipients:
            agent = self.agents.get(recipient_id)
            if agent:
                # Convert to simulator message format
                sim_msg = Message(
                    msg_type=msg.msg_type.name,
                    sender=sender_id,
                    payload=msg.payload,
                    timestamp=msg.timestamp,
                )
                agent.receive_message(sim_msg)

    def _find_consumer(self) -> Optional[str]:
        """Find the consumer agent."""
        for aid, agent in self.agents.items():
            if isinstance(agent, ConsumerAgent):
                return aid
        return None

    def _is_stable(self) -> bool:
        """Check if all agents are in stable states."""
        from ..transactions.escrow_lock import (
            ConsumerState, ProviderState, WitnessState,
        )

        stable_consumer_states = {ConsumerState.IDLE, ConsumerState.LOCKED, ConsumerState.FAILED}
        stable_provider_states = {ProviderState.IDLE, ProviderState.SERVICE_PHASE}
        stable_witness_states = {WitnessState.IDLE, WitnessState.ESCROW_ACTIVE, WitnessState.DONE}

        for agent in self.agents.values():
            if isinstance(agent, ConsumerAgent):
                if agent.state not in stable_consumer_states:
                    return False
            elif isinstance(agent, ProviderAgent):
                if agent.state not in stable_provider_states:
                    return False
            elif isinstance(agent, WitnessAgent):
                if agent.state not in stable_witness_states:
                    return False

        return True

    def _get_state(self) -> Dict[str, Any]:
        """Get current simulation state for assertion evaluation."""
        return {
            "agents": self.agents,
            "chains": self.chains,
            "message_log": self.message_log,
            "current_time": self.current_time,
            "delivery_stats": {
                "total_sent": len(self.message_log),
                "dropped": 0,  # TODO: track dropped messages
            },
        }


def run_trace(trace: Trace, max_time: float = 100.0) -> TraceRunResult:
    """
    Convenience function to run a trace.

    Args:
        trace: The trace to run
        max_time: Maximum simulation time

    Returns:
        TraceRunResult
    """
    runner = TraceRunner(trace)
    return runner.run(max_time)
