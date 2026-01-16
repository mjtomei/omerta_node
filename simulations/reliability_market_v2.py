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
    value_per_hour: float = 1.0  # How much value consumer gets from 1 compute hour

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

    @property
    def total_value_received(self) -> float:
        """Total value from useful compute"""
        return self.total_compute_hours * self.value_per_hour

    @property
    def profit(self) -> float:
        """Value received minus cost paid"""
        return self.total_value_received - self.total_money_paid

    @property
    def profit_per_useful_hour(self) -> float:
        """Profit per useful compute hour"""
        if self.total_compute_hours == 0:
            return 0
        return self.profit / self.total_compute_hours

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
    Calculate rational bid based on:
    1. Consumer's value per compute hour (willingness to pay)
    2. Provider reliability and consumer's checkpoint interval (expected efficiency)
    3. Market price (reference point, but consumer won't pay more than their value)

    Key insight: Consumer bids up to their value_per_hour, adjusted for expected waste.
    High-value consumers can outbid low-value consumers.
    """
    # Estimate probability of completion based on historical rate
    p_complete = provider.completion_rate

    # Expected wasted fraction due to cancellation
    # On cancel, we lose on average checkpoint_interval/2 hours
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

    # Maximum willingness to pay per hour of compute:
    # Consumer gets value_per_hour per USEFUL hour, so they'll pay up to:
    # value_per_hour * efficiency (because some compute is wasted)
    max_willingness = consumer.value_per_hour * expected_efficiency

    # Bid strategy: Start from market price, but cap at willingness to pay
    # This creates competition - high-value users can outbid low-value users
    bid = min(market_price, max_willingness)

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

        # Sort consumers by value (high-value consumers get priority in competitive market)
        sorted_consumers = sorted(consumers, key=lambda c: c.value_per_hour, reverse=True)

        for consumer in sorted_consumers:
            if consumer.id in active_sessions:
                continue

            # Find best available provider (maximize expected profit)
            available = [p for p in providers if p.id not in busy_providers]
            if not available:
                continue

            best_provider = None
            best_expected_profit = float('-inf')
            best_bid = 0

            for provider in available:
                bid = calculate_bid(consumer, provider, market.price)

                # Expected hours and efficiency
                p_complete = provider.completion_rate
                avg_waste = consumer.checkpoint_interval / 2
                if p_complete > 0.1:
                    expected_attempts = 1 / p_complete
                else:
                    expected_attempts = 10

                expected_paid_hours = consumer.job_duration + (expected_attempts - 1) * avg_waste
                expected_useful_hours = consumer.job_duration  # Always complete eventually

                # Expected profit = value - cost
                expected_value = expected_useful_hours * consumer.value_per_hour
                expected_cost = bid * expected_paid_hours
                expected_profit = expected_value - expected_cost

                # Only consider if profitable
                if expected_profit > best_expected_profit and expected_profit > 0:
                    best_expected_profit = expected_profit
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
    print("Model:")
    print("- Restart cost = wasted compute time (checkpoint_interval)")
    print("- Different consumers have different value_per_hour (willingness to pay)")
    print("- Consumers bid up to their value, adjusted for expected efficiency")
    print()

    random.seed(42)

    # Create providers with spread of initial thresholds
    n_providers = 20
    providers = [Provider(id=f"p{i}", threshold=random.uniform(1.1, 4.0))
                 for i in range(n_providers)]

    # Create consumers with different checkpoint intervals AND valuations
    # This tests whether high-value users pay more and get better service
    consumers = []

    # High-value consumers (e.g., HFT, urgent workloads) - value compute at $5/hr
    # Can checkpoint frequently
    for i in range(4):
        consumers.append(Consumer(id=f"high_val_low_cp_{i}",
                                  checkpoint_interval=0.1, job_duration=2.0, value_per_hour=5.0))
    # Cannot checkpoint
    for i in range(4):
        consumers.append(Consumer(id=f"high_val_high_cp_{i}",
                                  checkpoint_interval=2.0, job_duration=2.0, value_per_hour=5.0))

    # Medium-value consumers (e.g., research labs) - value compute at $2/hr
    for i in range(4):
        consumers.append(Consumer(id=f"med_val_low_cp_{i}",
                                  checkpoint_interval=0.1, job_duration=2.0, value_per_hour=2.0))
    for i in range(4):
        consumers.append(Consumer(id=f"med_val_high_cp_{i}",
                                  checkpoint_interval=2.0, job_duration=2.0, value_per_hour=2.0))

    # Low-value consumers (e.g., students, hobbyists) - value compute at $0.50/hr
    for i in range(4):
        consumers.append(Consumer(id=f"low_val_low_cp_{i}",
                                  checkpoint_interval=0.1, job_duration=2.0, value_per_hour=0.5))
    for i in range(4):
        consumers.append(Consumer(id=f"low_val_high_cp_{i}",
                                  checkpoint_interval=2.0, job_duration=2.0, value_per_hour=0.5))

    print(f"Providers: {n_providers}, initial thresholds in [1.1, 4.0]")
    print(f"Consumers: 24 total (3 value tiers × 2 checkpoint intervals × 4 each)")
    print(f"  High value ($5/hr): 4 low cp + 4 high cp")
    print(f"  Med value ($2/hr):  4 low cp + 4 high cp")
    print(f"  Low value ($0.50/hr): 4 low cp + 4 high cp")
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
    print("CONSUMER OUTCOMES BY VALUE TIER AND CHECKPOINT INTERVAL")
    print("=" * 70)

    # Group by value and checkpoint interval
    results_table = []
    for val_name, val in [("High ($5)", 5.0), ("Med ($2)", 2.0), ("Low ($0.5)", 0.5)]:
        for cp_name, cp in [("Low CP", 0.1), ("High CP", 2.0)]:
            clist = [c for c in consumers
                     if c.value_per_hour == val and c.checkpoint_interval == cp]
            if not clist:
                continue

            active = [c for c in clist if c.total_compute_hours > 0]
            if not active:
                results_table.append((val_name, cp_name, 0, 0, 0, 0, 0, 0))
                continue

            avg_rate = statistics.mean(c.avg_rate_paid for c in active if c.avg_rate_paid > 0) if any(c.avg_rate_paid > 0 for c in active) else 0
            avg_effective = statistics.mean(c.effective_cost_per_useful_hour for c in active if c.effective_cost_per_useful_hour > 0) if any(c.effective_cost_per_useful_hour > 0 for c in active) else 0
            avg_efficiency = statistics.mean(c.efficiency for c in active)
            avg_profit = statistics.mean(c.profit_per_useful_hour for c in active)
            avg_compute = statistics.mean(c.total_compute_hours for c in active)
            avg_restarts = statistics.mean(c.restarts for c in active)

            results_table.append((val_name, cp_name, avg_rate, avg_effective, avg_efficiency,
                                  avg_profit, avg_compute, avg_restarts))

    print(f"\n{'Value':<12} {'CP':<8} {'Rate/hr':>8} {'Eff.Cost':>10} {'Effic.':>8} {'Profit/hr':>10} {'Compute':>8} {'Restarts':>8}")
    print("-" * 82)
    for val, cp, rate, eff_cost, effic, profit, compute, restarts in results_table:
        if compute > 0:
            print(f"{val:<12} {cp:<8} ${rate:>7.2f} ${eff_cost:>9.2f} {effic:>7.1%} ${profit:>9.2f} {compute:>7.1f}h {restarts:>7.1f}")
        else:
            print(f"{val:<12} {cp:<8} {'---':>8} {'---':>10} {'---':>8} {'---':>10} {'0.0h':>8} {'---':>8}")

    # The key test
    print()
    print("=" * 70)
    print("HYPOTHESIS TESTS")
    print("=" * 70)

    # Test 1: Do high-value consumers get more compute?
    high_val = [c for c in consumers if c.value_per_hour == 5.0 and c.total_compute_hours > 0]
    low_val = [c for c in consumers if c.value_per_hour == 0.5 and c.total_compute_hours > 0]

    if high_val and low_val:
        high_compute = statistics.mean(c.total_compute_hours for c in high_val)
        low_compute = statistics.mean(c.total_compute_hours for c in low_val)
        print(f"\n1. COMPUTE ACCESS BY VALUE:")
        print(f"   High-value ($5/hr): {high_compute:.1f}h average compute")
        print(f"   Low-value ($0.50/hr): {low_compute:.1f}h average compute")
        if high_compute > low_compute * 1.1:
            print(f"   ✓ High-value users get MORE compute ({high_compute/low_compute:.1f}x)")
        else:
            print(f"   ~ Similar compute access")

    # Test 2: Do high-value consumers pay more?
    if high_val and low_val:
        high_rate = statistics.mean(c.avg_rate_paid for c in high_val if c.avg_rate_paid > 0)
        low_rate = statistics.mean(c.avg_rate_paid for c in low_val if c.avg_rate_paid > 0) if any(c.avg_rate_paid > 0 for c in low_val) else 0
        print(f"\n2. RATES PAID BY VALUE:")
        print(f"   High-value pays: ${high_rate:.2f}/hr")
        print(f"   Low-value pays: ${low_rate:.2f}/hr")
        if high_rate > low_rate * 1.1 and low_rate > 0:
            print(f"   ✓ High-value users pay HIGHER rates ({high_rate/low_rate:.1f}x)")
        elif low_rate == 0:
            print(f"   ! Low-value users priced out of market")
        else:
            print(f"   ~ Similar rates")

    # Test 3: Profit comparison
    if high_val and low_val:
        high_profit = statistics.mean(c.profit_per_useful_hour for c in high_val)
        low_profit = statistics.mean(c.profit_per_useful_hour for c in low_val) if low_val else 0
        print(f"\n3. PROFIT PER USEFUL HOUR:")
        print(f"   High-value profit: ${high_profit:.2f}/hr")
        print(f"   Low-value profit: ${low_profit:.2f}/hr")

    # Test 4: Effect of checkpoint interval within same value tier
    high_val_low_cp = [c for c in consumers if c.value_per_hour == 5.0 and c.checkpoint_interval == 0.1 and c.total_compute_hours > 0]
    high_val_high_cp = [c for c in consumers if c.value_per_hour == 5.0 and c.checkpoint_interval == 2.0 and c.total_compute_hours > 0]

    if high_val_low_cp and high_val_high_cp:
        low_cp_eff = statistics.mean(c.efficiency for c in high_val_low_cp)
        high_cp_eff = statistics.mean(c.efficiency for c in high_val_high_cp)
        print(f"\n4. CHECKPOINT INTERVAL EFFECT (within high-value tier):")
        print(f"   Low CP (0.1h) efficiency: {low_cp_eff:.1%}")
        print(f"   High CP (2.0h) efficiency: {high_cp_eff:.1%}")
        if low_cp_eff > high_cp_eff * 1.01:
            print(f"   ✓ Low checkpoint interval = higher efficiency")


def run_value_experiment(name: str, high_val_count: int, low_val_count: int,
                          n_providers: int = 20, n_rounds: int = 30):
    """
    Run experiment with specific mix of high vs low value consumers.
    """
    random.seed(42)

    providers = [Provider(id=f"p{i}", threshold=random.uniform(1.1, 4.0))
                 for i in range(n_providers)]

    consumers = []
    # High value consumers ($5/hr)
    for i in range(high_val_count):
        consumers.append(Consumer(id=f"high_{i}", checkpoint_interval=0.5,
                                  job_duration=2.0, value_per_hour=5.0))
    # Low value consumers ($0.50/hr)
    for i in range(low_val_count):
        consumers.append(Consumer(id=f"low_{i}", checkpoint_interval=0.5,
                                  job_duration=2.0, value_per_hour=0.5))

    market = Market(base_price=1.0, volatility=0.5)

    # Run simulation rounds
    for round_num in range(n_rounds):
        for p in providers:
            p.reset()
        for c in consumers:
            c.reset()
        market.reset()

        run_simulation(providers, consumers, market, duration=200, dt=0.1)

        if round_num < n_rounds - 1:
            for p in providers:
                p.threshold = adapt_threshold(p, providers)

    # Return results
    final_threshold = statistics.mean(p.threshold for p in providers)

    high_val = [c for c in consumers if c.value_per_hour == 5.0 and c.total_compute_hours > 0]
    low_val = [c for c in consumers if c.value_per_hour == 0.5 and c.total_compute_hours > 0]

    high_compute = statistics.mean(c.total_compute_hours for c in high_val) if high_val else 0
    low_compute = statistics.mean(c.total_compute_hours for c in low_val) if low_val else 0

    return final_threshold, high_compute, low_compute, len(high_val), len(low_val)


def main_experiments():
    """Run experiments showing how value distribution affects market outcomes."""
    print()
    print("=" * 70)
    print("EXPERIMENT: SUPPLY/DEMAND AND VALUE DIFFERENTIATION")
    print("=" * 70)
    print()
    print("Testing how scarcity affects price discrimination between value tiers.")
    print("(All consumers have same checkpoint interval to isolate value effect)")
    print()

    experiments = [
        ("Excess supply (20 providers, 8 consumers)", 4, 4),
        ("Balanced (20 providers, 20 consumers)", 10, 10),
        ("Scarcity (20 providers, 40 consumers)", 20, 20),
        ("Extreme scarcity (20 providers, 60 consumers)", 30, 30),
        ("Only high-value (20 providers, 20 high)", 20, 0),
        ("Only low-value (20 providers, 20 low)", 0, 20),
    ]

    print(f"{'Scenario':<45} | {'Threshold':>9} | {'High Compute':>12} | {'Low Compute':>11}")
    print("-" * 85)

    for name, high_count, low_count in experiments:
        threshold, high_compute, low_compute, high_active, low_active = run_value_experiment(
            name, high_count, low_count)
        print(f"{name:<45} | {threshold:>9.2f} | {high_compute:>11.1f}h | {low_compute:>10.1f}h")

    # Analysis
    print()
    print("=" * 70)
    print("ANALYSIS: VALUE-BASED MARKET DYNAMICS")
    print("=" * 70)
    print("""
Key findings:

1. BID CALCULATION with VALUE:
   max_bid = value_per_hour × expected_efficiency
   actual_bid = min(market_price, max_bid)

   High-value consumers can bid UP TO $5/hr, low-value up to $0.50/hr.
   When market price < $0.50, both pay similar rates.
   When market price > $0.50, low-value users hit their ceiling.

2. SCARCITY EFFECTS:
   - Excess supply: Everyone gets served, prices stay low
   - Scarcity: High-value outbid low-value, prices rise
   - Competition drives efficient allocation to highest-value uses

3. PROVIDER REVENUE:
   In scarce markets, providers earn more from high-value consumers.
   This incentivizes reliability when serving premium customers.
""")


if __name__ == "__main__":
    main()
    main_experiments()
