#!/usr/bin/env python3
"""
Reliability Market Simulation v2

Fixed model:
- Restart cost = wasted compute time (not separate $ penalty)
- Low checkpoint interval = low restart cost = can use unreliable providers cheaply
- Test whether providers converge to single optimal threshold
"""

import random
import math
from dataclasses import dataclass, field
import statistics


@dataclass
class Provider:
    id: str
    threshold: float  # Cancel if new_bid >= threshold * current_bid

    sessions_completed: int = 0
    sessions_cancelled: int = 0
    total_earnings: float = 0
    total_hours: float = 0

    @property
    def completion_rate(self) -> float:
        total = self.sessions_completed + self.sessions_cancelled
        return self.sessions_completed / total if total > 0 else 1.0

    @property
    def hourly_rate(self) -> float:
        return self.total_earnings / self.total_hours if self.total_hours > 0 else 0

    def reset(self):
        self.sessions_completed = 0
        self.sessions_cancelled = 0
        self.total_earnings = 0
        self.total_hours = 0


@dataclass
class Consumer:
    id: str
    checkpoint_interval: float  # Hours between checkpoints - THIS IS THE RESTART COST
    job_duration: float

    total_compute_hours: float = 0  # Useful work done
    total_hours_paid: float = 0     # Total hours paid for (including wasted)
    total_money_paid: float = 0     # Total $ spent
    jobs_completed: int = 0
    restarts: int = 0
    rates_paid: list = field(default_factory=list)
    thresholds_used: list = field(default_factory=list)

    @property
    def avg_rate_paid(self) -> float:
        """Average hourly rate we paid"""
        if self.total_hours_paid == 0:
            return 0
        return self.total_money_paid / self.total_hours_paid

    @property
    def effective_cost_per_useful_hour(self) -> float:
        """What we actually paid per USEFUL compute hour (includes waste)"""
        if self.total_compute_hours == 0:
            return 0
        return self.total_money_paid / self.total_compute_hours

    @property
    def efficiency(self) -> float:
        """Fraction of paid compute that was useful"""
        if self.total_hours_paid == 0:
            return 1.0
        return self.total_compute_hours / self.total_hours_paid

    def reset(self):
        self.total_compute_hours = 0
        self.total_hours_paid = 0
        self.total_money_paid = 0
        self.jobs_completed = 0
        self.restarts = 0
        self.rates_paid = []
        self.thresholds_used = []


class Market:
    def __init__(self, base_price: float = 1.0, volatility: float = 0.5):
        self.base_price = base_price
        self.volatility = volatility
        self.price = base_price
        self.time = 0

    def step(self, dt: float):
        self.time += dt
        # Mean-reverting random walk
        drift = 0.2 * (self.base_price - self.price) * dt
        noise = random.gauss(0, self.volatility * math.sqrt(dt))
        self.price = max(0.2, self.price + drift + noise)

    def reset(self):
        self.price = self.base_price
        self.time = 0


def calculate_bid(consumer: Consumer, provider: Provider, market_price: float) -> float:
    """
    Calculate rational bid based on provider reliability and consumer's checkpoint interval.

    Key insight: Consumer's "restart cost" is purely the wasted compute time.
    If checkpoint_interval is small, little work is lost on cancel, so unreliable is OK.
    """
    # Estimate probability of completion based on historical rate
    p_complete = provider.completion_rate

    # Expected wasted fraction due to cancellation
    # On cancel, we lose on average checkpoint_interval/2 hours
    # Plus we have to redo from last checkpoint
    avg_waste_per_cancel = consumer.checkpoint_interval / 2

    # Expected number of attempts to complete job
    # Geometric distribution: E[attempts] = 1/p_complete
    if p_complete > 0.1:
        expected_attempts = 1 / p_complete
    else:
        expected_attempts = 10  # Cap for very unreliable

    # Expected total hours paid = job_duration + (attempts-1) * avg_waste_per_cancel
    expected_hours_paid = consumer.job_duration + (expected_attempts - 1) * avg_waste_per_cancel

    # Efficiency = useful_hours / paid_hours
    expected_efficiency = consumer.job_duration / expected_hours_paid

    # Bid: We want to pay market_price per USEFUL hour
    # So we bid: market_price * efficiency (lower bid for unreliable provider)
    bid = market_price * expected_efficiency

    return max(bid, 0.1)  # Floor


def run_simulation(providers: list[Provider], consumers: list[Consumer],
                   market: Market, duration: float = 100, dt: float = 0.1):
    """Run one round of simulation."""

    active_sessions = {}  # consumer_id -> (provider, rate, start_time, elapsed, last_checkpoint)

    while market.time < duration:
        market.step(dt)

        # Process active sessions
        to_complete = []
        to_cancel = []

        for cid, (provider, rate, start, elapsed, last_cp) in active_sessions.items():
            consumer = next(c for c in consumers if c.id == cid)
            elapsed += dt

            # Update checkpoint
            while last_cp + consumer.checkpoint_interval <= elapsed:
                last_cp += consumer.checkpoint_interval

            # Check completion
            if elapsed >= consumer.job_duration:
                to_complete.append((cid, provider, rate, elapsed))
            else:
                # Check for competing bid that causes cancellation
                if random.random() < 0.2 * dt:  # 20% per hour chance of competing bid
                    competing = market.price * random.uniform(0.8, 1.5)
                    if competing >= rate * provider.threshold:
                        # Provider cancels!
                        work_lost = elapsed - last_cp
                        to_cancel.append((cid, provider, rate, elapsed, work_lost))
                    else:
                        active_sessions[cid] = (provider, rate, start, elapsed, last_cp)
                else:
                    active_sessions[cid] = (provider, rate, start, elapsed, last_cp)

        # Process completions
        for cid, provider, rate, elapsed in to_complete:
            consumer = next(c for c in consumers if c.id == cid)

            provider.sessions_completed += 1
            provider.total_earnings += rate * consumer.job_duration
            provider.total_hours += consumer.job_duration

            consumer.jobs_completed += 1
            consumer.total_compute_hours += consumer.job_duration
            consumer.total_hours_paid += elapsed  # May include partial work from restarts
            consumer.total_money_paid += rate * elapsed
            consumer.rates_paid.append(rate)
            consumer.thresholds_used.append(provider.threshold)

            del active_sessions[cid]

        # Process cancellations
        for cid, provider, rate, elapsed, work_lost in to_cancel:
            consumer = next(c for c in consumers if c.id == cid)

            provider.sessions_cancelled += 1
            provider.total_earnings += rate * elapsed
            provider.total_hours += elapsed

            consumer.restarts += 1
            consumer.total_hours_paid += elapsed
            consumer.total_money_paid += rate * elapsed
            # Useful work = elapsed - work_lost (work since last checkpoint is lost)
            consumer.total_compute_hours += (elapsed - work_lost)

            del active_sessions[cid]

        # Start new sessions for idle consumers
        busy_providers = {s[0].id for s in active_sessions.values()}

        for consumer in consumers:
            if consumer.id in active_sessions:
                continue

            # Find best available provider
            available = [p for p in providers if p.id not in busy_providers]
            if not available:
                continue

            best_provider = None
            best_expected_cost = float('inf')
            best_bid = 0

            for provider in available:
                bid = calculate_bid(consumer, provider, market.price)

                # Expected cost per useful hour
                p_complete = provider.completion_rate
                avg_waste = consumer.checkpoint_interval / 2
                if p_complete > 0.1:
                    expected_attempts = 1 / p_complete
                else:
                    expected_attempts = 10

                expected_paid = consumer.job_duration + (expected_attempts - 1) * avg_waste
                expected_cost = bid * expected_paid / consumer.job_duration

                if expected_cost < best_expected_cost:
                    best_expected_cost = expected_cost
                    best_provider = provider
                    best_bid = bid

            if best_provider:
                active_sessions[consumer.id] = (best_provider, best_bid, market.time, 0, 0)
                busy_providers.add(best_provider.id)


def adapt_threshold(provider: Provider, all_providers: list[Provider], lr: float = 0.2) -> float:
    """Adapt threshold toward better-performing providers."""
    if provider.total_hours == 0:
        return provider.threshold

    my_rate = provider.hourly_rate

    # Find providers doing better
    better = [p for p in all_providers if p.total_hours > 0 and p.hourly_rate > my_rate * 1.01]

    if better:
        # Move toward their average threshold
        target = statistics.mean(p.threshold for p in better)
        delta = lr * (target - provider.threshold)
    else:
        # I'm best - random exploration
        delta = random.gauss(0, 0.05)

    new_threshold = provider.threshold + delta
    return max(1.05, min(5.0, new_threshold))


def main():
    print("=" * 70)
    print("RELIABILITY MARKET SIMULATION v2")
    print("=" * 70)
    print()
    print("Restart cost = wasted compute time (checkpoint_interval)")
    print("Low checkpoint_interval = can checkpoint frequently = low restart cost")
    print()

    random.seed(42)

    # Create providers with spread of initial thresholds
    n_providers = 20
    providers = [Provider(id=f"p{i}", threshold=random.uniform(1.1, 4.0))
                 for i in range(n_providers)]

    # Create consumers with different checkpoint intervals (restart costs)
    # More extreme differences to test if market segmentation can exist
    consumers = []
    # Very frequent checkpointers - very low restart cost (can restart almost for free)
    for i in range(6):
        consumers.append(Consumer(id=f"low_{i}", checkpoint_interval=0.05, job_duration=2.0))
    # Medium checkpointers
    for i in range(6):
        consumers.append(Consumer(id=f"med_{i}", checkpoint_interval=0.5, job_duration=2.0))
    # Cannot checkpoint - entire job lost on restart (extreme high restart cost)
    for i in range(6):
        consumers.append(Consumer(id=f"high_{i}", checkpoint_interval=2.0, job_duration=2.0))

    print(f"Providers: {n_providers}, initial thresholds in [1.1, 4.0]")
    print(f"Consumers: 6 very low restart cost (cp=0.05h), 6 medium (cp=0.5h), 6 extreme (cp=2.0h=full job)")
    print()

    n_rounds = 50
    market = Market(base_price=1.0, volatility=0.5)

    threshold_history = {p.id: [p.threshold] for p in providers}

    print("Round | Threshold Range | Mean±Std | Best Rate | Worst Rate")
    print("-" * 65)

    for round_num in range(n_rounds):
        # Reset for new round
        for p in providers:
            p.reset()
        for c in consumers:
            c.reset()
        market.reset()

        # Run simulation
        run_simulation(providers, consumers, market, duration=200, dt=0.1)

        # Collect stats
        thresholds = [p.threshold for p in providers]
        rates = [p.hourly_rate for p in providers if p.total_hours > 0]

        if round_num % 10 == 0 or round_num == n_rounds - 1:
            print(f"{round_num:5d} | [{min(thresholds):.2f} - {max(thresholds):.2f}] | "
                  f"{statistics.mean(thresholds):.2f}±{statistics.stdev(thresholds):.2f} | "
                  f"${max(rates):.3f} | ${min(rates):.3f}")

        # Record history
        for p in providers:
            threshold_history[p.id].append(p.threshold)

        # Adapt thresholds
        if round_num < n_rounds - 1:
            for p in providers:
                p.threshold = adapt_threshold(p, providers)

    # Final analysis
    print()
    print("=" * 70)
    print("FINAL EQUILIBRIUM")
    print("=" * 70)

    final_thresholds = sorted([(p.threshold, p.hourly_rate) for p in providers])

    print(f"\nFinal threshold distribution:")
    print(f"  Min: {min(t for t,r in final_thresholds):.3f}")
    print(f"  Max: {max(t for t,r in final_thresholds):.3f}")
    print(f"  Mean: {statistics.mean(t for t,r in final_thresholds):.3f}")
    print(f"  Std: {statistics.stdev(t for t,r in final_thresholds):.3f}")

    # Check convergence
    initial_std = statistics.stdev(threshold_history[p.id][0] for p in providers)
    final_std = statistics.stdev(p.threshold for p in providers)

    print(f"\nConvergence:")
    print(f"  Initial std: {initial_std:.3f}")
    print(f"  Final std: {final_std:.3f}")

    if final_std < 0.1:
        converged_to = statistics.mean(p.threshold for p in providers)
        print(f"  ✓ CONVERGED to threshold ≈ {converged_to:.2f}")
    elif final_std < initial_std * 0.3:
        print(f"  ~ CONVERGING but not fully ({(1-final_std/initial_std)*100:.0f}% reduction)")
    else:
        print(f"  ✗ NOT CONVERGING")

    # Consumer outcomes
    print()
    print("=" * 70)
    print("CONSUMER OUTCOMES")
    print("=" * 70)

    for ctype, cp_interval in [("LOW (cp=0.05h)", 0.05), ("MED (cp=0.5h)", 0.5), ("HIGH (cp=2.0h)", 2.0)]:
        clist = [c for c in consumers if c.checkpoint_interval == cp_interval]

        avg_rate = statistics.mean(c.avg_rate_paid for c in clist if c.avg_rate_paid > 0)
        avg_effective = statistics.mean(c.effective_cost_per_useful_hour for c in clist if c.effective_cost_per_useful_hour > 0)
        avg_efficiency = statistics.mean(c.efficiency for c in clist)
        avg_restarts = statistics.mean(c.restarts for c in clist)
        avg_threshold = statistics.mean(
            statistics.mean(c.thresholds_used) for c in clist if c.thresholds_used
        )

        print(f"\n{ctype}:")
        print(f"  Hourly rate paid: ${avg_rate:.3f}/hr")
        print(f"  Effective cost:   ${avg_effective:.3f}/useful_hr  (rate/efficiency)")
        print(f"  Efficiency: {avg_efficiency:.1%} (useful/paid)")
        print(f"  Avg restarts: {avg_restarts:.1f}")
        print(f"  Avg provider threshold: {avg_threshold:.2f}")

    # The key test
    print()
    print("=" * 70)
    print("HYPOTHESIS TEST")
    print("=" * 70)

    low_cost = [c for c in consumers if c.checkpoint_interval == 0.05]
    high_cost = [c for c in consumers if c.checkpoint_interval == 2.0]

    low_rate = statistics.mean(c.effective_rate for c in low_cost if c.effective_rate > 0)
    high_rate = statistics.mean(c.effective_rate for c in high_cost if c.effective_rate > 0)

    low_thresh = statistics.mean(statistics.mean(c.thresholds_used) for c in low_cost if c.thresholds_used)
    high_thresh = statistics.mean(statistics.mean(c.thresholds_used) for c in high_cost if c.thresholds_used)

    print(f"\nLow restart cost consumers:")
    print(f"  Pay: ${low_rate:.3f}/hr, use providers with threshold {low_thresh:.2f}")
    print(f"\nHigh restart cost consumers:")
    print(f"  Pay: ${high_rate:.3f}/hr, use providers with threshold {high_thresh:.2f}")

    if low_rate < high_rate - 0.01:
        print(f"\n✓ CONFIRMED: Low restart cost users pay LESS (${low_rate:.3f} vs ${high_rate:.3f})")
    else:
        print(f"\n✗ NOT CONFIRMED: Low restart cost users don't pay less")

    if low_thresh < high_thresh - 0.05:
        print(f"✓ CONFIRMED: Low restart cost users choose LESS reliable providers ({low_thresh:.2f} vs {high_thresh:.2f})")
    else:
        print(f"✗ NOT CONFIRMED: No provider differentiation by consumer type")


if __name__ == "__main__":
    main()
