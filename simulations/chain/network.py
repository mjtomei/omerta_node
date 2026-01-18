"""
Network simulation for Omerta chain.

Manages identities, keepalives, sessions, and attestations.
"""

import math
import random
import time
from typing import Dict, List, Tuple, Optional

from .primitives import Chain, Block, BlockType, sign, generate_id
from .types import (
    SessionTerms,
    SessionStart,
    SessionEnd,
    SessionEndReason,
    CabalAttestation,
    AttestationOutcome,
)


class Network:
    """
    Simulates the Omerta network.

    Manages:
    - Identity chains
    - Keepalive-based DAG creation
    - Session lifecycle
    - Cabal formation and attestation
    - Trust computation
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

    def create_identity(self, name: str, initial_trust: float = 0.1) -> Chain:
        """Create a new identity with a fresh chain."""
        public_key = f"pk_{name}"
        private_key = f"sk_{name}"

        chain = Chain(public_key, private_key, self.current_time)
        self.chains[public_key] = chain
        self.trust_scores[public_key] = initial_trust
        self.keepalive_counts[public_key] = 0

        return chain

    def get_chain(self, public_key: str) -> Optional[Chain]:
        """Get a chain by public key."""
        return self.chains.get(public_key)

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

    def select_witnesses_deterministic(
        self,
        seed: bytes,
        chain_state: dict,
        count: int,
        exclude: List[str],
        min_high_trust: int = 2,
        max_prior_interactions: int = 5,
        interaction_with: str = None,
    ) -> List[str]:
        """
        Deterministically select witnesses from chain state.

        This is the provider-driven selection function that can be
        verified by the consumer.
        """
        # Get candidates from chain state
        known_peers = chain_state.get("known_peers", [])
        candidates = [p for p in known_peers if p not in exclude]

        if not candidates:
            return []

        # Sort deterministically
        candidates = sorted(candidates)

        # Filter by interaction count if available
        if interaction_with and "interaction_counts" in chain_state:
            counts = chain_state["interaction_counts"]
            candidates = [
                c for c in candidates
                if counts.get(c, 0) <= max_prior_interactions
            ]

        # Separate by trust level
        trust_scores = chain_state.get("trust_scores", {})
        HIGH_TRUST_THRESHOLD = 1.0

        high_trust = sorted([c for c in candidates if trust_scores.get(c, 0) >= HIGH_TRUST_THRESHOLD])
        low_trust = sorted([c for c in candidates if trust_scores.get(c, 0) < HIGH_TRUST_THRESHOLD])

        # Seeded selection
        rng = random.Random(seed)

        selected = []

        # Select required high-trust witnesses
        if high_trust:
            ht_sample = min(min_high_trust, len(high_trust))
            selected.extend(rng.sample(high_trust, ht_sample))

        # Fill remaining
        remaining_needed = count - len(selected)
        remaining_pool = sorted([c for c in high_trust + low_trust if c not in selected])

        if remaining_pool and remaining_needed > 0:
            fill_sample = min(remaining_needed, len(remaining_pool))
            selected.extend(rng.sample(remaining_pool, fill_sample))

        return selected

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
        Records on consumer's chain.
        """
        terms = self.sessions.get(session_id)
        if not terms:
            raise ValueError(f"Unknown session: {session_id}")

        consumer_chain = self.chains[terms.consumer]

        start = SessionStart(
            session_id=session_id,
            terms=terms,
            verified_access_at=self.current_time,
            consumer_signature=sign(consumer_chain.private_key, session_id),
        )

        consumer_chain.append(
            BlockType.SESSION_START,
            start.to_dict(),
            self.current_time,
        )

        self.session_starts[session_id] = start
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
        Records on provider's chain.
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

        provider_chain.append(
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
        """Run a complete session lifecycle."""
        terms = self.create_session(consumer_key, provider_key, **session_kwargs)
        self.start_session(terms.session_id)
        self.advance_time(duration_hours * 3600)
        self.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST, duration_hours)
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

            age_days = (self.current_time - attestation.created_at) / 86400
            recency = math.exp(-age_days / TAU_DECAY)

            duration = end.actual_duration_hours
            resource_weight = terms.cores / 4.0

            if attestation.outcome == AttestationOutcome.PASS:
                credit = BASE_CREDIT * resource_weight * duration * PASS_MULTIPLIER
            elif attestation.outcome == AttestationOutcome.FAIL:
                credit = -BASE_CREDIT * resource_weight * duration * FAIL_PENALTY
            else:
                credit = 0.0

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
