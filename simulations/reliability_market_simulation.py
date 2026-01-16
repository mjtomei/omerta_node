#!/usr/bin/env python3
"""
Reliability Market Simulation

Tests hypothesis: Rational consumers will price provider reliability differently
based on their restart costs and checkpointing granularity.

Unreliable providers (who cancel for small price increases) should receive
lower bids from rational consumers to compensate for expected restart costs.
"""

import random
import math
from dataclasses import dataclass, field
from typing import Optional
import json
import statistics


@dataclass
class Provider:
    """A compute provider with a reliability profile."""
    id: str
    cancellation_threshold: float  # Ratio at which they cancel (e.g., 1.5 = cancels if new bid is 1.5x current)
    base_price: float  # Minimum price they'll accept

    # Tracked metrics
    sessions_completed: int = 0
    sessions_cancelled: int = 0
    total_earnings: float = 0
    termination_events: list = field(default_factory=list)

    @property
    def completion_rate(self) -> float:
        total = self.sessions_completed + self.sessions_cancelled
        return self.sessions_completed / total if total > 0 else 1.0

    def would_cancel(self, current_rate: float, new_rate: float) -> bool:
        """Would this provider cancel current session for new rate?"""
        if new_rate / current_rate >= self.cancellation_threshold:
            return True
        return False


@dataclass
class Consumer:
    """A compute consumer with specific workload characteristics."""
    id: str
    restart_cost: float  # Cost in $ to restart a cancelled job
    checkpoint_interval: float  # Hours between checkpoints (work lost on cancel)
    job_duration: float  # Total job duration in hours

    # Tracked metrics
    jobs_completed: int = 0
    jobs_restarted: int = 0
    total_spent: float = 0
    total_compute_hours: float = 0
    total_wasted_hours: float = 0

    @property
    def effective_cost_per_hour(self) -> float:
        if self.total_compute_hours == 0:
            return 0
        return self.total_spent / self.total_compute_hours


@dataclass
class Session:
    """An active compute session."""
    provider: Provider
    consumer: Consumer
    rate: float
    start_time: float
    expected_duration: float
    checkpoint_interval: float

    # State
    elapsed: float = 0
    last_checkpoint: float = 0
    completed: bool = False
    cancelled: bool = False


class Market:
    """Simulates a compute market with price fluctuations."""

    def __init__(self, base_price: float = 1.0, volatility: float = 0.3):
        self.base_price = base_price
        self.volatility = volatility
        self.current_price = base_price
        self.time = 0
        self.price_history: list[tuple[float, float]] = []

    def step(self, dt: float = 0.1):
        """Advance market time and update price."""
        self.time += dt
        # Random walk with mean reversion
        drift = 0.1 * (self.base_price - self.current_price)
        shock = random.gauss(0, self.volatility * math.sqrt(dt))
        self.current_price = max(0.1, self.current_price + drift + shock)
        self.price_history.append((self.time, self.current_price))

    def get_competing_bid(self) -> float:
        """Get a new bid that might arrive (based on current market price)."""
        # New bids cluster around current market price with some variance
        return max(0.1, random.gauss(self.current_price, self.current_price * 0.2))


class Simulation:
    """Main simulation engine."""

    def __init__(self, providers: list[Provider], consumers: list[Consumer],
                 market: Market, strategy: str = "rational"):
        self.providers = {p.id: p for p in providers}
        self.consumers = {c.id: c for c in consumers}
        self.market = market
        self.strategy = strategy  # "rational" or "naive"
        self.active_sessions: list[Session] = []
        self.completed_sessions: list[Session] = []

    def calculate_rational_bid(self, consumer: Consumer, provider: Provider,
                               job_duration: float) -> float:
        """
        Calculate rational bid based on provider reliability and consumer's costs.

        Key insight: Lower reliability should result in lower bid to compensate
        for expected restart costs.
        """
        base_rate = self.market.current_price

        # Estimate cancellation probability based on provider's threshold
        # and market volatility
        # If provider cancels at threshold T, and market has volatility V,
        # estimate P(market rises to T * current_rate during job)

        threshold = provider.cancellation_threshold
        job_hours = job_duration

        # Simplified model: P(cancellation) based on historical completion rate
        # and job duration
        completion_rate = provider.completion_rate

        # Longer jobs = more chances for price spike = higher cancel risk
        # Model: P(complete) = completion_rate ^ (job_hours / mean_job_hours)
        mean_job_hours = 2.0
        p_complete = completion_rate ** (job_hours / mean_job_hours)
        p_cancel = 1 - p_complete

        # Expected cost of cancellation
        # Average work lost = checkpoint_interval / 2
        avg_work_lost = consumer.checkpoint_interval / 2
        cancel_cost = consumer.restart_cost + avg_work_lost * base_rate

        # Expected total cost at base rate
        expected_cost_at_base = (
            base_rate * job_hours +  # Compute cost
            p_cancel * cancel_cost    # Expected restart costs
        )

        # For reliable provider (p_cancel ≈ 0), willing to pay base_rate
        # For unreliable provider, need discount to achieve same expected cost

        # Solve for bid B such that:
        # B * job_hours + p_cancel * cancel_cost = expected_cost_reliable
        # where expected_cost_reliable = base_rate * job_hours (for 100% reliable)

        expected_cost_reliable = base_rate * job_hours

        # B = (expected_cost_reliable - p_cancel * cancel_cost) / job_hours
        rational_bid = (expected_cost_reliable - p_cancel * cancel_cost) / job_hours

        # Floor at some minimum
        rational_bid = max(rational_bid, base_rate * 0.3)

        return rational_bid

    def calculate_naive_bid(self, consumer: Consumer, provider: Provider,
                           job_duration: float) -> float:
        """Naive strategy: just bid market rate regardless of reliability."""
        return self.market.current_price

    def get_busy_providers(self) -> set:
        """Get set of provider IDs that are currently busy."""
        return {s.provider.id for s in self.active_sessions}

    def select_provider(self, consumer: Consumer, job_duration: float) -> tuple[Provider, float]:
        """Select best available provider and calculate bid."""
        best_provider = None
        best_expected_cost = float('inf')
        best_bid = 0

        busy_providers = self.get_busy_providers()

        # Shuffle to avoid always picking first provider
        available_providers = [p for p in self.providers.values() if p.id not in busy_providers]
        random.shuffle(available_providers)

        for provider in available_providers:
            if self.strategy == "rational":
                bid = self.calculate_rational_bid(consumer, provider, job_duration)
            else:
                bid = self.calculate_naive_bid(consumer, provider, job_duration)

            # Check if provider would accept this bid
            if bid < provider.base_price:
                continue

            # Calculate expected cost with this provider
            completion_rate = provider.completion_rate
            mean_job_hours = 2.0
            p_complete = completion_rate ** (job_duration / mean_job_hours)
            p_cancel = 1 - p_complete

            avg_work_lost = consumer.checkpoint_interval / 2
            cancel_cost = consumer.restart_cost + avg_work_lost * bid

            expected_cost = bid * job_duration + p_cancel * cancel_cost

            if expected_cost < best_expected_cost:
                best_expected_cost = expected_cost
                best_provider = provider
                best_bid = bid

        return best_provider, best_bid

    def start_session(self, consumer: Consumer) -> Optional[Session]:
        """Start a new session for consumer."""
        provider, bid = self.select_provider(consumer, consumer.job_duration)

        if provider is None:
            return None

        session = Session(
            provider=provider,
            consumer=consumer,
            rate=bid,
            start_time=self.market.time,
            expected_duration=consumer.job_duration,
            checkpoint_interval=consumer.checkpoint_interval
        )

        self.active_sessions.append(session)
        return session

    def process_sessions(self, dt: float):
        """Process active sessions - check for completions and cancellations."""
        completed = []

        for session in self.active_sessions:
            session.elapsed += dt

            # Update checkpoint
            while session.last_checkpoint + session.checkpoint_interval <= session.elapsed:
                session.last_checkpoint += session.checkpoint_interval

            # Check for completion
            if session.elapsed >= session.expected_duration:
                session.completed = True
                completed.append(session)

                # Update metrics
                session.provider.sessions_completed += 1
                session.provider.total_earnings += session.rate * session.expected_duration

                session.consumer.jobs_completed += 1
                session.consumer.total_spent += session.rate * session.expected_duration
                session.consumer.total_compute_hours += session.expected_duration
                continue

            # Check for cancellation (competing bid arrives)
            if random.random() < 0.1 * dt:  # 10% chance per hour of competing bid
                competing_bid = self.market.get_competing_bid()

                if session.provider.would_cancel(session.rate, competing_bid):
                    session.cancelled = True
                    completed.append(session)

                    # Record termination event
                    session.provider.termination_events.append({
                        'cancelled_rate': session.rate,
                        'usurping_rate': competing_bid,
                        'time_fraction': session.elapsed / session.expected_duration
                    })

                    # Update metrics
                    session.provider.sessions_cancelled += 1
                    session.provider.total_earnings += session.rate * session.elapsed

                    # Consumer pays for elapsed time but loses work since last checkpoint
                    work_lost = session.elapsed - session.last_checkpoint
                    session.consumer.total_spent += session.rate * session.elapsed
                    session.consumer.total_wasted_hours += work_lost
                    session.consumer.jobs_restarted += 1

                    # Consumer needs to restart - will be handled in main loop

        for session in completed:
            self.active_sessions.remove(session)
            self.completed_sessions.append(session)

    def run(self, duration: float = 100, dt: float = 0.1):
        """Run simulation for specified duration."""

        # Queue of consumers waiting for jobs
        job_queue = []

        # Initially all consumers need jobs
        for consumer in self.consumers.values():
            job_queue.append(consumer)

        while self.market.time < duration:
            self.market.step(dt)
            self.process_sessions(dt)

            # Check for consumers who need new sessions (completed or cancelled)
            for consumer in list(self.consumers.values()):
                # Check if consumer has active session
                has_active = any(s.consumer.id == consumer.id for s in self.active_sessions)

                if not has_active and consumer not in job_queue:
                    job_queue.append(consumer)

            # Start new sessions for queued consumers
            for consumer in list(job_queue):
                session = self.start_session(consumer)
                if session:
                    job_queue.remove(consumer)


def run_experiment(strategy: str, n_iterations: int = 5) -> dict:
    """Run experiment with given strategy."""

    results = {
        'strategy': strategy,
        'iterations': [],
        'provider_stats': {},
        'consumer_stats': {}
    }

    for iteration in range(n_iterations):
        # Create multiple providers of each reliability type
        # Each provider can only handle one job at a time
        providers = []
        for i in range(5):
            providers.append(Provider(id=f"reliable_{i}", cancellation_threshold=3.0, base_price=0.5))
            providers.append(Provider(id=f"moderate_{i}", cancellation_threshold=1.8, base_price=0.5))
            providers.append(Provider(id=f"unreliable_{i}", cancellation_threshold=1.3, base_price=0.5))

        # Create more consumers to drive competition
        consumers = []
        for i in range(5):
            consumers.append(Consumer(id=f"low_cost_{i}", restart_cost=0.5, checkpoint_interval=0.5, job_duration=2.0))
            consumers.append(Consumer(id=f"med_cost_{i}", restart_cost=2.0, checkpoint_interval=1.0, job_duration=2.0))
            consumers.append(Consumer(id=f"high_cost_{i}", restart_cost=5.0, checkpoint_interval=2.0, job_duration=2.0))

        market = Market(base_price=1.0, volatility=0.4)

        sim = Simulation(providers, consumers, market, strategy=strategy)
        sim.run(duration=500, dt=0.1)

        # Collect results - aggregate by provider type
        iteration_results = {
            'providers': {'reliable': [], 'moderate': [], 'unreliable': []},
            'consumers': {'low_cost': [], 'med_cost': [], 'high_cost': []}
        }

        for p in providers:
            # Determine provider type from id
            if p.id.startswith('reliable'):
                ptype = 'reliable'
            elif p.id.startswith('moderate'):
                ptype = 'moderate'
            else:
                ptype = 'unreliable'

            total_sessions = p.sessions_completed + p.sessions_cancelled
            if total_sessions > 0:
                avg_rate = p.total_earnings / (total_sessions * 2.0)  # Divide by avg job duration
            else:
                avg_rate = 0

            iteration_results['providers'][ptype].append({
                'completion_rate': p.completion_rate,
                'total_earnings': p.total_earnings,
                'sessions_completed': p.sessions_completed,
                'sessions_cancelled': p.sessions_cancelled,
                'avg_rate_received': avg_rate
            })

        for c in consumers:
            # Determine consumer type from id
            if c.id.startswith('low_cost'):
                ctype = 'low_cost'
            elif c.id.startswith('med_cost'):
                ctype = 'med_cost'
            else:
                ctype = 'high_cost'

            iteration_results['consumers'][ctype].append({
                'jobs_completed': c.jobs_completed,
                'jobs_restarted': c.jobs_restarted,
                'total_spent': c.total_spent,
                'total_compute_hours': c.total_compute_hours,
                'total_wasted_hours': c.total_wasted_hours,
                'effective_cost_per_hour': c.effective_cost_per_hour
            })

        results['iterations'].append(iteration_results)

    # Aggregate across iterations
    for p_type in ['reliable', 'moderate', 'unreliable']:
        all_rates = []
        all_completions = []
        all_sessions = []
        for it in results['iterations']:
            for p_data in it['providers'][p_type]:
                if p_data['sessions_completed'] + p_data['sessions_cancelled'] > 0:
                    all_rates.append(p_data['avg_rate_received'])
                    all_completions.append(p_data['completion_rate'])
                    all_sessions.append(p_data['sessions_completed'] + p_data['sessions_cancelled'])

        results['provider_stats'][p_type] = {
            'mean_rate': statistics.mean(all_rates) if all_rates else 0,
            'std_rate': statistics.stdev(all_rates) if len(all_rates) > 1 else 0,
            'mean_completion_rate': statistics.mean(all_completions) if all_completions else 1.0,
            'total_sessions': sum(all_sessions)
        }

    for c_type in ['low_cost', 'med_cost', 'high_cost']:
        all_costs = []
        all_restarts = []
        for it in results['iterations']:
            for c_data in it['consumers'][c_type]:
                if c_data['total_compute_hours'] > 0:
                    all_costs.append(c_data['effective_cost_per_hour'])
                all_restarts.append(c_data['jobs_restarted'])

        results['consumer_stats'][c_type] = {
            'mean_effective_cost': statistics.mean(all_costs) if all_costs else 0,
            'std_effective_cost': statistics.stdev(all_costs) if len(all_costs) > 1 else 0,
            'mean_restarts': statistics.mean(all_restarts) if all_restarts else 0
        }

    return results


def main():
    print("=" * 70)
    print("RELIABILITY MARKET SIMULATION")
    print("=" * 70)
    print()
    print("Hypothesis: Rational consumers will bid less for unreliable providers")
    print("            to compensate for expected restart costs.")
    print()
    print("Providers:")
    print("  - Reliable:   cancels only if new bid >= 3.0x current rate")
    print("  - Moderate:   cancels if new bid >= 1.8x current rate")
    print("  - Unreliable: cancels if new bid >= 1.3x current rate")
    print()
    print("Consumers:")
    print("  - Low restart cost:  $0.50 restart, 0.5hr checkpoint interval")
    print("  - Med restart cost:  $2.00 restart, 1.0hr checkpoint interval")
    print("  - High restart cost: $5.00 restart, 2.0hr checkpoint interval")
    print()

    # Run with naive strategy
    print("-" * 70)
    print("NAIVE STRATEGY (bid market rate regardless of reliability)")
    print("-" * 70)
    naive_results = run_experiment("naive", n_iterations=10)

    print("\nProvider Results (Naive):")
    print(f"  {'Provider':<15} {'Completion Rate':>18} {'Avg Rate Received':>18}")
    print(f"  {'-'*15} {'-'*18} {'-'*18}")
    for p_id in ['reliable', 'moderate', 'unreliable']:
        stats = naive_results['provider_stats'][p_id]
        print(f"  {p_id:<15} {stats['mean_completion_rate']:>17.1%} ${stats['mean_rate']:>17.3f}")

    print("\nConsumer Results (Naive):")
    print(f"  {'Consumer':<15} {'Effective $/hr':>15} {'Avg Restarts':>15}")
    print(f"  {'-'*15} {'-'*15} {'-'*15}")
    for c_id in ['low_cost', 'med_cost', 'high_cost']:
        stats = naive_results['consumer_stats'][c_id]
        print(f"  {c_id:<15} ${stats['mean_effective_cost']:>14.3f} {stats['mean_restarts']:>15.1f}")

    # Run with rational strategy
    print()
    print("-" * 70)
    print("RATIONAL STRATEGY (bid based on reliability and restart costs)")
    print("-" * 70)
    rational_results = run_experiment("rational", n_iterations=10)

    print("\nProvider Results (Rational):")
    print(f"  {'Provider':<15} {'Completion Rate':>18} {'Avg Rate Received':>18}")
    print(f"  {'-'*15} {'-'*18} {'-'*18}")
    for p_id in ['reliable', 'moderate', 'unreliable']:
        stats = rational_results['provider_stats'][p_id]
        print(f"  {p_id:<15} {stats['mean_completion_rate']:>17.1%} ${stats['mean_rate']:>17.3f}")

    print("\nConsumer Results (Rational):")
    print(f"  {'Consumer':<15} {'Effective $/hr':>15} {'Avg Restarts':>15}")
    print(f"  {'-'*15} {'-'*15} {'-'*15}")
    for c_id in ['low_cost', 'med_cost', 'high_cost']:
        stats = rational_results['consumer_stats'][c_id]
        print(f"  {c_id:<15} ${stats['mean_effective_cost']:>14.3f} {stats['mean_restarts']:>15.1f}")

    # Comparison
    print()
    print("=" * 70)
    print("COMPARISON: NAIVE vs RATIONAL")
    print("=" * 70)

    print("\nRate Differential (Reliable - Unreliable):")
    naive_diff = (naive_results['provider_stats']['reliable']['mean_rate'] -
                  naive_results['provider_stats']['unreliable']['mean_rate'])
    rational_diff = (rational_results['provider_stats']['reliable']['mean_rate'] -
                     rational_results['provider_stats']['unreliable']['mean_rate'])
    print(f"  Naive strategy:    ${naive_diff:+.3f}")
    print(f"  Rational strategy: ${rational_diff:+.3f}")

    print("\nEffective Cost Improvement (Naive - Rational):")
    for c_id in ['low_cost', 'med_cost', 'high_cost']:
        naive_cost = naive_results['consumer_stats'][c_id]['mean_effective_cost']
        rational_cost = rational_results['consumer_stats'][c_id]['mean_effective_cost']
        improvement = naive_cost - rational_cost
        pct = (improvement / naive_cost * 100) if naive_cost > 0 else 0
        print(f"  {c_id:<15}: ${improvement:+.3f} ({pct:+.1f}%)")

    print()
    print("=" * 70)
    print("HYPOTHESIS TEST")
    print("=" * 70)

    reliable_rate = rational_results['provider_stats']['reliable']['mean_rate']
    unreliable_rate = rational_results['provider_stats']['unreliable']['mean_rate']

    if unreliable_rate > 0 and reliable_rate > unreliable_rate * 1.05:
        print("\n✓ CONFIRMED: Reliable providers receive higher rates under rational bidding")
        print(f"  Reliable: ${reliable_rate:.3f}/hr")
        print(f"  Unreliable: ${unreliable_rate:.3f}/hr")
        print(f"  Premium for reliability: {(reliable_rate/unreliable_rate - 1)*100:.1f}%")
    elif unreliable_rate == 0:
        print("\n? INCONCLUSIVE: Unreliable providers received no jobs")
        print(f"  Reliable: ${reliable_rate:.3f}/hr")
        print(f"  Unreliable: ${unreliable_rate:.3f}/hr (no data)")
    else:
        print("\n✗ NOT CONFIRMED: Rate differential not significant")
        print(f"  Reliable: ${reliable_rate:.3f}/hr")
        print(f"  Unreliable: ${unreliable_rate:.3f}/hr")

    # Save results
    all_results = {
        'naive': naive_results,
        'rational': rational_results
    }

    with open('${OMERTA_DIR}/simulations/reliability_market_results.json', 'w') as f:
        json.dump(all_results, f, indent=2, default=str)

    print("\nResults saved to reliability_market_results.json")


if __name__ == "__main__":
    random.seed(42)  # For reproducibility
    main()
