#!/usr/bin/env python3
"""
Verification Attestation Protocol for Omerta

This module implements the panel-based verification system where:
1. Transactions are randomly selected for verification
2. A panel of uninvolved, trusted parties verifies the transaction
3. Panel votes using commit-reveal to prevent bandwagoning
4. Results are confirmed by majority before penalties
5. Attestations are broadcast for others to incorporate into local trust

Key insight: You don't need to see raw transactions to compute trust.
You see VERIFIED ATTESTATIONS from trusted panels about transaction validity.
"""

import hashlib
import json
import random
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Set
from enum import Enum
import time

from local_chain import (
    ChainNetwork, LocalChain, HalfBlock, BlockType,
    TrustComputer, hash_block, sign, verify_signature
)


# =============================================================================
# Protocol Parameters
# =============================================================================

VERIFICATION_PANEL_SIZE = 5          # Number of verifiers per check
VERIFIER_TRUST_THRESHOLD = 1.0       # Minimum trust to be a verifier
COMMIT_DEADLINE_SECONDS = 60         # Time to submit commits
REVEAL_DEADLINE_SECONDS = 60         # Time to reveal after commits
MAJORITY_THRESHOLD = 0.5             # Fraction needed for outcome
VERIFICATION_SAMPLE_RATE = 0.1       # Fraction of transactions verified
ATTESTATION_WEIGHT_DECAY = 180       # Days for attestation weight to halve


# =============================================================================
# Data Structures
# =============================================================================

class VerificationOutcome(Enum):
    PENDING = "pending"
    PASS = "pass"
    FAIL = "fail"
    INCONCLUSIVE = "inconclusive"  # Not enough votes


@dataclass
class VerificationVote:
    """A single verifier's vote on a transaction."""
    verifier_key: str
    transaction_id: str
    vote: bool                    # True = pass, False = fail
    nonce: str                    # Random nonce for commit-reveal
    evidence: dict                # What the verifier observed
    timestamp: float
    signature: str = ""

    def compute_commit(self) -> str:
        """Compute commit hash for commit-reveal protocol."""
        data = f"{self.verifier_key}:{self.transaction_id}:{self.vote}:{self.nonce}"
        return hashlib.sha256(data.encode()).hexdigest()[:16]

    def to_dict(self) -> dict:
        return {
            "verifier_key": self.verifier_key,
            "transaction_id": self.transaction_id,
            "vote": self.vote,
            "nonce": self.nonce,
            "evidence": self.evidence,
            "timestamp": self.timestamp,
            "signature": self.signature,
        }


@dataclass
class VerificationAttestation:
    """
    A signed attestation from a verification panel about a transaction.

    This is the key data structure that gets broadcast through the network.
    Recipients incorporate these attestations into their local trust computation.
    """
    # What was verified
    transaction_id: str
    provider_key: str
    consumer_key: str
    session_data: dict            # Copy of session details for context

    # Who verified
    panel_members: List[str]      # Public keys of panel members

    # Outcome
    outcome: VerificationOutcome
    votes_pass: int
    votes_fail: int
    margin: float                 # |pass - fail| / total

    # Individual votes (revealed after deadline)
    revealed_votes: Dict[str, bool]  # verifier_key -> vote

    # Signatures (each panelist signs the attestation)
    signatures: Dict[str, str]    # verifier_key -> signature

    # Metadata
    initiated_by: str             # Who triggered the verification
    initiated_at: float
    completed_at: float
    attestation_id: str = ""

    def __post_init__(self):
        if not self.attestation_id:
            self.attestation_id = self._compute_id()

    def _compute_id(self) -> str:
        """Compute unique attestation ID."""
        data = {
            "transaction_id": self.transaction_id,
            "panel": sorted(self.panel_members),
            "outcome": self.outcome.value,
            "completed_at": self.completed_at,
        }
        return hash_block(data)

    def is_fully_signed(self) -> bool:
        """Check if all panel members have signed."""
        return set(self.signatures.keys()) == set(self.panel_members)

    def verify_signatures(self) -> bool:
        """Verify all signatures are valid."""
        attestation_data = self._signable_data()
        for verifier_key, sig in self.signatures.items():
            if not verify_signature(verifier_key, attestation_data, sig):
                return False
        return True

    def _signable_data(self) -> str:
        """Get the data that is signed by panelists."""
        return json.dumps({
            "transaction_id": self.transaction_id,
            "outcome": self.outcome.value,
            "votes_pass": self.votes_pass,
            "votes_fail": self.votes_fail,
            "completed_at": self.completed_at,
        }, sort_keys=True)

    def to_dict(self) -> dict:
        return {
            "attestation_id": self.attestation_id,
            "transaction_id": self.transaction_id,
            "provider_key": self.provider_key,
            "consumer_key": self.consumer_key,
            "session_data": self.session_data,
            "panel_members": self.panel_members,
            "outcome": self.outcome.value,
            "votes_pass": self.votes_pass,
            "votes_fail": self.votes_fail,
            "margin": self.margin,
            "revealed_votes": self.revealed_votes,
            "signatures": self.signatures,
            "initiated_by": self.initiated_by,
            "initiated_at": self.initiated_at,
            "completed_at": self.completed_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> 'VerificationAttestation':
        return cls(
            transaction_id=data["transaction_id"],
            provider_key=data["provider_key"],
            consumer_key=data["consumer_key"],
            session_data=data["session_data"],
            panel_members=data["panel_members"],
            outcome=VerificationOutcome(data["outcome"]),
            votes_pass=data["votes_pass"],
            votes_fail=data["votes_fail"],
            margin=data["margin"],
            revealed_votes=data["revealed_votes"],
            signatures=data["signatures"],
            initiated_by=data["initiated_by"],
            initiated_at=data["initiated_at"],
            completed_at=data["completed_at"],
            attestation_id=data["attestation_id"],
        )


# =============================================================================
# Panel Selection
# =============================================================================

class PanelSelector:
    """
    Selects verification panels according to the protocol rules.

    Panel selection prioritizes:
    - High trust (reliable verifiers)
    - Low interaction history with parties (independence)
    - Availability (walk sorted list until panel filled)

    Key insight: We can't require ZERO interaction history because:
    - Even panel participation creates interaction
    - Strict requirements cause availability problems
    - Instead, we MINIMIZE interaction via sorting
    """

    def __init__(self, network: ChainNetwork, trust_scores: Dict[str, float]):
        self.network = network
        self.trust_scores = trust_scores
        # Track panel participation as interaction
        self.panel_history: Dict[Tuple[str, str], int] = {}  # (a, b) -> count

    def get_interaction_count(self, key_a: str, key_b: str) -> int:
        """
        Get total interaction count between two identities.

        Includes:
        - Direct transactions
        - Panel co-membership
        - Any other recorded interaction
        """
        # Normalize key order for consistent lookup
        pair = tuple(sorted([key_a, key_b]))

        # Count transactions
        chain_a = self.network.chains.get(key_a)
        tx_count = 0
        if chain_a:
            for block in chain_a.blocks:
                if block.partner_public_key == key_b:
                    tx_count += 1

        # Count panel co-membership
        panel_count = self.panel_history.get(pair, 0)

        return tx_count + panel_count

    def record_panel_interaction(self, panel: List[str]):
        """Record that these identities served on a panel together."""
        for i, a in enumerate(panel):
            for b in panel[i+1:]:
                pair = tuple(sorted([a, b]))
                self.panel_history[pair] = self.panel_history.get(pair, 0) + 1

    def compute_selection_score(
        self,
        candidate_key: str,
        provider_key: str,
        consumer_key: str,
    ) -> float:
        """
        Compute selection score for a candidate.

        Higher score = better candidate.
        Score = trust / (1 + interaction_count)

        This prefers high-trust verifiers with minimal prior interaction.
        """
        trust = self.trust_scores.get(candidate_key, 0)
        if trust < VERIFIER_TRUST_THRESHOLD:
            return -1  # Ineligible

        # Sum interaction with both parties
        interaction_with_provider = self.get_interaction_count(candidate_key, provider_key)
        interaction_with_consumer = self.get_interaction_count(candidate_key, consumer_key)
        total_interaction = interaction_with_provider + interaction_with_consumer

        # Score: trust divided by interaction penalty
        score = trust / (1 + total_interaction)

        return score

    def select_panel(
        self,
        provider_key: str,
        consumer_key: str,
        size: int = VERIFICATION_PANEL_SIZE,
        availability_simulation: Optional[Dict[str, bool]] = None,
    ) -> List[str]:
        """
        Select a verification panel by walking a sorted candidate list.

        Process:
        1. Score all candidates by trust / (1 + interaction)
        2. Sort by score (descending)
        3. Walk the list, trying each candidate
        4. Stop when panel is filled or list exhausted

        availability_simulation: For testing - dict of key -> is_available
        """
        # Score all candidates
        candidates = []

        for key in self.network.chains.keys():
            # Can't verify yourself
            if key in (provider_key, consumer_key):
                continue

            score = self.compute_selection_score(key, provider_key, consumer_key)
            if score > 0:  # Eligible
                candidates.append((key, score))

        # Sort by score (descending)
        candidates.sort(key=lambda x: x[1], reverse=True)

        # Walk the list until panel is filled
        selected = []
        for key, score in candidates:
            if len(selected) >= size:
                break

            # Check availability (in real system: try to contact)
            if availability_simulation is not None:
                if not availability_simulation.get(key, True):
                    continue  # Skip unavailable

            selected.append(key)

        # Record panel interactions for future reference
        if len(selected) >= 3:  # Only if valid panel formed
            self.record_panel_interaction(selected)

        return selected


# =============================================================================
# Verification Session
# =============================================================================

@dataclass
class FailureAlert:
    """Alert from one panel member to others: 'I detected a failure, please check too.'"""
    sender_key: str
    transaction_id: str
    failure_evidence: dict
    timestamp: float


@dataclass
class KeepaliveMessage:
    """Keepalive between panel members to detect offline members."""
    sender_key: str
    transaction_id: str
    timestamp: float
    sequence: int


class VerificationSession:
    """
    Manages a single verification session with intra-panel communication.

    Protocol:
    1. Panel formed when session starts
    2. Panel members monitor session and send keepalives to each other
    3. If member goes offline (missed keepalives), others find replacement
    4. If member detects failure, they alert others: "check this too"
    5. Each member votes their own observation (PASS or FAIL)
    6. When provider signals session end, members exchange votes
    7. Attestation created from collected votes

    Key points:
    - Always vote what you observe (don't wait for others)
    - Failure alerts prompt others to also check (so they can also vote FAIL)
    - Keepalives detect offline members for replacement
    - Vote exchange happens at session end, not during
    """

    # Keepalive parameters
    KEEPALIVE_INTERVAL = 10.0  # seconds between keepalives
    KEEPALIVE_TIMEOUT = 30.0   # seconds before considered offline

    def __init__(
        self,
        transaction_id: str,
        provider_key: str,
        consumer_key: str,
        session_data: dict,
        panel: List[str],
        initiated_by: str,
        current_time: float,
    ):
        self.transaction_id = transaction_id
        self.provider_key = provider_key
        self.consumer_key = consumer_key
        self.session_data = session_data
        self.panel = list(panel)  # Mutable - can add replacements
        self.original_panel = list(panel)  # For reference
        self.initiated_by = initiated_by
        self.initiated_at = current_time

        # Keepalive tracking
        self.last_keepalive: Dict[str, float] = {k: current_time for k in panel}
        self.keepalive_sequence: Dict[str, int] = {k: 0 for k in panel}

        # Failure alerts (intra-panel communication)
        self.failure_alerts: List[FailureAlert] = []
        self.alerted_members: Set[str] = set()  # Members who sent failure alerts

        # Member status
        self.offline_members: Set[str] = set()
        self.replacement_members: List[str] = []  # Members added as replacements

        # Votes (held until session end)
        self.pending_votes: Dict[str, VerificationVote] = {}  # Not yet exchanged
        self.exchanged_votes: Dict[str, VerificationVote] = {}  # After exchange

        # Session lifecycle
        self.session_ended = False
        self.session_end_time: Optional[float] = None
        self.votes_exchanged = False
        self.completed = False
        self.attestation: Optional[VerificationAttestation] = None

    def send_keepalive(self, sender_key: str, current_time: float) -> KeepaliveMessage:
        """Send a keepalive to other panel members."""
        if sender_key not in self.panel:
            return None

        self.keepalive_sequence[sender_key] = self.keepalive_sequence.get(sender_key, 0) + 1
        self.last_keepalive[sender_key] = current_time

        return KeepaliveMessage(
            sender_key=sender_key,
            transaction_id=self.transaction_id,
            timestamp=current_time,
            sequence=self.keepalive_sequence[sender_key],
        )

    def receive_keepalive(self, msg: KeepaliveMessage, current_time: float) -> bool:
        """Process received keepalive from panel member."""
        if msg.sender_key not in self.panel:
            return False

        self.last_keepalive[msg.sender_key] = current_time
        return True

    def check_for_offline_members(self, current_time: float) -> List[str]:
        """Check for members who have missed keepalives."""
        newly_offline = []

        for member in self.panel:
            if member in self.offline_members:
                continue

            last_seen = self.last_keepalive.get(member, self.initiated_at)
            if current_time - last_seen > self.KEEPALIVE_TIMEOUT:
                self.offline_members.add(member)
                newly_offline.append(member)

        return newly_offline

    def add_replacement_member(self, new_member_key: str, current_time: float) -> bool:
        """Add a replacement for an offline member."""
        if new_member_key in self.panel:
            return False  # Already on panel

        self.panel.append(new_member_key)
        self.replacement_members.append(new_member_key)
        self.last_keepalive[new_member_key] = current_time
        self.keepalive_sequence[new_member_key] = 0

        return True

    def send_failure_alert(
        self,
        sender_key: str,
        evidence: dict,
        current_time: float,
    ) -> FailureAlert:
        """
        Alert other panel members: 'I detected a failure, please check too.'

        This is NOT asking for permission to vote FAIL.
        This is prompting others to independently verify so they can also vote FAIL.
        The sender will vote FAIL regardless.
        """
        if sender_key not in self.panel:
            return None

        alert = FailureAlert(
            sender_key=sender_key,
            transaction_id=self.transaction_id,
            failure_evidence=evidence,
            timestamp=current_time,
        )

        self.failure_alerts.append(alert)
        self.alerted_members.add(sender_key)

        return alert

    def receive_failure_alert(self, alert: FailureAlert) -> bool:
        """
        Receive failure alert from another panel member.

        Prompts this member to check the same issue.
        """
        if alert.sender_key not in self.panel:
            return False

        # Record the alert
        if alert not in self.failure_alerts:
            self.failure_alerts.append(alert)
            self.alerted_members.add(alert.sender_key)

        return True

    def record_vote(self, vote: VerificationVote) -> bool:
        """
        Record a vote (held until session end).

        Each member votes their own observation - PASS or FAIL.
        Don't wait for others. Vote what you see.
        """
        if vote.verifier_key not in self.panel:
            return False
        if vote.verifier_key in self.pending_votes:
            return False  # Already voted

        self.pending_votes[vote.verifier_key] = vote
        return True

    def signal_session_end(self, current_time: float) -> bool:
        """
        Signal that the compute session has ended.

        Triggers vote exchange among panel members.
        """
        if self.session_ended:
            return False

        self.session_ended = True
        self.session_end_time = current_time
        return True

    def exchange_votes(self) -> Dict[str, VerificationVote]:
        """
        Exchange votes among panel members.

        Called after session end. Returns all collected votes.
        Members who haven't voted are counted as implicit PASS.
        """
        if not self.session_ended:
            return {}

        self.exchanged_votes = dict(self.pending_votes)
        self.votes_exchanged = True

        return self.exchanged_votes

    def get_active_panel(self) -> List[str]:
        """Get panel members who are still online."""
        return [m for m in self.panel if m not in self.offline_members]

    def can_finalize(self) -> bool:
        """Check if session can be finalized."""
        return self.session_ended and self.votes_exchanged

    def finalize(self, current_time: float, private_keys: Dict[str, str]) -> VerificationAttestation:
        """
        Finalize the session and create attestation.

        Active members who didn't vote = implicit PASS.
        Offline members are excluded from vote count.
        """
        if self.completed:
            return self.attestation

        if not self.can_finalize():
            return None

        # Count votes from active members only
        active_panel = self.get_active_panel()
        votes_pass = 0
        votes_fail = 0
        revealed_votes = {}

        for member in active_panel:
            if member in self.exchanged_votes:
                vote = self.exchanged_votes[member]
                revealed_votes[member] = vote.vote
                if vote.vote:
                    votes_pass += 1
                else:
                    votes_fail += 1
            else:
                # Active but no vote = implicit PASS
                revealed_votes[member] = True
                votes_pass += 1

        total_votes = votes_pass + votes_fail

        # Determine outcome
        if total_votes == 0:
            outcome = VerificationOutcome.INCONCLUSIVE
            margin = 0.0
        elif votes_fail > votes_pass:
            outcome = VerificationOutcome.FAIL
            margin = (votes_fail - votes_pass) / total_votes
        elif votes_pass > votes_fail:
            outcome = VerificationOutcome.PASS
            margin = (votes_pass - votes_fail) / total_votes
        else:
            outcome = VerificationOutcome.INCONCLUSIVE
            margin = 0.0

        # Create attestation
        self.attestation = VerificationAttestation(
            transaction_id=self.transaction_id,
            provider_key=self.provider_key,
            consumer_key=self.consumer_key,
            session_data=self.session_data,
            panel_members=active_panel,  # Only active members
            outcome=outcome,
            votes_pass=votes_pass,
            votes_fail=votes_fail,
            margin=margin,
            revealed_votes=revealed_votes,
            signatures={},
            initiated_by=self.initiated_by,
            initiated_at=self.initiated_at,
            completed_at=current_time,
        )

        # Collect signatures from active panel
        signable = self.attestation._signable_data()
        for verifier_key in active_panel:
            if verifier_key in private_keys:
                sig = sign(private_keys[verifier_key], signable)
                self.attestation.signatures[verifier_key] = sig

        self.completed = True
        return self.attestation


# =============================================================================
# Attestation Store
# =============================================================================

class AttestationStore:
    """
    Stores and indexes attestations for trust computation.

    This is what each node maintains as their view of verified transactions.
    """

    def __init__(self):
        # Index by transaction
        self.by_transaction: Dict[str, VerificationAttestation] = {}

        # Index by provider (for trust computation)
        self.by_provider: Dict[str, List[VerificationAttestation]] = {}

        # Index by consumer
        self.by_consumer: Dict[str, List[VerificationAttestation]] = {}

        # Index by verifier (to track verifier accuracy)
        self.by_verifier: Dict[str, List[Tuple[VerificationAttestation, bool]]] = {}

    def add(self, attestation: VerificationAttestation) -> bool:
        """Add an attestation to the store."""
        if attestation.transaction_id in self.by_transaction:
            return False  # Already have this one

        # Verify signatures
        if not attestation.is_fully_signed():
            return False

        # Store
        self.by_transaction[attestation.transaction_id] = attestation

        # Index by provider
        if attestation.provider_key not in self.by_provider:
            self.by_provider[attestation.provider_key] = []
        self.by_provider[attestation.provider_key].append(attestation)

        # Index by consumer
        if attestation.consumer_key not in self.by_consumer:
            self.by_consumer[attestation.consumer_key] = []
        self.by_consumer[attestation.consumer_key].append(attestation)

        # Index by verifier with their vote
        for verifier_key, vote in attestation.revealed_votes.items():
            if verifier_key not in self.by_verifier:
                self.by_verifier[verifier_key] = []
            # Store whether verifier voted with majority
            voted_with_majority = (
                (vote and attestation.outcome == VerificationOutcome.PASS) or
                (not vote and attestation.outcome == VerificationOutcome.FAIL)
            )
            self.by_verifier[verifier_key].append((attestation, voted_with_majority))

        return True

    def get_provider_attestations(self, provider_key: str) -> List[VerificationAttestation]:
        """Get all attestations for a provider."""
        return self.by_provider.get(provider_key, [])

    def get_verifier_accuracy(self, verifier_key: str) -> float:
        """Compute a verifier's accuracy (fraction of votes matching majority)."""
        history = self.by_verifier.get(verifier_key, [])
        if not history:
            return 0.5  # No history, assume neutral

        correct = sum(1 for _, matched in history if matched)
        return correct / len(history)


# =============================================================================
# Trust Computer with Attestations
# =============================================================================

class AttestationTrustComputer:
    """
    Computes trust using both chain data and broadcast attestations.

    Key insight: You don't need to see every transaction directly.
    You can incorporate VERIFIED ATTESTATIONS from trusted panels.
    """

    # Parameters
    K_AGE = 0.01
    TAU_AGE = 30
    BASE_CREDIT = 0.1
    TAU_DECAY = 365
    VERIFICATION_PENALTY = 0.5

    # Attestation parameters
    PASS_CREDIT_MULTIPLIER = 1.2    # Bonus for verified passing
    FAIL_PENALTY_MULTIPLIER = 2.0   # Penalty multiplier for verified fail

    def __init__(
        self,
        current_time: float,
        attestation_store: AttestationStore,
        verifier_trust: Dict[str, float],
    ):
        self.current_time = current_time
        self.attestations = attestation_store
        self.verifier_trust = verifier_trust

    def compute_trust(self, subject_key: str) -> Tuple[float, dict]:
        """
        Compute trust for a subject using attestations.

        Unlike the chain-based approach, this uses broadcast attestations
        that have been verified by trusted panels.
        """
        # Age component (still based on chain data - genesis timestamp)
        # This would come from seeing the subject's genesis attestation
        # For now, simplified
        t_age = 0.0  # Would need genesis info

        # Attestation component
        t_attestations, attestation_details = self._compute_attestation_trust(subject_key)

        total = max(0.0, t_age + t_attestations)

        return total, {
            "t_age": t_age,
            "t_attestations": t_attestations,
            "attestation_details": attestation_details,
            "total": total,
        }

    def _compute_attestation_trust(self, subject_key: str) -> Tuple[float, List[dict]]:
        """Compute trust from attestations about this subject."""
        attestations = self.attestations.get_provider_attestations(subject_key)

        if not attestations:
            return 0.0, []

        t_total = 0.0
        details = []

        for att in attestations:
            # Weight by panel credibility
            panel_weight = self._compute_panel_weight(att)

            # Recency decay
            age_days = (self.current_time - att.completed_at) / 86400
            recency = math.exp(-age_days / self.TAU_DECAY)

            # Session value
            session = att.session_data
            duration = session.get("duration_hours", 1)
            cores = session.get("resource_cores", 1)
            resource_weight = cores / 4.0

            # Credit based on outcome
            if att.outcome == VerificationOutcome.PASS:
                # Verified pass: positive credit with bonus
                credit = (self.BASE_CREDIT * resource_weight * duration *
                         self.PASS_CREDIT_MULTIPLIER * att.margin)
            elif att.outcome == VerificationOutcome.FAIL:
                # Verified fail: penalty
                credit = -(self.VERIFICATION_PENALTY * resource_weight * duration *
                          self.FAIL_PENALTY_MULTIPLIER * att.margin)
            else:
                # Inconclusive: small positive (transaction happened)
                credit = self.BASE_CREDIT * resource_weight * duration * 0.5

            # Apply weights
            weighted_credit = credit * panel_weight * recency
            t_total += weighted_credit

            details.append({
                "transaction_id": att.transaction_id,
                "outcome": att.outcome.value,
                "margin": att.margin,
                "panel_weight": panel_weight,
                "recency": recency,
                "credit": weighted_credit,
            })

        return t_total, details

    def _compute_panel_weight(self, attestation: VerificationAttestation) -> float:
        """
        Compute weight of an attestation based on panel credibility.

        Uses geometric mean of panel members' trust * their historical accuracy.
        """
        if not attestation.panel_members:
            return 0.0

        weights = []
        for member in attestation.panel_members:
            trust = self.verifier_trust.get(member, 0)
            accuracy = self.attestations.get_verifier_accuracy(member)

            # Combine trust and accuracy
            member_weight = math.sqrt(trust) * accuracy
            weights.append(max(member_weight, 0.01))  # Floor to avoid zero

        # Geometric mean
        product = 1.0
        for w in weights:
            product *= w

        return product ** (1.0 / len(weights))


# =============================================================================
# Verification Coordinator
# =============================================================================

class VerificationCoordinator:
    """
    Coordinates the full verification protocol:
    1. Select transactions for verification
    2. Form panels
    3. Run commit-reveal voting
    4. Create and broadcast attestations
    """

    def __init__(self, network: ChainNetwork):
        self.network = network
        self.trust_scores: Dict[str, float] = {}
        self.attestation_store = AttestationStore()
        self.active_sessions: Dict[str, VerificationSession] = {}
        self.pending_broadcasts: List[VerificationAttestation] = []

    def update_trust_scores(self, scores: Dict[str, float]):
        """Update trust scores for panel selection."""
        self.trust_scores = scores

    def select_transactions_for_verification(
        self,
        sample_rate: float = VERIFICATION_SAMPLE_RATE,
    ) -> List[Tuple[str, str, str, dict]]:
        """
        Select transactions to verify.

        Returns list of (transaction_id, provider_key, consumer_key, session_data)
        """
        candidates = []

        for key, chain in self.network.chains.items():
            for block in chain.blocks:
                if block.block_type != BlockType.COMPUTE_SESSION:
                    continue
                if block.payload.get("role") != "provider":
                    continue

                tx_id = block.transaction_id

                # Skip if already verified
                if tx_id in self.attestation_store.by_transaction:
                    continue

                candidates.append((
                    tx_id,
                    block.public_key,  # provider
                    block.partner_public_key,  # consumer
                    block.payload.get("session", {}),
                ))

        # Random sample
        k = max(1, int(len(candidates) * sample_rate))
        return random.sample(candidates, min(k, len(candidates)))

    def initiate_verification(
        self,
        transaction_id: str,
        provider_key: str,
        consumer_key: str,
        session_data: dict,
        initiated_by: str,
    ) -> Optional[VerificationSession]:
        """Initiate a verification session."""
        # Select panel
        selector = PanelSelector(self.network, self.trust_scores)
        panel = selector.select_panel(provider_key, consumer_key)

        if len(panel) < 3:  # Need minimum panel size
            return None

        session = VerificationSession(
            transaction_id=transaction_id,
            provider_key=provider_key,
            consumer_key=consumer_key,
            session_data=session_data,
            panel=panel,
            initiated_by=initiated_by,
            current_time=self.network.current_time,
        )

        self.active_sessions[transaction_id] = session
        return session

    def simulate_verification(
        self,
        session: VerificationSession,
        actual_valid: bool,
        noise: float = 0.1,
    ) -> VerificationAttestation:
        """
        Simulate the verification process for testing.

        Simulates the full protocol:
        1. Panel members send keepalives throughout session
        2. Each verifier independently monitors and detects issues
        3. If failure detected, alert others ("check this too")
        4. Each verifier votes their own observation
        5. When session ends, exchange votes
        6. Create attestation from collected votes
        """
        private_keys = {}

        # Collect private keys
        for verifier_key in session.panel:
            chain = self.network.chains.get(verifier_key)
            if chain:
                private_keys[verifier_key] = chain.private_key

        # Phase 1: Keepalives (simulated - everyone stays online)
        for verifier_key in session.panel:
            session.send_keepalive(verifier_key, self.network.current_time)

        # Phase 2: Each verifier independently checks and votes
        for verifier_key in session.panel:
            # Simulate detection (with noise)
            if random.random() < noise:
                detected_valid = not actual_valid  # Noise: wrong detection
            else:
                detected_valid = actual_valid

            # If failure detected, alert others
            if not detected_valid:
                session.send_failure_alert(
                    verifier_key,
                    {"detected": "simulated_failure"},
                    self.network.current_time,
                )

            # Vote what you see (don't wait for others)
            vote_obj = VerificationVote(
                verifier_key=verifier_key,
                transaction_id=session.transaction_id,
                vote=detected_valid,
                nonce=hashlib.sha256(f"{verifier_key}{random.random()}".encode()).hexdigest()[:8],
                evidence={"simulated": True},
                timestamp=self.network.current_time,
            )
            vote_obj.signature = sign(private_keys.get(verifier_key, ""), str(vote_obj.to_dict()))

            session.record_vote(vote_obj)

        # Phase 3: Session ends, exchange votes
        session.signal_session_end(self.network.current_time)
        session.exchange_votes()

        # Phase 4: Finalize
        attestation = session.finalize(self.network.current_time, private_keys)

        # Store and queue for broadcast
        self.attestation_store.add(attestation)
        self.pending_broadcasts.append(attestation)

        return attestation

    def get_pending_broadcasts(self) -> List[VerificationAttestation]:
        """Get attestations ready to broadcast."""
        broadcasts = self.pending_broadcasts
        self.pending_broadcasts = []
        return broadcasts

    def receive_broadcast(self, attestation: VerificationAttestation) -> bool:
        """Receive a broadcast attestation from the network."""
        return self.attestation_store.add(attestation)

    def compute_trust_from_attestations(self, subject_key: str) -> Tuple[float, dict]:
        """Compute trust using stored attestations."""
        computer = AttestationTrustComputer(
            self.network.current_time,
            self.attestation_store,
            self.trust_scores,
        )
        return computer.compute_trust(subject_key)


# =============================================================================
# Demo
# =============================================================================

def demo():
    """Demonstrate the verification attestation protocol."""
    print("=" * 70)
    print("VERIFICATION ATTESTATION PROTOCOL DEMO")
    print("=" * 70)

    # Create network with multiple participants
    net = ChainNetwork()

    # Create identities
    # Providers
    alice = net.create_identity("alice")
    bob = net.create_identity("bob")

    # Consumer
    charlie = net.create_identity("charlie")

    # Verifiers (will form panels)
    verifiers = []
    for i in range(10):
        v = net.create_identity(f"verifier_{i}")
        verifiers.append(v)

    print(f"\nCreated network:")
    print(f"  Providers: alice, bob")
    print(f"  Consumer: charlie")
    print(f"  Verifiers: {len(verifiers)} panel members")

    # Simulate transactions
    print(f"\n{'='*70}")
    print("PHASE 1: TRANSACTIONS")
    print("=" * 70)

    transactions = []
    for day in range(30):
        net.advance_time(1)

        # Charlie uses Alice (good provider)
        if day % 2 == 0:
            c_block, p_block = net.create_compute_session(
                consumer_key=charlie.public_key,
                provider_key=alice.public_key,
                cores=4,
                duration_hours=2.0,
                verification_score=0.95,  # Good service
            )
            transactions.append((p_block.transaction_id, "alice", True))

        # Charlie uses Bob (sometimes bad)
        if day % 3 == 0:
            good = random.random() > 0.3  # 30% failure rate
            c_block, p_block = net.create_compute_session(
                consumer_key=charlie.public_key,
                provider_key=bob.public_key,
                cores=4,
                duration_hours=2.0,
                verification_score=0.95 if good else 0.3,
            )
            transactions.append((p_block.transaction_id, "bob", good))

    print(f"\nGenerated {len(transactions)} transactions over 30 days")
    print(f"  Alice: {sum(1 for t in transactions if t[1] == 'alice')} transactions (all good)")
    print(f"  Bob: {sum(1 for t in transactions if t[1] == 'bob')} transactions "
          f"({sum(1 for t in transactions if t[1] == 'bob' and t[2])} good, "
          f"{sum(1 for t in transactions if t[1] == 'bob' and not t[2])} bad)")

    # Set up verification coordinator
    print(f"\n{'='*70}")
    print("PHASE 2: VERIFICATION")
    print("=" * 70)

    coordinator = VerificationCoordinator(net)

    # Give verifiers some trust (bootstrap)
    initial_trust = {v.public_key: 2.0 for v in verifiers}
    initial_trust[alice.public_key] = 0.5  # Providers start lower
    initial_trust[bob.public_key] = 0.5
    initial_trust[charlie.public_key] = 0.5
    coordinator.update_trust_scores(initial_trust)

    # Verify transactions
    print(f"\nRunning verification on {len(transactions)} transactions...")

    for tx_id, provider_name, was_good in transactions:
        provider_key = f"pk_{provider_name}"
        consumer_key = charlie.public_key

        # Get session data
        session_data = {"duration_hours": 2.0, "resource_cores": 4}

        # Initiate verification
        session = coordinator.initiate_verification(
            transaction_id=tx_id,
            provider_key=provider_key,
            consumer_key=consumer_key,
            session_data=session_data,
            initiated_by=charlie.public_key,
        )

        if session:
            # Simulate panel voting
            attestation = coordinator.simulate_verification(
                session,
                actual_valid=was_good,
                noise=0.1,  # 10% chance of wrong vote
            )

    # Check results
    print(f"\nVerification complete!")
    print(f"  Attestations stored: {len(coordinator.attestation_store.by_transaction)}")

    # Show attestation breakdown
    alice_atts = coordinator.attestation_store.get_provider_attestations(alice.public_key)
    bob_atts = coordinator.attestation_store.get_provider_attestations(bob.public_key)

    print(f"\n  Alice attestations:")
    print(f"    PASS: {sum(1 for a in alice_atts if a.outcome == VerificationOutcome.PASS)}")
    print(f"    FAIL: {sum(1 for a in alice_atts if a.outcome == VerificationOutcome.FAIL)}")

    print(f"\n  Bob attestations:")
    print(f"    PASS: {sum(1 for a in bob_atts if a.outcome == VerificationOutcome.PASS)}")
    print(f"    FAIL: {sum(1 for a in bob_atts if a.outcome == VerificationOutcome.FAIL)}")

    # Compute trust from attestations
    print(f"\n{'='*70}")
    print("PHASE 3: TRUST COMPUTATION FROM ATTESTATIONS")
    print("=" * 70)

    alice_trust, alice_details = coordinator.compute_trust_from_attestations(alice.public_key)
    bob_trust, bob_details = coordinator.compute_trust_from_attestations(bob.public_key)

    print(f"\nTrust scores (from attestations only):")
    print(f"  Alice: {alice_trust:.4f}")
    print(f"  Bob: {bob_trust:.4f}")

    print(f"\nAlice breakdown:")
    for d in alice_details.get("attestation_details", [])[:3]:
        print(f"    {d['transaction_id'][:8]}: {d['outcome']} "
              f"(margin={d['margin']:.2f}, credit={d['credit']:.4f})")
    if len(alice_details.get("attestation_details", [])) > 3:
        print(f"    ... and {len(alice_details['attestation_details']) - 3} more")

    print(f"\nBob breakdown:")
    for d in bob_details.get("attestation_details", [])[:5]:
        print(f"    {d['transaction_id'][:8]}: {d['outcome']} "
              f"(margin={d['margin']:.2f}, credit={d['credit']:.4f})")
    if len(bob_details.get("attestation_details", [])) > 5:
        print(f"    ... and {len(bob_details['attestation_details']) - 5} more")

    # Demonstrate broadcast
    print(f"\n{'='*70}")
    print("PHASE 4: ATTESTATION BROADCAST")
    print("=" * 70)

    # Get pending broadcasts
    broadcasts = coordinator.get_pending_broadcasts()
    print(f"\nPending broadcasts: {len(broadcasts)} attestations")

    # Simulate another node receiving broadcasts
    print(f"\nSimulating new node receiving broadcasts...")
    new_node_store = AttestationStore()
    received = 0
    for att in broadcasts:
        if new_node_store.add(att):
            received += 1

    print(f"  New node received {received} attestations")
    print(f"  New node can now compute trust for alice and bob!")

    # New node computes trust
    new_computer = AttestationTrustComputer(
        net.current_time,
        new_node_store,
        initial_trust,  # Would have its own trust scores
    )

    new_alice_trust, _ = new_computer.compute_trust(alice.public_key)
    new_bob_trust, _ = new_computer.compute_trust(bob.public_key)

    print(f"\nNew node's trust computation:")
    print(f"  Alice: {new_alice_trust:.4f}")
    print(f"  Bob: {new_bob_trust:.4f}")

    print(f"\n{'='*70}")
    print("DEMO COMPLETE")
    print("=" * 70)
    print(f"""
Protocol summary:
1. Panel selected by: trust / (1 + interaction_count) - prefer independent verifiers
2. Panel members send KEEPALIVES to detect offline members
3. Offline members get REPLACED by next candidates in sorted list
4. Each verifier votes their OWN observation (PASS or FAIL)
5. On detecting failure: ALERT others to check too (so they can also vote FAIL)
6. Votes exchanged when PROVIDER SIGNALS session end
7. Attestations SIGNED by active panel, BROADCAST to network
8. Nodes compute trust FROM ATTESTATIONS - no need to see raw transactions

Results:
- Alice (reliable): {alice_trust:.2f} trust
- Bob (30% failures): {bob_trust:.2f} trust
""")


if __name__ == "__main__":
    random.seed(42)
    demo()
