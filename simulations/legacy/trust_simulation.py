#!/usr/bin/env python3
"""
Trust Score Simulation for Omerta Network

Simulates the trust system with various scenarios to test if the math works.
"""

import math
import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple, Any
from collections import defaultdict

# =============================================================================
# Parameters (from participation-verification-math.md)
# =============================================================================

# Age parameters
K_AGE = 0.01  # Trust per day at steady state
TAU_AGE = 30  # Days to reach ~63% of steady rate

# Transaction parameters
BASE_CREDIT = 0.1  # Trust per hour of compute
TAU_TRANSACTION = 365  # Half-life in days (slower decay)
VERIFICATION_FAIL_PENALTY = 0.5  # Trust penalty per failed hour

# Assertion parameters
TAU_ASSERTION = 90  # Days for assertion to mostly decay
RESIDUAL = 0.1  # Permanent fraction

# Credibility parameters
T_REFERENCE = 100  # Trust level for credibility = 1.0

# Payment parameters
K_PAYMENT = 0.1  # Payment curve scaling (higher = faster approach to 100%)

# Detection parameters
ISOLATION_THRESHOLD = 0.9
SIMILARITY_THRESHOLD = 0.85

# Assertion analysis parameters
ACCURACY_THRESHOLD = 0.5
SPAM_THRESHOLD = 10.0
TARGETING_THRESHOLD = 0.7

# Coin velocity parameters
RUNWAY_THRESHOLD = 90  # Days of reserves before penalty
HOARDING_PENALTY_WEIGHT = 1.0
MIN_VOLUME_FOR_HOARDING_CHECK = 100  # OMC

# Transaction security parameters
SMALL_THRESHOLD = 10  # OMC
LARGE_THRESHOLD = 100  # OMC
IMMEDIATE_RELEASE_FRACTION = 0.5
BASE_DELAY = 7  # Days
TRUST_FOR_MIN_DELAY = 500
MIN_DELAY = 1  # Days

# Local trust parameters
TRANSITIVITY_DECAY = 0.5  # Trust halves per hop
MAX_PATH_LENGTH = 4
NEW_OBSERVER_DISCOUNT = 0.3

# Transfer burn parameters
K_TRANSFER = 0.01  # Same as payment curve

# Accusation parameters
ACCUSATION_WINDOW = 90  # Days before same accuser can accuse same subject again
BASE_VERIFICATION_RATE = 0.1  # 10% of sessions verified normally
MAX_VERIFICATION_RATE = 0.5  # Up to 50% when accused
PENDING_PENALTY_WEIGHT = 0.1  # Penalty per pending unverified accusation

# Solver parameters
EPSILON = 0.001
MAX_ITERATIONS = 100


# =============================================================================
# Data Structures
# =============================================================================

@dataclass
class Transaction:
    """A compute transaction between consumer and provider."""
    consumer_id: str
    provider_id: str
    resource_weight: float  # 0.5 to 8.0
    duration_hours: float
    verification_score: float  # 0.0 to 1.0
    day: int  # When it occurred


@dataclass
class Assertion:
    """An assertion (positive or negative) about an identity."""
    asserter_id: str
    subject_id: str
    score: float  # -1.0 to +1.0
    classification: str
    day: int  # When it occurred
    has_evidence: bool = True


@dataclass
class Identity:
    """A network participant."""
    id: str
    creation_day: int
    transactions_as_provider: List[Transaction] = field(default_factory=list)
    transactions_as_consumer: List[Transaction] = field(default_factory=list)
    assertions_received: List[Assertion] = field(default_factory=list)
    assertions_made: List[Assertion] = field(default_factory=list)

    # Computed values (updated by solver)
    trust: float = 0.0
    cluster_weight: float = 1.0

    # Coin tracking for velocity/hoarding
    coin_balance: float = 0.0
    total_earned: float = 0.0
    total_spent: float = 0.0

    # Escrow tracking
    escrowed_funds: float = 0.0
    escrow_release_day: int = 0


class Network:
    """The Omerta network simulation."""

    def __init__(self):
        self.identities: Dict[str, Identity] = {}
        self.current_day: int = 0
        # Track accusations: (accuser, subject) -> day of last accusation
        self.accusation_history: Dict[Tuple[str, str], int] = {}
        # Track pending unverified accusations: (accuser, subject) -> day
        self.pending_accusations: Dict[Tuple[str, str], int] = {}
        # Track verification boosts from accusations: subject -> boost amount
        self.verification_boosts: Dict[str, float] = defaultdict(float)

    def create_identity(self, id: str) -> Identity:
        """Create a new identity."""
        identity = Identity(id=id, creation_day=self.current_day)
        self.identities[id] = identity
        return identity

    def add_transaction(self, consumer_id: str, provider_id: str,
                        resource_weight: float = 1.0,
                        duration_hours: float = 1.0,
                        verification_score: float = 1.0):
        """Record a transaction."""
        tx = Transaction(
            consumer_id=consumer_id,
            provider_id=provider_id,
            resource_weight=resource_weight,
            duration_hours=duration_hours,
            verification_score=verification_score,
            day=self.current_day
        )
        self.identities[consumer_id].transactions_as_consumer.append(tx)
        self.identities[provider_id].transactions_as_provider.append(tx)

    def has_transaction_history(self, accuser_id: str, subject_id: str) -> int:
        """Check how many transactions exist between accuser (as consumer) and subject (as provider)."""
        accuser = self.identities.get(accuser_id)
        if not accuser:
            return 0
        count = sum(1 for tx in accuser.transactions_as_consumer
                   if tx.provider_id == subject_id)
        return count

    def can_accuse(self, accuser_id: str, subject_id: str) -> Tuple[bool, float]:
        """Check if accuser can make accusation and return weight modifier."""
        # Check transaction history
        tx_count = self.has_transaction_history(accuser_id, subject_id)
        if tx_count == 0:
            return False, 0.0

        # Check accusation window
        key = (accuser_id, subject_id)
        last_accusation = self.accusation_history.get(key, -ACCUSATION_WINDOW - 1)
        if self.current_day - last_accusation < ACCUSATION_WINDOW:
            return False, 0.0

        # Weight based on transaction count
        weight = min(tx_count / 3.0, 1.0)
        return True, weight

    def add_assertion(self, asserter_id: str, subject_id: str,
                      score: float, classification: str = "UNCLASSIFIED",
                      has_evidence: bool = True) -> bool:
        """Record an assertion. Returns True if assertion was accepted."""
        # For negative assertions, check if accusation is allowed
        if score < 0:
            can_accuse, weight = self.can_accuse(asserter_id, subject_id)
            if not can_accuse:
                return False  # Accusation rejected

            # Record accusation time
            self.accusation_history[(asserter_id, subject_id)] = self.current_day

            # Add to pending (will be resolved by verification)
            self.pending_accusations[(asserter_id, subject_id)] = self.current_day

            # Boost verification rate for subject
            accuser_trust = self.identities.get(asserter_id, Identity(id="", creation_day=0)).trust
            credibility = self.compute_credibility(accuser_trust)
            self.verification_boosts[subject_id] += credibility * abs(score)

            # Modify score by weight (fewer transactions = less weight)
            score = score * weight

        assertion = Assertion(
            asserter_id=asserter_id,
            subject_id=subject_id,
            score=score,
            classification=classification,
            day=self.current_day,
            has_evidence=has_evidence
        )
        self.identities[asserter_id].assertions_made.append(assertion)
        self.identities[subject_id].assertions_received.append(assertion)
        return True

    def get_verification_rate(self, subject_id: str) -> float:
        """Get current verification rate for a subject."""
        boost = self.verification_boosts.get(subject_id, 0.0)
        rate = min(BASE_VERIFICATION_RATE * (1 + boost), MAX_VERIFICATION_RATE)
        return rate

    def resolve_accusation(self, accuser_id: str, subject_id: str, verified_bad: bool):
        """Resolve a pending accusation based on verification results."""
        key = (accuser_id, subject_id)
        if key not in self.pending_accusations:
            return

        del self.pending_accusations[key]

        # Reduce verification boost
        if subject_id in self.verification_boosts:
            self.verification_boosts[subject_id] = max(0, self.verification_boosts[subject_id] - 0.5)

        if verified_bad:
            # Accusation was accurate - accuser gains credibility
            # (This happens naturally through the trust solver)
            pass
        else:
            # Accusation was inaccurate - accuser loses credibility
            accuser = self.identities.get(accuser_id)
            if accuser:
                # Add a self-penalty assertion
                penalty_assertion = Assertion(
                    asserter_id="system",
                    subject_id=accuser_id,
                    score=-0.3,  # Penalty for false accusation
                    classification="UNVERIFIED_ACCUSATION",
                    day=self.current_day,
                    has_evidence=True
                )
                accuser.assertions_received.append(penalty_assertion)

    def count_pending_accusations(self, accuser_id: str) -> int:
        """Count pending unverified accusations by an accuser."""
        return sum(1 for (a, s), day in self.pending_accusations.items()
                  if a == accuser_id)

    def advance_days(self, days: int):
        """Advance simulation by N days."""
        self.current_day += days

    # =========================================================================
    # Trust Calculation
    # =========================================================================

    def compute_age(self, identity: Identity) -> float:
        """Compute age in days."""
        return self.current_day - identity.creation_day

    def compute_activity(self, identity: Identity, window: int = 30) -> float:
        """Compute activity factor (0 to 1)."""
        recent_txs = sum(
            1 for tx in identity.transactions_as_provider
            if self.current_day - tx.day <= window
        ) + sum(
            1 for tx in identity.transactions_as_consumer
            if self.current_day - tx.day <= window
        )
        return min(recent_txs / 1.0, 1.0)  # ACTIVITY_THRESHOLD = 1

    def compute_t_age(self, identity: Identity) -> float:
        """Compute trust from identity age."""
        age = self.compute_age(identity)
        if age <= 0:
            return 0.0

        # Integrate age_rate * activity over time (simplified discrete version)
        t_age = 0.0
        for day in range(identity.creation_day, self.current_day):
            days_old = day - identity.creation_day
            age_rate = K_AGE * (1 - math.exp(-days_old / TAU_AGE))
            # Simplified: assume activity = 1 if they have any transactions
            activity = 1.0 if identity.transactions_as_provider else 0.5
            t_age += age_rate * activity

        return t_age

    def compute_t_transactions(self, identity: Identity) -> float:
        """Compute trust from transaction history."""
        t_transactions = 0.0

        for tx in identity.transactions_as_provider:
            age = self.current_day - tx.day
            recency = math.exp(-age / TAU_TRANSACTION)

            if tx.verification_score >= 0.7:
                # Good transaction: positive credit
                credit = (BASE_CREDIT * tx.resource_weight * tx.duration_hours *
                         tx.verification_score * identity.cluster_weight)
            else:
                # Failed verification: PENALTY
                credit = -VERIFICATION_FAIL_PENALTY * tx.resource_weight * tx.duration_hours * (0.7 - tx.verification_score)

            t_transactions += credit * recency

        return t_transactions

    def compute_credibility(self, trust: float) -> float:
        """Compute credibility from trust."""
        if trust <= 0:
            return 0.0
        return math.log(1 + trust) / math.log(1 + T_REFERENCE)

    def compute_t_assertions(self, identity: Identity,
                             trust_map: Dict[str, float]) -> float:
        """Compute trust from assertions received."""
        t_assertions = 0.0

        for assertion in identity.assertions_received:
            age = self.current_day - assertion.day
            decay = RESIDUAL + (1 - RESIDUAL) * math.exp(-age / TAU_ASSERTION)

            asserter_trust = trust_map.get(assertion.asserter_id, 0)
            credibility = self.compute_credibility(asserter_trust)

            # Evidence bonus/penalty
            evidence_factor = 1.0 if assertion.has_evidence else 0.5

            t_assertions += assertion.score * credibility * decay * evidence_factor

        return t_assertions

    def compute_asserter_penalties(self, identity: Identity,
                                   trust_map: Dict[str, float]) -> float:
        """Compute penalties for inaccurate assertions made by this identity."""
        penalty = 0.0

        for assertion in identity.assertions_made:
            subject = self.identities.get(assertion.subject_id)
            if not subject:
                continue

            # Check if assertion was accurate
            # Negative assertion about someone with good transaction history = inaccurate
            if assertion.score < -0.3:
                # Count subject's successful transactions after the assertion
                good_txs = sum(1 for tx in subject.transactions_as_provider
                              if tx.day > assertion.day and tx.verification_score >= 0.9)
                if good_txs >= 3:
                    # False accusation! Penalize asserter
                    age = self.current_day - assertion.day
                    decay = math.exp(-age / TAU_ASSERTION)
                    penalty += abs(assertion.score) * 0.5 * decay

            # Positive assertion about someone who later failed = inaccurate
            elif assertion.score > 0.3:
                bad_txs = sum(1 for tx in subject.transactions_as_provider
                             if tx.day > assertion.day and tx.verification_score < 0.5)
                if bad_txs >= 2:
                    # Vouched for bad actor! Penalize asserter
                    age = self.current_day - assertion.day
                    decay = math.exp(-age / TAU_ASSERTION)
                    penalty += assertion.score * 0.5 * decay

        return penalty

    def detect_clusters(self) -> Dict[str, float]:
        """Detect Sybil clusters and return cluster weights."""
        # Build transaction graph - track who transacts with whom
        edges: Dict[Tuple[str, str], float] = defaultdict(float)
        provider_consumers: Dict[str, Set[str]] = defaultdict(set)

        for identity in self.identities.values():
            for tx in identity.transactions_as_provider:
                pair = tuple(sorted([tx.consumer_id, tx.provider_id]))
                edges[pair] += tx.duration_hours
                provider_consumers[tx.provider_id].add(tx.consumer_id)

        # Detect tight clusters: groups that ONLY transact internally
        # Key insight: Sybils transact with each other, not with outside consumers

        cluster_weights = {id: 1.0 for id in self.identities}

        # Find groups of providers who share the same consumers
        providers = [id for id, ident in self.identities.items()
                    if ident.transactions_as_provider]

        # For each pair of providers, check if they share consumers suspiciously
        suspicious_groups: List[Set[str]] = []

        for i, p1 in enumerate(providers):
            for p2 in providers[i+1:]:
                c1 = provider_consumers[p1]
                c2 = provider_consumers[p2]

                if not c1 or not c2:
                    continue

                # Check if these providers' consumers are mostly each other
                # (Sybil pattern: provider A's consumer is provider B, and vice versa)
                p1_is_consumer_of_p2 = p1 in c2
                p2_is_consumer_of_p1 = p2 in c1

                # Check overlap
                overlap = len(c1 & c2)
                total = len(c1 | c2)

                # Suspicious if providers are each other's consumers
                # AND they have high consumer overlap
                if p1_is_consumer_of_p2 and p2_is_consumer_of_p1:
                    # Find or create suspicious group
                    found = False
                    for group in suspicious_groups:
                        if p1 in group or p2 in group:
                            group.add(p1)
                            group.add(p2)
                            found = True
                            break
                    if not found:
                        suspicious_groups.append({p1, p2})

        # Apply cluster penalty to suspicious groups
        for group in suspicious_groups:
            # Check if this group has external consumers (not in the group)
            external_consumers = set()
            for provider in group:
                for consumer in provider_consumers[provider]:
                    if consumer not in group:
                        external_consumers.add(consumer)

            # If very few external consumers, this is a Sybil cluster
            if len(external_consumers) < len(group):
                for member in group:
                    cluster_weights[member] = 1.0 / len(group)

        return cluster_weights

    def solve_trust(self, verbose: bool = False) -> Dict[str, float]:
        """Iteratively solve for trust scores."""
        # Detect clusters first
        cluster_weights = self.detect_clusters()
        for id, weight in cluster_weights.items():
            self.identities[id].cluster_weight = weight

        # Initialize with age + transactions only
        trust_map = {}
        for id, identity in self.identities.items():
            t_age = self.compute_t_age(identity)
            t_transactions = self.compute_t_transactions(identity)
            trust_map[id] = t_age + t_transactions

        # Iterate until convergence
        for iteration in range(MAX_ITERATIONS):
            new_trust_map = {}

            for id, identity in self.identities.items():
                t_age = self.compute_t_age(identity)
                t_transactions = self.compute_t_transactions(identity)
                t_assertions = self.compute_t_assertions(identity, trust_map)
                t_asserter_penalty = self.compute_asserter_penalties(identity, trust_map)

                new_trust_map[id] = max(0, t_age + t_transactions + t_assertions - t_asserter_penalty)

            # Check convergence
            max_diff = max(
                abs(new_trust_map[id] - trust_map[id])
                for id in trust_map
            )

            trust_map = new_trust_map

            if verbose:
                print(f"  Iteration {iteration + 1}: max_diff = {max_diff:.6f}")

            if max_diff < EPSILON:
                if verbose:
                    print(f"  Converged after {iteration + 1} iterations")
                break

        # Update identities
        for id, trust in trust_map.items():
            self.identities[id].trust = trust

        return trust_map

    def compute_payment_share(self, trust: float) -> float:
        """Compute provider payment share (asymptotic to 1.0)."""
        return 1 - 1 / (1 + K_PAYMENT * trust)

    # =========================================================================
    # Local Trust (Network-Weighted)
    # =========================================================================

    def build_edge_weights(self) -> Dict[Tuple[str, str], float]:
        """Build edge weights from transaction history."""
        edges: Dict[Tuple[str, str], float] = defaultdict(float)

        for identity in self.identities.values():
            for tx in identity.transactions_as_provider:
                # Edge from consumer to provider (directed)
                age = self.current_day - tx.day
                recency = math.exp(-age / TAU_TRANSACTION)
                weight = tx.resource_weight * tx.duration_hours * tx.verification_score * recency
                edges[(tx.consumer_id, tx.provider_id)] += weight

        return edges

    def compute_direct_trust(self, subject_id: str, observer_id: str) -> float:
        """Compute direct trust from observer's transactions with subject."""
        observer = self.identities.get(observer_id)
        if not observer:
            return 0.0

        direct_trust = 0.0

        # Observer as consumer, subject as provider
        for tx in observer.transactions_as_consumer:
            if tx.provider_id == subject_id:
                age = self.current_day - tx.day
                recency = math.exp(-age / TAU_TRANSACTION)
                direct_trust += tx.resource_weight * tx.duration_hours * tx.verification_score * recency

        # Observer as provider, subject as consumer
        for tx in observer.transactions_as_provider:
            if tx.consumer_id == subject_id:
                age = self.current_day - tx.day
                recency = math.exp(-age / TAU_TRANSACTION)
                direct_trust += tx.resource_weight * tx.duration_hours * tx.verification_score * recency * 0.5

        return direct_trust

    def find_trust_paths(self, subject_id: str, observer_id: str,
                         edges: Dict[Tuple[str, str], float],
                         max_depth: int = MAX_PATH_LENGTH) -> List[Tuple[List[str], float]]:
        """Find paths from observer to subject through transaction graph."""
        if subject_id == observer_id:
            return [([observer_id], float('inf'))]

        paths = []
        # BFS with path tracking
        queue = [(observer_id, [observer_id], float('inf'))]
        visited_at_depth: Dict[str, int] = {observer_id: 0}

        while queue:
            current, path, min_edge = queue.pop(0)
            depth = len(path) - 1

            if depth >= max_depth:
                continue

            # Find all neighbors (both directions in transaction graph)
            for (src, dst), weight in edges.items():
                if src == current and dst not in path:
                    new_min = min(min_edge, weight)
                    new_path = path + [dst]

                    if dst == subject_id:
                        paths.append((new_path, new_min))
                    elif dst not in visited_at_depth or visited_at_depth[dst] > len(new_path):
                        visited_at_depth[dst] = len(new_path)
                        queue.append((dst, new_path, new_min))

                # Also check reverse direction (symmetric trust)
                if dst == current and src not in path:
                    new_min = min(min_edge, weight * 0.5)  # Reverse direction weighted less
                    new_path = path + [src]

                    if src == subject_id:
                        paths.append((new_path, new_min))
                    elif src not in visited_at_depth or visited_at_depth[src] > len(new_path):
                        visited_at_depth[src] = len(new_path)
                        queue.append((src, new_path, new_min))

        return paths

    def compute_local_trust(self, subject_id: str, observer_id: str,
                            edges: Optional[Dict[Tuple[str, str], float]] = None) -> float:
        """Compute trust of subject as seen by observer."""
        if edges is None:
            edges = self.build_edge_weights()

        # Direct trust
        direct = self.compute_direct_trust(subject_id, observer_id)
        if direct > 0:
            return direct  # Direct experience dominates

        # Find paths through network
        paths = self.find_trust_paths(subject_id, observer_id, edges)

        if not paths:
            # No path - use discounted global trust
            global_trust = self.identities[subject_id].trust if subject_id in self.identities else 0
            return global_trust * NEW_OBSERVER_DISCOUNT

        # Take max path (not sum, to prevent gaming)
        max_trust = 0.0
        for path, min_edge in paths:
            hops = len(path) - 1
            path_trust = min_edge * (TRANSITIVITY_DECAY ** hops)
            max_trust = max(max_trust, path_trust)

        return max_trust

    # =========================================================================
    # Coin Velocity / Hoarding Penalty
    # =========================================================================

    def compute_runway(self, identity: Identity) -> float:
        """Compute runway (days of reserves at current spend rate)."""
        # Compute average daily outflow over last 90 days
        outflow_window = 90
        recent_spent = 0.0

        for tx in identity.transactions_as_consumer:
            if self.current_day - tx.day <= outflow_window:
                # Estimate payment (simplified)
                recent_spent += tx.resource_weight * tx.duration_hours

        avg_daily_outflow = recent_spent / outflow_window if outflow_window > 0 else 0

        if avg_daily_outflow <= 0:
            return float('inf')

        return identity.coin_balance / avg_daily_outflow

    def compute_hoarding_penalty(self, identity: Identity) -> float:
        """Compute trust penalty for hoarding coins."""
        age = self.compute_age(identity)

        # Exemptions
        if age < 30:
            return 0.0
        if identity.total_earned < MIN_VOLUME_FOR_HOARDING_CHECK:
            return 0.0

        runway = self.compute_runway(identity)
        if runway <= RUNWAY_THRESHOLD:
            return 0.0

        # Logarithmic penalty
        penalty = math.log(runway / RUNWAY_THRESHOLD) * HOARDING_PENALTY_WEIGHT
        return penalty

    def compute_effective_trust(self, identity: Identity) -> float:
        """Compute effective trust after hoarding penalty."""
        hoarding_penalty = self.compute_hoarding_penalty(identity)
        if hoarding_penalty <= 0:
            return identity.trust
        return identity.trust / (1 + hoarding_penalty)

    # =========================================================================
    # Delayed Release Escrow
    # =========================================================================

    def compute_escrow_delay(self, provider_trust: float, transaction_value: float) -> int:
        """Compute escrow delay in days based on trust and transaction size."""
        if transaction_value < LARGE_THRESHOLD:
            return 0  # No delay for small transactions

        trust_factor = min(provider_trust / TRUST_FOR_MIN_DELAY, 1.0)
        delay = BASE_DELAY * (1 - trust_factor)
        return max(int(delay), MIN_DELAY)

    def compute_immediate_release(self, transaction_value: float) -> float:
        """Compute immediate release amount for large transactions."""
        if transaction_value < LARGE_THRESHOLD:
            return transaction_value
        return transaction_value * IMMEDIATE_RELEASE_FRACTION

    # =========================================================================
    # Transfer Burns
    # =========================================================================

    def compute_transfer_burn_rate(self, sender_id: str, receiver_id: str) -> float:
        """Compute burn rate for a transfer between two identities."""
        sender_trust = self.identities.get(sender_id, Identity(id="", creation_day=0)).trust
        receiver_trust = self.identities.get(receiver_id, Identity(id="", creation_day=0)).trust

        min_trust = min(sender_trust, receiver_trust)
        # Same formula as payment share, inverted
        burn_rate = 1 / (1 + K_TRANSFER * min_trust)
        return burn_rate

    def transfer_coins(self, sender_id: str, receiver_id: str, amount: float) -> Tuple[float, float]:
        """Transfer coins between identities with trust-based burn.

        Returns: (amount_received, amount_burned)
        """
        burn_rate = self.compute_transfer_burn_rate(sender_id, receiver_id)
        amount_burned = amount * burn_rate
        amount_received = amount - amount_burned

        # Update balances
        sender = self.identities.get(sender_id)
        receiver = self.identities.get(receiver_id)

        if sender:
            sender.coin_balance -= amount
            sender.total_spent += amount

        if receiver:
            receiver.coin_balance += amount_received
            receiver.total_earned += amount_received

        return amount_received, amount_burned

    def print_state(self):
        """Print current network state."""
        print(f"\n{'='*60}")
        print(f"Network State at Day {self.current_day}")
        print(f"{'='*60}")

        for id, identity in sorted(self.identities.items()):
            age = self.compute_age(identity)
            txs = len(identity.transactions_as_provider)
            assertions = len(identity.assertions_received)
            payment = self.compute_payment_share(identity.trust) * 100

            cluster_note = ""
            if identity.cluster_weight < 1.0:
                cluster_note = f" [CLUSTER: {identity.cluster_weight:.2f}]"

            print(f"  {id}: trust={identity.trust:.2f}, "
                  f"age={age}d, txs={txs}, assertions={assertions}, "
                  f"payment={payment:.1f}%{cluster_note}")


# =============================================================================
# Simulation Scenarios
# =============================================================================

def scenario_normal_operation():
    """Normal operation with honest providers."""
    print("\n" + "="*60)
    print("SCENARIO: Normal Operation")
    print("="*60)

    net = Network()

    # Create honest providers
    net.create_identity("alice")
    net.create_identity("bob")
    net.create_identity("charlie")

    # Create consumers
    net.create_identity("consumer1")
    net.create_identity("consumer2")

    # Simulate 180 days of activity
    for day in range(180):
        net.advance_days(1)

        # Random transactions each day
        if random.random() < 0.3:
            provider = random.choice(["alice", "bob", "charlie"])
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_transaction(consumer, provider,
                              resource_weight=random.uniform(1, 3),
                              duration_hours=random.uniform(1, 8),
                              verification_score=random.uniform(0.9, 1.0))

        # Occasional positive assertions
        if random.random() < 0.05:
            asserter = random.choice(["consumer1", "consumer2"])
            subject = random.choice(["alice", "bob", "charlie"])
            net.add_assertion(asserter, subject,
                            score=random.uniform(0.3, 0.8),
                            classification="EXCELLENT_SERVICE")

    trust_map = net.solve_trust(verbose=True)
    net.print_state()

    return net


def scenario_sybil_attack():
    """Sybil attack: fake identities transacting with each other."""
    print("\n" + "="*60)
    print("SCENARIO: Sybil Attack")
    print("="*60)

    net = Network()

    # Create honest providers
    net.create_identity("honest1")
    net.create_identity("honest2")

    # Create Sybil cluster
    sybils = [f"sybil{i}" for i in range(5)]
    for s in sybils:
        net.create_identity(s)

    # Create legitimate consumer
    net.create_identity("consumer")

    # Simulate 90 days
    for day in range(90):
        net.advance_days(1)

        # Honest transactions
        if random.random() < 0.2:
            net.add_transaction("consumer", random.choice(["honest1", "honest2"]),
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

        # Sybil transactions (only among themselves)
        if random.random() < 0.5:
            provider = random.choice(sybils)
            consumer = random.choice([s for s in sybils if s != provider])
            net.add_transaction(consumer, provider,
                              resource_weight=3.0,
                              duration_hours=8.0,
                              verification_score=1.0)

        # Sybils assert positively about each other
        if random.random() < 0.3:
            asserter = random.choice(sybils)
            subject = random.choice([s for s in sybils if s != asserter])
            net.add_assertion(asserter, subject, score=0.9,
                            classification="EXCELLENT_SERVICE")

    trust_map = net.solve_trust(verbose=True)
    net.print_state()

    print("\nAnalysis:")
    honest_trust = (net.identities["honest1"].trust +
                   net.identities["honest2"].trust) / 2
    sybil_trust = sum(net.identities[s].trust for s in sybils) / len(sybils)
    print(f"  Average honest trust: {honest_trust:.2f}")
    print(f"  Average sybil trust: {sybil_trust:.2f}")
    print(f"  Sybil cluster detected and penalized: {sybil_trust < honest_trust}")

    return net


def scenario_collusion_ring():
    """Collusion: providers making false accusations against competitor."""
    print("\n" + "="*60)
    print("SCENARIO: Collusion Ring (False Accusations)")
    print("="*60)

    net = Network()

    # Create providers
    net.create_identity("victim")  # Honest provider being attacked
    net.create_identity("colluder1")
    net.create_identity("colluder2")
    net.create_identity("colluder3")

    # Create consumers
    net.create_identity("consumer1")
    net.create_identity("consumer2")

    # Build up initial trust for everyone (60 days)
    for day in range(60):
        net.advance_days(1)

        for provider in ["victim", "colluder1", "colluder2", "colluder3"]:
            if random.random() < 0.2:
                consumer = random.choice(["consumer1", "consumer2"])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    print("After initial trust building (60 days):")
    net.solve_trust()
    net.print_state()

    # Colluders attack victim with false accusations
    print("\nColluders attack victim with false accusations...")
    for day in range(30):
        net.advance_days(1)

        # Colluders make false accusations
        if random.random() < 0.3:
            attacker = random.choice(["colluder1", "colluder2", "colluder3"])
            net.add_assertion(attacker, "victim",
                            score=-0.7,
                            classification="RESOURCE_MISMATCH",
                            has_evidence=False)

        # Victim continues honest service
        if random.random() < 0.3:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_transaction(consumer, "victim",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    print("\nAfter attack (90 days total):")
    net.solve_trust()
    net.print_state()

    print("\nAnalysis:")
    print(f"  Victim trust: {net.identities['victim'].trust:.2f}")
    avg_colluder = sum(net.identities[f'colluder{i}'].trust for i in range(1,4)) / 3
    print(f"  Average colluder trust: {avg_colluder:.2f}")

    return net


def scenario_long_con():
    """Long con: build trust then exploit."""
    print("\n" + "="*60)
    print("SCENARIO: Long Con Attack")
    print("="*60)

    net = Network()

    # Create attacker and honest provider
    net.create_identity("attacker")
    net.create_identity("honest")

    # Create consumers
    net.create_identity("consumer1")
    net.create_identity("consumer2")

    # Phase 1: Attacker builds trust (180 days)
    print("Phase 1: Attacker builds trust for 180 days...")
    for day in range(180):
        net.advance_days(1)

        for provider in ["attacker", "honest"]:
            if random.random() < 0.3:
                consumer = random.choice(["consumer1", "consumer2"])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    print("After trust building:")
    net.solve_trust()
    net.print_state()

    attacker_trust_before = net.identities["attacker"].trust
    payment_before = net.compute_payment_share(attacker_trust_before)
    print(f"\nAttacker trust: {attacker_trust_before:.2f}")
    print(f"Attacker payment share: {payment_before*100:.1f}%")

    # Phase 2: Attacker exploits (fails verifications, abandons sessions)
    print("\nPhase 2: Attacker exploits trust...")
    for day in range(30):
        net.advance_days(1)

        # Attacker fails verifications
        if random.random() < 0.5:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_transaction(consumer, "attacker",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.2)  # Fail!

        # Consumers complain
        if random.random() < 0.4:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_assertion(consumer, "attacker",
                            score=-0.8,
                            classification="VERIFICATION_FAILURE")

        # Honest provider continues
        if random.random() < 0.3:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_transaction(consumer, "honest",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    print("\nAfter exploitation:")
    net.solve_trust()
    net.print_state()

    attacker_trust_after = net.identities["attacker"].trust
    payment_after = net.compute_payment_share(attacker_trust_after)

    print(f"\nAnalysis:")
    print(f"  Attacker trust before: {attacker_trust_before:.2f}")
    print(f"  Attacker trust after: {attacker_trust_after:.2f}")
    print(f"  Trust lost: {attacker_trust_before - attacker_trust_after:.2f}")
    print(f"  Payment share dropped: {payment_before*100:.1f}% -> {payment_after*100:.1f}%")

    return net


def scenario_new_entrant():
    """New entrant trying to break into established network."""
    print("\n" + "="*60)
    print("SCENARIO: New Entrant")
    print("="*60)

    net = Network()

    # Established providers
    net.create_identity("established1")
    net.create_identity("established2")

    # Consumers
    net.create_identity("consumer1")
    net.create_identity("consumer2")

    # Build established providers (180 days)
    for day in range(180):
        net.advance_days(1)

        for provider in ["established1", "established2"]:
            if random.random() < 0.3:
                consumer = random.choice(["consumer1", "consumer2"])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    print("Established network (180 days):")
    net.solve_trust()
    net.print_state()

    # New entrant joins
    print("\nNew entrant joins...")
    net.create_identity("newbie")

    # New entrant provides good service for 60 days
    for day in range(60):
        net.advance_days(1)

        # Newbie works hard
        if random.random() < 0.5:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_transaction(consumer, "newbie",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.98)

        # Gets positive assertions
        if random.random() < 0.1:
            consumer = random.choice(["consumer1", "consumer2"])
            net.add_assertion(consumer, "newbie",
                            score=0.6,
                            classification="EXCELLENT_SERVICE")

    print("\nAfter 60 days of newbie service (240 total):")
    net.solve_trust()
    net.print_state()

    print("\nAnalysis:")
    newbie_trust = net.identities["newbie"].trust
    established_avg = (net.identities["established1"].trust +
                      net.identities["established2"].trust) / 2
    print(f"  Newbie trust: {newbie_trust:.2f}")
    print(f"  Established average: {established_avg:.2f}")
    print(f"  Newbie payment share: {net.compute_payment_share(newbie_trust)*100:.1f}%")
    print(f"  Established payment share: {net.compute_payment_share(established_avg)*100:.1f}%")

    return net


def scenario_donation_bootstrapping():
    """New provider using donation (negative bids) to accelerate trust."""
    print("\n" + "="*60)
    print("SCENARIO: Donation Bootstrapping")
    print("="*60)

    net = Network()

    # Create two new providers
    net.create_identity("normal_new")
    net.create_identity("donation_new")

    # Consumer
    net.create_identity("consumer")

    # Research org for donations
    net.create_identity("research_org")

    # Both work for 60 days
    for day in range(60):
        net.advance_days(1)

        # Normal new provider - regular commercial work
        if random.random() < 0.3:
            net.add_transaction("consumer", "normal_new",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

        # Donation provider - donates with burn (simulated as higher credit)
        # We simulate the burn bonus by using higher resource_weight
        if random.random() < 0.3:
            # Normal donation work
            net.add_transaction("research_org", "donation_new",
                              resource_weight=2.0,  # Base
                              duration_hours=4.0,
                              verification_score=0.95)

            # Additional "burn bonus" simulated as extra transaction weight
            net.add_transaction("research_org", "donation_new",
                              resource_weight=4.0,  # Burn bonus (2x)
                              duration_hours=4.0,
                              verification_score=0.95)

    print("After 60 days:")
    net.solve_trust()
    net.print_state()

    print("\nAnalysis:")
    normal = net.identities["normal_new"].trust
    donation = net.identities["donation_new"].trust
    print(f"  Normal new provider trust: {normal:.2f}")
    print(f"  Donation new provider trust: {donation:.2f}")
    print(f"  Donation advantage: {donation/normal:.2f}x")
    print(f"  Normal payment share: {net.compute_payment_share(normal)*100:.1f}%")
    print(f"  Donation payment share: {net.compute_payment_share(donation)*100:.1f}%")

    return net


# =============================================================================
# Main
# =============================================================================

def main():
    random.seed(42)  # For reproducibility

    print("="*60)
    print("OMERTA TRUST SYSTEM SIMULATION")
    print("="*60)

    scenario_normal_operation()
    scenario_sybil_attack()
    scenario_collusion_ring()
    scenario_long_con()
    scenario_new_entrant()
    scenario_donation_bootstrapping()

    print("\n" + "="*60)
    print("SIMULATION COMPLETE")
    print("="*60)


if __name__ == "__main__":
    main()
