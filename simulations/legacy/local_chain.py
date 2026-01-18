#!/usr/bin/env python3
"""
Local Chain Implementation for Omerta

TrustChain-inspired half-block DAG with verifiable trust computation.

Key concepts:
- Each identity maintains their own chain of blocks
- Transactions create linked half-blocks (one per party)
- Trust computation is deterministic from chain data
- Anyone can verify trust scores by recomputing from chain data
"""

import hashlib
import json
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Set
from enum import Enum
import time


# =============================================================================
# Cryptographic Primitives (simplified for simulation)
# =============================================================================

def hash_block(data: dict) -> str:
    """Compute deterministic hash of block data."""
    canonical = json.dumps(data, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def sign(private_key: str, data: str) -> str:
    """Simulate signing (in real impl: Ed25519 or similar)."""
    return hashlib.sha256(f"{private_key}:{data}".encode()).hexdigest()[:16]


def verify_signature(public_key: str, data: str, signature: str) -> bool:
    """Simulate signature verification."""
    # In simulation, we trust signatures. Real impl would verify cryptographically.
    return len(signature) == 16


# =============================================================================
# Block Types
# =============================================================================

class BlockType(Enum):
    GENESIS = "genesis"
    COMPUTE_SESSION = "compute_session"
    ASSERTION = "assertion"
    PAYMENT = "payment"


@dataclass
class HalfBlock:
    """
    A half-block in a local chain.

    Each transaction creates two half-blocks that share a transaction_id.
    Both blocks reference the same transaction, creating entanglement.
    This avoids circular hash dependencies while maintaining tamper-evidence.
    """
    # Identity info
    public_key: str              # Owner of this half-block
    sequence_number: int         # Position in owner's chain

    # Chain links
    previous_hash: str           # Hash of previous block in THIS chain
    partner_public_key: str      # The other party in this transaction
    partner_sequence: int        # Partner's sequence number for this tx
    transaction_id: str          # Shared ID linking both half-blocks

    # Content
    block_type: BlockType
    timestamp: float
    payload: dict               # Type-specific data

    # Signatures
    signature: str              # Owner's signature
    partner_signature: str      # Partner's counter-signature (agreement)

    # Computed
    block_hash: str = ""

    def __post_init__(self):
        if not self.block_hash:
            self.block_hash = self.compute_hash()

    def compute_hash(self) -> str:
        """Compute block hash from contents."""
        data = {
            "public_key": self.public_key,
            "sequence_number": self.sequence_number,
            "previous_hash": self.previous_hash,
            "partner_public_key": self.partner_public_key,
            "partner_sequence": self.partner_sequence,
            "transaction_id": self.transaction_id,
            "block_type": self.block_type.value,
            "timestamp": self.timestamp,
            "payload": self.payload,
        }
        return hash_block(data)

    def to_dict(self) -> dict:
        """Serialize for transmission/storage."""
        return {
            "public_key": self.public_key,
            "sequence_number": self.sequence_number,
            "previous_hash": self.previous_hash,
            "partner_public_key": self.partner_public_key,
            "partner_sequence": self.partner_sequence,
            "transaction_id": self.transaction_id,
            "block_type": self.block_type.value,
            "timestamp": self.timestamp,
            "payload": self.payload,
            "signature": self.signature,
            "partner_signature": self.partner_signature,
            "block_hash": self.block_hash,
        }

    @classmethod
    def from_dict(cls, data: dict) -> 'HalfBlock':
        """Deserialize from dict."""
        return cls(
            public_key=data["public_key"],
            sequence_number=data["sequence_number"],
            previous_hash=data["previous_hash"],
            partner_public_key=data["partner_public_key"],
            partner_sequence=data["partner_sequence"],
            transaction_id=data["transaction_id"],
            block_type=BlockType(data["block_type"]),
            timestamp=data["timestamp"],
            payload=data["payload"],
            signature=data["signature"],
            partner_signature=data["partner_signature"],
            block_hash=data["block_hash"],
        )


@dataclass
class LocalChain:
    """
    A single identity's local chain.

    Contains all half-blocks for this identity, forming a linked list
    that is entangled with other chains through bilateral transactions.
    """
    public_key: str
    private_key: str  # For signing (would be kept secret in real impl)

    blocks: List[HalfBlock] = field(default_factory=list)
    genesis_timestamp: float = 0.0

    def __post_init__(self):
        if not self.blocks:
            self._create_genesis()

    def _create_genesis(self):
        """Create genesis block for this chain."""
        self.genesis_timestamp = time.time()
        genesis = HalfBlock(
            public_key=self.public_key,
            sequence_number=0,
            previous_hash="0" * 16,
            partner_public_key=self.public_key,  # Self-reference for genesis
            partner_sequence=0,
            transaction_id="genesis_" + self.public_key[:8],
            block_type=BlockType.GENESIS,
            timestamp=self.genesis_timestamp,
            payload={"created": self.genesis_timestamp},
            signature=sign(self.private_key, "genesis"),
            partner_signature="",
        )
        self.blocks.append(genesis)

    @property
    def head(self) -> HalfBlock:
        """Get the latest block."""
        return self.blocks[-1]

    @property
    def sequence(self) -> int:
        """Get current sequence number."""
        return len(self.blocks) - 1

    def age_days(self, current_time: float) -> float:
        """Get chain age in days."""
        return (current_time - self.genesis_timestamp) / 86400

    def get_block(self, sequence: int) -> Optional[HalfBlock]:
        """Get block by sequence number."""
        if 0 <= sequence < len(self.blocks):
            return self.blocks[sequence]
        return None

    def append_block(self, block: HalfBlock) -> bool:
        """Append a new block to the chain."""
        # Validate chain linkage
        if block.previous_hash != self.head.block_hash:
            return False
        if block.sequence_number != self.sequence + 1:
            return False
        if block.public_key != self.public_key:
            return False

        self.blocks.append(block)
        return True


# =============================================================================
# Compute Session Payload
# =============================================================================

@dataclass
class ComputeSessionData:
    """Data for a compute session transaction."""
    session_id: str
    resource_cores: int
    resource_memory_gb: float
    duration_hours: float
    price_omc: float

    # Verification results (filled in after session)
    verification_score: float = 0.0
    verified_at: float = 0.0

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "resource_cores": self.resource_cores,
            "resource_memory_gb": self.resource_memory_gb,
            "duration_hours": self.duration_hours,
            "price_omc": self.price_omc,
            "verification_score": self.verification_score,
            "verified_at": self.verified_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> 'ComputeSessionData':
        return cls(**data)


# =============================================================================
# Network of Local Chains
# =============================================================================

class ChainNetwork:
    """
    Network of local chains with bilateral transaction creation.
    """

    def __init__(self):
        self.chains: Dict[str, LocalChain] = {}
        self.current_time: float = time.time()

    def create_identity(self, name: str) -> LocalChain:
        """Create a new identity with its local chain."""
        # In real impl: generate keypair
        public_key = f"pk_{name}"
        private_key = f"sk_{name}"

        chain = LocalChain(public_key=public_key, private_key=private_key)
        chain.genesis_timestamp = self.current_time
        self.chains[public_key] = chain
        return chain

    def advance_time(self, days: float):
        """Advance simulation time."""
        self.current_time += days * 86400

    def create_compute_session(
        self,
        consumer_key: str,
        provider_key: str,
        cores: int = 4,
        memory_gb: float = 8.0,
        duration_hours: float = 1.0,
        price_omc: float = 0.1,
        verification_score: float = 1.0,
    ) -> Tuple[HalfBlock, HalfBlock]:
        """
        Create a bilateral compute session transaction.

        Returns the two half-blocks (consumer's and provider's).
        """
        consumer_chain = self.chains[consumer_key]
        provider_chain = self.chains[provider_key]

        session_data = ComputeSessionData(
            session_id=hash_block({"t": self.current_time, "c": consumer_key, "p": provider_key})[:8],
            resource_cores=cores,
            resource_memory_gb=memory_gb,
            duration_hours=duration_hours,
            price_omc=price_omc,
            verification_score=verification_score,
            verified_at=self.current_time,
        )

        # Generate shared transaction ID
        tx_id = session_data.session_id

        # Create consumer's half-block
        consumer_block = HalfBlock(
            public_key=consumer_key,
            sequence_number=consumer_chain.sequence + 1,
            previous_hash=consumer_chain.head.block_hash,
            partner_public_key=provider_key,
            partner_sequence=provider_chain.sequence + 1,
            transaction_id=tx_id,
            block_type=BlockType.COMPUTE_SESSION,
            timestamp=self.current_time,
            payload={
                "role": "consumer",
                "session": session_data.to_dict(),
            },
            signature="",
            partner_signature="",
        )

        # Create provider's half-block
        provider_block = HalfBlock(
            public_key=provider_key,
            sequence_number=provider_chain.sequence + 1,
            previous_hash=provider_chain.head.block_hash,
            partner_public_key=consumer_key,
            partner_sequence=consumer_chain.sequence + 1,
            transaction_id=tx_id,
            block_type=BlockType.COMPUTE_SESSION,
            timestamp=self.current_time,
            payload={
                "role": "provider",
                "session": session_data.to_dict(),
            },
            signature="",
            partner_signature="",
        )

        # Sign blocks
        consumer_block.signature = sign(consumer_chain.private_key, consumer_block.block_hash)
        provider_block.signature = sign(provider_chain.private_key, provider_block.block_hash)

        # Counter-sign (agreement)
        consumer_block.partner_signature = sign(provider_chain.private_key, consumer_block.block_hash)
        provider_block.partner_signature = sign(consumer_chain.private_key, provider_block.block_hash)

        # Append to chains
        consumer_chain.append_block(consumer_block)
        provider_chain.append_block(provider_block)

        return consumer_block, provider_block

    def get_chain_data(self, public_key: str, max_sequence: Optional[int] = None) -> List[dict]:
        """
        Get chain data up to a specific sequence number.

        This is what gets transmitted for verification.
        """
        chain = self.chains.get(public_key)
        if not chain:
            return []

        end = max_sequence + 1 if max_sequence is not None else len(chain.blocks)
        return [block.to_dict() for block in chain.blocks[:end]]


# =============================================================================
# Deterministic Trust Computation
# =============================================================================

class TrustComputer:
    """
    Computes trust scores deterministically from chain data.

    Key property: given the same chain data, any node computes the same trust score.
    This enables verification by spot-checking.
    """

    # Parameters (must be agreed upon network-wide)
    K_AGE = 0.01              # Trust per day at steady state
    TAU_AGE = 30              # Days to reach ~63% of steady rate
    BASE_CREDIT = 0.1         # Trust per compute-hour
    TAU_DECAY = 365           # Half-life for transaction credit decay
    VERIFICATION_PENALTY = 0.5  # Penalty multiplier for failed verification

    def __init__(self, current_time: float):
        self.current_time = current_time

    def compute_trust(
        self,
        subject_chain: List[dict],
        counterparty_chains: Dict[str, List[dict]],
    ) -> Tuple[float, dict]:
        """
        Compute trust score for a subject from their chain data.

        Args:
            subject_chain: The subject's chain data (list of block dicts)
            counterparty_chains: Chains of counterparties for cross-validation

        Returns:
            (trust_score, computation_details)

        The computation_details can be used to verify the calculation.
        """
        if not subject_chain:
            return 0.0, {"error": "empty chain"}

        # Reconstruct blocks
        blocks = [HalfBlock.from_dict(b) for b in subject_chain]
        genesis = blocks[0]

        # 1. Age component
        age_days = (self.current_time - genesis.timestamp) / 86400
        t_age = self._compute_age_trust(age_days)

        # 2. Transaction component
        t_transactions, tx_details = self._compute_transaction_trust(
            blocks, counterparty_chains
        )

        # 3. Total trust (floored at 0)
        total_trust = max(0.0, t_age + t_transactions)

        details = {
            "age_days": age_days,
            "t_age": t_age,
            "t_transactions": t_transactions,
            "tx_details": tx_details,
            "total": total_trust,
            "computed_at": self.current_time,
        }

        return total_trust, details

    def _compute_age_trust(self, age_days: float) -> float:
        """Compute trust from identity age."""
        if age_days <= 0:
            return 0.0

        # Integral of age rate over time
        # age_rate(t) = K_AGE * (1 - exp(-t/TAU_AGE))
        # Simplified: use steady-state rate times age, discounted
        t_age = 0.0
        for day in range(int(age_days)):
            age_rate = self.K_AGE * (1 - math.exp(-day / self.TAU_AGE))
            t_age += age_rate

        return t_age

    def _compute_transaction_trust(
        self,
        blocks: List[HalfBlock],
        counterparty_chains: Dict[str, List[dict]],
    ) -> Tuple[float, List[dict]]:
        """Compute trust from transaction history."""
        t_transactions = 0.0
        details = []

        for block in blocks:
            if block.block_type != BlockType.COMPUTE_SESSION:
                continue

            payload = block.payload
            if payload.get("role") != "provider":
                continue  # Only count when acting as provider

            session = payload.get("session", {})

            # Validate against counterparty chain if available
            partner_key = block.partner_public_key
            validated = self._validate_against_counterparty(
                block, counterparty_chains.get(partner_key, [])
            )

            if not validated:
                # Unvalidated transaction - could be fabricated
                details.append({
                    "block_seq": block.sequence_number,
                    "status": "unvalidated",
                    "credit": 0.0,
                })
                continue

            # Compute credit
            age_days = (self.current_time - block.timestamp) / 86400
            recency = math.exp(-age_days / self.TAU_DECAY)

            duration = session.get("duration_hours", 0)
            cores = session.get("resource_cores", 1)
            verification = session.get("verification_score", 0)

            resource_weight = cores / 4.0  # Normalize to 4-core baseline

            if verification >= 0.7:
                credit = self.BASE_CREDIT * resource_weight * duration * verification * recency
            else:
                # Failed verification: penalty
                credit = -self.VERIFICATION_PENALTY * resource_weight * duration * (0.7 - verification) * recency

            t_transactions += credit
            details.append({
                "block_seq": block.sequence_number,
                "status": "validated",
                "duration": duration,
                "verification": verification,
                "recency": recency,
                "credit": credit,
            })

        return t_transactions, details

    def _validate_against_counterparty(
        self,
        block: HalfBlock,
        counterparty_chain: List[dict],
    ) -> bool:
        """
        Validate that a transaction exists in counterparty's chain.

        This is the key verification step: we check that the counterparty
        also has a matching half-block with the same transaction_id,
        proving bilateral agreement.
        """
        if not counterparty_chain:
            return False

        # Look for matching block in counterparty chain
        for cp_block_dict in counterparty_chain:
            cp_block = HalfBlock.from_dict(cp_block_dict)

            # Check if this is the matching half-block
            # Must have: same transaction_id, correct partner references
            if (cp_block.transaction_id == block.transaction_id and
                cp_block.partner_public_key == block.public_key and
                cp_block.partner_sequence == block.sequence_number):
                return True

        return False


# =============================================================================
# Spot-Check Verification Protocol
# =============================================================================

@dataclass
class TrustClaim:
    """A claim about someone's trust score."""
    subject_key: str
    claimed_score: float
    claimed_at: float

    # Chain state at time of claim (for reproducibility)
    subject_chain_head: str     # Hash of subject's chain head
    subject_chain_seq: int      # Sequence number used

    # Claimant info
    claimant_key: str
    claimant_signature: str


@dataclass
class VerificationChallenge:
    """A challenge to verify a trust claim."""
    claim: TrustClaim
    challenger_key: str
    challenge_time: float


@dataclass
class VerificationResult:
    """Result of verifying a trust claim."""
    claim: TrustClaim
    recomputed_score: float
    computation_details: dict
    is_valid: bool
    discrepancy: float

    # Signatures from verifier
    verifier_key: str
    verifier_signature: str


class SpotCheckVerifier:
    """
    Implements spot-check verification of trust claims.

    When a trust score affects payments, the affected party can challenge.
    A verifier (could be any node) recomputes the score from chain data.
    If the original claim was wrong, the claimant is penalized.
    """

    TOLERANCE = 0.01  # Allow small floating-point differences

    def __init__(self, network: ChainNetwork):
        self.network = network
        self.pending_claims: List[TrustClaim] = []
        self.verification_results: List[VerificationResult] = []

    def create_claim(
        self,
        claimant_key: str,
        subject_key: str,
        claimed_score: float,
    ) -> TrustClaim:
        """Create a trust claim (e.g., for use in payment calculation)."""
        subject_chain = self.network.chains.get(subject_key)
        if not subject_chain:
            raise ValueError(f"Unknown subject: {subject_key}")

        claim = TrustClaim(
            subject_key=subject_key,
            claimed_score=claimed_score,
            claimed_at=self.network.current_time,
            subject_chain_head=subject_chain.head.block_hash,
            subject_chain_seq=subject_chain.sequence,
            claimant_key=claimant_key,
            claimant_signature=sign(
                self.network.chains[claimant_key].private_key,
                f"{subject_key}:{claimed_score}:{subject_chain.head.block_hash}"
            ),
        )

        self.pending_claims.append(claim)
        return claim

    def verify_claim(
        self,
        claim: TrustClaim,
        verifier_key: str,
    ) -> VerificationResult:
        """
        Verify a trust claim by recomputing from chain data.

        This is the core spot-check mechanism.
        """
        # Get chain data up to the claimed sequence
        subject_chain_data = self.network.get_chain_data(
            claim.subject_key,
            max_sequence=claim.subject_chain_seq
        )

        # Get counterparty chains for cross-validation
        counterparty_keys = set()
        for block_dict in subject_chain_data:
            if block_dict.get("partner_public_key") != claim.subject_key:
                counterparty_keys.add(block_dict["partner_public_key"])

        counterparty_chains = {}
        for cp_key in counterparty_keys:
            counterparty_chains[cp_key] = self.network.get_chain_data(cp_key)

        # Recompute trust
        computer = TrustComputer(claim.claimed_at)
        recomputed_score, details = computer.compute_trust(
            subject_chain_data,
            counterparty_chains
        )

        # Check validity
        discrepancy = abs(recomputed_score - claim.claimed_score)
        is_valid = discrepancy <= self.TOLERANCE

        result = VerificationResult(
            claim=claim,
            recomputed_score=recomputed_score,
            computation_details=details,
            is_valid=is_valid,
            discrepancy=discrepancy,
            verifier_key=verifier_key,
            verifier_signature=sign(
                self.network.chains[verifier_key].private_key,
                f"verified:{claim.subject_key}:{recomputed_score}:{is_valid}"
            ),
        )

        self.verification_results.append(result)
        return result

    def random_audit(self, auditor_key: str, sample_rate: float = 0.1) -> List[VerificationResult]:
        """
        Randomly audit pending claims.

        This is proactive verification to deter cheating.
        """
        import random

        results = []
        claims_to_audit = [c for c in self.pending_claims if random.random() < sample_rate]

        for claim in claims_to_audit:
            result = self.verify_claim(claim, auditor_key)
            results.append(result)

            if not result.is_valid:
                print(f"AUDIT FAILURE: {claim.claimant_key} claimed {claim.claimed_score:.4f} "
                      f"for {claim.subject_key}, actual: {result.recomputed_score:.4f}")

        return results


# =============================================================================
# Demo / Test
# =============================================================================

def demo():
    """Demonstrate the local chain and verification system."""
    print("="*60)
    print("LOCAL CHAIN + VERIFIABLE TRUST DEMO")
    print("="*60)

    # Create network
    net = ChainNetwork()

    # Create identities
    alice = net.create_identity("alice")
    bob = net.create_identity("bob")
    charlie = net.create_identity("charlie")  # Will be a verifier

    print(f"\nCreated identities:")
    print(f"  Alice: {alice.public_key}")
    print(f"  Bob: {bob.public_key}")
    print(f"  Charlie: {charlie.public_key}")

    # Simulate some transactions over 30 days
    print(f"\nSimulating 30 days of transactions...")

    for day in range(30):
        net.advance_time(1)

        # Bob provides compute to Alice
        if day % 3 == 0:
            c_block, p_block = net.create_compute_session(
                consumer_key=alice.public_key,
                provider_key=bob.public_key,
                cores=4,
                duration_hours=2.0,
                verification_score=0.95,
            )
            print(f"  Day {day}: Alice consumed from Bob (session {p_block.payload['session']['session_id']})")

    print(f"\nChain states:")
    print(f"  Alice: {alice.sequence} blocks")
    print(f"  Bob: {bob.sequence} blocks")

    # Compute Bob's trust
    print(f"\n{'='*60}")
    print("TRUST COMPUTATION")
    print("="*60)

    computer = TrustComputer(net.current_time)

    bob_chain_data = net.get_chain_data(bob.public_key)
    counterparty_chains = {
        alice.public_key: net.get_chain_data(alice.public_key)
    }

    trust_score, details = computer.compute_trust(bob_chain_data, counterparty_chains)

    print(f"\nBob's trust score: {trust_score:.4f}")
    print(f"  Age component: {details['t_age']:.4f} ({details['age_days']:.1f} days)")
    print(f"  Transaction component: {details['t_transactions']:.4f}")
    print(f"  Validated transactions: {sum(1 for t in details['tx_details'] if t['status'] == 'validated')}")

    # Demonstrate verification
    print(f"\n{'='*60}")
    print("SPOT-CHECK VERIFICATION")
    print("="*60)

    verifier = SpotCheckVerifier(net)

    # Alice makes a claim about Bob's trust (correct)
    print(f"\n1. Correct claim:")
    correct_claim = verifier.create_claim(
        claimant_key=alice.public_key,
        subject_key=bob.public_key,
        claimed_score=trust_score,
    )
    print(f"   Alice claims Bob's trust is {correct_claim.claimed_score:.4f}")

    result = verifier.verify_claim(correct_claim, charlie.public_key)
    print(f"   Charlie verifies: recomputed={result.recomputed_score:.4f}, valid={result.is_valid}")

    # Alice makes a false claim (trying to burn more of Bob's coins)
    print(f"\n2. False claim (understating trust):")
    false_claim = verifier.create_claim(
        claimant_key=alice.public_key,
        subject_key=bob.public_key,
        claimed_score=trust_score * 0.5,  # Claiming half the actual trust
    )
    print(f"   Alice falsely claims Bob's trust is {false_claim.claimed_score:.4f}")

    result = verifier.verify_claim(false_claim, charlie.public_key)
    print(f"   Charlie verifies: recomputed={result.recomputed_score:.4f}, valid={result.is_valid}")
    print(f"   Discrepancy: {result.discrepancy:.4f} (Alice tried to cheat!)")

    # Show that verification is deterministic
    print(f"\n3. Verification is deterministic:")
    result2 = verifier.verify_claim(correct_claim, alice.public_key)
    result3 = verifier.verify_claim(correct_claim, bob.public_key)
    print(f"   Charlie's result: {result.recomputed_score:.4f}")
    print(f"   Alice's result:   {result2.recomputed_score:.4f}")
    print(f"   Bob's result:     {result3.recomputed_score:.4f}")
    print(f"   All match: {result.recomputed_score == result2.recomputed_score == result3.recomputed_score}")

    print(f"\n{'='*60}")
    print("DEMO COMPLETE")
    print("="*60)


if __name__ == "__main__":
    demo()
