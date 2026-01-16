#!/usr/bin/env python3
"""
Reliability Market Equilibrium Simulation

Iterative simulation where:
- Consumers bid rationally based on provider reliability
- Providers adjust cancellation thresholds to maximize earnings
- Market converges to equilibrium

Key questions:
1. What cancellation threshold maximizes provider earnings?
2. Do low restart cost consumers benefit from cheap unreliable compute?
3. Where does the market equilibrium end up?
"""

import random
import math
from dataclasses import dataclass, field
from typing import Optional
import json
import statistics
from copy import deepcopy


@dataclass
class Provider:
    """A compute provider with adaptive reliability."""
    id: str
    cancellation_threshold: float  # Ratio at which they cancel
    base_price: float  # Minimum price they'll accept

    # Tracked metrics
    sessions_completed: int = 0
    sessions_cancelled: int = 0
    total_earnings: float = 0
    total_hours_worked: float = 0
    termination_events: list = field(default_factory=list)

    # History for adaptation
    earnings_history: list = field(default_factory=list)
    threshold_history: list = field(default_factory=list)

    @property
    def completion_rate(self) -> float:
        total = self.sessions_completed + self.sessions_cancelled
        return self.sessions_completed / total if total > 0 else 1.0

    @property
    def hourly_earnings(self) -> float:
        return self.total_earnings / self.total_hours_worked if self.total_hours_worked > 0 else 0

    def would_cancel(self, current_rate: float, new_rate: float) -> bool:
        """Would this provider cancel current session for new rate?"""
        return new_rate / current_rate >= self.cancellation_threshold

    def reset_metrics(self):
        """Reset metrics for new round."""
        self.sessions_completed = 0
        self.sessions_cancelled = 0
        self.total_earnings = 0
        self.total_hours_worked = 0
        self.termination_events = []


@dataclass
class Consumer:
    """A compute consumer with specific workload characteristics."""
    id: str
    restart_cost: float  # Cost in $ to restart a cancelled job
    checkpoint_interval: float  # Hours between checkpoints
    job_duration: float  # Total job duration in hours

    # Tracked metrics
    jobs_completed: int = 0
    jobs_restarted: int = 0
    total_spent: float = 0
    total_compute_hours: float = 0
    total_wasted_hours: float = 0

    # Track which providers they used
    provider_usage: dict = field(default_factory=dict)
    thresholds_used: list = field(default_factory=list)

    @property
    def effective_cost_per_hour(self) -> float:
        if self.total_compute_hours == 0:
            return 0
        return self.total_spent / self.total_compute_hours

    def reset_metrics(self):
        """Reset metrics for new round."""
        self.jobs_completed = 0
        self.jobs_restarted = 0
        self.total_spent = 0
        self.total_compute_hours = 0
        self.total_wasted_hours = 0
        self.provider_usage = {}
        self.thresholds_used = []


@dataclass
class Session:
    """An active compute session."""
    provider: Provider
    consumer: Consumer
    rate: float
    start_time: float
    expected_duration: float
    checkpoint_interval: float
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

    def step(self, dt: float = 0.1):
        """Advance market time and update price."""
        self.time += dt
        drift = 0.1 * (self.base_price - self.current_price)
        shock = random.gauss(0, self.volatility * math.sqrt(dt))
        self.current_price = max(0.1, self.current_price + drift + shock)

    def get_competing_bid(self) -> float:
        """Get a new bid that might arrive."""
        return max(0.1, random.gauss(self.current_price, self.current_price * 0.2))

    def reset(self):
        self.current_price = self.base_price
        self.time = 0


class Simulation:
    """Main simulation engine."""

    def __init__(self, providers: list[Provider], consumers: list[Consumer], market: Market):
        self.providers = {p.id: p for p in providers}
        self.consumers = {c.id: c for c in consumers}
        self.market = market
        self.active_sessions: list[Session] = []
        self.completed_sessions: list[Session] = []

    def calculate_rational_bid(self, consumer: Consumer, provider: Provider,
                               job_duration: float) -> float:
        """Calculate rational bid based on provider reliability and consumer's costs."""
        base_rate = self.market.current_price

        completion_rate = provider.completion_rate
        mean_job_hours = 2.0
        p_complete = completion_rate ** (job_duration / mean_job_hours)
        p_cancel = 1 - p_complete

        avg_work_lost = consumer.checkpoint_interval / 2
        cancel_cost = consumer.restart_cost + avg_work_lost * base_rate

        expected_cost_reliable = base_rate * job_duration
        rational_bid = (expected_cost_reliable - p_cancel * cancel_cost) / job_duration
        rational_bid = max(rational_bid, base_rate * 0.3)

        return rational_bid

    def get_busy_providers(self) -> set:
        return {s.provider.id for s in self.active_sessions}

    def select_provider(self, consumer: Consumer, job_duration: float) -> tuple[Provider, float]:
        """Select best available provider."""
        best_provider = None
        best_expected_cost = float('inf')
        best_bid = 0

        busy_providers = self.get_busy_providers()
        available_providers = [p for p in self.providers.values() if p.id not in busy_providers]
        random.shuffle(available_providers)

        for provider in available_providers:
            bid = self.calculate_rational_bid(consumer, provider, job_duration)

            if bid < provider.base_price:
                continue

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
        """Process active sessions."""
        completed = []

        for session in self.active_sessions:
            session.elapsed += dt

            while session.last_checkpoint + session.checkpoint_interval <= session.elapsed:
                session.last_checkpoint += session.checkpoint_interval

            if session.elapsed >= session.expected_duration:
                session.completed = True
                completed.append(session)

                session.provider.sessions_completed += 1
                session.provider.total_earnings += session.rate * session.expected_duration
                session.provider.total_hours_worked += session.expected_duration

                session.consumer.jobs_completed += 1
                session.consumer.total_spent += session.rate * session.expected_duration
                session.consumer.total_compute_hours += session.expected_duration

                # Track provider usage by threshold
                threshold = session.provider.cancellation_threshold
                ptype = self.get_provider_type(session.provider.id)
                session.consumer.provider_usage[ptype] = session.consumer.provider_usage.get(ptype, 0) + 1

                # Track actual threshold used
                if 'thresholds_used' not in session.consumer.__dict__:
                    session.consumer.thresholds_used = []
                session.consumer.thresholds_used.append(threshold)
                continue

            if random.random() < 0.15 * dt:  # 15% chance per hour of competing bid
                competing_bid = self.market.get_competing_bid()

                if session.provider.would_cancel(session.rate, competing_bid):
                    session.cancelled = True
                    completed.append(session)

                    session.provider.termination_events.append({
                        'cancelled_rate': session.rate,
                        'usurping_rate': competing_bid,
                        'time_fraction': session.elapsed / session.expected_duration
                    })

                    session.provider.sessions_cancelled += 1
                    session.provider.total_earnings += session.rate * session.elapsed
                    session.provider.total_hours_worked += session.elapsed

                    work_lost = session.elapsed - session.last_checkpoint
                    session.consumer.total_spent += session.rate * session.elapsed
                    session.consumer.total_wasted_hours += work_lost
                    session.consumer.jobs_restarted += 1

        for session in completed:
            self.active_sessions.remove(session)
            self.completed_sessions.append(session)

    def get_provider_type(self, provider_id: str) -> str:
        """Classify provider by current threshold."""
        provider = self.providers[provider_id]
        threshold = provider.cancellation_threshold
        if threshold >= 2.5:
            return 'reliable'
        elif threshold >= 1.7:
            return 'moderate'
        else:
            return 'unreliable'

    def get_provider_threshold(self, provider_id: str) -> float:
        """Get provider's current threshold."""
        return self.providers[provider_id].cancellation_threshold

    def run(self, duration: float = 100, dt: float = 0.1):
        """Run simulation for specified duration."""
        job_queue = list(self.consumers.values())

        while self.market.time < duration:
            self.market.step(dt)
            self.process_sessions(dt)

            for consumer in list(self.consumers.values()):
                has_active = any(s.consumer.id == consumer.id for s in self.active_sessions)
                if not has_active and consumer not in job_queue:
                    job_queue.append(consumer)

            for consumer in list(job_queue):
                session = self.start_session(consumer)
                if session:
                    job_queue.remove(consumer)


def adapt_provider_threshold(provider: Provider, all_providers: list[Provider],
                             learning_rate: float = 0.1) -> float:
    """
    Adapt provider's cancellation threshold based on relative performance.

    Strategy: Move toward thresholds of better-performing providers.
    """
    if provider.total_hours_worked == 0:
        return provider.cancellation_threshold

    my_hourly = provider.hourly_earnings

    # Find providers doing better
    better_providers = [p for p in all_providers
                       if p.total_hours_worked > 0 and p.hourly_earnings > my_hourly]

    if not better_providers:
        # I'm doing best - small random exploration
        delta = random.gauss(0, 0.1)
        new_threshold = provider.cancellation_threshold + delta
    else:
        # Move toward average threshold of better performers
        better_avg_threshold = statistics.mean([p.cancellation_threshold for p in better_providers])
        delta = learning_rate * (better_avg_threshold - provider.cancellation_threshold)
        # Add some noise for exploration
        delta += random.gauss(0, 0.05)
        new_threshold = provider.cancellation_threshold + delta

    # Clamp to reasonable range
    new_threshold = max(1.1, min(5.0, new_threshold))

    return new_threshold


def run_equilibrium_simulation(n_rounds: int = 20, round_duration: float = 200):
    """Run iterative simulation until equilibrium."""

    print("=" * 70)
    print("RELIABILITY MARKET EQUILIBRIUM SIMULATION")
    print("=" * 70)
    print()
    print("Providers adapt their cancellation thresholds to maximize earnings.")
    print("Consumers bid rationally based on observed reliability.")
    print()

    # Initialize providers with varied thresholds - wider range for differentiation
    n_providers = 20
    providers = []
    for i in range(n_providers):
        # Start with random thresholds between 1.1 and 4.0
        threshold = random.uniform(1.1, 4.0)
        providers.append(Provider(
            id=f"provider_{i}",
            cancellation_threshold=threshold,
            base_price=0.5
        ))

    # Create consumers with different profiles
    consumers = []
    # Low restart cost (should prefer cheap unreliable)
    for i in range(5):
        consumers.append(Consumer(
            id=f"low_cost_{i}",
            restart_cost=0.2,
            checkpoint_interval=0.25,
            job_duration=2.0
        ))
    # Medium restart cost
    for i in range(5):
        consumers.append(Consumer(
            id=f"med_cost_{i}",
            restart_cost=1.0,
            checkpoint_interval=0.5,
            job_duration=2.0
        ))
    # High restart cost (should prefer reliable)
    for i in range(5):
        consumers.append(Consumer(
            id=f"high_cost_{i}",
            restart_cost=3.0,
            checkpoint_interval=1.0,
            job_duration=2.0
        ))

    # Track history
    round_results = []

    print(f"Starting with {n_providers} providers, random thresholds in [1.2, 3.0]")
    print(f"Running {n_rounds} rounds of {round_duration} time units each")
    print()

    for round_num in range(n_rounds):
        # Reset metrics for new round
        for p in providers:
            p.reset_metrics()
        for c in consumers:
            c.reset_metrics()

        market = Market(base_price=1.0, volatility=0.6)  # Higher volatility = more price spikes
        sim = Simulation(providers, consumers, market)
        sim.run(duration=round_duration, dt=0.1)

        # Collect round statistics
        round_stats = {
            'round': round_num,
            'providers': [],
            'consumers': {'low_cost': [], 'med_cost': [], 'high_cost': []}
        }

        for p in providers:
            round_stats['providers'].append({
                'id': p.id,
                'threshold': p.cancellation_threshold,
                'completion_rate': p.completion_rate,
                'hourly_earnings': p.hourly_earnings,
                'total_sessions': p.sessions_completed + p.sessions_cancelled
            })
            p.earnings_history.append(p.hourly_earnings)
            p.threshold_history.append(p.cancellation_threshold)

        for c in consumers:
            ctype = 'low_cost' if 'low' in c.id else ('med_cost' if 'med' in c.id else 'high_cost')
            round_stats['consumers'][ctype].append({
                'effective_cost': c.effective_cost_per_hour,
                'restarts': c.jobs_restarted,
                'provider_usage': c.provider_usage.copy()
            })

        round_results.append(round_stats)

        # Print round summary
        thresholds = [p.cancellation_threshold for p in providers]
        earnings = [p.hourly_earnings for p in providers if p.total_hours_worked > 0]

        if round_num % 5 == 0 or round_num == n_rounds - 1:
            print(f"Round {round_num:2d}: Thresholds [{min(thresholds):.2f} - {max(thresholds):.2f}], "
                  f"mean={statistics.mean(thresholds):.2f}, "
                  f"Earnings: ${statistics.mean(earnings):.3f}/hr" if earnings else "")

        # Adapt provider thresholds (except last round)
        if round_num < n_rounds - 1:
            for p in providers:
                p.cancellation_threshold = adapt_provider_threshold(p, providers)

    # Final analysis
    print()
    print("=" * 70)
    print("FINAL EQUILIBRIUM ANALYSIS")
    print("=" * 70)

    # Group providers by final threshold
    final_thresholds = [(p.id, p.cancellation_threshold, p.hourly_earnings, p.completion_rate)
                        for p in providers]
    final_thresholds.sort(key=lambda x: x[1])

    print("\nProvider Final States (sorted by threshold):")
    print(f"  {'ID':<12} {'Threshold':>10} {'$/hr':>10} {'Completion':>12}")
    print(f"  {'-'*12} {'-'*10} {'-'*10} {'-'*12}")
    for pid, thresh, earnings, comp in final_thresholds:
        print(f"  {pid:<12} {thresh:>10.2f} ${earnings:>9.3f} {comp:>11.1%}")

    # Threshold distribution
    thresholds = [p.cancellation_threshold for p in providers]
    print(f"\nThreshold Distribution:")
    print(f"  Min: {min(thresholds):.2f}")
    print(f"  Max: {max(thresholds):.2f}")
    print(f"  Mean: {statistics.mean(thresholds):.2f}")
    print(f"  Std: {statistics.stdev(thresholds):.2f}")

    # Correlation between threshold and earnings
    earnings = [p.hourly_earnings for p in providers]
    if len(set(thresholds)) > 1 and len(set(earnings)) > 1:
        # Simple correlation
        mean_t = statistics.mean(thresholds)
        mean_e = statistics.mean(earnings)
        numerator = sum((t - mean_t) * (e - mean_e) for t, e in zip(thresholds, earnings))
        denom_t = math.sqrt(sum((t - mean_t)**2 for t in thresholds))
        denom_e = math.sqrt(sum((e - mean_e)**2 for e in earnings))
        if denom_t > 0 and denom_e > 0:
            correlation = numerator / (denom_t * denom_e)
            print(f"\nCorrelation (threshold vs earnings): {correlation:.3f}")

    # Consumer analysis - use actual consumer objects for threshold data
    print()
    print("=" * 70)
    print("CONSUMER OUTCOMES")
    print("=" * 70)

    consumer_results = {'low_cost': [], 'med_cost': [], 'high_cost': []}
    for c in consumers:
        ctype = 'low_cost' if 'low' in c.id else ('med_cost' if 'med' in c.id else 'high_cost')
        consumer_results[ctype].append(c)

    for ctype in ['low_cost', 'med_cost', 'high_cost']:
        clist = consumer_results[ctype]
        costs = [c.effective_cost_per_hour for c in clist if c.effective_cost_per_hour > 0]
        restarts = [c.jobs_restarted for c in clist]

        # Get actual thresholds used
        all_thresholds = []
        for c in clist:
            all_thresholds.extend(c.thresholds_used)

        # Aggregate provider usage
        usage = {}
        for c in clist:
            for ptype, count in c.provider_usage.items():
                usage[ptype] = usage.get(ptype, 0) + count

        print(f"\n{ctype.upper()} consumers (restart_cost=${clist[0].restart_cost:.2f}):")
        print(f"  Effective cost: ${statistics.mean(costs):.3f}/hr" if costs else "  No data")
        print(f"  Avg restarts: {statistics.mean(restarts):.1f}")
        print(f"  Provider usage: {usage}")
        if all_thresholds:
            print(f"  Avg threshold used: {statistics.mean(all_thresholds):.2f}")
            print(f"  Threshold range: [{min(all_thresholds):.2f} - {max(all_thresholds):.2f}]")

    # Check if low-cost consumers use more unreliable providers
    print()
    print("=" * 70)
    print("HYPOTHESIS TESTS")
    print("=" * 70)

    # Calculate average threshold used by each consumer type
    print("\nDo different consumer types choose different providers?")
    avg_thresholds = {}
    for ctype in ['low_cost', 'med_cost', 'high_cost']:
        clist = consumer_results[ctype]
        all_thresholds = []
        for c in clist:
            all_thresholds.extend(c.thresholds_used)
        if all_thresholds:
            avg_thresholds[ctype] = statistics.mean(all_thresholds)

    if len(avg_thresholds) == 3:
        low_thresh = avg_thresholds['low_cost']
        high_thresh = avg_thresholds['high_cost']
        if high_thresh > low_thresh:
            print(f"\n✓ CONFIRMED: High restart cost consumers choose MORE reliable providers")
            print(f"  Low cost avg threshold: {low_thresh:.3f}")
            print(f"  High cost avg threshold: {high_thresh:.3f}")
            print(f"  Difference: {high_thresh - low_thresh:.3f}")
        else:
            print(f"\n✗ NOT CONFIRMED: No clear differentiation")
            print(f"  Low cost avg threshold: {low_thresh:.3f}")
            print(f"  High cost avg threshold: {high_thresh:.3f}")

    # Provider convergence check
    print("\nProvider Threshold Convergence:")
    initial_thresholds = [r['threshold'] for r in round_results[0]['providers']]
    final_thresholds_list = [r['threshold'] for r in round_results[-1]['providers']]
    initial_std = statistics.stdev(initial_thresholds)
    final_std = statistics.stdev(final_thresholds_list)
    print(f"  Initial std: {initial_std:.3f}")
    print(f"  Final std: {final_std:.3f}")
    if final_std < initial_std:
        print(f"  → Providers CONVERGING (std reduced by {(1-final_std/initial_std)*100:.1f}%)")
    else:
        print(f"  → Providers DIVERGING or stable")

    # Optimal threshold analysis
    print("\nOptimal Threshold Analysis:")
    # Group providers into bins and compare earnings
    bins = [(1.0, 1.5), (1.5, 2.0), (2.0, 2.5), (2.5, 3.0), (3.0, 5.0)]
    for low, high in bins:
        providers_in_bin = [p for p in providers if low <= p.cancellation_threshold < high]
        if providers_in_bin:
            avg_earnings = statistics.mean([p.hourly_earnings for p in providers_in_bin])
            avg_completion = statistics.mean([p.completion_rate for p in providers_in_bin])
            print(f"  Threshold [{low:.1f}-{high:.1f}): {len(providers_in_bin)} providers, "
                  f"${avg_earnings:.3f}/hr, {avg_completion:.1%} completion")

    # Save results
    with open('${OMERTA_DIR}/simulations/reliability_equilibrium_results.json', 'w') as f:
        json.dump({
            'rounds': round_results,
            'final_providers': [{'id': p.id, 'threshold': p.cancellation_threshold,
                                'earnings': p.hourly_earnings, 'completion': p.completion_rate}
                               for p in providers]
        }, f, indent=2, default=str)

    print("\nResults saved to reliability_equilibrium_results.json")

    return providers, consumers, round_results


if __name__ == "__main__":
    random.seed(42)
    run_equilibrium_simulation(n_rounds=30, round_duration=300)
