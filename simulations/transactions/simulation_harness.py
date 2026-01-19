"""
Simulation harness for escrow lock protocol testing.

This module provides test infrastructure for running escrow lock simulations
with the generated protocol actors.
"""

from typing import Dict, List, Any

from .escrow_lock_generated import (
    Consumer, Provider, Witness,
    ConsumerState, ProviderState, WitnessState,
    Message, MessageType, Actor,
)


class EscrowLockSimulation:
    """
    Helper class to run escrow lock simulations.

    Manages message passing between actors and time advancement.
    """

    def __init__(self, network):
        self.network = network
        self.actors: Dict[str, Actor] = {}
        self.current_time = network.current_time
        self.message_log: List[Message] = []

    def create_consumer(self, peer_id: str) -> Consumer:
        """Create a consumer actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        consumer = Consumer(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
        )
        self.actors[peer_id] = consumer
        return consumer

    def create_provider(self, peer_id: str) -> Provider:
        """Create a provider actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        provider = Provider(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
        )
        self.actors[peer_id] = provider
        return provider

    def create_witness(self, peer_id: str) -> Witness:
        """Create a witness actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        witness = Witness(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
        )
        self.actors[peer_id] = witness
        return witness

    def route_message(self, msg: Message, recipient: str):
        """Route a message to a recipient actor."""
        if recipient in self.actors:
            self.actors[recipient].receive_message(msg)
            self.message_log.append(msg)

    def tick(self, time_step: float = 1.0) -> int:
        """
        Advance simulation by one tick.

        Returns number of messages sent.
        """
        self.current_time += time_step
        total_messages = 0

        for peer_id, actor in self.actors.items():
            outgoing = actor.tick(self.current_time)

            for msg in outgoing:
                total_messages += 1

                # Use recipient if specified, otherwise broadcast
                if msg.recipient:
                    self.route_message(msg, msg.recipient)
                else:
                    # Broadcast to all other actors
                    for recipient in self.actors:
                        if recipient != msg.sender:
                            self.route_message(msg, recipient)

        return total_messages

    def run_until_stable(self, max_ticks: int = 100, time_step: float = 1.0) -> int:
        """
        Run simulation until no more messages are being sent.

        Returns number of ticks run.
        """
        for tick_num in range(max_ticks):
            messages = self.tick(time_step)
            if messages == 0:
                # Check if all actors are in stable states
                all_stable = True
                for actor in self.actors.values():
                    if isinstance(actor, Consumer):
                        if actor.state not in (ConsumerState.IDLE, ConsumerState.LOCKED, ConsumerState.FAILED):
                            all_stable = False
                    elif isinstance(actor, Provider):
                        if actor.state not in (ProviderState.IDLE, ProviderState.SERVICE_PHASE):
                            all_stable = False
                    elif isinstance(actor, Witness):
                        if actor.state not in (WitnessState.IDLE, WitnessState.ESCROW_ACTIVE, WitnessState.DONE):
                            all_stable = False

                if all_stable:
                    return tick_num + 1

        return max_ticks
