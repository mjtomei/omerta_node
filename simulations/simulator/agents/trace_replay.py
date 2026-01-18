"""
Trace replay agent for deterministic simulation replay.
"""

from typing import Any, Dict, List, Optional

from .base import Agent, AgentContext
from ..engine import Action


class TraceReplayAgent(Agent):
    """Agent that replays a recorded action sequence."""

    def __init__(self, agent_id: str, trace: 'Trace', role: str = "unknown", goal: str = ""):
        super().__init__(agent_id, role, goal)
        self.trace = trace
        self.action_index = 0
        self.trace_start_time: Optional[float] = None

        # Find actions for this agent
        self.my_actions = [
            a for a in trace.actions
            if a.actor == agent_id
        ]

    def decide_action(self, context: AgentContext) -> Optional[Action]:
        """Return next action from trace if it's time, else None."""
        if self.trace_start_time is None:
            self.trace_start_time = context.current_time

        while self.action_index < len(self.my_actions):
            trace_action = self.my_actions[self.action_index]
            action_time = self.trace_start_time + trace_action.time

            if context.current_time >= action_time:
                # Time to execute this action
                self.action_index += 1
                return Action(
                    action_type=trace_action.action,
                    params=trace_action.params.copy() if trace_action.params else {},
                )
            else:
                # Not yet time
                return None

        # No more actions
        return None

    def reset(self):
        """Reset agent to beginning of trace."""
        self.action_index = 0
        self.trace_start_time = None
        self.pending_messages.clear()
        self.message_queue.clear()
