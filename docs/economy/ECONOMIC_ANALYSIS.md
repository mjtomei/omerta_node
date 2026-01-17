# Economic Analysis: The Value of Unreliable Compute

## Executive Summary

This analysis examines whether introducing unreliable compute (home providers with power-only costs) creates genuine economic value or merely redistributes surplus from datacenters to consumers. Through simulation, we find that **the answer depends critically on market conditions**:

- **Undersupplied markets**: Home providers create genuine value by serving unmet demand
- **Balanced/Oversupplied markets**: Home providers displace datacenters through price competition

We then argue that **machine intelligence fundamentally transforms compute markets into perpetually undersupplied markets**, making unreliable compute economically valuable for the foreseeable future.

---

## Part 1: Simulation Results

### Provider Cost Structures

| Provider Type | Capex | Opex | Total Cost | Reliability | Can Cancel for Profit |
|--------------|-------|------|------------|-------------|----------------------|
| Datacenter | $0.30/hr | $0.20/hr | **$0.50/hr** | 99.8% | No (SLA commitment) |
| Home User | $0.00/hr | $0.08/hr | **$0.08/hr** | 92% | Yes (1.5× threshold) |

Home providers have a **6× cost advantage** because they:
1. Already own the hardware (no capex amortization)
2. Only pay marginal electricity costs
3. Have no facility, cooling, or staffing overhead

### Market Dynamics by Supply/Demand Balance

#### Undersupplied Market (Demand > Supply)

When datacenter capacity cannot meet all demand:

| Metric | DC Only | DC + Home | Change |
|--------|---------|-----------|--------|
| Consumers Served | 10/30 | 30/30 | **+200%** |
| Compute Delivered | 1,600h | 4,800h | **+200%** |
| Consumer Cost | $1.93/hr | $0.96/hr | **-50%** |
| DC Profit | $1.43/hr | $0.50/hr | -65% |
| Home Profit | --- | $0.82/hr | New revenue |

**Key finding**: Home providers unlock unserved demand. Total economic value increases even though datacenter profits decrease.

#### Balanced Market (Supply ≈ Demand)

When total provider capacity roughly matches demand:

| Metric | DC Only | DC + Home | Change |
|--------|---------|-----------|--------|
| Consumers Served | 10/15 | 15/15 | +50% |
| Consumer Cost | $0.56/hr | $0.05/hr | **-91%** |
| DC Profit | $0.06/hr | $0.00/hr | **-100%** |

**Key finding**: Home providers completely displace datacenters through price competition.

#### Oversupplied Market (Supply > Demand)

When provider capacity exceeds demand:

| Metric | DC Only | DC + Home | Change |
|--------|---------|-----------|--------|
| Consumers Served | 8/8 | 8/8 | 0% |
| Consumer Cost | $0.55/hr | $0.09/hr | **-84%** |
| DC Profit | $0.06/hr | $0.00/hr | **-100%** |
| Useful Compute | 2,988h | 2,737h | **-8%** |

**Key finding**: Consumers save significantly, but datacenters are eliminated and total useful compute may decrease due to reliability issues.

### Impact of Consumer Heterogeneity

Consumer value distributions significantly affect outcomes:

| Value Distribution | DC Profit Impact | Notes |
|-------------------|------------------|-------|
| Uniform High ($2/hr all) | -3% | DCs retain premium segment |
| Uniform Low ($1/hr all) | 0% | Natural market segmentation |
| Mixed ($2 and $1) | -66% | Competition for middle market |
| Wide Spread ($3, $1.5, $0.75) | -83% | Intense competition |

**Key finding**: When consumer values are heterogeneous, home providers can capture middle-market consumers that datacenters would otherwise serve.

### Impact of Checkpoint Frequency

| Checkpoint Interval | Compute Change | Consumer Cost Change |
|--------------------|----------------|---------------------|
| Frequent (0.1h) | +211% | -13% |
| Moderate (0.5h) | +205% | -13% |
| Infrequent (1.0h) | +199% | -13% |

**Key finding**: Checkpoint frequency has moderate impact on total value but doesn't fundamentally change market dynamics. Even consumers with infrequent checkpoints prefer cheaper unreliable compute because the 6× cost advantage dominates.

---

## Part 2: The Machine Intelligence Transformation

### The Traditional View: Compute as a Scarce Resource

Traditional economic analysis of compute markets assumes:
1. Human-driven demand is bounded
2. Markets tend toward equilibrium
3. Oversupply leads to price collapse and provider exit

Under this view, introducing cheap unreliable compute is problematic:
- In oversupplied markets, it drives prices to marginal cost
- Datacenters cannot compete and exit the market
- Total useful compute may decrease due to reliability issues

### The New Reality: Unbounded Machine Demand

Machine intelligence fundamentally changes this calculus because **machines can always find productive uses for additional compute**.

#### Today: Subhuman Intelligence, Positive Marginal Value

Current AI systems operate below human-level intelligence but can still generate value from compute:

| Task Type | Human Value | Machine Value | Notes |
|-----------|-------------|---------------|-------|
| Frontier research | $100/hr | $0/hr | Requires human insight |
| Code review | $50/hr | $30/hr | Machines assist humans |
| Data processing | $20/hr | $18/hr | Machines nearly as good |
| Background search | $10/hr | $8/hr | Machines can do autonomously |
| Speculative exploration | $5/hr | $3/hr | Low priority but valuable |
| Precomputation | $1/hr | $0.50/hr | Preparing for future needs |

The key insight: **There is always a next-best task**.

A machine that cannot profitably do a $50/hr task can still profitably do a $20/hr task. A machine that cannot afford datacenter compute at $0.50/hr can still generate value using home compute at $0.08/hr.

This creates a **demand curve that extends to arbitrarily low prices**:

```
Value per
Compute Hour
    ^
$50 |----*
    |     \
$20 |------*
    |        \
$5  |---------*
    |           \
$1  |------------*
    |              \
$0  +---------------*----> Compute Hours Demanded
```

#### The Implication: Perpetual Undersupply

If machines can always find productive uses for compute at any price point, then:

1. **There is no "oversupplied" market** - demand expands to absorb any supply
2. **Price floors are set by marginal value, not marginal cost** - machines bid what tasks are worth
3. **All compute capacity is utilized** - nothing sits idle

This transforms our simulation results:

| Old Assumption | New Reality |
|----------------|-------------|
| Oversupplied market | Does not exist |
| Balanced market | Temporarily possible |
| Undersupplied market | **The normal state** |

### The Future: Superhuman Intelligence, Unlimited Demand

As machine intelligence approaches and exceeds human levels, the value of compute increases without bound:

1. **Intelligence improvements compound** - More compute → Better AI → More valuable compute use
2. **New capability thresholds** - Each intelligence improvement unlocks new high-value tasks
3. **Self-improvement loops** - AI systems can optimize their own compute utilization

At this stage, **any quality of compute has value**:

| Compute Quality | Use Case |
|-----------------|----------|
| Datacenter (99.9% reliable) | Real-time inference, critical tasks |
| Home (92% reliable) | Background reasoning, exploration |
| Intermittent (50% reliable) | Speculative computation |
| Scavenged (10% reliable) | Statistical sampling, search |

The demand curve becomes:

```
Value per
Compute Hour
    ^
    |  (unlimited demand at any price)
    |  ****************************
    |  *
    |  *
    |  *
$0  +--*-------------------------> Compute Hours Demanded
```

---

## Part 3: Economic Implications

### For Datacenters

Datacenters will not be "displaced" in the traditional sense. Instead:

1. **They serve the highest-value tier** - Real-time, reliable, guaranteed compute
2. **They maintain premium pricing** - Reliability commands a premium for critical tasks
3. **They face competition at the margin** - But the margin expands as machine intelligence grows

### For Home Providers

Home providers become viable at scale because:

1. **Perpetual undersupply means perpetual demand** - Always someone willing to buy
2. **Low-value tasks are still valuable** - Machines find uses for cheap compute
3. **Aggregation creates reliability** - Many unreliable nodes → reliable service

### For the Market

The total market expands dramatically:

| Era | Compute Demand | Market Structure |
|-----|---------------|------------------|
| Human-only | Bounded | Tends toward oversupply |
| Human + Machine (today) | Large but finite | Undersupplied for foreseeable future |
| Machine-dominated (future) | Unbounded | Permanently undersupplied |

### Value Creation, Not Redistribution

Our simulation showed that home providers create genuine value only in undersupplied markets. The machine intelligence thesis argues that **undersupply is the permanent state**.

Therefore:
- **Consumer surplus increases** - More tasks get done at lower cost
- **Producer surplus increases** - New providers earn returns on idle hardware
- **Total surplus increases** - Previously impossible tasks become economical

This is not a zero-sum redistribution from datacenters to home providers. It is genuine economic value creation through:

1. **Capital utilization** - Idle home hardware becomes productive
2. **Task completion** - Previously uneconomical tasks get done
3. **Intelligence amplification** - More compute enables better AI enables more value

---

## Conclusion

The introduction of unreliable compute creates genuine economic value under one critical condition: **demand must exceed supply**.

Traditional human-driven demand is bounded and tends toward equilibrium. But machine intelligence creates unbounded demand that expands to absorb any available compute at any quality level.

In a world where machines can always find productive uses for additional compute:

1. **Unreliable compute is always valuable** - There's always a task worth doing
2. **Markets are perpetually undersupplied** - Demand grows faster than supply
3. **All providers can coexist** - Datacenters serve premium tier, home providers serve elastic demand

The question is not whether unreliable compute will displace datacenters. The question is whether we can deploy enough compute of any quality to satisfy the exponentially growing demand of machine intelligence.

---

## Appendix: Simulation Parameters

### Provider Configuration

```python
# Datacenter
capex_per_hour = 0.30      # Amortized server cost
opex_per_hour = 0.20       # Power, cooling, staff, facilities
hourly_survival_rate = 0.998  # Only hardware failures
cancel_threshold = infinity   # SLA commitment

# Home Provider
capex_per_hour = 0.00      # Already own hardware
opex_per_hour = 0.08       # Power only (~$0.15/kWh × 500W)
hourly_survival_rate = 0.92   # May need machine for personal use
cancel_threshold = 1.5        # Cancel if better offer > 1.5× current rate
```

### Consumer Configuration

```python
checkpoint_intervals = [0.1, 0.5, 1.0]  # Hours between saves
job_duration = 2.0                       # Hours per job
value_distributions = {
    "uniform_high": all at $2.00/hr,
    "uniform_low": all at $1.00/hr,
    "mixed": half $2.00, half $1.00,
    "wide_spread": $3.00, $1.50, $0.75
}
```

### Market Configurations

```python
demand_levels = {
    "undersupplied": 30 consumers, 10 DCs,
    "balanced": 15 consumers, 10 DCs,
    "oversupplied": 8 consumers, 10 DCs
}
home_providers = 20  # Added in mixed scenarios
```
