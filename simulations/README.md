# Omerta Simulations

This directory contains simulation code for validating the participation verification system and market dynamics.

## Simulation Files

### Trust System Simulations

| File | Description |
|------|-------------|
| `trust_simulation.py` | Core trust accumulation and decay simulation |
| `failure_modes.py` | Attack scenarios and failure mode analysis |
| `monetary_policy_simulation.py` | Automated monetary policy testing |
| `monetary_policy_iteration2.py` | Refined monetary policy model |

### Identity and Transfer Simulations

| File | Description |
|------|-------------|
| `identity_rotation_attack.py` | Tests the "wealthy sock puppet" attack and defenses |

**Key findings:**
- Trust inheritance (Section 12.8) successfully prevents identity rotation from escaping scrutiny
- Large transfers force recipient to inherit sender's effective trust level
- "Spotlight follows the money" - cannot shed visibility by moving wealth

### Reliability Market Simulations

| File | Description |
|------|-------------|
| `reliability_market_simulation.py` | Basic reliability pricing test |
| `reliability_market_equilibrium.py` | Provider threshold convergence study |
| `reliability_market_v2.py` | Full model with value differentiation |
| `economic_value_simulation.py` | Datacenter vs home provider economics |

**Key findings:**

1. **Provider convergence**: All providers converge to a single optimal cancellation threshold (~2.2x). No natural market segmentation emerges.

2. **Value differentiation works**: High-value consumers ($5/hr) get priority access and pay higher rates. Low-value consumers ($0.50/hr) are priced out under scarcity.

3. **Effective cost equalization**: At equilibrium, all consumer types pay similar effective rates per useful compute hour when accounting for restart costs.

4. **Restart cost model**: Restart cost should be measured in compute time (checkpoint_interval), not dollars. Consumers who can checkpoint frequently tolerate unreliability.

5. **Economic value of unreliable compute**: Introducing home providers (power-only cost, can cancel for profit) reduces effective $/useful_hr by 42% and increases compute delivered by 188%.

### Utility Files

| File | Description |
|------|-------------|
| `generate_visualizations.py` | Generate charts and graphs |
| `run_full_study.py` | Run comprehensive simulation study |

## Running Simulations

```bash
# Set up virtual environment (first time)
python3 -m venv .venv
source .venv/bin/activate
pip install matplotlib numpy

# Run individual simulation
python3 reliability_market_v2.py

# Run full study
python3 run_full_study.py
```

## Key Results Summary

### Identity Rotation Attack (Attack Class 6)

**Attack:** Wealthy user W creates sock puppet P, matures with minimal investment, transfers large sum to escape scrutiny.

**Defense:** Trust inheritance on transfer (Section 12.8):
```
transfer_ratio = transfer_amount / recipient_new_balance
blended_trust = transfer_ratio × T(sender) + (1 - transfer_ratio) × T(recipient)
T(recipient)_new = min(T(recipient), blended_trust)
```

**Result:** Recipient's trust drops to match sender's effective trust level. Cannot buy trust; can only inherit (downward).

### Reliability Market Equilibrium

**Question:** Do providers converge to a single reliability level?

**Answer:** Yes. Starting from random thresholds [1.1, 4.0], providers converge to ~2.2 (std drops 98%).

**Implication:** Market naturally finds single equilibrium. "Reliable" vs "unreliable" tiers don't emerge spontaneously.

### Consumer Value Differentiation

| Value Tier | Rate Paid | Compute Access | Notes |
|-----------|----------|----------------|-------|
| High ($5/hr) | $1.04/hr | 199h | Full access |
| Med ($2/hr) | $1.00/hr | 197h | Full access |
| Low ($0.50/hr) | $0.39/hr | 75h | Limited access |
| Low + No checkpoint | --- | 0h | **Priced out** |

**Key insight:** Low-value consumers with high checkpoint intervals cannot compete in the market.

### Scarcity Effects

| Supply/Demand | Low-Value Access |
|--------------|-----------------|
| Excess supply | 67h |
| Balanced | 61h |
| Scarcity | **0h** |

Under scarcity, high-value users outbid low-value users completely.

### Economic Value: Datacenter vs Home Providers

**Provider cost structures:**
- **Datacenter**: $0.50/hr (capex + opex), 99.8% reliability, cannot cancel for profit (SLA)
- **Home user**: $0.08/hr (power only), 92% reliability, can cancel for profit

**Price-setter model (realistic):**

Datacenters have pricing power in undersupplied markets - they set prices to maximize profit, not just cover costs. This prices out lower-value consumers.

| Scenario | $/useful_hr | Compute | DC Profit | Home Profit |
|----------|-------------|---------|-----------|-------------|
| DC only (price-setter) | $1.60 | 1,306h | $1.10/hr | --- |
| DC + Home (price-setter) | $1.19 | 5,462h | **$1.10/hr** | $0.95/hr |

**Key insight: Genuine value creation, not surplus transfer**

- **DC profit unchanged**: $1.10/hr in both scenarios
- **Additional consumers served**: 20 (from 10 to 30)
- **Additional compute**: +4,156h (+318%)
- **Consumer cost**: -25.8%

This proves home providers create **real economic value**:
1. Datacenters lose nothing (same profit per hour)
2. Consumers who were priced out now get service
3. Home providers profit from serving lower-value segment
4. This is "deadweight loss recovery" - capturing value that was lost

**Market segmentation emerges naturally:**
- Datacenters: serve high-value customers at premium prices
- Home providers: serve lower-value customers at lower prices
- Both profitable, no cannibalization

### Machine Intelligence and Perpetual Undersupply

See [ECONOMIC_ANALYSIS.md](./ECONOMIC_ANALYSIS.md) for the full analysis.

**Key thesis**: Machine intelligence transforms compute markets into perpetually undersupplied markets because machines can always find productive uses for additional compute at any quality level.

| Era | Compute Demand | Market Structure |
|-----|---------------|------------------|
| Human-only | Bounded | Tends toward oversupply |
| Human + Machine (today) | Large but finite | Undersupplied |
| Machine-dominated (future) | **Unbounded** | Permanently undersupplied |

**Implications**:
1. Unreliable compute is always valuable (there's always a lower-priority task worth doing)
2. Markets are perpetually undersupplied (demand grows faster than supply)
3. All providers can coexist (datacenters serve premium tier, home providers serve elastic demand)

The question is not whether unreliable compute will displace datacenters. The question is whether we can deploy enough compute of any quality to satisfy the exponentially growing demand of machine intelligence.

## References

Full documentation in `/docs/participation-verification-math.md`:
- Section 5.12: Reliability Score Model
- Section 12.7: Transfer Amount Scaling
- Section 12.8: Trust Inheritance on Transfer
- Section 19: Simulation Results
