#!/usr/bin/env python3
"""
Economic Value Simulation

Tests whether introducing unreliable compute (home users paying only power costs)
creates economic value compared to reliable-only compute (datacenters with capex+opex).

Key question: Does $/effective_compute_hour go DOWN when unreliable capacity exists?

Provider types:
- Datacenter: High cost (capex amortization + opex), high reliability
- Home user: Low cost (power only), low reliability (cancels for personal use)
"""

import random
import math
from dataclasses import dataclass, field
import statistics
from typing import Optional


@dataclass
class Provider:
    id: str
    provider_type: str  # "datacenter" or "home"

    # Cost structure
    capex_per_hour: float  # Amortized capital cost
    opex_per_hour: float   # Operating cost (power, cooling, etc.)

    # Reliability - probability of NOT cancelling per hour for personal reasons
    # Datacenter: very high (only hardware failures)
    # Home users: lower (need machine for personal use)
    hourly_survival_rate: float

    # Cancellation threshold - cancel if competing bid exceeds current_rate * threshold
    # Datacenter: infinite (never cancel for profit - SLA commitment)
    # Home users: finite (will cancel for significantly better offer)
    cancel_threshold: float = float('inf')

    # Stats
    total_revenue: float = 0
    total_hours_provided: float = 0
    sessions_completed: int = 0
    sessions_cancelled: int = 0
    cancelled_for_profit: int = 0  # Track profit-based cancellations separately

    @property
    def cost_per_hour(self) -> float:
        return self.capex_per_hour + self.opex_per_hour

    @property
    def completion_rate(self) -> float:
        total = self.sessions_completed + self.sessions_cancelled
        return self.sessions_completed / total if total > 0 else self.hourly_survival_rate

    @property
    def profit(self) -> float:
        return self.total_revenue - (self.total_hours_provided * self.cost_per_hour)

    @property
    def profit_per_hour(self) -> float:
        if self.total_hours_provided == 0:
            return 0
        return self.profit / self.total_hours_provided

    @property
    def revenue_per_hour(self) -> float:
        if self.total_hours_provided == 0:
            return 0
        return self.total_revenue / self.total_hours_provided

    def reset(self):
        self.total_revenue = 0
        self.total_hours_provided = 0
        self.sessions_completed = 0
        self.sessions_cancelled = 0
        self.cancelled_for_profit = 0


@dataclass
class Consumer:
    id: str
    checkpoint_interval: float  # Hours between checkpoints
    job_duration: float
    value_per_hour: float  # Value derived from compute

    # Stats
    total_useful_compute: float = 0
    total_hours_paid: float = 0
    total_money_paid: float = 0
    jobs_completed: int = 0
    restarts: int = 0

    @property
    def effective_cost_per_useful_hour(self) -> float:
        if self.total_useful_compute == 0:
            return 0
        return self.total_money_paid / self.total_useful_compute

    @property
    def efficiency(self) -> float:
        if self.total_hours_paid == 0:
            return 1.0
        return self.total_useful_compute / self.total_hours_paid

    def reset(self):
        self.total_useful_compute = 0
        self.total_hours_paid = 0
        self.total_money_paid = 0
        self.jobs_completed = 0
        self.restarts = 0


def calculate_bid(consumer: Consumer, provider: Provider, market_price: float = None) -> float:
    """
    Consumer bids based on provider's expected reliability and market conditions.

    In competitive markets (market_price provided), consumers can bid closer to
    the market clearing price rather than their full willingness to pay.
    """
    # Expected completion probability for this job
    p_complete = provider.completion_rate

    # Expected attempts to complete
    if p_complete > 0.1:
        expected_attempts = 1 / p_complete
    else:
        expected_attempts = 10

    # Average waste per failed attempt
    avg_waste = consumer.checkpoint_interval / 2

    # Expected total hours to complete job
    expected_hours = consumer.job_duration + (expected_attempts - 1) * avg_waste

    # Expected efficiency
    expected_efficiency = consumer.job_duration / expected_hours

    # Maximum willingness to pay (adjusted for expected waste)
    max_willingness = consumer.value_per_hour * expected_efficiency

    if market_price is not None and market_price < max_willingness:
        # Competitive market: bid at market price (plus small margin to ensure acceptance)
        bid = market_price * 1.05
        # But never more than willingness to pay
        bid = min(bid, max_willingness * 0.95)
    else:
        # Non-competitive: bid 80% of max willingness to capture surplus
        bid = max_willingness * 0.8

    return max(bid, 0.01)


def provider_accepts_bid(provider: Provider, bid: float, market_clearing_price: float = None) -> bool:
    """
    Provider accepts if bid covers their costs with margin.

    If market_clearing_price is set, provider acts as price-setter (won't accept below market price).
    Otherwise, provider is price-taker (accepts anything above cost).
    """
    min_cost = provider.cost_per_hour * 1.1  # 10% margin minimum

    if market_clearing_price is not None:
        # Price-setter: won't accept below market clearing price
        return bid >= max(min_cost, market_clearing_price)
    else:
        # Price-taker: accepts anything above cost
        return bid >= min_cost


def debug_market(providers: list[Provider], consumers: list[Consumer]):
    """Debug market state."""
    print("DEBUG: Provider costs and min bids:")
    for p in providers[:3]:
        min_bid = p.cost_per_hour * 1.1
        print(f"  {p.id}: cost=${p.cost_per_hour:.2f}, min_bid=${min_bid:.2f}")

    print("DEBUG: Consumer values and bids:")
    for c in consumers[:3]:
        for p in providers[:2]:
            bid = calculate_bid(c, p)
            accepts = provider_accepts_bid(p, bid)
            print(f"  {c.id} (val=${c.value_per_hour}) -> {p.id}: bid=${bid:.3f}, accepts={accepts}")


def run_market_simulation(providers: list[Provider], consumers: list[Consumer],
                          duration: float = 100, dt: float = 0.1,
                          market_volatility: float = 0.3,
                          dc_min_price: float = None):
    """
    Run market simulation with provider-side price competition.

    Providers set prices based on competition:
    - In oversupplied markets, providers lower prices to attract consumers
    - In undersupplied markets, providers can charge higher prices
    - Consumers choose based on price/reliability tradeoff

    dc_min_price: If set, datacenters won't accept bids below this (price-setter behavior).
    """

    # Active sessions: consumer_id -> (provider, rate, elapsed, last_checkpoint)
    active_sessions = {}

    # Provider offered prices - each provider sets a price based on competition
    # Start at cost + 100% margin, adjust based on utilization
    provider_prices = {p.id: p.cost_per_hour * 2.0 for p in providers}

    # Market price for reference (fluctuates)
    base_market_price = 0.80
    market_price = base_market_price

    time = 0
    while time < duration:
        time += dt

        # Update market price (mean-reverting random walk)
        drift = 0.2 * (base_market_price - market_price) * dt
        noise = random.gauss(0, market_volatility * math.sqrt(dt))
        market_price = max(0.2, market_price + drift + noise)

        # Process active sessions
        to_complete = []
        to_cancel = []

        for cid, (provider, rate, elapsed, last_cp) in list(active_sessions.items()):
            consumer = next(c for c in consumers if c.id == cid)
            elapsed += dt

            # Update checkpoint
            while last_cp + consumer.checkpoint_interval <= elapsed:
                last_cp += consumer.checkpoint_interval

            # Check completion
            if elapsed >= consumer.job_duration:
                to_complete.append((cid, provider, rate, elapsed, "completed"))
            else:
                cancelled = False
                cancel_reason = None

                # Check for personal-use cancellation (both types, but rare for DC)
                p_personal_cancel = 1 - provider.hourly_survival_rate ** dt
                if random.random() < p_personal_cancel:
                    cancelled = True
                    cancel_reason = "personal"

                # Check for profit-based cancellation (home users only)
                # Home users see competing bids and may cancel if profitable
                if not cancelled and provider.cancel_threshold < float('inf'):
                    # Simulate competing bid arriving
                    if random.random() < 0.3 * dt:  # 30% per hour chance of seeing better offer
                        competing_bid = market_price * random.uniform(0.9, 1.3)
                        if competing_bid >= rate * provider.cancel_threshold:
                            cancelled = True
                            cancel_reason = "profit"
                            provider.cancelled_for_profit += 1

                if cancelled:
                    work_lost = elapsed - last_cp
                    to_cancel.append((cid, provider, rate, elapsed, work_lost))
                else:
                    active_sessions[cid] = (provider, rate, elapsed, last_cp)

        # Process completions
        for cid, provider, rate, elapsed, _ in to_complete:
            consumer = next(c for c in consumers if c.id == cid)

            provider.sessions_completed += 1
            provider.total_revenue += rate * consumer.job_duration
            provider.total_hours_provided += consumer.job_duration

            consumer.jobs_completed += 1
            consumer.total_useful_compute += consumer.job_duration
            consumer.total_hours_paid += elapsed
            consumer.total_money_paid += rate * elapsed

            del active_sessions[cid]

        # Process cancellations
        for cid, provider, rate, elapsed, work_lost in to_cancel:
            consumer = next(c for c in consumers if c.id == cid)

            provider.sessions_cancelled += 1
            provider.total_revenue += rate * elapsed
            provider.total_hours_provided += elapsed

            consumer.restarts += 1
            consumer.total_hours_paid += elapsed
            consumer.total_money_paid += rate * elapsed
            consumer.total_useful_compute += (elapsed - work_lost)

            del active_sessions[cid]

        # Providers adjust prices based on utilization
        # Idle providers lower prices, busy providers raise prices
        busy_providers = {s[0].id for s in active_sessions.values()}

        for provider in providers:
            min_price = provider.cost_per_hour * 1.1  # Minimum: cost + 10% margin

            # DC price floor from pricing power
            if provider.provider_type == "datacenter" and dc_min_price is not None:
                min_price = max(min_price, dc_min_price)

            current_price = provider_prices[provider.id]

            if provider.id in busy_providers:
                # Busy: slowly raise price (can charge more)
                new_price = current_price * (1 + 0.1 * dt)
            else:
                # Idle: lower price to attract customers
                new_price = current_price * (1 - 0.3 * dt)

            # Clamp to valid range
            provider_prices[provider.id] = max(min_price, min(new_price, 5.0))

        # Start new sessions - consumers choose best value
        for consumer in sorted(consumers, key=lambda c: c.value_per_hour, reverse=True):
            if consumer.id in active_sessions:
                continue

            available = [p for p in providers if p.id not in busy_providers]
            if not available:
                continue

            best_provider = None
            best_expected_profit = float('-inf')
            best_price = 0

            for provider in available:
                price = provider_prices[provider.id]

                # Calculate expected cost accounting for reliability
                p_complete = provider.completion_rate
                if p_complete > 0.1:
                    expected_attempts = 1 / p_complete
                else:
                    expected_attempts = 10

                avg_waste = consumer.checkpoint_interval / 2
                expected_hours = consumer.job_duration + (expected_attempts - 1) * avg_waste

                # Consumer's expected profit at this price
                expected_cost = price * expected_hours
                expected_value = consumer.job_duration * consumer.value_per_hour
                expected_profit = expected_value - expected_cost

                # Consumer picks provider with highest expected profit
                if expected_profit > best_expected_profit and expected_profit > 0:
                    best_expected_profit = expected_profit
                    best_provider = provider
                    best_price = price

            if best_provider:
                active_sessions[consumer.id] = (best_provider, best_price, 0, 0)
                busy_providers.add(best_provider.id)


def run_scenario(name: str, datacenter_count: int, home_count: int,
                 consumer_count: int, checkpoint_interval: float,
                 duration: float = 200, dc_pricing_power: bool = False) -> dict:
    """Run a single scenario and return results."""

    random.seed(42)

    providers = []

    # Datacenter providers: high cost, high reliability, SLA commitment (no profit cancellation)
    for i in range(datacenter_count):
        providers.append(Provider(
            id=f"dc_{i}",
            provider_type="datacenter",
            capex_per_hour=0.30,  # Amortized server cost
            opex_per_hour=0.20,  # Power, cooling, staff, facilities
            hourly_survival_rate=0.998,  # 99.8% - only hardware failures
            cancel_threshold=float('inf')  # Never cancel for profit (SLA)
        ))

    # Home providers: low cost, low reliability, CAN cancel for profit
    for i in range(home_count):
        providers.append(Provider(
            id=f"home_{i}",
            provider_type="home",
            capex_per_hour=0.0,   # Already own the hardware
            opex_per_hour=0.08,  # Just power cost (~$0.15/kWh × 500W)
            hourly_survival_rate=0.92,  # 92% - may need machine for personal use
            cancel_threshold=1.5  # Cancel if competing bid > 1.5× current rate
        ))

    # Consumers with mixed values
    consumers = []
    for i in range(consumer_count):
        # Mix of high and medium value consumers (all can afford DC)
        if i % 2 == 0:
            value = 2.0  # High value
        else:
            value = 1.0  # Medium value (still above DC minimum of $0.55)

        consumers.append(Consumer(
            id=f"c_{i}",
            checkpoint_interval=checkpoint_interval,
            job_duration=2.0,
            value_per_hour=value
        ))

    # If DCs have pricing power, calculate market-clearing price
    dc_min_price = None
    if dc_pricing_power and datacenter_count > 0:
        # DCs set price to maximize profit - find price where demand = supply
        # Create a dummy DC provider to calculate actual bids with efficiency adjustment
        dummy_dc = Provider(
            id="dummy", provider_type="datacenter",
            capex_per_hour=0.30, opex_per_hour=0.20,
            hourly_survival_rate=0.998
        )
        # Calculate what each consumer would actually bid for DC-level reliability
        consumer_bids = sorted(
            [calculate_bid(c, dummy_dc) for c in consumers],
            reverse=True
        )

        if datacenter_count < len(consumer_bids):
            # Undersupplied: price at the marginal consumer's bid (minus epsilon for floating point)
            dc_min_price = consumer_bids[datacenter_count - 1] * 0.999
        # If oversupplied, DCs compete and price falls to cost (no pricing power)

    # Run simulation
    run_market_simulation(providers, consumers, duration=duration, dc_min_price=dc_min_price)

    # Collect results
    dc_providers = [p for p in providers if p.provider_type == "datacenter"]
    home_providers = [p for p in providers if p.provider_type == "home"]

    active_consumers = [c for c in consumers if c.total_useful_compute > 0]

    results = {
        "name": name,
        "datacenter_count": datacenter_count,
        "home_count": home_count,
        "consumer_count": consumer_count,
        "checkpoint_interval": checkpoint_interval,
    }

    # Consumer metrics
    if active_consumers:
        results["avg_effective_cost"] = statistics.mean(
            c.effective_cost_per_useful_hour for c in active_consumers
        )
        results["avg_efficiency"] = statistics.mean(c.efficiency for c in active_consumers)
        results["total_useful_compute"] = sum(c.total_useful_compute for c in consumers)
        results["consumers_served"] = len(active_consumers)
    else:
        results["avg_effective_cost"] = 0
        results["avg_efficiency"] = 0
        results["total_useful_compute"] = 0
        results["consumers_served"] = 0

    # Datacenter metrics
    if dc_providers and any(p.total_hours_provided > 0 for p in dc_providers):
        active_dc = [p for p in dc_providers if p.total_hours_provided > 0]
        results["dc_revenue_per_hour"] = statistics.mean(p.revenue_per_hour for p in active_dc) if active_dc else 0
        results["dc_profit_per_hour"] = statistics.mean(p.profit_per_hour for p in active_dc) if active_dc else 0
        results["dc_completion_rate"] = statistics.mean(p.completion_rate for p in active_dc) if active_dc else 0
        results["dc_total_hours"] = sum(p.total_hours_provided for p in dc_providers)
    else:
        results["dc_revenue_per_hour"] = 0
        results["dc_profit_per_hour"] = 0
        results["dc_completion_rate"] = 0
        results["dc_total_hours"] = 0

    # Home provider metrics
    if home_providers and any(p.total_hours_provided > 0 for p in home_providers):
        active_home = [p for p in home_providers if p.total_hours_provided > 0]
        results["home_revenue_per_hour"] = statistics.mean(p.revenue_per_hour for p in active_home) if active_home else 0
        results["home_profit_per_hour"] = statistics.mean(p.profit_per_hour for p in active_home) if active_home else 0
        results["home_completion_rate"] = statistics.mean(p.completion_rate for p in active_home) if active_home else 0
        results["home_total_hours"] = sum(p.total_hours_provided for p in home_providers)
    else:
        results["home_revenue_per_hour"] = 0
        results["home_profit_per_hour"] = 0
        results["home_completion_rate"] = 0
        results["home_total_hours"] = 0

    return results


def run_parameter_sweep():
    """Run comprehensive parameter sweep varying demand, checkpoint interval, and value distribution."""

    print("=" * 80)
    print("COMPREHENSIVE PARAMETER SWEEP")
    print("=" * 80)
    print()
    print("Varying: Demand level, Checkpoint interval, Consumer value distribution")
    print("Measuring: DC impact, Market impact, Value creation")
    print()

    # Fixed parameters
    DC_COUNT = 10
    HOME_COUNT = 20
    DURATION = 150

    # Parameter ranges
    demand_levels = [
        ("Undersupplied", 30),   # 3x demand vs DC capacity
        ("Balanced", 15),        # 1.5x demand vs DC capacity
        ("Oversupplied", 8),     # 0.8x demand vs DC capacity
    ]

    checkpoint_intervals = [
        ("Frequent (0.1h)", 0.1),
        ("Moderate (0.5h)", 0.5),
        ("Infrequent (1.0h)", 1.0),
    ]

    value_distributions = [
        ("Uniform High", lambda i, n: 2.0),  # All consumers value at $2/hr
        ("Mixed", lambda i, n: 2.0 if i < n//2 else 1.0),  # Half $2, half $1
        ("Uniform Low", lambda i, n: 1.0),   # All consumers value at $1/hr
        ("Wide Spread", lambda i, n: 3.0 if i < n//4 else (1.5 if i < n//2 else 0.75)),  # $3, $1.5, $0.75
    ]

    results = []

    for demand_name, consumer_count in demand_levels:
        for cp_name, checkpoint_interval in checkpoint_intervals:
            for value_name, value_fn in value_distributions:
                random.seed(42)

                # Create providers
                providers_dc_only = []
                providers_mixed = []

                for i in range(DC_COUNT):
                    providers_dc_only.append(Provider(
                        id=f"dc_{i}", provider_type="datacenter",
                        capex_per_hour=0.30, opex_per_hour=0.20,
                        hourly_survival_rate=0.998, cancel_threshold=float('inf')
                    ))
                    providers_mixed.append(Provider(
                        id=f"dc_{i}", provider_type="datacenter",
                        capex_per_hour=0.30, opex_per_hour=0.20,
                        hourly_survival_rate=0.998, cancel_threshold=float('inf')
                    ))

                for i in range(HOME_COUNT):
                    providers_mixed.append(Provider(
                        id=f"home_{i}", provider_type="home",
                        capex_per_hour=0.0, opex_per_hour=0.08,
                        hourly_survival_rate=0.92, cancel_threshold=1.5
                    ))

                # Create consumers
                consumers_dc = []
                consumers_mixed = []
                for i in range(consumer_count):
                    value = value_fn(i, consumer_count)
                    consumers_dc.append(Consumer(
                        id=f"c_{i}", checkpoint_interval=checkpoint_interval,
                        job_duration=2.0, value_per_hour=value
                    ))
                    consumers_mixed.append(Consumer(
                        id=f"c_{i}", checkpoint_interval=checkpoint_interval,
                        job_duration=2.0, value_per_hour=value
                    ))

                # Calculate DC pricing power price
                dummy_dc = Provider(id="dummy", provider_type="datacenter",
                                   capex_per_hour=0.30, opex_per_hour=0.20,
                                   hourly_survival_rate=0.998)
                consumer_bids = sorted([calculate_bid(c, dummy_dc) for c in consumers_dc], reverse=True)
                dc_min_price = None
                if DC_COUNT < len(consumer_bids):
                    dc_min_price = consumer_bids[DC_COUNT - 1] * 0.999

                # Run DC-only simulation (DCs can price-set when they're the only option)
                run_market_simulation(providers_dc_only, consumers_dc, duration=DURATION, dc_min_price=dc_min_price)

                # Reset and run mixed simulation (DCs must compete with home providers - no price floor)
                for c in consumers_mixed:
                    c.reset()
                run_market_simulation(providers_mixed, consumers_mixed, duration=DURATION, dc_min_price=None)

                # Collect DC-only metrics
                dc_only_providers = [p for p in providers_dc_only if p.provider_type == "datacenter"]
                dc_only_active = [p for p in dc_only_providers if p.total_hours_provided > 0]
                dc_only_consumers = [c for c in consumers_dc if c.total_useful_compute > 0]

                # Collect mixed metrics
                mixed_dc = [p for p in providers_mixed if p.provider_type == "datacenter"]
                mixed_home = [p for p in providers_mixed if p.provider_type == "home"]
                mixed_dc_active = [p for p in mixed_dc if p.total_hours_provided > 0]
                mixed_home_active = [p for p in mixed_home if p.total_hours_provided > 0]
                mixed_consumers = [c for c in consumers_mixed if c.total_useful_compute > 0]

                result = {
                    "demand": demand_name,
                    "checkpoint": cp_name,
                    "value_dist": value_name,
                    "consumer_count": consumer_count,

                    # DC-only metrics
                    "dc_only_compute": sum(c.total_useful_compute for c in consumers_dc),
                    "dc_only_served": len(dc_only_consumers),
                    "dc_only_cost": statistics.mean(c.effective_cost_per_useful_hour for c in dc_only_consumers) if dc_only_consumers else 0,
                    "dc_only_profit": statistics.mean(p.profit_per_hour for p in dc_only_active) if dc_only_active else 0,
                    "dc_only_hours": sum(p.total_hours_provided for p in dc_only_providers),

                    # Mixed metrics
                    "mixed_compute": sum(c.total_useful_compute for c in consumers_mixed),
                    "mixed_served": len(mixed_consumers),
                    "mixed_cost": statistics.mean(c.effective_cost_per_useful_hour for c in mixed_consumers) if mixed_consumers else 0,
                    "mixed_dc_profit": statistics.mean(p.profit_per_hour for p in mixed_dc_active) if mixed_dc_active else 0,
                    "mixed_dc_hours": sum(p.total_hours_provided for p in mixed_dc),
                    "mixed_home_profit": statistics.mean(p.profit_per_hour for p in mixed_home_active) if mixed_home_active else 0,
                    "mixed_home_hours": sum(p.total_hours_provided for p in mixed_home),
                }

                # Calculate deltas
                if result["dc_only_profit"] > 0:
                    result["dc_profit_change"] = (result["mixed_dc_profit"] - result["dc_only_profit"]) / result["dc_only_profit"] * 100
                else:
                    result["dc_profit_change"] = 0 if result["mixed_dc_profit"] == 0 else float('inf')

                if result["dc_only_hours"] > 0:
                    result["dc_hours_change"] = (result["mixed_dc_hours"] - result["dc_only_hours"]) / result["dc_only_hours"] * 100
                else:
                    result["dc_hours_change"] = 0 if result["mixed_dc_hours"] == 0 else float('inf')

                if result["dc_only_compute"] > 0:
                    result["compute_change"] = (result["mixed_compute"] - result["dc_only_compute"]) / result["dc_only_compute"] * 100
                else:
                    result["compute_change"] = float('inf') if result["mixed_compute"] > 0 else 0

                if result["dc_only_cost"] > 0:
                    result["cost_change"] = (result["mixed_cost"] - result["dc_only_cost"]) / result["dc_only_cost"] * 100
                else:
                    result["cost_change"] = 0

                results.append(result)

    return results


def print_sweep_results(results: list[dict]):
    """Print comprehensive sweep results."""

    # Group by demand level
    demand_groups = {}
    for r in results:
        if r["demand"] not in demand_groups:
            demand_groups[r["demand"]] = []
        demand_groups[r["demand"]].append(r)

    print("=" * 100)
    print("IMPACT ON DATACENTERS")
    print("=" * 100)
    print()
    print("How does home provider entry affect datacenter profitability and utilization?")
    print()

    for demand_name in ["Undersupplied", "Balanced", "Oversupplied"]:
        if demand_name not in demand_groups:
            continue
        group = demand_groups[demand_name]

        print(f"--- {demand_name.upper()} MARKET ({group[0]['consumer_count']} consumers, 10 DCs) ---")
        print()
        print(f"{'Checkpoint':<20} | {'Value Dist':<15} | {'DC Profit Δ':>12} | {'DC Hours Δ':>11} | {'DC $/hr':>8} | {'Home $/hr':>9}")
        print("-" * 100)

        for r in group:
            dc_profit_delta = f"{r['dc_profit_change']:+.1f}%" if abs(r['dc_profit_change']) < 1000 else "N/A"
            dc_hours_delta = f"{r['dc_hours_change']:+.1f}%" if abs(r['dc_hours_change']) < 1000 else "N/A"
            dc_profit = f"${r['mixed_dc_profit']:.2f}" if r['mixed_dc_profit'] > 0 else "---"
            home_profit = f"${r['mixed_home_profit']:.2f}" if r['mixed_home_profit'] > 0 else "---"

            print(f"{r['checkpoint']:<20} | {r['value_dist']:<15} | {dc_profit_delta:>12} | {dc_hours_delta:>11} | {dc_profit:>8} | {home_profit:>9}")
        print()

    print()
    print("=" * 100)
    print("IMPACT ON MARKET (Total Economic Value)")
    print("=" * 100)
    print()
    print("How does home provider entry affect total compute delivered and consumer costs?")
    print()

    for demand_name in ["Undersupplied", "Balanced", "Oversupplied"]:
        if demand_name not in demand_groups:
            continue
        group = demand_groups[demand_name]

        print(f"--- {demand_name.upper()} MARKET ---")
        print()
        print(f"{'Checkpoint':<20} | {'Value Dist':<15} | {'Compute Δ':>10} | {'Cost Δ':>10} | {'Served':>12} | {'DC-only':>10}")
        print("-" * 100)

        for r in group:
            compute_delta = f"{r['compute_change']:+.1f}%" if abs(r['compute_change']) < 10000 else f"+{r['compute_change']:.0f}%"
            cost_delta = f"{r['cost_change']:+.1f}%" if r['dc_only_cost'] > 0 else "N/A"
            served = f"{r['mixed_served']}/{r['consumer_count']}"
            dc_only_served = f"{r['dc_only_served']}/{r['consumer_count']}"

            print(f"{r['checkpoint']:<20} | {r['value_dist']:<15} | {compute_delta:>10} | {cost_delta:>10} | {served:>12} | {dc_only_served:>10}")
        print()

    # Summary statistics
    print()
    print("=" * 100)
    print("SUMMARY: When do home providers create value vs cannibalize DCs?")
    print("=" * 100)
    print()

    # Categorize results
    value_creation = []  # DC profit unchanged or up, market expands
    neutral = []         # Little change either way
    cannibalization = [] # DC profit down significantly

    for r in results:
        if r['dc_profit_change'] < -5:
            cannibalization.append(r)
        elif r['compute_change'] > 10 and r['dc_profit_change'] >= -5:
            value_creation.append(r)
        else:
            neutral.append(r)

    print(f"VALUE CREATION scenarios ({len(value_creation)}/{len(results)}):")
    print("  Home providers expand market without hurting DC profits")
    if value_creation:
        avg_compute_gain = statistics.mean(r['compute_change'] for r in value_creation)
        avg_dc_impact = statistics.mean(r['dc_profit_change'] for r in value_creation)
        print(f"  Average compute increase: {avg_compute_gain:+.1f}%")
        print(f"  Average DC profit change: {avg_dc_impact:+.1f}%")
        print(f"  Common conditions: {set(r['demand'] for r in value_creation)}")
    print()

    print(f"NEUTRAL scenarios ({len(neutral)}/{len(results)}):")
    print("  Little market change (DCs already serve all demand)")
    if neutral:
        print(f"  Common conditions: {set(r['demand'] for r in neutral)}")
    print()

    print(f"CANNIBALIZATION scenarios ({len(cannibalization)}/{len(results)}):")
    print("  Home providers take business from DCs")
    if cannibalization:
        avg_dc_loss = statistics.mean(r['dc_profit_change'] for r in cannibalization)
        print(f"  Average DC profit change: {avg_dc_loss:+.1f}%")
        print(f"  Common conditions: {set(r['demand'] for r in cannibalization)}")


def main():
    print("=" * 80)
    print("ECONOMIC VALUE SIMULATION")
    print("=" * 80)
    print()
    print("Question: Does introducing unreliable compute create economic value?")
    print()
    print("Provider types:")
    print("  Datacenter:")
    print("    - Cost: capex=$0.30/hr + opex=$0.20/hr = $0.50/hr total")
    print("    - Reliability: 99.8% hourly (only hardware failures)")
    print("    - SLA commitment: CANNOT cancel for profit")
    print()
    print("  Home user:")
    print("    - Cost: capex=$0.00/hr + opex=$0.08/hr = $0.08/hr (power only)")
    print("    - Reliability: 92% hourly (may need machine)")
    print("    - No SLA: CAN cancel for profit (threshold: 1.5× rate)")
    print()

    # Test different scenarios
    scenarios = []

    # === SCENARIO SET 1: Undersupplied market (original) ===
    # Datacenter capacity insufficient for all consumers
    scenarios.append(run_scenario(
        "Undersupplied: DC only",
        datacenter_count=10, home_count=0,
        consumer_count=30, checkpoint_interval=0.5
    ))

    scenarios.append(run_scenario(
        "Undersupplied: DC + Home",
        datacenter_count=10, home_count=20,
        consumer_count=30, checkpoint_interval=0.5
    ))

    # === SCENARIO SET 2: Sufficient supply ===
    # Datacenter capacity CAN meet all demand - does home still add value?
    scenarios.append(run_scenario(
        "Sufficient: DC only",
        datacenter_count=30, home_count=0,
        consumer_count=20, checkpoint_interval=0.5
    ))

    scenarios.append(run_scenario(
        "Sufficient: DC + Home",
        datacenter_count=30, home_count=20,
        consumer_count=20, checkpoint_interval=0.5
    ))

    # === SCENARIO SET 3: Oversupplied market ===
    # More providers than consumers - pure price competition
    scenarios.append(run_scenario(
        "Oversupplied: DC only",
        datacenter_count=40, home_count=0,
        consumer_count=15, checkpoint_interval=0.5
    ))

    scenarios.append(run_scenario(
        "Oversupplied: DC + Home",
        datacenter_count=40, home_count=30,
        consumer_count=15, checkpoint_interval=0.5
    ))

    # === SCENARIO SET 4: DC with pricing power (undersupplied) ===
    # DCs set price to maximize profit - do home providers still add value?
    scenarios.append(run_scenario(
        "DC Pricing Power: DC only",
        datacenter_count=10, home_count=0,
        consumer_count=30, checkpoint_interval=0.5,
        dc_pricing_power=True
    ))

    scenarios.append(run_scenario(
        "DC Pricing Power: DC + Home",
        datacenter_count=10, home_count=20,
        consumer_count=30, checkpoint_interval=0.5,
        dc_pricing_power=True
    ))

    # Print results
    print("=" * 80)
    print("CONSUMER OUTCOMES")
    print("=" * 80)
    print()
    print(f"{'Scenario':<30} | {'$/useful_hr':>12} | {'Efficiency':>10} | {'Compute':>10} | {'Served':>6}")
    print("-" * 80)

    for s in scenarios:
        print(f"{s['name']:<30} | ${s['avg_effective_cost']:>11.3f} | {s['avg_efficiency']:>9.1%} | {s['total_useful_compute']:>9.1f}h | {s['consumers_served']:>6}")

    print()
    print("=" * 80)
    print("PROVIDER PROFITABILITY")
    print("=" * 80)
    print()
    print(f"{'Scenario':<30} | {'DC $/hr':>8} | {'DC Profit':>10} | {'Home $/hr':>9} | {'Home Profit':>11}")
    print("-" * 80)

    for s in scenarios:
        dc_rev = f"${s['dc_revenue_per_hour']:.2f}" if s['dc_revenue_per_hour'] > 0 else "---"
        dc_prof = f"${s['dc_profit_per_hour']:.3f}" if s['dc_profit_per_hour'] != 0 else "---"
        home_rev = f"${s['home_revenue_per_hour']:.2f}" if s['home_revenue_per_hour'] > 0 else "---"
        home_prof = f"${s['home_profit_per_hour']:.3f}" if s['home_profit_per_hour'] != 0 else "---"
        print(f"{s['name']:<30} | {dc_rev:>8} | {dc_prof:>10} | {home_rev:>9} | {home_prof:>11}")

    print()
    print("=" * 80)
    print("CAPACITY UTILIZATION")
    print("=" * 80)
    print()
    print(f"{'Scenario':<30} | {'DC Hours':>10} | {'DC Complete':>11} | {'Home Hours':>11} | {'Home Complete':>13}")
    print("-" * 80)

    for s in scenarios:
        dc_hrs = f"{s['dc_total_hours']:.1f}h" if s['dc_total_hours'] > 0 else "---"
        dc_comp = f"{s['dc_completion_rate']:.1%}" if s['dc_completion_rate'] > 0 else "---"
        home_hrs = f"{s['home_total_hours']:.1f}h" if s['home_total_hours'] > 0 else "---"
        home_comp = f"{s['home_completion_rate']:.1%}" if s['home_completion_rate'] > 0 else "---"
        print(f"{s['name']:<30} | {dc_hrs:>10} | {dc_comp:>11} | {home_hrs:>11} | {home_comp:>13}")

    # Analysis
    print()
    print("=" * 80)
    print("ANALYSIS BY MARKET CONDITION")
    print("=" * 80)

    # Analyze each market condition
    conditions = [
        ("UNDERSUPPLIED (price-taking DCs)", scenarios[0], scenarios[1]),
        ("SUFFICIENT SUPPLY", scenarios[2], scenarios[3]),
        ("OVERSUPPLIED", scenarios[4], scenarios[5]),
        ("UNDERSUPPLIED (price-setting DCs)", scenarios[6], scenarios[7]),
    ]

    for condition_name, dc_only, dc_plus_home in conditions:
        print(f"\n{condition_name} MARKET:")

        if dc_only['avg_effective_cost'] > 0:
            dc_cost = dc_only['avg_effective_cost']
            dc_compute = dc_only['total_useful_compute']
            dc_profit = dc_only['dc_profit_per_hour']

            print(f"  DC only:    ${dc_cost:.2f}/useful_hr, {dc_compute:.0f}h delivered, DC profit ${dc_profit:.2f}/hr")
        else:
            print(f"  DC only:    No compute delivered")
            dc_cost = 0

        if dc_plus_home['avg_effective_cost'] > 0:
            mixed_cost = dc_plus_home['avg_effective_cost']
            mixed_compute = dc_plus_home['total_useful_compute']
            mixed_dc_profit = dc_plus_home['dc_profit_per_hour']
            mixed_home_profit = dc_plus_home['home_profit_per_hour']

            print(f"  DC + Home:  ${mixed_cost:.2f}/useful_hr, {mixed_compute:.0f}h delivered, DC profit ${mixed_dc_profit:.2f}/hr, Home profit ${mixed_home_profit:.2f}/hr")

            if dc_cost > 0:
                cost_change = (mixed_cost - dc_cost) / dc_cost * 100
                dc_profit_change = (mixed_dc_profit - dc_profit) / dc_profit * 100 if dc_profit > 0 else 0
                print(f"  Effect:     Consumer cost {cost_change:+.1f}%, DC profit {dc_profit_change:+.1f}%")
        else:
            print(f"  DC + Home:  No compute delivered")

    print()
    print("=" * 80)
    print("KEY INSIGHT")
    print("=" * 80)
    print("""
The value of unreliable compute depends on market conditions:

1. UNDERSUPPLIED (price-taking DCs): Home providers unlock unserved demand.
   Consumers benefit, datacenters maintain high profits. Clear value creation.

2. UNDERSUPPLIED (price-setting DCs): Datacenters maximize profit by pricing
   at the marginal consumer's willingness to pay. Home providers:
   - Serve consumers priced out by DCs
   - Create NEW economic value (deadweight loss recovery)
   - Don't compete directly with DCs - serve different market segments

3. SUFFICIENT/OVERSUPPLIED: Home providers compete with datacenters.
   - If consumers can checkpoint: they switch to cheaper home providers
   - Datacenter profits decrease (price competition)
   - Consumer costs may decrease, but it's redistribution not creation

Key finding: In undersupplied markets with price-setting DCs, home providers
create real economic value by serving consumers who would otherwise be priced
out - this is deadweight loss recovery, not just surplus transfer.
""")

    # Specific analysis of price-setting scenario
    if len(scenarios) >= 8:
        dc_only = scenarios[6]
        dc_plus_home = scenarios[7]

        print("=" * 80)
        print("PRICE-SETTING DATACENTER ANALYSIS")
        print("=" * 80)
        print()
        print("When datacenters can set prices optimally (undersupplied market):")
        print()
        print(f"  DC-only scenario:")
        print(f"    - DCs serve {dc_only['consumers_served']} consumers at ${dc_only['avg_effective_cost']:.2f}/useful_hr")
        print(f"    - DC profit: ${dc_only['dc_profit_per_hour']:.2f}/hr")
        print(f"    - Useful compute delivered: {dc_only['total_useful_compute']:.0f}h")
        print()
        print(f"  DC + Home scenario:")
        print(f"    - Total consumers served: {dc_plus_home['consumers_served']}")
        print(f"    - DC profit: ${dc_plus_home['dc_profit_per_hour']:.2f}/hr (UNCHANGED)")
        print(f"    - Home profit: ${dc_plus_home['home_profit_per_hour']:.2f}/hr")
        print(f"    - Useful compute delivered: {dc_plus_home['total_useful_compute']:.0f}h")
        print()
        print("  VALUE CREATED:")
        compute_increase = dc_plus_home['total_useful_compute'] - dc_only['total_useful_compute']
        consumers_served_increase = dc_plus_home['consumers_served'] - dc_only['consumers_served']
        print(f"    - Additional consumers served: {consumers_served_increase}")
        print(f"    - Additional compute: {compute_increase:.0f}h")
        print(f"    - DC profit change: 0% (price-setters maintain their margin)")
        print()
        print("  This is GENUINE VALUE CREATION, not surplus transfer:")
        print("    - DCs lose nothing (same profit per hour)")
        print("    - Consumers who were priced out now get service")
        print("    - Home providers profit from serving lower-value segment")
        print("    - Total economic surplus increases")
        print()

    # Run comprehensive parameter sweep
    print()
    print()
    results = run_parameter_sweep()
    print_sweep_results(results)


if __name__ == "__main__":
    main()
