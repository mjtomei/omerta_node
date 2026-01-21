"""
Protocol Setup

Functions to create protocol agents from trace specifications.
Sets up chains, relationships, and initial balances.
"""

from typing import Any, Dict, List, Optional, Tuple

from ..traces.schema import Trace, TraceChainSpec
from ..network.model import NetworkModel
from ...chain.primitives import Chain


def create_chain_from_spec(
    peer_id: str,
    spec: Optional[TraceChainSpec],
    current_time: float,
) -> Chain:
    """
    Create a Chain from a trace specification.

    Args:
        peer_id: The peer's ID (used as public key for simulation)
        spec: Chain specification from trace, or None for defaults
        current_time: Current simulation time (used as genesis time)

    Returns:
        A configured Chain instance
    """
    # For simulation, use peer_id as both public and private key
    chain = Chain(
        public_key=peer_id,
        private_key=f"priv_{peer_id}",
        current_time=current_time,
    )

    # We could add balance tracking to the chain, but for now
    # balances are tracked in witness cached_chains
    return chain


def setup_relationships(
    chains: Dict[str, Chain],
    relationships: List[Tuple[List[str], int]],
    current_time: float,
):
    """
    Set up peer relationships by recording peer hashes.

    Each relationship specifies peers that know each other and
    how long they've known each other (in days).

    We do two passes:
    1. First pass: everyone records everyone else's genesis hash (establishes links)
    2. Second pass: everyone updates their view with current chain heads
       (so checkpoints include all peer knowledge)

    Args:
        chains: Map of peer_id to Chain
        relationships: List of (peer_list, age_days) tuples
        current_time: Current simulation time
    """
    # First pass: record initial relationships (at historical time)
    for peers, age_days in relationships:
        first_seen_time = current_time - (age_days * 86400)

        for peer_id in peers:
            if peer_id not in chains:
                continue

            chain = chains[peer_id]
            for other_id in peers:
                if other_id == peer_id:
                    continue
                if other_id not in chains:
                    continue

                other_chain = chains[other_id]
                chain.record_peer_hash(
                    peer_key=other_id,
                    peer_hash=other_chain.head_hash,
                    timestamp=first_seen_time,
                )

    # Second pass: update with current chain heads (at simulation start time)
    # This ensures checkpoints reference chains that include peer knowledge
    all_peers = set()
    for peers, _ in relationships:
        all_peers.update(peers)

    for peer_id in all_peers:
        if peer_id not in chains:
            continue
        chain = chains[peer_id]
        for other_id in all_peers:
            if other_id == peer_id:
                continue
            if other_id not in chains:
                continue
            # Only update if they're in a relationship together
            in_relationship = False
            for peers, _ in relationships:
                if peer_id in peers and other_id in peers:
                    in_relationship = True
                    break
            if in_relationship:
                other_chain = chains[other_id]
                chain.record_peer_hash(
                    peer_key=other_id,
                    peer_hash=other_chain.head_hash,
                    timestamp=current_time,  # At simulation start
                )


def create_protocol_agents_from_trace(
    trace: Trace,
    network_model: NetworkModel,
    current_time: float = 0.0,
) -> Tuple[Dict[str, Any], Dict[str, Chain]]:
    """
    Create all protocol agents from a trace specification.

    Args:
        trace: The trace specification
        network_model: The network model (needed for provider witness selection)
        current_time: Initial simulation time

    Returns:
        Tuple of (agents_dict, chains_dict)
    """
    from .adapters import (
        ConsumerAgent, ProviderAgent, WitnessAgent,
        create_protocol_agent,
    )
    from ...transactions.escrow_lock_generated import Consumer, Provider, Witness

    # Create chains for all nodes
    chains: Dict[str, Chain] = {}
    for node_spec in trace.network.nodes:
        chain_spec = trace.setup.chains.get(node_spec.id)
        chains[node_spec.id] = create_chain_from_spec(
            peer_id=node_spec.id,
            spec=chain_spec,
            current_time=current_time,
        )

    # Setup relationships
    relationships = []
    for rel in trace.setup.relationships:
        relationships.append((rel.peers, rel.age_days))
    setup_relationships(chains, relationships, current_time)

    # Determine roles from trace actions
    roles = infer_roles_from_trace(trace)

    # Create agents
    agents: Dict[str, Any] = {}
    for node_spec in trace.network.nodes:
        node_id = node_spec.id
        chain = chains[node_id]
        role = roles.get(node_id, "witness")  # Default to witness

        # Create the appropriate protocol actor
        if role == "consumer":
            actor = Consumer(peer_id=node_id, chain=chain)
            agent = ConsumerAgent(agent_id=node_id, protocol_actor=actor)
        elif role == "provider":
            actor = Provider(peer_id=node_id, chain=chain)
            agent = ProviderAgent(agent_id=node_id, protocol_actor=actor)
        else:
            actor = Witness(peer_id=node_id, chain=chain)
            agent = WitnessAgent(agent_id=node_id, protocol_actor=actor)

            # Set up cached chain data for witnesses
            chain_spec = trace.setup.chains.get(node_id)
            for other_id, other_chain in chains.items():
                if other_id != node_id:
                    other_spec = trace.setup.chains.get(other_id)
                    agent.set_cached_chain(other_id, {
                        "balance": other_spec.balance if other_spec else 0.0,
                        "head_hash": other_chain.head_hash,
                    })

        agents[node_id] = agent

    return agents, chains


def infer_roles_from_trace(trace: Trace) -> Dict[str, str]:
    """
    Infer agent roles from trace actions.

    Looks for characteristic actions:
    - initiate_lock -> consumer
    - select_witnesses, finalize_lock -> provider
    - vote -> witness
    """
    roles: Dict[str, str] = {}

    consumer_actions = {"initiate_lock", "send_witness_requests", "sign_lock"}
    provider_actions = {"select_witnesses", "send_witness_commitment", "finalize_lock"}
    witness_actions = {"vote"}

    for action in trace.actions:
        actor = action.actor
        action_name = action.action

        if action_name in consumer_actions:
            if actor not in roles:
                roles[actor] = "consumer"
        elif action_name in provider_actions:
            if actor not in roles:
                roles[actor] = "provider"
        elif action_name in witness_actions:
            if actor not in roles:
                roles[actor] = "witness"

    return roles
