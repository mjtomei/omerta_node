"""
Type definitions for sessions, attestations, and escrow.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional
from enum import Enum

from .primitives import hash_data


# =============================================================================
# Session-related Enums
# =============================================================================

class SessionEndReason(Enum):
    """Reasons a session can end."""
    PROVIDER_VOLUNTARY = "provider_voluntary"
    CONSUMER_REQUEST = "consumer_request"
    VM_DIED = "vm_died"
    TIMEOUT = "timeout"


class AttestationOutcome(Enum):
    """Possible outcomes of cabal attestation."""
    PASS = "pass"
    FAIL = "fail"
    INCONCLUSIVE = "inconclusive"


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
# Escrow Types
# =============================================================================

class LockStatus(Enum):
    """Status of an escrow lock."""
    ACCEPTED = "accepted"
    REJECTED = "rejected"


class WitnessVerdict(Enum):
    """Witness preliminary verdict."""
    ACCEPT = "accept"
    REJECT = "reject"
    NEED_MORE_INFO = "need_more_info"


@dataclass
class LockIntent:
    """Consumer's intent to lock funds."""
    consumer: str
    provider: str
    amount: float
    session_id: str
    consumer_nonce: bytes
    provider_chain_checkpoint: str
    checkpoint_timestamp: float
    timestamp: float
    signature: str = ""

    def to_dict(self) -> dict:
        return {
            "consumer": self.consumer,
            "provider": self.provider,
            "amount": self.amount,
            "session_id": self.session_id,
            "consumer_nonce": self.consumer_nonce.hex() if isinstance(self.consumer_nonce, bytes) else self.consumer_nonce,
            "provider_chain_checkpoint": self.provider_chain_checkpoint,
            "checkpoint_timestamp": self.checkpoint_timestamp,
            "timestamp": self.timestamp,
            "signature": self.signature,
        }


@dataclass
class WitnessSelectionCommitment:
    """Provider's commitment to witness selection."""
    session_id: str
    provider: str
    provider_nonce: bytes
    provider_chain_segment: List[dict]
    selection_inputs: dict
    witnesses: List[str]
    timestamp: float
    signature: str = ""

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "provider": self.provider,
            "provider_nonce": self.provider_nonce.hex() if isinstance(self.provider_nonce, bytes) else self.provider_nonce,
            "provider_chain_segment": self.provider_chain_segment,
            "selection_inputs": self.selection_inputs,
            "witnesses": self.witnesses,
            "timestamp": self.timestamp,
            "signature": self.signature,
        }


@dataclass
class LockResult:
    """Result of escrow lock attempt."""
    session_id: str
    consumer: str
    provider: str
    amount: float
    status: LockStatus
    observed_balance: float
    witnesses: List[str]
    witness_signatures: List[str]
    consumer_signature: str
    timestamp: float

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "consumer": self.consumer,
            "provider": self.provider,
            "amount": self.amount,
            "status": self.status.value,
            "observed_balance": self.observed_balance,
            "witnesses": self.witnesses,
            "witness_signatures": self.witness_signatures,
            "consumer_signature": self.consumer_signature,
            "timestamp": self.timestamp,
        }
