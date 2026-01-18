#!/usr/bin/env python3
"""
Omerta Chain - DAG via Keepalives + Cabal Attestations

Key design:
1. DAG created by recording peer hashes from keepalives (piggyback on mesh)
2. Sessions recorded by consumer (start) and provider (end)
3. Trust comes from cabal attestations, not bilateral claims

Block types:
- GENESIS: Identity creation
- PEER_HASH: Saw peer's chain at hash H (from keepalives)
- SESSION_START: Consumer verified VM access
- SESSION_END: Provider signals completion
- ATTESTATION: Cabal member records verification result
"""

import hashlib
import json
import math
import random
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Set
from enum import Enum


# =============================================================================
# Cryptographic Primitives (simplified for simulation)
# =============================================================================

def hash_data(data: dict) -> str:
    """Compute deterministic hash."""
    canonical = json.dumps(data, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def sign(private_key: str, data: str) -> str:
    """Simulate signing."""
    return hashlib.sha256(f"{private_key}:{data}".encode()).hexdigest()[:16]


def verify_sig(public_key: str, data: str, signature: str) -> bool:
    """Simulate signature verification."""
    return len(signature) == 16


def generate_id() -> str:
    """Generate random ID."""
    return hashlib.sha256(f"{time.time()}{random.random()}".encode()).hexdigest()[:12]


# =============================================================================
# Block Types
# =============================================================================

class BlockType(Enum):
    GENESIS = "genesis"
    PEER_HASH = "peer_hash"
    SESSION_START = "session_start"
    SESSION_END = "session_end"
    ATTESTATION = "attestation"


class SessionEndReason(Enum):
    PROVIDER_VOLUNTARY = "provider_voluntary"
    CONSUMER_REQUEST = "consumer_request"
    VM_DIED = "vm_died"
    TIMEOUT = "timeout"


class AttestationOutcome(Enum):
    PASS = "pass"
    FAIL = "fail"
    INCONCLUSIVE = "inconclusive"


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
    """

    def __init__(self, public_key: str, private_key: str, current_time: float):
        self.public_key = public_key
        self.private_key = private_key
        self.blocks: List[Block] = []

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
        return self.blocks[-1]

    @property
    def head_hash(self) -> str:
        return self.head.block_hash

    def age_days(self, current_time: float) -> float:
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


# =============================================================================
# Session Management
# =============================================================================

@dataclass
class SessionTerms:
    """Agreed terms for a compute session."""
    session_id: str
    consumer: str
    provider: str
    cabal: List[str]

    # Resources
    cores: int
    memory_gb: float
    max_duration_hours: float

    # Economics
    price_per_hour: float

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "consumer": self.consumer,
            "provider": self.provider,
            "cabal": self.cabal,
            "cores": self.cores,
            "memory_gb": self.memory_gb,
            "max_duration_hours": self.max_duration_hours,
            "price_per_hour": self.price_per_hour,
        }


@dataclass
class SessionStart:
    """Consumer's record that session started."""
    session_id: str
    terms: SessionTerms
    verified_access_at: float
    consumer_signature: str

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "terms": self.terms.to_dict(),
            "verified_access_at": self.verified_access_at,
            "consumer_signature": self.consumer_signature,
        }


@dataclass
class SessionEnd:
    """Provider's record that session ended."""
    session_id: str
    end_reason: SessionEndReason
    ended_at: float
    actual_duration_hours: float
    provider_signature: str

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "end_reason": self.end_reason.value,
            "ended_at": self.ended_at,
            "actual_duration_hours": self.actual_duration_hours,
            "provider_signature": self.provider_signature,
        }


# =============================================================================
# Cabal Attestation
# =============================================================================

@dataclass
class CabalAttestation:
    """
    Cabal's verification of a session.

    Each cabal member records this on their chain.
    The attestation includes all votes and signatures.
    """
    session_id: str

    # What was verified
    session_start_hash: str       # Hash of consumer's SESSION_START block
    session_end_hash: str         # Hash of provider's SESSION_END block

    # Outcome
    outcome: AttestationOutcome
    votes: Dict[str, bool]        # cabal_member -> vote (True=pass)

    # All cabal members sign the attestation
    signatures: Dict[str, str]    # cabal_member -> signature

    # Metadata
    created_at: float
    attestation_id: str = ""

    def __post_init__(self):
        if not self.attestation_id:
            self.attestation_id = self._compute_id()

    def _compute_id(self) -> str:
        data = {
            "session_id": self.session_id,
            "outcome": self.outcome.value,
            "votes": self.votes,
            "created_at": self.created_at,
        }
        return hash_data(data)

    def to_dict(self) -> dict:
        return {
            "attestation_id": self.attestation_id,
            "session_id": self.session_id,
            "session_start_hash": self.session_start_hash,
            "session_end_hash": self.session_end_hash,
            "outcome": self.outcome.value,
            "votes": self.votes,
            "signatures": self.signatures,
            "created_at": self.created_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> 'CabalAttestation':
        return cls(
            session_id=data["session_id"],
            session_start_hash=data["session_start_hash"],
            session_end_hash=data["session_end_hash"],
            outcome=AttestationOutcome(data["outcome"]),
            votes=data["votes"],
            signatures=data["signatures"],
            created_at=data["created_at"],
            attestation_id=data["attestation_id"],
        )


# =============================================================================
# Network
# =============================================================================

class Network:
    """
    Simulates the Omerta network.

    Manages:
    - Identity chains
    - Keepalive-based DAG creation
    - Session lifecycle
    - Cabal formation and attestation
    """

    # Keepalive parameters
    KEEPALIVE_INTERVAL = 30.0          # Seconds between keepalives
    HASH_RECORD_FREQUENCY = 10         # Record peer hash every N keepalives

    # Cabal parameters
    CABAL_SIZE = 5
    MIN_TRUST_FOR_CABAL = 1.0

    def __init__(self):
        self.chains: Dict[str, Chain] = {}
        self.current_time: float = time.time()

        # Active sessions
        self.sessions: Dict[str, SessionTerms] = {}
        self.session_starts: Dict[str, SessionStart] = {}
        self.session_ends: Dict[str, SessionEnd] = {}

        # Attestations (indexed by session)
        self.attestations: Dict[str, CabalAttestation] = {}

        # Trust scores (would be computed from attestations)
        self.trust_scores: Dict[str, float] = {}

        # Keepalive counters
        self.keepalive_counts: Dict[str, int] = {}

        # Interaction tracking for cabal selection
        self.interaction_counts: Dict[Tuple[str, str], int] = {}

    def create_identity(self, name: str) -> Chain:
        """Create a new identity."""
        public_key = f"pk_{name}"
        private_key = f"sk_{name}"

        chain = Chain(public_key, private_key, self.current_time)
        self.chains[public_key] = chain
        self.trust_scores[public_key] = 0.1  # Initial trust
        self.keepalive_counts[public_key] = 0

        return chain

    def advance_time(self, seconds: float):
        """Advance simulation time."""
        self.current_time += seconds

    # ─────────────────────────────────────────────────────────────────────────
    # Keepalive / DAG Creation
    # ─────────────────────────────────────────────────────────────────────────

    def send_keepalive(self, sender_key: str, recipient_key: str) -> bool:
        """
        Simulate sending a keepalive.

        Every N keepalives, the recipient records sender's chain hash.
        This creates the DAG structure.
        """
        if sender_key not in self.chains or recipient_key not in self.chains:
            return False

        sender_chain = self.chains[sender_key]
        recipient_chain = self.chains[recipient_key]

        # Increment keepalive counter
        self.keepalive_counts[recipient_key] = self.keepalive_counts.get(recipient_key, 0) + 1

        # Record peer hash periodically
        if self.keepalive_counts[recipient_key] % self.HASH_RECORD_FREQUENCY == 0:
            recipient_chain.record_peer_hash(
                sender_key,
                sender_chain.head_hash,
                self.current_time,
            )

            # Track interaction for cabal selection
            pair = tuple(sorted([sender_key, recipient_key]))
            self.interaction_counts[pair] = self.interaction_counts.get(pair, 0) + 1

        return True

    def simulate_keepalives(self, rounds: int = 1):
        """Simulate keepalive rounds between all peers."""
        keys = list(self.chains.keys())

        for _ in range(rounds):
            for sender in keys:
                for recipient in keys:
                    if sender != recipient:
                        self.send_keepalive(sender, recipient)

    # ─────────────────────────────────────────────────────────────────────────
    # Cabal Selection
    # ─────────────────────────────────────────────────────────────────────────

    def select_cabal(
        self,
        consumer_key: str,
        provider_key: str,
        size: int = None,
    ) -> List[str]:
        """
        Select a cabal for verifying a session.

        Prefers: high trust, low interaction with parties.
        """
        size = size or self.CABAL_SIZE

        candidates = []
        for key in self.chains.keys():
            if key in (consumer_key, provider_key):
                continue

            trust = self.trust_scores.get(key, 0)
            if trust < self.MIN_TRUST_FOR_CABAL:
                continue

            # Interaction with both parties
            pair_c = tuple(sorted([key, consumer_key]))
            pair_p = tuple(sorted([key, provider_key]))
            interaction = (
                self.interaction_counts.get(pair_c, 0) +
                self.interaction_counts.get(pair_p, 0)
            )

            # Score: trust / (1 + interaction)
            score = trust / (1 + interaction)
            candidates.append((key, score))

        # Sort by score descending
        candidates.sort(key=lambda x: x[1], reverse=True)

        return [key for key, _ in candidates[:size]]

    # ─────────────────────────────────────────────────────────────────────────
    # Session Lifecycle
    # ─────────────────────────────────────────────────────────────────────────

    def create_session(
        self,
        consumer_key: str,
        provider_key: str,
        cores: int = 4,
        memory_gb: float = 8.0,
        max_duration_hours: float = 1.0,
        price_per_hour: float = 0.1,
    ) -> SessionTerms:
        """Create a new session (terms agreed off-chain or via auction)."""

        # Select cabal
        cabal = self.select_cabal(consumer_key, provider_key)
        if len(cabal) < 3:
            raise ValueError("Not enough cabal members available")

        session_id = generate_id()

        terms = SessionTerms(
            session_id=session_id,
            consumer=consumer_key,
            provider=provider_key,
            cabal=cabal,
            cores=cores,
            memory_gb=memory_gb,
            max_duration_hours=max_duration_hours,
            price_per_hour=price_per_hour,
        )

        self.sessions[session_id] = terms
        return terms

    def start_session(self, session_id: str) -> SessionStart:
        """
        Consumer signals session start.

        Called after consumer verified they can access the VM.
        Records on consumer's chain, broadcasts to cabal + provider.
        """
        terms = self.sessions.get(session_id)
        if not terms:
            raise ValueError(f"Unknown session: {session_id}")

        consumer_chain = self.chains[terms.consumer]

        # Consumer records on their chain
        start = SessionStart(
            session_id=session_id,
            terms=terms,
            verified_access_at=self.current_time,
            consumer_signature=sign(consumer_chain.private_key, session_id),
        )

        block = consumer_chain.append(
            BlockType.SESSION_START,
            start.to_dict(),
            self.current_time,
        )

        self.session_starts[session_id] = start

        # In reality: broadcast to cabal + provider
        # They would record seeing this

        return start

    def end_session(
        self,
        session_id: str,
        reason: SessionEndReason,
        actual_duration_hours: float = None,
    ) -> SessionEnd:
        """
        Provider signals session end.

        Called when session ends for any reason.
        Records on provider's chain, broadcasts to cabal.
        """
        terms = self.sessions.get(session_id)
        if not terms:
            raise ValueError(f"Unknown session: {session_id}")

        start = self.session_starts.get(session_id)
        if not start:
            raise ValueError(f"Session not started: {session_id}")

        provider_chain = self.chains[terms.provider]

        # Calculate duration if not provided
        if actual_duration_hours is None:
            elapsed_seconds = self.current_time - start.verified_access_at
            actual_duration_hours = elapsed_seconds / 3600

        end = SessionEnd(
            session_id=session_id,
            end_reason=reason,
            ended_at=self.current_time,
            actual_duration_hours=actual_duration_hours,
            provider_signature=sign(provider_chain.private_key, session_id),
        )

        block = provider_chain.append(
            BlockType.SESSION_END,
            end.to_dict(),
            self.current_time,
        )

        self.session_ends[session_id] = end

        return end

    # ─────────────────────────────────────────────────────────────────────────
    # Cabal Attestation
    # ─────────────────────────────────────────────────────────────────────────

    def create_attestation(
        self,
        session_id: str,
        votes: Dict[str, bool],
    ) -> CabalAttestation:
        """
        Create attestation from cabal votes.

        Called after session ends and cabal members have exchanged votes.
        Each cabal member records this on their chain.
        """
        terms = self.sessions.get(session_id)
        start = self.session_starts.get(session_id)
        end = self.session_ends.get(session_id)

        if not all([terms, start, end]):
            raise ValueError(f"Session incomplete: {session_id}")

        # Get block hashes
        consumer_chain = self.chains[terms.consumer]
        provider_chain = self.chains[terms.provider]

        start_blocks = [b for b in consumer_chain.blocks
                       if b.block_type == BlockType.SESSION_START
                       and b.payload.get("session_id") == session_id]
        end_blocks = [b for b in provider_chain.blocks
                     if b.block_type == BlockType.SESSION_END
                     and b.payload.get("session_id") == session_id]

        if not start_blocks or not end_blocks:
            raise ValueError("Session blocks not found")

        # Determine outcome
        votes_pass = sum(1 for v in votes.values() if v)
        votes_fail = len(votes) - votes_pass

        if votes_pass > votes_fail:
            outcome = AttestationOutcome.PASS
        elif votes_fail > votes_pass:
            outcome = AttestationOutcome.FAIL
        else:
            outcome = AttestationOutcome.INCONCLUSIVE

        # Collect signatures from all cabal members
        signatures = {}
        for member_key in terms.cabal:
            if member_key in self.chains:
                chain = self.chains[member_key]
                sig_data = f"{session_id}:{outcome.value}"
                signatures[member_key] = sign(chain.private_key, sig_data)

        attestation = CabalAttestation(
            session_id=session_id,
            session_start_hash=start_blocks[0].block_hash,
            session_end_hash=end_blocks[0].block_hash,
            outcome=outcome,
            votes=votes,
            signatures=signatures,
            created_at=self.current_time,
        )

        # Each cabal member records on their chain
        for member_key in terms.cabal:
            if member_key in self.chains:
                self.chains[member_key].append(
                    BlockType.ATTESTATION,
                    attestation.to_dict(),
                    self.current_time,
                )

        self.attestations[session_id] = attestation

        return attestation

    def simulate_verification(
        self,
        session_id: str,
        actual_valid: bool,
        noise: float = 0.1,
    ) -> CabalAttestation:
        """
        Simulate cabal verification of a session.

        Each cabal member independently verifies, with some noise.
        """
        terms = self.sessions.get(session_id)
        if not terms:
            raise ValueError(f"Unknown session: {session_id}")

        # Simulate each member's verification
        votes = {}
        for member_key in terms.cabal:
            # With noise, might vote wrong
            if random.random() < noise:
                votes[member_key] = not actual_valid
            else:
                votes[member_key] = actual_valid

        return self.create_attestation(session_id, votes)

    def run_full_session(
        self,
        consumer_key: str,
        provider_key: str,
        duration_hours: float = 1.0,
        actual_valid: bool = True,
        **session_kwargs,
    ) -> Tuple[SessionTerms, CabalAttestation]:
        """
        Run a complete session lifecycle.

        1. Create session (terms agreed)
        2. Start session
        3. End session
        4. Cabal verification
        """
        # 1. Create session
        terms = self.create_session(consumer_key, provider_key, **session_kwargs)

        # 2. Start session
        self.start_session(terms.session_id)

        # 3. Simulate session duration
        self.advance_time(duration_hours * 3600)

        # 4. End session
        self.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST, duration_hours)

        # 5. Cabal verification
        attestation = self.simulate_verification(terms.session_id, actual_valid)

        return terms, attestation

    # ─────────────────────────────────────────────────────────────────────────
    # Trust Computation
    # ─────────────────────────────────────────────────────────────────────────

    def compute_trust(self, subject_key: str) -> Tuple[float, dict]:
        """
        Compute trust for an identity from attestations.

        Trust = age_component + attestation_component
        """
        chain = self.chains.get(subject_key)
        if not chain:
            return 0.0, {"error": "unknown identity"}

        # Age component
        age_days = chain.age_days(self.current_time)
        t_age = self._compute_age_trust(age_days)

        # Attestation component (as provider)
        t_attestations, att_details = self._compute_attestation_trust(subject_key)

        total = max(0.0, t_age + t_attestations)

        details = {
            "age_days": age_days,
            "t_age": t_age,
            "t_attestations": t_attestations,
            "attestation_details": att_details,
            "total": total,
        }

        return total, details

    def _compute_age_trust(self, age_days: float) -> float:
        """Trust from identity age."""
        K_AGE = 0.01
        TAU_AGE = 30

        t_age = 0.0
        for day in range(int(age_days)):
            rate = K_AGE * (1 - math.exp(-day / TAU_AGE))
            t_age += rate

        return t_age

    def _compute_attestation_trust(self, provider_key: str) -> Tuple[float, List[dict]]:
        """Trust from attestations where identity was provider."""
        BASE_CREDIT = 0.1
        TAU_DECAY = 365
        PASS_MULTIPLIER = 1.0
        FAIL_PENALTY = 2.0

        t_total = 0.0
        details = []

        for session_id, attestation in self.attestations.items():
            terms = self.sessions.get(session_id)
            if not terms or terms.provider != provider_key:
                continue

            end = self.session_ends.get(session_id)
            if not end:
                continue

            # Recency
            age_days = (self.current_time - attestation.created_at) / 86400
            recency = math.exp(-age_days / TAU_DECAY)

            # Credit based on outcome
            duration = end.actual_duration_hours
            resource_weight = terms.cores / 4.0

            if attestation.outcome == AttestationOutcome.PASS:
                credit = BASE_CREDIT * resource_weight * duration * PASS_MULTIPLIER
            elif attestation.outcome == AttestationOutcome.FAIL:
                credit = -BASE_CREDIT * resource_weight * duration * FAIL_PENALTY
            else:
                credit = 0.0

            # Margin bonus/penalty
            votes_pass = sum(1 for v in attestation.votes.values() if v)
            votes_fail = len(attestation.votes) - votes_pass
            total_votes = len(attestation.votes)
            margin = abs(votes_pass - votes_fail) / total_votes if total_votes > 0 else 0

            weighted_credit = credit * recency * (0.5 + 0.5 * margin)
            t_total += weighted_credit

            details.append({
                "session_id": session_id,
                "outcome": attestation.outcome.value,
                "duration": duration,
                "margin": margin,
                "credit": weighted_credit,
            })

        return t_total, details

    def update_all_trust_scores(self):
        """Recompute trust scores for all identities."""
        for key in self.chains.keys():
            trust, _ = self.compute_trust(key)
            self.trust_scores[key] = trust

    # ─────────────────────────────────────────────────────────────────────────
    # Diagnostics
    # ─────────────────────────────────────────────────────────────────────────

    def print_chain(self, key: str):
        """Print a chain's blocks."""
        chain = self.chains.get(key)
        if not chain:
            print(f"Unknown chain: {key}")
            return

        print(f"\n{'='*60}")
        print(f"Chain: {key}")
        print(f"{'='*60}")

        for block in chain.blocks:
            print(f"  [{block.sequence}] {block.block_type.value}")
            print(f"      hash: {block.block_hash}")
            if block.block_type == BlockType.PEER_HASH:
                print(f"      peer: {block.payload['peer'][:20]}...")
            elif block.block_type == BlockType.SESSION_START:
                print(f"      session: {block.payload['session_id']}")
            elif block.block_type == BlockType.SESSION_END:
                print(f"      session: {block.payload['session_id']}")
                print(f"      reason: {block.payload['end_reason']}")
            elif block.block_type == BlockType.ATTESTATION:
                print(f"      session: {block.payload['session_id']}")
                print(f"      outcome: {block.payload['outcome']}")

    def print_summary(self):
        """Print network summary."""
        print(f"\n{'='*60}")
        print("NETWORK SUMMARY")
        print(f"{'='*60}")
        print(f"Identities: {len(self.chains)}")
        print(f"Sessions: {len(self.sessions)}")
        print(f"Attestations: {len(self.attestations)}")

        print(f"\nTrust scores:")
        for key, trust in sorted(self.trust_scores.items(), key=lambda x: -x[1]):
            chain = self.chains[key]
            blocks = len(chain.blocks)
            print(f"  {key}: trust={trust:.4f} ({blocks} blocks)")


# =============================================================================
# Demo
# =============================================================================

def demo():
    print("=" * 70)
    print("OMERTA CHAIN - DAG + CABAL ATTESTATION DEMO")
    print("=" * 70)

    net = Network()

    # Create identities
    print("\n1. Creating identities...")

    # Providers
    alice = net.create_identity("alice")
    bob = net.create_identity("bob")

    # Consumer
    charlie = net.create_identity("charlie")

    # Verifiers (will form cabals)
    verifiers = [net.create_identity(f"v{i}") for i in range(10)]

    # Give verifiers initial trust
    for v in verifiers:
        net.trust_scores[v.public_key] = 2.0

    print(f"  Created {len(net.chains)} identities")

    # Simulate keepalives to create DAG
    print("\n2. Simulating keepalives (DAG creation)...")

    for day in range(30):
        net.advance_time(86400)  # 1 day
        net.simulate_keepalives(rounds=10)

    # Check DAG structure
    peer_hash_counts = {}
    for key, chain in net.chains.items():
        count = len(chain.get_blocks_by_type(BlockType.PEER_HASH))
        peer_hash_counts[key] = count

    avg_peer_hashes = sum(peer_hash_counts.values()) / len(peer_hash_counts)
    print(f"  Average PEER_HASH blocks per chain: {avg_peer_hashes:.1f}")

    # Run sessions
    print("\n3. Running compute sessions...")

    sessions_run = []

    for i in range(10):
        net.advance_time(3600)  # 1 hour between sessions

        # Alice is reliable - always passes verification
        terms, attestation = net.run_full_session(
            charlie.public_key,
            alice.public_key,
            duration_hours=1.0,
            actual_valid=True,
        )
        sessions_run.append(("alice", True, attestation))

        # Bob is sometimes unreliable - 30% failure rate
        good = random.random() > 0.3
        terms, attestation = net.run_full_session(
            charlie.public_key,
            bob.public_key,
            duration_hours=1.0,
            actual_valid=good,
        )
        sessions_run.append(("bob", good, attestation))

    print(f"  Ran {len(sessions_run)} sessions")
    alice_sessions = [s for s in sessions_run if s[0] == 'alice']
    bob_sessions = [s for s in sessions_run if s[0] == 'bob']
    bob_good = sum(1 for s in bob_sessions if s[1])
    bob_bad = len(bob_sessions) - bob_good

    print(f"  Alice: {len(alice_sessions)} sessions, all PASS")
    print(f"  Bob: {len(bob_sessions)} sessions, {bob_good} PASS, {bob_bad} FAIL")

    # Update trust scores
    print("\n4. Computing trust scores...")
    net.update_all_trust_scores()

    alice_trust, alice_details = net.compute_trust(alice.public_key)
    bob_trust, bob_details = net.compute_trust(bob.public_key)

    print(f"\n  Alice:")
    print(f"    Age trust: {alice_details['t_age']:.4f}")
    print(f"    Attestation trust: {alice_details['t_attestations']:.4f}")
    print(f"    Total: {alice_trust:.4f}")

    print(f"\n  Bob:")
    print(f"    Age trust: {bob_details['t_age']:.4f}")
    print(f"    Attestation trust: {bob_details['t_attestations']:.4f}")
    print(f"    Total: {bob_trust:.4f}")

    # Show chain structure
    print("\n5. Chain structure (Charlie - consumer)...")
    net.print_chain(charlie.public_key)

    # Summary
    net.print_summary()

    print(f"\n{'='*70}")
    print("DEMO COMPLETE")
    print("=" * 70)
    print("""
Key points demonstrated:
1. DAG created via PEER_HASH blocks from keepalives
2. Session lifecycle (SESSION_START, SESSION_END)
3. Sessions verified by cabal (ATTESTATION blocks)
4. Trust computed from attestation history
""")


if __name__ == "__main__":
    random.seed(42)
    demo()
