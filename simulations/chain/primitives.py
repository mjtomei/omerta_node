"""
Core blockchain primitives: cryptographic functions, Block, and Chain.
"""

import hashlib
import json
import time
import random
from dataclasses import dataclass
from typing import List, Optional, Dict, Any
from enum import Enum


# =============================================================================
# Cryptographic Primitives (simplified for simulation)
# =============================================================================

class _EnumEncoder(json.JSONEncoder):
    """JSON encoder that handles Enum values."""
    def default(self, obj):
        if isinstance(obj, Enum):
            return obj.name
        return super().default(obj)


def hash_data(data: dict) -> str:
    """Compute deterministic hash of a dictionary."""
    canonical = json.dumps(data, sort_keys=True, separators=(',', ':'), cls=_EnumEncoder)
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def sign(private_key: str, data: str) -> str:
    """Simulate signing (not cryptographically secure - for simulation only)."""
    return hashlib.sha256(f"{private_key}:{data}".encode()).hexdigest()[:16]


def verify_sig(public_key: str, data: str, signature: str) -> bool:
    """Simulate signature verification (always returns True if signature has correct length)."""
    return len(signature) == 16


def generate_id() -> str:
    """Generate random ID."""
    return hashlib.sha256(f"{time.time()}{random.random()}".encode()).hexdigest()[:12]


def random_bytes(n: int) -> bytes:
    """Generate n random bytes."""
    return bytes(random.getrandbits(8) for _ in range(n))


# =============================================================================
# Block Types
# =============================================================================

class BlockType(Enum):
    """Types of blocks that can appear in a local chain."""
    GENESIS = "genesis"
    PEER_HASH = "peer_hash"          # Recorded hash of peer's chain (from keepalives)
    SESSION_START = "session_start"   # Consumer verified VM access
    SESSION_END = "session_end"       # Provider signals completion
    ATTESTATION = "attestation"       # Cabal member records verification result

    # Escrow-related
    BALANCE_LOCK = "balance_lock"     # Consumer locks funds
    BALANCE_TOPUP = "balance_topup"   # Consumer adds funds to existing escrow
    WITNESS_COMMITMENT = "witness_commitment"  # Witness records lock commitment
    WITNESS_REPLACEMENT = "witness_replacement"  # Witness was replaced


# =============================================================================
# Block Structure
# =============================================================================

@dataclass
class Block:
    """
    A block in an identity's local chain.

    Unlike half-blocks, these are unilateral - each identity records
    their own observations. Entanglement comes from PEER_HASH blocks
    that record what we saw of others' chains.
    """
    # Chain structure
    owner: str                    # Public key of chain owner
    sequence: int                 # Position in chain
    previous_hash: str            # Hash of previous block in this chain

    # Content
    block_type: BlockType
    timestamp: float
    payload: dict

    # Signature
    signature: str = ""
    block_hash: str = ""

    def __post_init__(self):
        if not self.block_hash:
            self.block_hash = self.compute_hash()

    def compute_hash(self) -> str:
        """Compute the hash of this block."""
        data = {
            "owner": self.owner,
            "sequence": self.sequence,
            "previous_hash": self.previous_hash,
            "block_type": self.block_type.value,
            "timestamp": self.timestamp,
            "payload": self.payload,
        }
        return hash_data(data)

    def to_dict(self) -> dict:
        """Serialize block to dictionary."""
        return {
            "owner": self.owner,
            "sequence": self.sequence,
            "previous_hash": self.previous_hash,
            "block_type": self.block_type.value,
            "timestamp": self.timestamp,
            "payload": self.payload,
            "signature": self.signature,
            "block_hash": self.block_hash,
        }

    @classmethod
    def from_dict(cls, data: dict) -> 'Block':
        """Deserialize block from dictionary."""
        return cls(
            owner=data["owner"],
            sequence=data["sequence"],
            previous_hash=data["previous_hash"],
            block_type=BlockType(data["block_type"]),
            timestamp=data["timestamp"],
            payload=data["payload"],
            signature=data["signature"],
            block_hash=data["block_hash"],
        )


# =============================================================================
# Local Chain
# =============================================================================

class Chain:
    """
    A single identity's local chain.

    Records:
    - Genesis (creation)
    - Peer hashes (what we saw of others via keepalives)
    - Session starts (if consumer)
    - Session ends (if provider)
    - Attestations (if cabal member)
    - Balance locks (escrow)
    """

    def __init__(self, public_key: str, private_key: str, current_time: float):
        self.public_key = public_key
        self.private_key = private_key
        self.blocks: List[Block] = []

        # Peer chain cache - for testing and gossip-received data
        # Maps peer_id -> {"data": chain_data, "head": head_hash, "state": state_dict}
        self._peer_cache: Dict[str, dict] = {}

        # Create genesis
        genesis = Block(
            owner=public_key,
            sequence=0,
            previous_hash="0" * 16,
            block_type=BlockType.GENESIS,
            timestamp=current_time,
            payload={"created": current_time},
        )
        genesis.signature = sign(private_key, genesis.block_hash)
        self.blocks.append(genesis)

    @property
    def head(self) -> Block:
        """Get the most recent block."""
        return self.blocks[-1]

    @property
    def head_hash(self) -> str:
        """Get the hash of the most recent block."""
        return self.head.block_hash

    def age_days(self, current_time: float) -> float:
        """Get the age of this chain in days."""
        return (current_time - self.blocks[0].timestamp) / 86400

    def append(self, block_type: BlockType, payload: dict, timestamp: float) -> Block:
        """Append a new block to the chain."""
        block = Block(
            owner=self.public_key,
            sequence=len(self.blocks),
            previous_hash=self.head_hash,
            block_type=block_type,
            timestamp=timestamp,
            payload=payload,
        )
        block.signature = sign(self.private_key, block.block_hash)
        self.blocks.append(block)
        return block

    def record_peer_hash(self, peer_key: str, peer_hash: str, timestamp: float) -> Block:
        """Record a peer's chain hash (from keepalive)."""
        return self.append(
            BlockType.PEER_HASH,
            {"peer": peer_key, "hash": peer_hash},
            timestamp,
        )

    def get_blocks_by_type(self, block_type: BlockType) -> List[Block]:
        """Get all blocks of a given type."""
        return [b for b in self.blocks if b.block_type == block_type]

    def get_peer_hash(self, peer_key: str, before_time: Optional[float] = None) -> Optional[Block]:
        """
        Get the most recent PEER_HASH block for a given peer.

        If before_time is specified, only consider blocks before that time.
        """
        peer_blocks = [
            b for b in self.blocks
            if b.block_type == BlockType.PEER_HASH
            and b.payload.get("peer") == peer_key
            and (before_time is None or b.timestamp < before_time)
        ]
        if not peer_blocks:
            return None
        return max(peer_blocks, key=lambda b: b.timestamp)

    def verify_chain(self) -> bool:
        """Verify the chain's integrity."""
        if not self.blocks:
            return False

        # Check genesis
        if self.blocks[0].previous_hash != "0" * 16:
            return False

        # Check hash chain
        for i in range(1, len(self.blocks)):
            if self.blocks[i].previous_hash != self.blocks[i-1].block_hash:
                return False
            if self.blocks[i].sequence != i:
                return False

        return True

    def get_state_at(self, block_hash: str) -> Optional[Dict[str, Any]]:
        """
        Extract chain state at a specific block hash.

        Returns a dictionary with:
        - known_peers: list of peer_ids seen in PEER_HASH blocks
        - peer_hashes: map of peer_id to their last known hash
        - balance_locks: list of active locks
        """
        # Find the block with this hash
        target_idx = None
        for i, block in enumerate(self.blocks):
            if block.block_hash == block_hash:
                target_idx = i
                break

        if target_idx is None:
            return None

        # Build state from blocks up to target
        state = {
            "known_peers": set(),
            "peer_hashes": {},
            "balance_locks": [],
            "block_hash": block_hash,
            "sequence": target_idx,
        }

        for block in self.blocks[:target_idx + 1]:
            if block.block_type == BlockType.PEER_HASH:
                peer = block.payload.get("peer")
                if peer:
                    state["known_peers"].add(peer)
                    state["peer_hashes"][peer] = block.payload.get("hash")
            elif block.block_type == BlockType.BALANCE_LOCK:
                state["balance_locks"].append(block.payload)

        state["known_peers"] = list(state["known_peers"])
        return state

    @staticmethod
    def state_from_segment(segment: List[dict], target_hash: str) -> Optional[Dict[str, Any]]:
        """
        Build chain state from a segment (list of serialized blocks) up to target hash.

        This is used when processing chain data received from network messages.
        """
        if not segment:
            return None

        # Find the block with target hash
        target_idx = None
        for i, block in enumerate(segment):
            if block.get("block_hash") == target_hash:
                target_idx = i
                break

        if target_idx is None:
            return None

        # Build state from blocks up to target
        state = {
            "known_peers": set(),
            "peer_hashes": {},
            "balance_locks": [],
            "block_hash": target_hash,
            "sequence": target_idx,
        }

        for block in segment[:target_idx + 1]:
            block_type = block.get("block_type")
            # Handle both string and enum block types
            if block_type == "peer_hash" or block_type == BlockType.PEER_HASH:
                peer = block.get("payload", {}).get("peer")
                if peer:
                    state["known_peers"].add(peer)
                    state["peer_hashes"][peer] = block.get("payload", {}).get("hash")
            elif block_type == "balance_lock" or block_type == BlockType.BALANCE_LOCK:
                state["balance_locks"].append(block.get("payload", {}))

        state["known_peers"] = list(state["known_peers"])
        return state

    def contains_hash(self, block_hash: str) -> bool:
        """Check if this chain contains a block with the given hash."""
        return any(b.block_hash == block_hash for b in self.blocks)

    def to_segment(self, from_hash: Optional[str] = None, to_hash: Optional[str] = None) -> List[dict]:
        """
        Extract a segment of the chain as serializable data.

        If from_hash is None, starts from genesis.
        If to_hash is None, goes to head.
        """
        start_idx = 0
        end_idx = len(self.blocks)

        if from_hash:
            for i, block in enumerate(self.blocks):
                if block.block_hash == from_hash:
                    start_idx = i
                    break

        if to_hash:
            for i, block in enumerate(self.blocks):
                if block.block_hash == to_hash:
                    end_idx = i + 1
                    break

        return [b.to_dict() for b in self.blocks[start_idx:end_idx]]

    # =========================================================================
    # Peer Chain Cache - for testing and gossip-received data
    # =========================================================================

    def seed_peer_chain(
        self,
        peer_id: str,
        balance: float,
        head_hash: Optional[str] = None,
        chain_data: Optional[bytes] = None,
        locked_amount: float = 0.0,
        trust_score: float = 0.0,
    ) -> None:
        """
        Seed the peer chain cache with data for testing.

        This simulates having received gossip data about a peer's chain state.
        In production, this would be populated via chain sync messages.

        Args:
            peer_id: The peer's identifier
            balance: The peer's current balance
            head_hash: The hash of their chain head (auto-generated if None)
            chain_data: Serialized chain data (placeholder if None)
            locked_amount: Amount currently locked in escrow
            trust_score: The peer's trust score
        """
        if head_hash is None:
            head_hash = hash_data(f"{peer_id}:{balance}:{locked_amount}")

        if chain_data is None:
            chain_data = b"placeholder_chain_data"

        self._peer_cache[peer_id] = {
            "data": chain_data,
            "head": head_hash,
            "state": {
                "block_hash": head_hash,
                "balance": balance,
                "locked_amount": locked_amount,
                "trust_score": trust_score,
                "block_height": 1,
            },
        }

    def has_peer_data(self, peer_id: str) -> bool:
        """Check if we have cached chain data for a peer."""
        return peer_id in self._peer_cache

    def get_peer_data(self, peer_id: str) -> Optional[bytes]:
        """Get cached chain data for a peer."""
        if peer_id in self._peer_cache:
            return self._peer_cache[peer_id]["data"]
        return None

    def get_peer_head(self, peer_id: str) -> Optional[str]:
        """Get cached chain head hash for a peer."""
        if peer_id in self._peer_cache:
            return self._peer_cache[peer_id]["head"]
        return None

    def get_peer_state(self, peer_id: str) -> Optional[Dict[str, Any]]:
        """
        Get cached chain state for a peer.

        Returns a dict with: balance, locked_amount, trust_score, block_height, block_hash
        """
        if peer_id in self._peer_cache:
            return self._peer_cache[peer_id]["state"]
        return None
