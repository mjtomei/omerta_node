# Double-Spend Resolution Simulation Plan

**Status: COMPLETED** - See results below and `simulations/double_spend_simulation.py`

## Objective

Demonstrate the relationship between network connectivity, double-spend resolution strategies, and currency "weight". Show that:

1. Higher connectivity → faster detection → lighter currency viable
2. "Both keep coins" works in high-trust networks with sufficient penalties
3. "Wait for agreement" provides stronger guarantees at latency cost
4. Network partitions naturally resolve to separate currencies

---

## Simulation 1: Detection Rate vs Connectivity

**Question**: How does network connectivity affect double-spend detection rate and time-to-detection?

### Setup

```python
@dataclass
class Node:
    id: str
    peers: set[str]              # Direct connections
    chain: list[Transaction]      # Local view of transaction history
    trust_score: float

@dataclass
class Transaction:
    id: str
    sender: str
    recipient: str
    amount: float
    timestamp: float

@dataclass
class Network:
    nodes: dict[str, Node]
    connectivity: float           # 0-1, fraction of possible edges present
    propagation_delay: float      # Time for message to traverse one hop

def attempt_double_spend(network: Network, attacker: str,
                         victim1: str, victim2: str, amount: float):
    """
    Attacker creates two conflicting transactions to different recipients.
    Returns: (detected: bool, detection_time: float, detected_by: set[str])
    """
```

### Parameters to Vary

| Parameter | Range | Purpose |
|-----------|-------|---------|
| `connectivity` | 0.1 - 1.0 | Network density |
| `num_nodes` | 10 - 1000 | Network size |
| `propagation_delay` | 0.01 - 1.0 s | Message latency |
| `attacker_position` | central/peripheral | Graph position of attacker |

### Metrics

- Detection rate: % of double-spends detected
- Time to detection: seconds until first honest node detects
- Detection spread: time until >90% of nodes know
- False positive rate: honest tx flagged as double-spend

### Expected Results

| Connectivity | Detection Rate | Detection Time |
|--------------|----------------|----------------|
| High (0.9+) | ~100% | < 1s |
| Medium (0.5) | ~95% | 1-5s |
| Low (0.2) | ~70% | 5-30s |
| Very low (0.1) | ~40% | 30s+ or never |

---

## Simulation 2: "Both Keep Coins" Economics

**Question**: Under what conditions is "both keep coins" economically stable?

### Setup

```python
@dataclass
class EconomyState:
    total_supply: float
    inflation_from_fraud: float
    fraud_rate: float            # Double-spends per time unit
    avg_fraud_amount: float

@dataclass
class AttackerProfile:
    trust_score: float
    coins_held: float
    risk_tolerance: float        # Willing to lose X trust for Y coins

def simulate_both_keep_economy(
    num_participants: int,
    attacker_fraction: float,
    trust_penalty_multiplier: float,  # penalty = multiplier × amount stolen
    simulation_duration: float
) -> EconomyState:
```

### Parameters to Vary

| Parameter | Range | Purpose |
|-----------|-------|---------|
| `trust_penalty_multiplier` | 1x - 100x | Severity of penalty |
| `attacker_fraction` | 0.01 - 0.20 | % of malicious actors |
| `detection_rate` | 0.5 - 1.0 | From Simulation 1 |
| `trust_value_ratio` | varies | How much trust is worth in coins |

### Metrics

- Annual inflation rate from fraud
- Attacker profitability (coins gained - trust lost value)
- Honest participant purchasing power over time
- System stability (does it converge or spiral?)

### Key Equations

```
Expected attacker profit = P(success) × coins_stolen - P(caught) × trust_penalty

Trust penalty cost = trust_lost × daily_distribution_share × expected_remaining_lifetime

For stability:
trust_penalty_cost > coins_stolen × (P(success) / P(caught))
```

### Expected Results

| Detection Rate | Required Penalty Multiplier | Inflation Rate |
|----------------|----------------------------|----------------|
| 99% | 2x | < 0.1% |
| 90% | 10x | < 1% |
| 70% | 50x | 2-5% |
| 50% | 100x+ | Unstable |

---

## Simulation 3: "Wait for Agreement" Latency

**Question**: How does finality threshold affect confirmation time and security?

### Setup

```python
@dataclass
class ConfirmationResult:
    confirmed: bool
    confirmation_time: float
    confirming_peers: int
    total_peers: int

def wait_for_agreement(
    network: Network,
    transaction: Transaction,
    finality_threshold: float,      # 0.5 - 0.99
    confirmation_window: float,     # Max time to wait
    recent_peer_window: float       # How far back for "recent"
) -> ConfirmationResult:
```

### Parameters to Vary

| Parameter | Range | Purpose |
|-----------|-------|---------|
| `finality_threshold` | 0.5 - 0.99 | Required peer agreement |
| `confirmation_window` | 1 - 60 s | Max wait time |
| `network_connectivity` | 0.2 - 1.0 | From Simulation 1 |
| `network_latency` | 0.01 - 1.0 s | Message delay |

### Metrics

- Confirmation time (median, p95, p99)
- Confirmation success rate (within window)
- Double-spend acceptance rate
- Throughput (tx/second with confirmations)

### Expected Results

| Threshold | Median Confirm | Double-Spend Blocked |
|-----------|----------------|---------------------|
| 50% | 0.5s | 50% |
| 70% | 1.2s | 85% |
| 90% | 3.5s | 99% |
| 99% | 10s+ | 99.9% |

---

## Simulation 4: Network Partition Behavior

**Question**: What happens when networks partition and later reconnect?

### Setup

```python
@dataclass
class PartitionScenario:
    partition_duration: float
    partition_fraction: float      # Fraction of nodes in smaller partition
    tx_rate_during_partition: float
    double_spend_attempts: int

def simulate_partition(
    network: Network,
    scenario: PartitionScenario
) -> PartitionResult:
    """
    1. Split network into two partitions
    2. Run transactions in each partition independently
    3. Reconnect and observe resolution
    """
```

### Scenarios

| Scenario | Setup | Expected Outcome |
|----------|-------|------------------|
| Brief partition | 10s split, 50/50 | Quick merge, minor conflicts |
| Extended partition | 1hr split, 50/50 | Many conflicts, some inflation |
| Asymmetric | 10min split, 90/10 | Minority chain discarded |
| Permanent | Never reconnect | Two separate currencies |

### Metrics

- Conflicts after reconnection
- Resolution time
- Coins "created" by double-spends during partition
- Trust score changes
- Economic impact on each partition

---

## Simulation 5: Adaptive Policy

**Question**: Can policy parameters adapt to maintain stability?

### Setup

```python
@dataclass
class PolicyState:
    finality_threshold: float
    trust_penalty_multiplier: float
    confirmation_window: float

@dataclass
class NetworkConditions:
    connectivity: float
    fraud_rate: float
    avg_latency: float

def adaptive_policy_controller(
    current_policy: PolicyState,
    observed_conditions: NetworkConditions,
    target_metrics: dict
) -> PolicyState:
    """
    Adjust policy based on observed network conditions.

    Targets:
    - max_inflation_rate: 1%
    - max_confirmation_time: 5s
    - min_double_spend_blocked: 95%
    """
```

### Parameters to Vary

| Parameter | Range | Purpose |
|-----------|-------|---------|
| `initial_policy` | conservative/aggressive | Starting point |
| `fraud_rate_changes` | sudden spikes, gradual | Attack patterns |
| `connectivity_changes` | stable, degrading | Network health |
| `adaptation_rate` | slow/fast | Policy adjustment speed |

### Metrics

- Policy parameter trajectories over time
- Stability (oscillation vs convergence)
- Response time to fraud spikes
- Economic impact during adaptation

---

## Implementation Plan

### Phase 1: Network Model ✓
- [x] Implement `Node`, `Transaction`, `Network` classes
- [x] Graph generation with configurable connectivity
- [x] Message propagation simulation (BFS-based gossip)
- [x] Basic double-spend detection

### Phase 2: Detection Simulation ✓
- [x] Implement Simulation 1
- [x] Run parameter sweeps
- [x] Generate detection rate vs connectivity curves

### Phase 3: Economic Models ✓
- [x] Implement "both keep coins" economy
- [x] Implement trust penalty calculations
- [x] Run Simulation 2 (penalty vs stability)

### Phase 4: Finality Simulation ✓
- [x] Implement "wait for agreement" protocol
- [x] Run Simulation 3 (threshold vs latency)
- [x] Compare strategies under same conditions

### Phase 5: Partition & Adaptation ✓
- [x] Implement network partition mechanics
- [x] Run Simulation 4 (partition scenarios)
- [x] Currency weight spectrum calculation (Simulation 5)
- [ ] Adaptive policy controller (deferred - not needed for core validation)

### Phase 6: Integration & Analysis ✓
- [x] Combine results into unified model
- [x] Generate "currency weight" spectrum visualization
- [x] Write up findings for documentation
- [x] Update academic paper with results

---

## Expected Deliverables

1. **`double_spend_simulation.py`** - Core simulation code
2. **Detection rate curves** - Connectivity vs detection graphs
3. **Economic stability regions** - Penalty vs fraud rate phase diagram
4. **Finality tradeoff curves** - Threshold vs latency vs security
5. **Partition analysis** - Recovery time and cost by scenario
6. **Adaptive policy demo** - Policy responding to changing conditions
7. **Summary visualization** - "Currency weight spectrum" showing all tradeoffs

---

## Key Hypotheses to Test

1. **H1**: Detection rate > 90% is achievable with connectivity > 0.5
2. **H2**: "Both keep coins" is stable when penalty > 10x amount and detection > 90%
3. **H3**: 70% finality threshold provides good latency/security tradeoff
4. **H4**: Brief partitions (< 1 min) resolve with minimal economic impact
5. **H5**: Adaptive policy can maintain stability under varying fraud rates

---

## Connection to Documentation

Results will be added to:
- Section 19.9 of `participation-verification-math.md` (quantitative support)
- Section 7.6 of academic paper (new simulation results section)
- `ECONOMIC_ANALYSIS.md` (double-spend section)

The simulations demonstrate the core thesis: **currency weight is proportional to network performance requirements**.

---

## Results Summary

### Hypotheses Tested

| Hypothesis | Expected | Actual | Status |
|------------|----------|--------|--------|
| H1: Detection > 90% with connectivity > 0.5 | >90% | **100%** even at 0.1 connectivity | ✓ Exceeded |
| H2: "Both keep" stable with penalty > 10x, detection > 90% | Stable | Stable with **5x penalty at 50% detection** | ✓ Exceeded |
| H3: 70% threshold good latency/security | <1s, >90% blocked | **0.14s, 100%** | ✓ Confirmed |
| H4: Brief partitions resolve with minimal impact | Minimal | **100% detected after healing** | ✓ Confirmed |
| H5: Adaptive policy maintains stability | TBD | Deferred (core validation sufficient) | - |

### Key Findings

**1. Detection is more robust than expected**

In gossip networks, double-spends are always eventually detected because conflicting transactions propagate to common nodes. Connectivity affects detection *speed*, not *completeness*. Even at 0.1 connectivity, 100% of double-spends are detected.

**2. Economic penalties work at lower thresholds**

The "both keep coins" strategy is stable across a wider range than expected:
- 50% detection + 5x penalty → stable (1.9% inflation)
- Attackers always lose money regardless of detection rate

**3. Finality is faster than expected**

Sub-200ms confirmation times across all threshold/connectivity combinations. Peer confirmations arrive in parallel through gossip, so higher thresholds don't proportionally increase latency.

**4. Partitions create a "damage window"**

During partitions, double-spends can temporarily succeed (both victims accept). After healing, all conflicts are detected. Risk mitigation: use "wait for agreement" for high-value transactions.

**5. Currency weight spectrum validated**

| Network Quality | Weight | Viable Strategy |
|----------------|--------|-----------------|
| High (0.9 conn) | 0.14 | Lightest: instant finality, high fraud tolerance |
| Medium (0.5 conn) | 0.34 | Light: fast finality, moderate tolerance |
| Low (0.1 conn) | 0.80 | Heavy: slow finality, low tolerance |

### Conclusion

The simulations confirm the core hypothesis: **network performance determines viable trust level**. Better connectivity enables lighter trust mechanisms—the digital equivalent of physical proximity enabling village-level trust. The system degrades gracefully along the currency weight spectrum, with heavier mechanisms available for lower-quality network conditions.
