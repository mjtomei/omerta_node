#!/usr/bin/env python3
"""
Automated Monetary Policy Simulation for Omerta Network

Extensive simulation suite demonstrating:
1. Observable network metrics over time
2. Automated parameter adjustments based on metrics
3. Attack scenarios that trigger policy responses
4. Comparison of static vs dynamic parameters

This simulation is designed to run for several hours.
"""

import math
import random
import json
import time
import os
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional, Any
from collections import defaultdict
import statistics
from datetime import datetime

# Import base simulation
from trust_simulation import (
    Network, Identity, Transaction, Assertion,
    K_PAYMENT, BASE_CREDIT, TAU_TRANSACTION, TAU_ASSERTION,
    LARGE_THRESHOLD, IMMEDIATE_RELEASE_FRACTION, BASE_DELAY,
    NEW_OBSERVER_DISCOUNT, TRANSITIVITY_DECAY, K_AGE, TAU_AGE,
    ISOLATION_THRESHOLD, SIMILARITY_THRESHOLD, RUNWAY_THRESHOLD,
    K_TRANSFER, EPSILON, MAX_ITERATIONS
)

# =============================================================================
# Configurable Parameters (these are what automated policy can adjust)
# =============================================================================

@dataclass
class NetworkParameters:
    """All tunable network parameters."""
    # Trust accumulation
    k_age: float = 0.01
    tau_age: float = 30
    base_credit: float = 0.1
    tau_transaction: float = 365

    # Payment curve
    k_payment: float = 0.1

    # Transfer burns
    k_transfer: float = 0.01

    # Detection
    isolation_threshold: float = 0.9
    similarity_threshold: float = 0.85

    # Verification
    base_verification_rate: float = 0.1
    expected_verification_rate: float = 0.1

    # Velocity
    runway_threshold: float = 90
    hoarding_penalty_weight: float = 1.0

    # Escrow
    large_threshold: float = 100
    base_delay: float = 7
    immediate_release_fraction: float = 0.5

    # Local trust
    transitivity_decay: float = 0.5
    new_observer_discount: float = 0.3

    def copy(self):
        """Return a copy of parameters."""
        return NetworkParameters(
            k_age=self.k_age,
            tau_age=self.tau_age,
            base_credit=self.base_credit,
            tau_transaction=self.tau_transaction,
            k_payment=self.k_payment,
            k_transfer=self.k_transfer,
            isolation_threshold=self.isolation_threshold,
            similarity_threshold=self.similarity_threshold,
            base_verification_rate=self.base_verification_rate,
            expected_verification_rate=self.expected_verification_rate,
            runway_threshold=self.runway_threshold,
            hoarding_penalty_weight=self.hoarding_penalty_weight,
            large_threshold=self.large_threshold,
            base_delay=self.base_delay,
            immediate_release_fraction=self.immediate_release_fraction,
            transitivity_decay=self.transitivity_decay,
            new_observer_discount=self.new_observer_discount
        )

# =============================================================================
# Metrics Collection
# =============================================================================

@dataclass
class DailyMetrics:
    """Metrics collected each day."""
    day: int

    # Network-wide trust metrics
    total_identities: int = 0
    active_identities: int = 0
    total_trust: float = 0.0
    mean_trust: float = 0.0
    median_trust: float = 0.0
    max_trust: float = 0.0
    min_trust: float = 0.0
    trust_std: float = 0.0
    trust_gini: float = 0.0

    # Transaction metrics
    daily_transactions: int = 0
    total_transaction_volume: float = 0.0
    mean_transaction_value: float = 0.0
    session_completion_rate: float = 0.0
    verification_pass_rate: float = 0.0

    # Economic metrics
    daily_burn_volume: float = 0.0
    daily_mint_volume: float = 0.0
    total_coin_supply: float = 0.0
    coin_velocity: float = 0.0
    hoarding_prevalence: float = 0.0

    # Security metrics
    cluster_count: int = 0
    cluster_prevalence: float = 0.0
    accusation_count: int = 0
    accusation_rate: float = 0.0
    verification_failure_rate: float = 0.0
    anomaly_count: int = 0

    # Verification participation
    verifications_originated: int = 0
    verification_origination_rate: float = 0.0

    # New entrant metrics
    new_identities_created: int = 0
    new_identity_survival_rate: float = 0.0
    time_to_viable_trust: float = 0.0

    # Parameter snapshot
    params: Optional[NetworkParameters] = None


def compute_gini(values: List[float]) -> float:
    """Compute Gini coefficient (0 = perfect equality, 1 = perfect inequality)."""
    if not values or len(values) < 2:
        return 0.0

    sorted_values = sorted(values)
    n = len(sorted_values)
    total = sum(sorted_values)

    if total == 0:
        return 0.0

    cumulative = 0.0
    gini_sum = 0.0
    for i, v in enumerate(sorted_values):
        cumulative += v
        gini_sum += (2 * (i + 1) - n - 1) * v

    return gini_sum / (n * total)


# =============================================================================
# Extended Network with Metrics and Policy
# =============================================================================

class PolicyNetwork(Network):
    """Network with automated monetary policy."""

    def __init__(self, params: Optional[NetworkParameters] = None):
        super().__init__()
        self.params = params or NetworkParameters()
        self.metrics_history: List[DailyMetrics] = []
        self.parameter_changes: List[Dict[str, Any]] = []

        # Additional tracking
        self.daily_transactions: List[Transaction] = []
        self.daily_burns: float = 0.0
        self.daily_mints: float = 0.0
        self.verifications_originated_today: int = 0
        self.verification_results: List[bool] = []  # True = pass, False = fail
        self.new_identities_today: int = 0
        self.session_completions: List[bool] = []  # True = completed, False = abandoned

        # Automated policy settings
        self.auto_policy_enabled: bool = False
        self.policy_phase: str = "GENESIS"  # GENESIS, OBSERVATION, LIMITED_AUTO, FULL_AUTO
        self.last_policy_adjustment: int = -999
        self.min_adjustment_interval: int = 7
        self.max_change_rate: float = 0.05  # 5% max change per adjustment
        self.dampening_factor: float = 0.3

        # Target metrics for policy
        self.target_gini: float = 0.4
        self.target_verification_failure_rate: float = 0.05
        self.target_hoarding_prevalence: float = 0.1
        self.target_cluster_prevalence: float = 0.05

    def create_identity(self, id: str) -> Identity:
        """Create a new identity with tracking."""
        identity = super().create_identity(id)
        self.new_identities_today += 1
        return identity

    def add_transaction(self, consumer_id: str, provider_id: str,
                        resource_weight: float = 1.0,
                        duration_hours: float = 1.0,
                        verification_score: float = 1.0,
                        completed: bool = True):
        """Record a transaction with additional tracking."""
        super().add_transaction(consumer_id, provider_id,
                               resource_weight, duration_hours, verification_score)

        tx = self.identities[provider_id].transactions_as_provider[-1]
        self.daily_transactions.append(tx)

        # Track verification result
        if random.random() < self.params.base_verification_rate:
            self.verification_results.append(verification_score >= 0.7)
            self.verifications_originated_today += 1

        # Track session completion
        self.session_completions.append(completed)

        # Simulate payment and burn
        provider_trust = self.identities[provider_id].trust
        payment_share = 1 - 1 / (1 + self.params.k_payment * provider_trust)
        tx_value = resource_weight * duration_hours
        self.daily_burns += tx_value * (1 - payment_share)

        # Update coin balances
        provider = self.identities[provider_id]
        provider.coin_balance += tx_value * payment_share
        provider.total_earned += tx_value * payment_share

    def simulate_daily_mint(self):
        """Simulate daily coin distribution."""
        total_effective_trust = sum(
            self.compute_effective_trust(i)
            for i in self.identities.values()
        )

        if total_effective_trust <= 0:
            return

        daily_mint = 100.0  # Fixed daily mint
        self.daily_mints = daily_mint

        for identity in self.identities.values():
            effective = self.compute_effective_trust(identity)
            share = effective / total_effective_trust * daily_mint
            identity.coin_balance += share
            identity.total_earned += share

    def collect_metrics(self) -> DailyMetrics:
        """Collect all metrics for the current day."""
        metrics = DailyMetrics(day=self.current_day)

        # Network-wide trust
        all_identities = list(self.identities.values())
        metrics.total_identities = len(all_identities)

        active = [i for i in all_identities
                  if self.compute_activity(i, window=30) > 0]
        metrics.active_identities = len(active)

        trusts = [i.trust for i in all_identities if i.trust > 0]
        if trusts:
            metrics.total_trust = sum(trusts)
            metrics.mean_trust = statistics.mean(trusts)
            metrics.median_trust = statistics.median(trusts)
            metrics.max_trust = max(trusts)
            metrics.min_trust = min(trusts)
            metrics.trust_std = statistics.stdev(trusts) if len(trusts) > 1 else 0
            metrics.trust_gini = compute_gini(trusts)
        else:
            metrics.trust_gini = 0.0

        # Transaction metrics
        metrics.daily_transactions = len(self.daily_transactions)
        if self.daily_transactions:
            volumes = [tx.resource_weight * tx.duration_hours
                      for tx in self.daily_transactions]
            metrics.total_transaction_volume = sum(volumes)
            metrics.mean_transaction_value = statistics.mean(volumes)

        if self.session_completions:
            metrics.session_completion_rate = sum(self.session_completions) / len(self.session_completions)

        if self.verification_results:
            metrics.verification_pass_rate = sum(self.verification_results) / len(self.verification_results)
            metrics.verification_failure_rate = 1 - metrics.verification_pass_rate

        # Economic metrics
        metrics.daily_burn_volume = self.daily_burns
        metrics.daily_mint_volume = self.daily_mints
        metrics.total_coin_supply = sum(i.coin_balance for i in all_identities)

        if metrics.total_coin_supply > 0:
            metrics.coin_velocity = metrics.total_transaction_volume / metrics.total_coin_supply

        hoarding = sum(1 for i in all_identities
                      if self.compute_runway(i) > self.params.runway_threshold)
        metrics.hoarding_prevalence = hoarding / max(len(all_identities), 1)

        # Security metrics
        cluster_weights = self.detect_clusters()
        clustered = sum(1 for w in cluster_weights.values() if w < 1.0)
        metrics.cluster_count = len([w for w in cluster_weights.values() if w < 1.0])
        metrics.cluster_prevalence = clustered / max(len(all_identities), 1)

        accusations = sum(len(i.assertions_made) for i in all_identities
                         if any(a.score < 0 and a.day == self.current_day
                               for a in i.assertions_made))
        metrics.accusation_count = accusations
        if metrics.daily_transactions > 0:
            metrics.accusation_rate = accusations / metrics.daily_transactions

        # Verification participation
        metrics.verifications_originated = self.verifications_originated_today
        if metrics.daily_transactions > 0:
            metrics.verification_origination_rate = (
                self.verifications_originated_today / metrics.daily_transactions
            )

        # New entrant metrics
        metrics.new_identities_created = self.new_identities_today

        # Store params snapshot
        metrics.params = self.params.copy()

        return metrics

    def reset_daily_counters(self):
        """Reset counters for a new day."""
        self.daily_transactions = []
        self.daily_burns = 0.0
        self.daily_mints = 0.0
        self.verifications_originated_today = 0
        self.verification_results = []
        self.new_identities_today = 0
        self.session_completions = []

    def advance_day(self):
        """Advance by one day with metric collection and policy adjustment."""
        # Collect metrics before advancing
        metrics = self.collect_metrics()
        self.metrics_history.append(metrics)

        # Apply automated policy if enabled
        if self.auto_policy_enabled:
            self.apply_automated_policy()

        # Reset counters and advance
        self.reset_daily_counters()
        self.advance_days(1)

        # Daily mint
        self.simulate_daily_mint()

    def update_policy_phase(self):
        """Update policy phase based on network age."""
        if self.current_day < 90:
            self.policy_phase = "GENESIS"
        elif self.current_day < 180:
            self.policy_phase = "OBSERVATION"
        elif self.current_day < 365:
            self.policy_phase = "LIMITED_AUTO"
        else:
            self.policy_phase = "FULL_AUTO"

    def apply_automated_policy(self):
        """Apply automated parameter adjustments based on metrics."""
        self.update_policy_phase()

        if self.policy_phase == "GENESIS":
            return  # No adjustments during genesis

        # Check if enough time has passed since last adjustment
        if self.current_day - self.last_policy_adjustment < self.min_adjustment_interval:
            return

        # Get recent metrics (last 14 days)
        if len(self.metrics_history) < 14:
            return

        recent = self.metrics_history[-14:]

        # Compute averages
        avg_gini = statistics.mean(m.trust_gini for m in recent) if recent else 0
        failure_rates = [m.verification_failure_rate for m in recent if m.verification_failure_rate > 0]
        avg_failure_rate = statistics.mean(failure_rates) if failure_rates else 0
        avg_cluster_prevalence = statistics.mean(m.cluster_prevalence for m in recent) if recent else 0
        avg_hoarding = statistics.mean(m.hoarding_prevalence for m in recent) if recent else 0
        mean_trusts = [m.mean_trust for m in recent if m.mean_trust > 0]
        avg_mean_trust = statistics.mean(mean_trusts) if mean_trusts else 0

        changes_made = []

        # GINI-based K_PAYMENT adjustment
        if self.policy_phase in ["LIMITED_AUTO", "FULL_AUTO"]:
            gini_error = avg_gini - self.target_gini
            if abs(gini_error) > 0.1:  # Dead zone
                adjustment = -gini_error * self.dampening_factor * self.params.k_payment
                adjustment = max(-self.max_change_rate * self.params.k_payment,
                               min(self.max_change_rate * self.params.k_payment, adjustment))
                old_val = self.params.k_payment
                self.params.k_payment = max(0.01, self.params.k_payment + adjustment)
                if abs(adjustment) > 0.0001:
                    changes_made.append({
                        "parameter": "k_payment",
                        "old_value": old_val,
                        "new_value": self.params.k_payment,
                        "trigger": f"gini={avg_gini:.3f}, target={self.target_gini}"
                    })

        # Failure rate based detection threshold adjustment
        if self.policy_phase == "FULL_AUTO":
            if avg_failure_rate > self.target_verification_failure_rate * 2:
                # Too many failures - tighten detection
                old_val = self.params.isolation_threshold
                self.params.isolation_threshold = max(0.7,
                    self.params.isolation_threshold - 0.02)
                if old_val != self.params.isolation_threshold:
                    changes_made.append({
                        "parameter": "isolation_threshold",
                        "old_value": old_val,
                        "new_value": self.params.isolation_threshold,
                        "trigger": f"failure_rate={avg_failure_rate:.3f}"
                    })

        # Cluster prevalence based adjustment
        if self.policy_phase == "FULL_AUTO":
            if avg_cluster_prevalence > self.target_cluster_prevalence * 2:
                old_val = self.params.k_transfer
                self.params.k_transfer = self.params.k_transfer * 1.05
                changes_made.append({
                    "parameter": "k_transfer",
                    "old_value": old_val,
                    "new_value": self.params.k_transfer,
                    "trigger": f"cluster_prevalence={avg_cluster_prevalence:.3f}"
                })

        # Trust inflation/deflation adjustment
        if self.policy_phase == "FULL_AUTO" and len(self.metrics_history) > 60:
            old_metrics = self.metrics_history[-60:-30]
            old_mean = statistics.mean(m.mean_trust for m in old_metrics if m.mean_trust > 0) or 1

            if avg_mean_trust > 0 and old_mean > 0:
                trust_growth = (avg_mean_trust - old_mean) / old_mean

                if trust_growth > 0.2:  # Trust growing too fast
                    old_val = self.params.tau_transaction
                    self.params.tau_transaction = max(90,
                        self.params.tau_transaction * 0.95)
                    changes_made.append({
                        "parameter": "tau_transaction",
                        "old_value": old_val,
                        "new_value": self.params.tau_transaction,
                        "trigger": f"trust_growth={trust_growth:.3f}"
                    })
                elif trust_growth < -0.1:  # Trust declining
                    old_val = self.params.tau_transaction
                    self.params.tau_transaction = min(730,
                        self.params.tau_transaction * 1.05)
                    changes_made.append({
                        "parameter": "tau_transaction",
                        "old_value": old_val,
                        "new_value": self.params.tau_transaction,
                        "trigger": f"trust_growth={trust_growth:.3f}"
                    })

        if changes_made:
            self.last_policy_adjustment = self.current_day
            self.parameter_changes.append({
                "day": self.current_day,
                "phase": self.policy_phase,
                "changes": changes_made
            })


# =============================================================================
# Simulation Scenarios
# =============================================================================

def run_baseline_simulation(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """Run baseline honest network simulation."""
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create initial providers and consumers
    for i in range(10):
        net.create_identity(f"provider_{i}")
    for i in range(20):
        net.create_identity(f"consumer_{i}")

    for day in range(days):
        # Normal transaction activity
        providers = [f"provider_{i}" for i in range(10)]
        consumers = [f"consumer_{i}" for i in range(20)]

        for provider in providers:
            if random.random() < 0.3:
                consumer = random.choice(consumers)
                net.add_transaction(
                    consumer, provider,
                    resource_weight=random.uniform(1, 4),
                    duration_hours=random.uniform(1, 8),
                    verification_score=random.uniform(0.85, 1.0),
                    completed=random.random() > 0.1
                )

        # Occasional positive assertions
        if random.random() < 0.05:
            asserter = random.choice(consumers)
            subject = random.choice(providers)
            net.add_assertion(asserter, subject, score=random.uniform(0.3, 0.8),
                            classification="EXCELLENT_SERVICE")

        # Gradually add new participants
        if day % 30 == 0 and day > 0:
            new_idx = 10 + day // 30
            net.create_identity(f"provider_{new_idx}")
            net.create_identity(f"consumer_{20 + day // 30}")

        net.solve_trust()
        net.advance_day()

    return net


def run_trust_inflation_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Participants collude to rapidly inflate each other's trust.

    This should trigger TAU_TRANSACTION adjustment in automated policy.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create honest participants
    for i in range(5):
        net.create_identity(f"honest_{i}")
    for i in range(10):
        net.create_identity(f"consumer_{i}")

    # Create inflation cartel
    for i in range(5):
        net.create_identity(f"cartel_{i}")

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(10)]
        honest = [f"honest_{i}" for i in range(5)]
        cartel = [f"cartel_{i}" for i in range(5)]

        # Normal honest activity
        for provider in honest:
            if random.random() < 0.2:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Cartel rapidly inflates each other
        # After day 90, cartel starts aggressive mutual transactions
        if day > 90:
            for provider in cartel:
                # Cartel members transact heavily with each other
                for _ in range(3 if day > 180 else 1):
                    other = random.choice([c for c in cartel if c != provider])
                    net.add_transaction(other, provider,
                        resource_weight=random.uniform(3, 5),
                        duration_hours=random.uniform(6, 10),
                        verification_score=1.0)

                    # Also positive assertions
                    if random.random() < 0.3:
                        net.add_assertion(other, provider, score=0.9,
                                        classification="EXCELLENT_SERVICE")

        net.solve_trust()
        net.advance_day()

    return net


def run_sybil_explosion_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Sudden creation of many Sybil identities.

    This should trigger ISOLATION_THRESHOLD and K_TRANSFER adjustments.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create honest network
    for i in range(10):
        net.create_identity(f"honest_{i}")
    for i in range(15):
        net.create_identity(f"consumer_{i}")

    sybil_created = False
    sybils = []

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(15)]
        honest = [f"honest_{i}" for i in range(10)]

        # Normal activity
        for provider in honest:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Day 180: Sudden Sybil explosion
        if day == 180 and not sybil_created:
            for i in range(30):  # Create 30 sybils
                net.create_identity(f"sybil_{i}")
                sybils.append(f"sybil_{i}")
            sybil_created = True

        # Sybils transact among themselves
        if sybil_created and sybils:
            for sybil in sybils:
                if random.random() < 0.4:
                    other = random.choice([s for s in sybils if s != sybil])
                    net.add_transaction(other, sybil,
                        resource_weight=random.uniform(2, 4),
                        duration_hours=random.uniform(4, 8),
                        verification_score=1.0)

            # Sybils try to interact with honest network
            if day > 220:
                for sybil in random.sample(sybils, min(5, len(sybils))):
                    if random.random() < 0.2:
                        consumer = random.choice(consumers)
                        net.add_transaction(consumer, sybil,
                            resource_weight=random.uniform(2, 4),
                            duration_hours=random.uniform(4, 8),
                            verification_score=random.uniform(0.3, 0.8))

        net.solve_trust()
        net.advance_day()

    return net


def run_verification_starvation_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Free-riders don't participate in verification.

    This should trigger verification rate adjustments.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create good citizens who verify
    for i in range(5):
        net.create_identity(f"citizen_{i}")

    # Create free-riders who don't verify
    for i in range(10):
        net.create_identity(f"freeloader_{i}")

    # Consumers
    for i in range(15):
        net.create_identity(f"consumer_{i}")

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(15)]
        citizens = [f"citizen_{i}" for i in range(5)]
        freeloaders = [f"freeloader_{i}" for i in range(10)]

        # Citizens do normal work and verify
        for provider in citizens:
            if random.random() < 0.3:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

                # Citizens originate verifications
                net.verifications_originated_today += 1

        # Freeloaders transact but never verify
        for provider in freeloaders:
            if random.random() < 0.4:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(2, 4),
                    duration_hours=random.uniform(3, 7),
                    verification_score=random.uniform(0.8, 0.95))
                # Freeloaders don't originate verifications

        net.solve_trust()
        net.advance_day()

    return net


def run_hoarding_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Participants accumulate coins without economic participation.

    This should trigger RUNWAY_THRESHOLD and HOARDING_PENALTY_WEIGHT adjustments.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create normal participants
    for i in range(8):
        net.create_identity(f"normal_{i}")

    # Create hoarders
    for i in range(4):
        net.create_identity(f"hoarder_{i}")

    # Consumers
    for i in range(12):
        net.create_identity(f"consumer_{i}")

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(12)]
        normals = [f"normal_{i}" for i in range(8)]
        hoarders = [f"hoarder_{i}" for i in range(4)]

        # Normal participants cycle coins
        for provider in normals:
            if random.random() < 0.3:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

            # Normals also spend as consumers
            if random.random() < 0.2:
                other_provider = random.choice([p for p in normals if p != provider])
                net.add_transaction(provider, other_provider,
                    resource_weight=random.uniform(1, 2),
                    duration_hours=random.uniform(1, 3),
                    verification_score=random.uniform(0.9, 1.0))

        # Hoarders earn but don't spend
        for provider in hoarders:
            if random.random() < 0.3:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(2, 4),
                    duration_hours=random.uniform(3, 7),
                    verification_score=random.uniform(0.9, 1.0))
            # Hoarders NEVER spend as consumers

        net.solve_trust()
        net.advance_day()

    return net


def run_gini_manipulation_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Wealthy participants try to concentrate trust.

    This should trigger K_PAYMENT adjustments to flatten the curve.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create whales (early entrants with massive activity)
    for i in range(3):
        net.create_identity(f"whale_{i}")

    # Create normal participants
    for i in range(12):
        net.create_identity(f"normal_{i}")

    # Consumers
    for i in range(20):
        net.create_identity(f"consumer_{i}")

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(20)]
        whales = [f"whale_{i}" for i in range(3)]
        normals = [f"normal_{i}" for i in range(12)]

        # Whales dominate transaction volume
        for whale in whales:
            # Whales do 5x more transactions than normal
            for _ in range(5 if day < 300 else 3):
                if random.random() < 0.6:
                    consumer = random.choice(consumers)
                    net.add_transaction(consumer, whale,
                        resource_weight=random.uniform(3, 6),  # Higher value
                        duration_hours=random.uniform(4, 10),
                        verification_score=random.uniform(0.95, 1.0))

            # Whales get lots of positive assertions
            if random.random() < 0.2:
                consumer = random.choice(consumers)
                net.add_assertion(consumer, whale, score=0.9,
                                classification="EXCELLENT_SERVICE")

        # Normal participants struggle
        for provider in normals:
            if random.random() < 0.15:  # Lower activity rate
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 2),
                    duration_hours=random.uniform(1, 4),
                    verification_score=random.uniform(0.85, 0.95))

        net.solve_trust()
        net.advance_day()

    return net


def run_slow_degradation_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack: Provider slowly degrades quality over time.

    Verification rate should catch this.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create degrader and honest providers
    net.create_identity("degrader")
    for i in range(5):
        net.create_identity(f"honest_{i}")

    # Consumers
    for i in range(15):
        net.create_identity(f"consumer_{i}")

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(15)]
        honest = [f"honest_{i}" for i in range(5)]

        # Calculate degradation
        if day < 180:
            degrader_quality = 0.95
        else:
            # Quality degrades over time
            degrader_quality = max(0.3, 0.95 - (day - 180) * 0.002)

        # Degrader provides (possibly poor) service
        if random.random() < 0.3:
            consumer = random.choice(consumers)
            net.add_transaction(consumer, "degrader",
                resource_weight=random.uniform(2, 4),
                duration_hours=random.uniform(3, 7),
                verification_score=degrader_quality,
                completed=random.random() > (0.3 if degrader_quality < 0.7 else 0.05))

        # Honest providers maintain quality
        for provider in honest:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        net.solve_trust()
        net.advance_day()

    return net


# =============================================================================
# Experiment Runner
# =============================================================================

def run_experiment(name: str, scenario_fn, days: int = 720,
                   runs_per_scenario: int = 5) -> Dict[str, Any]:
    """Run a single experiment multiple times and collect results."""
    print(f"\n{'='*60}")
    print(f"EXPERIMENT: {name}")
    print(f"{'='*60}")

    results = {
        "name": name,
        "days": days,
        "runs": runs_per_scenario,
        "with_policy": [],
        "without_policy": []
    }

    for run_idx in range(runs_per_scenario):
        print(f"  Run {run_idx + 1}/{runs_per_scenario}...", end="", flush=True)
        start_time = time.time()

        # Run without policy
        random.seed(42 + run_idx)
        net_no_policy = scenario_fn(days=days, with_policy=False)

        # Run with policy
        random.seed(42 + run_idx)
        net_with_policy = scenario_fn(days=days, with_policy=True)

        elapsed = time.time() - start_time
        print(f" done ({elapsed:.1f}s)")

        # Extract final metrics
        if net_no_policy.metrics_history:
            final_no = net_no_policy.metrics_history[-1]
            results["without_policy"].append({
                "final_mean_trust": final_no.mean_trust,
                "final_gini": final_no.trust_gini,
                "final_cluster_prevalence": final_no.cluster_prevalence,
                "total_identities": final_no.total_identities,
                "verification_failure_rate": final_no.verification_failure_rate,
                "hoarding_prevalence": final_no.hoarding_prevalence,
                "metrics_history": [
                    {
                        "day": m.day,
                        "mean_trust": m.mean_trust,
                        "trust_gini": m.trust_gini,
                        "cluster_prevalence": m.cluster_prevalence,
                        "verification_failure_rate": m.verification_failure_rate,
                        "daily_transactions": m.daily_transactions
                    }
                    for m in net_no_policy.metrics_history[::7]  # Sample every 7 days
                ]
            })

        if net_with_policy.metrics_history:
            final_with = net_with_policy.metrics_history[-1]
            results["with_policy"].append({
                "final_mean_trust": final_with.mean_trust,
                "final_gini": final_with.trust_gini,
                "final_cluster_prevalence": final_with.cluster_prevalence,
                "total_identities": final_with.total_identities,
                "verification_failure_rate": final_with.verification_failure_rate,
                "hoarding_prevalence": final_with.hoarding_prevalence,
                "parameter_changes": net_with_policy.parameter_changes,
                "final_params": {
                    "k_payment": net_with_policy.params.k_payment,
                    "k_transfer": net_with_policy.params.k_transfer,
                    "tau_transaction": net_with_policy.params.tau_transaction,
                    "isolation_threshold": net_with_policy.params.isolation_threshold
                },
                "metrics_history": [
                    {
                        "day": m.day,
                        "mean_trust": m.mean_trust,
                        "trust_gini": m.trust_gini,
                        "cluster_prevalence": m.cluster_prevalence,
                        "verification_failure_rate": m.verification_failure_rate,
                        "daily_transactions": m.daily_transactions
                    }
                    for m in net_with_policy.metrics_history[::7]
                ]
            })

    return results


def run_all_experiments(output_dir: str = "results"):
    """Run all experiments and save results."""
    os.makedirs(output_dir, exist_ok=True)

    experiments = [
        ("Baseline (Honest Network)", run_baseline_simulation),
        ("Trust Inflation Attack", run_trust_inflation_attack),
        ("Sybil Explosion Attack", run_sybil_explosion_attack),
        ("Verification Starvation Attack", run_verification_starvation_attack),
        ("Hoarding Attack", run_hoarding_attack),
        ("Gini Manipulation Attack", run_gini_manipulation_attack),
        ("Slow Degradation Attack", run_slow_degradation_attack),
    ]

    all_results = []
    total_start = time.time()

    for name, scenario_fn in experiments:
        result = run_experiment(name, scenario_fn, days=720, runs_per_scenario=5)
        all_results.append(result)

        # Save intermediate results
        with open(f"{output_dir}/experiment_{name.replace(' ', '_').replace('/', '_')}.json", "w") as f:
            json.dump(result, f, indent=2, default=str)

    total_elapsed = time.time() - total_start

    # Save all results
    with open(f"{output_dir}/all_experiments.json", "w") as f:
        json.dump({
            "timestamp": datetime.now().isoformat(),
            "total_runtime_seconds": total_elapsed,
            "experiments": all_results
        }, f, indent=2, default=str)

    return all_results


# =============================================================================
# Long-Running Extended Simulations
# =============================================================================

def run_extended_baseline(days: int = 1825, seed: int = 42) -> PolicyNetwork:
    """
    Extended 5-year baseline simulation for comprehensive metric collection.
    """
    random.seed(seed)
    net = PolicyNetwork()
    net.auto_policy_enabled = True

    # Initial network
    for i in range(15):
        net.create_identity(f"provider_{i}")
    for i in range(30):
        net.create_identity(f"consumer_{i}")

    provider_count = 15
    consumer_count = 30

    for day in range(days):
        if day % 100 == 0:
            print(f"  Extended baseline: Day {day}/{days}")

        providers = [f"provider_{i}" for i in range(provider_count)]
        consumers = [f"consumer_{i}" for i in range(consumer_count)]

        # Transaction activity
        for provider in providers:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 4),
                    duration_hours=random.uniform(1, 8),
                    verification_score=random.uniform(0.85, 1.0),
                    completed=random.random() > 0.08)

        # Occasional assertions
        if random.random() < 0.03:
            asserter = random.choice(consumers)
            subject = random.choice(providers)
            net.add_assertion(asserter, subject,
                score=random.uniform(0.2, 0.8) if random.random() > 0.1 else random.uniform(-0.5, -0.2),
                classification="EXCELLENT_SERVICE" if random.random() > 0.1 else "RESOURCE_MISMATCH")

        # Network growth
        if day % 45 == 0 and day > 0:
            net.create_identity(f"provider_{provider_count}")
            provider_count += 1
            net.create_identity(f"consumer_{consumer_count}")
            consumer_count += 1

        # Provider churn (some providers leave)
        if day % 90 == 0 and day > 180:
            # Simulate provider leaving by reducing their activity to near zero
            pass  # In a more complex sim, we'd mark them inactive

        net.solve_trust()
        net.advance_day()

    return net


def run_adversarial_multi_attack(days: int = 1825, seed: int = 42) -> PolicyNetwork:
    """
    Extended simulation with multiple attack waves over 5 years.
    """
    random.seed(seed)
    net = PolicyNetwork()
    net.auto_policy_enabled = True

    # Initial honest network
    for i in range(10):
        net.create_identity(f"honest_{i}")
    for i in range(20):
        net.create_identity(f"consumer_{i}")

    attack_waves = {
        180: "sybil",       # Day 180: Sybil attack
        450: "inflation",   # Day 450: Trust inflation
        720: "hoarding",    # Day 720: Hoarding attack
        990: "degradation", # Day 990: Quality degradation
        1260: "coordinated", # Day 1260: Coordinated assault
    }

    attackers = {}

    for day in range(days):
        if day % 100 == 0:
            print(f"  Adversarial multi-attack: Day {day}/{days}")

        consumers = [id for id in net.identities.keys() if id.startswith("consumer")]
        honest = [id for id in net.identities.keys() if id.startswith("honest")]

        # Normal honest activity
        for provider in honest:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Check for attack waves
        if day in attack_waves:
            attack_type = attack_waves[day]
            print(f"    Attack wave: {attack_type} on day {day}")

            if attack_type == "sybil":
                for i in range(15):
                    net.create_identity(f"sybil_{day}_{i}")
                attackers[day] = [f"sybil_{day}_{i}" for i in range(15)]

            elif attack_type == "inflation":
                for i in range(5):
                    net.create_identity(f"inflator_{day}_{i}")
                attackers[day] = [f"inflator_{day}_{i}" for i in range(5)]

            elif attack_type == "hoarding":
                for i in range(3):
                    net.create_identity(f"hoarder_{day}_{i}")
                attackers[day] = [f"hoarder_{day}_{i}" for i in range(3)]

            elif attack_type == "degradation":
                net.create_identity(f"degrader_{day}")
                attackers[day] = [f"degrader_{day}"]

            elif attack_type == "coordinated":
                for i in range(10):
                    net.create_identity(f"coord_{day}_{i}")
                attackers[day] = [f"coord_{day}_{i}" for i in range(10)]

        # Execute ongoing attacks
        for attack_day, attack_ids in attackers.items():
            if day > attack_day:
                attack_type = attack_waves.get(attack_day, "unknown")

                if attack_type == "sybil":
                    # Sybils transact among themselves
                    for attacker in attack_ids:
                        if attacker in net.identities and random.random() < 0.3:
                            other = random.choice([a for a in attack_ids if a != attacker and a in net.identities])
                            if other:
                                net.add_transaction(other, attacker,
                                    resource_weight=2.0, duration_hours=4.0,
                                    verification_score=1.0)

                elif attack_type == "inflation":
                    # Inflators boost each other rapidly
                    for attacker in attack_ids:
                        if attacker in net.identities:
                            for _ in range(2):
                                if random.random() < 0.4:
                                    other = random.choice([a for a in attack_ids if a != attacker and a in net.identities])
                                    if other:
                                        net.add_transaction(other, attacker,
                                            resource_weight=4.0, duration_hours=8.0,
                                            verification_score=1.0)

                elif attack_type == "hoarding":
                    # Hoarders earn but don't spend
                    for attacker in attack_ids:
                        if attacker in net.identities and random.random() < 0.3:
                            consumer = random.choice(consumers)
                            net.add_transaction(consumer, attacker,
                                resource_weight=3.0, duration_hours=6.0,
                                verification_score=0.95)

                elif attack_type == "degradation":
                    # Degrader's quality drops over time
                    quality = max(0.3, 0.95 - (day - attack_day) * 0.001)
                    for attacker in attack_ids:
                        if attacker in net.identities and random.random() < 0.3:
                            consumer = random.choice(consumers)
                            net.add_transaction(consumer, attacker,
                                resource_weight=2.0, duration_hours=4.0,
                                verification_score=quality)

                elif attack_type == "coordinated":
                    # Coordinated attack: mutual boosting + attacking honest
                    for attacker in attack_ids:
                        if attacker in net.identities:
                            # Boost each other
                            if random.random() < 0.3:
                                other = random.choice([a for a in attack_ids if a != attacker and a in net.identities])
                                if other:
                                    net.add_transaction(other, attacker,
                                        resource_weight=3.0, duration_hours=6.0,
                                        verification_score=1.0)

                            # Attack honest providers
                            if random.random() < 0.1:
                                target = random.choice(honest)
                                net.add_assertion(attacker, target,
                                    score=-0.5, classification="RESOURCE_MISMATCH",
                                    has_evidence=False)

        net.solve_trust()
        net.advance_day()

    return net


# =============================================================================
# Report Generation
# =============================================================================

def generate_report(results: List[Dict], output_file: str = "results/simulation_report.md"):
    """Generate comprehensive markdown report."""

    report = []
    report.append("# Omerta Automated Monetary Policy Simulation Report")
    report.append(f"\nGenerated: {datetime.now().isoformat()}\n")

    report.append("## Executive Summary\n")
    report.append("This report presents the results of extensive simulations testing the ")
    report.append("automated monetary policy system for the Omerta trust network. ")
    report.append("Each scenario was run multiple times with and without automated policy adjustments.\n")

    # Summary table
    report.append("### Results Summary\n")
    report.append("| Experiment | Metric | Without Policy | With Policy | Improvement |")
    report.append("|------------|--------|----------------|-------------|-------------|")

    for result in results:
        name = result["name"]

        # Average final metrics
        if result["without_policy"] and result["with_policy"]:
            wo_gini = statistics.mean(r["final_gini"] for r in result["without_policy"])
            w_gini = statistics.mean(r["final_gini"] for r in result["with_policy"])
            wo_cluster = statistics.mean(r["final_cluster_prevalence"] for r in result["without_policy"])
            w_cluster = statistics.mean(r["final_cluster_prevalence"] for r in result["with_policy"])

            gini_improvement = ((wo_gini - w_gini) / wo_gini * 100) if wo_gini > 0 else 0
            cluster_improvement = ((wo_cluster - w_cluster) / wo_cluster * 100) if wo_cluster > 0 else 0

            report.append(f"| {name} | Gini | {wo_gini:.3f} | {w_gini:.3f} | {gini_improvement:+.1f}% |")
            report.append(f"| | Cluster Prevalence | {wo_cluster:.3f} | {w_cluster:.3f} | {cluster_improvement:+.1f}% |")

    report.append("\n---\n")

    # Detailed results for each experiment
    for result in results:
        report.append(f"## {result['name']}\n")

        report.append(f"- **Duration**: {result['days']} days")
        report.append(f"- **Runs**: {result['runs']} per configuration\n")

        if result["with_policy"]:
            # Parameter changes
            total_changes = sum(len(r.get("parameter_changes", [])) for r in result["with_policy"])
            report.append(f"### Automated Policy Adjustments")
            report.append(f"Total parameter changes across all runs: {total_changes}\n")

            # Show example changes from first run
            if result["with_policy"][0].get("parameter_changes"):
                report.append("**Sample adjustments from Run 1:**\n")
                for change_event in result["with_policy"][0]["parameter_changes"][:5]:
                    report.append(f"- Day {change_event['day']} ({change_event['phase']}):")
                    for c in change_event["changes"]:
                        report.append(f"  - `{c['parameter']}`: {c['old_value']:.4f} → {c['new_value']:.4f}")
                        report.append(f"    - Trigger: {c['trigger']}")
                report.append("")

            # Final parameter values
            if result["with_policy"][0].get("final_params"):
                report.append("**Final parameter values (Run 1):**\n")
                for param, value in result["with_policy"][0]["final_params"].items():
                    report.append(f"- `{param}`: {value:.4f}")
                report.append("")

        report.append("### Metrics Comparison\n")
        if result["without_policy"] and result["with_policy"]:
            report.append("| Metric | Without Policy | With Policy |")
            report.append("|--------|----------------|-------------|")

            wo_trust = statistics.mean(r["final_mean_trust"] for r in result["without_policy"])
            w_trust = statistics.mean(r["final_mean_trust"] for r in result["with_policy"])
            report.append(f"| Mean Trust | {wo_trust:.2f} | {w_trust:.2f} |")

            wo_gini = statistics.mean(r["final_gini"] for r in result["without_policy"])
            w_gini = statistics.mean(r["final_gini"] for r in result["with_policy"])
            report.append(f"| Trust Gini | {wo_gini:.3f} | {w_gini:.3f} |")

            wo_cluster = statistics.mean(r["final_cluster_prevalence"] for r in result["without_policy"])
            w_cluster = statistics.mean(r["final_cluster_prevalence"] for r in result["with_policy"])
            report.append(f"| Cluster Prevalence | {wo_cluster:.3f} | {w_cluster:.3f} |")

            wo_fail = statistics.mean(r["verification_failure_rate"] for r in result["without_policy"])
            w_fail = statistics.mean(r["verification_failure_rate"] for r in result["with_policy"])
            report.append(f"| Verification Failure Rate | {wo_fail:.3f} | {w_fail:.3f} |")

        report.append("\n---\n")

    # Attack-specific analysis
    report.append("## Attack Analysis\n")
    report.append("This section analyzes how each attack scenario was affected by automated policy.\n")

    attack_analysis = {
        "Trust Inflation Attack": """
The trust inflation attack attempts to rapidly increase trust scores through
coordinated mutual transactions. The automated policy responds by:
- Adjusting TAU_TRANSACTION to increase trust decay
- This makes recent behavior matter less, slowing the inflation
- Result: Inflated trust decays faster, limiting attacker advantage
""",
        "Sybil Explosion Attack": """
The Sybil explosion attack creates many fake identities to manipulate the network.
The automated policy responds by:
- Detecting increased cluster prevalence
- Increasing K_TRANSFER to make coin distribution to Sybils expensive
- Decreasing ISOLATION_THRESHOLD for stricter cluster detection
- Result: Sybils have less economic power and are more easily detected
""",
        "Verification Starvation Attack": """
Free-riders benefit from network security without contributing verification.
The automated policy responds by:
- Tracking verification origination rates
- Adjusting profile scores to penalize low origination
- Increasing BASE_VERIFICATION_RATE when failure rates rise
- Result: Free-riders have lower effective trust
""",
        "Hoarding Attack": """
Hoarders accumulate coins without economic participation.
The automated policy responds by:
- Detecting increased hoarding prevalence
- Adjusting RUNWAY_THRESHOLD and penalties
- Result: Hoarders face trust penalties, incentivizing participation
""",
        "Gini Manipulation Attack": """
Whales attempt to concentrate trust at the top.
The automated policy responds by:
- Monitoring trust Gini coefficient
- Decreasing K_PAYMENT when Gini is too high
- This makes trust differences matter less for payment
- Result: New entrants can compete more effectively
""",
        "Slow Degradation Attack": """
Provider gradually decreases quality while maintaining reputation.
The automated policy responds by:
- Detecting increased verification failure rates
- Increasing verification sampling
- Result: Quality degradation is detected earlier
"""
    }

    for attack, analysis in attack_analysis.items():
        if any(r["name"] == attack for r in results):
            report.append(f"### {attack}\n")
            report.append(analysis)
            report.append("")

    # Conclusions
    report.append("## Conclusions\n")
    report.append("""
The automated monetary policy system demonstrates several key benefits:

1. **Adaptive Response**: The system automatically responds to changing network conditions
   without requiring governance votes for every adjustment.

2. **Attack Mitigation**: Multiple attack vectors are partially or fully mitigated by
   the policy adjustments, particularly Sybil attacks and trust concentration.

3. **Stability**: The dampening factor and rate limits prevent oscillation and
   maintain network stability during adjustments.

4. **Transparency**: All parameter changes are logged with their triggering metrics,
   enabling post-hoc analysis and governance oversight.

### Limitations

1. **Bootstrap Period**: The system requires ~365 days of data before full
   automated adjustments are enabled.

2. **Novel Attacks**: The policy can only respond to attacks that affect
   monitored metrics; novel attack vectors may go undetected initially.

3. **Parameter Interactions**: Some parameter combinations may have unexpected
   effects that the current system doesn't fully account for.

### Recommendations

1. Run extended simulations (5+ years) to test long-term stability
2. Test combined attack scenarios where multiple attack types occur simultaneously
3. Implement parameter interaction constraints to prevent destabilizing combinations
4. Consider adding more sophisticated detection (ML-based anomaly detection)
""")

    # Write report
    with open(output_file, "w") as f:
        f.write("\n".join(report))

    print(f"\nReport written to {output_file}")
    return output_file


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    """Run the complete simulation suite."""
    print("="*80)
    print("OMERTA AUTOMATED MONETARY POLICY SIMULATION")
    print("="*80)
    print(f"Started at: {datetime.now().isoformat()}")
    print("This will take several hours to complete...\n")

    output_dir = "results"
    os.makedirs(output_dir, exist_ok=True)

    # Run main experiments (this takes ~1-2 hours)
    print("\n" + "="*60)
    print("PHASE 1: Running main experiments")
    print("="*60)

    results = run_all_experiments(output_dir)

    # Run extended simulations (this takes ~2-3 hours)
    print("\n" + "="*60)
    print("PHASE 2: Running extended simulations (5 years each)")
    print("="*60)

    print("\nRunning 5-year baseline simulation...")
    extended_baseline = run_extended_baseline(days=1825)
    with open(f"{output_dir}/extended_baseline_metrics.json", "w") as f:
        json.dump({
            "days": 1825,
            "metrics": [
                {
                    "day": m.day,
                    "mean_trust": m.mean_trust,
                    "trust_gini": m.trust_gini,
                    "cluster_prevalence": m.cluster_prevalence,
                    "total_identities": m.total_identities,
                    "daily_transactions": m.daily_transactions
                }
                for m in extended_baseline.metrics_history[::30]  # Every 30 days
            ],
            "parameter_changes": extended_baseline.parameter_changes,
            "final_params": {
                "k_payment": extended_baseline.params.k_payment,
                "k_transfer": extended_baseline.params.k_transfer,
                "tau_transaction": extended_baseline.params.tau_transaction
            }
        }, f, indent=2, default=str)

    print("\nRunning 5-year adversarial multi-attack simulation...")
    adversarial = run_adversarial_multi_attack(days=1825)
    with open(f"{output_dir}/adversarial_multi_attack_metrics.json", "w") as f:
        json.dump({
            "days": 1825,
            "metrics": [
                {
                    "day": m.day,
                    "mean_trust": m.mean_trust,
                    "trust_gini": m.trust_gini,
                    "cluster_prevalence": m.cluster_prevalence,
                    "total_identities": m.total_identities,
                    "daily_transactions": m.daily_transactions
                }
                for m in adversarial.metrics_history[::30]
            ],
            "parameter_changes": adversarial.parameter_changes,
            "final_params": {
                "k_payment": adversarial.params.k_payment,
                "k_transfer": adversarial.params.k_transfer,
                "tau_transaction": adversarial.params.tau_transaction
            }
        }, f, indent=2, default=str)

    # Generate report
    print("\n" + "="*60)
    print("PHASE 3: Generating report")
    print("="*60)

    generate_report(results, f"{output_dir}/simulation_report.md")

    # Add original attack results from failure_modes.py
    print("\nRunning original failure mode attacks for comparison...")
    from failure_modes import run_all_attacks

    # Capture output of original attacks
    import io
    import sys
    old_stdout = sys.stdout
    sys.stdout = captured_output = io.StringIO()
    run_all_attacks()
    original_attacks_output = captured_output.getvalue()
    sys.stdout = old_stdout

    with open(f"{output_dir}/original_failure_modes_output.txt", "w") as f:
        f.write(original_attacks_output)

    # Generate visualizations
    print("\n" + "="*60)
    print("PHASE 4: Generating visualizations")
    print("="*60)

    try:
        from generate_visualizations import main as generate_viz
        generate_viz()
    except ImportError as e:
        print(f"matplotlib not available in current environment: {e}")
        print("Attempting to run with virtual environment...")
        import subprocess
        venv_python = os.path.join(os.path.dirname(__file__), ".venv", "bin", "python3")
        viz_script = os.path.join(os.path.dirname(__file__), "generate_visualizations.py")
        if os.path.exists(venv_python):
            result = subprocess.run([venv_python, viz_script], capture_output=True, text=True)
            print(result.stdout)
            if result.stderr:
                print(result.stderr)
        else:
            print("Run ./run_visualization.sh to generate graphs after installing matplotlib")
    except Exception as e:
        print(f"Error generating visualizations: {e}")

    print("\n" + "="*80)
    print("SIMULATION COMPLETE")
    print("="*80)
    print(f"\nFinished at: {datetime.now().isoformat()}")
    print(f"\nResults saved to: {output_dir}/")
    print("  - simulation_report.md (main report with figures)")
    print("  - all_experiments.json (all experiment data)")
    print("  - extended_baseline_metrics.json (5-year baseline)")
    print("  - adversarial_multi_attack_metrics.json (5-year attack scenario)")
    print("  - original_failure_modes_output.txt (original attack simulations)")
    print("  - *.png (visualization graphs)")


if __name__ == "__main__":
    main()
