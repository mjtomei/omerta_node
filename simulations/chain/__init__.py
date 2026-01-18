"""
Omerta Chain - Core blockchain primitives and network simulation.

This package provides:
- primitives: Block, Chain, and cryptographic functions
- types: Enums and dataclasses for sessions, attestations, etc.
- network: Network simulation for testing
- gossip: Gossip protocol for propagating multi-signed results
"""

from .primitives import (
    hash_data,
    sign,
    verify_sig,
    generate_id,
    Block,
    BlockType,
    Chain,
)

from .types import (
    SessionEndReason,
    AttestationOutcome,
    SessionTerms,
    SessionStart,
    SessionEnd,
    CabalAttestation,
)

from .network import Network

from .gossip import (
    GossipType,
    GossipItem,
    DualHashTable,
    PropagationQueue,
    GossipLayer,
    create_lock_result_item,
    create_topup_result_item,
    create_attestation_item,
)

__all__ = [
    # Primitives
    "hash_data",
    "sign",
    "verify_sig",
    "generate_id",
    "Block",
    "BlockType",
    "Chain",
    # Types
    "SessionEndReason",
    "AttestationOutcome",
    "SessionTerms",
    "SessionStart",
    "SessionEnd",
    "CabalAttestation",
    # Network
    "Network",
    # Gossip
    "GossipType",
    "GossipItem",
    "DualHashTable",
    "PropagationQueue",
    "GossipLayer",
    "create_lock_result_item",
    "create_topup_result_item",
    "create_attestation_item",
]
