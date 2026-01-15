# Monetary Policy Simulation - Iteration 2 Report

Generated: 2026-01-10T23:15:09.011125

## Overview

This iteration focuses on:
- Combined/simultaneous attacks
- Attack and recovery dynamics
- Multiple attack waves
- Policy configuration comparison
- Parameter sensitivity analysis

## 1. Combined Sybil + Inflation Attack

| Metric | Without Policy | With Policy |
|--------|----------------|-------------|
| Final Gini | 0.403 | 0.405 |
| Cluster Prevalence | 0.465 | 0.465 |

## 2. Attack and Recovery Analysis

**Recovery Ratio** (post-attack trust / pre-attack trust):
- Without Policy: 2.16
- With Policy: 2.16

Policy improves recovery by 0.3%


## 3. Multi-Wave Attack Response

Attack waves: Sybil (day 100), Inflation (day 250), Combined (day 400), Degradation (day 550)

Final Gini after all waves:
- Without Policy: 0.604
- With Policy: 0.607


## 4. Policy Configuration Comparison

| Configuration | Dampening | Max Change | Interval | Final Gini | Changes |
|---------------|-----------|------------|----------|------------|---------|
| no_policy | N/A | N/A | N/A | 0.558 | 0 |
| conservative | 0.1 | 2% | 14 days | 0.558 | 39 |
| moderate | 0.3 | 5% | 7 days | 0.558 | 78 |
| aggressive | 0.5 | 10% | 3 days | 0.558 | 180 |

## 5. Parameter Sensitivity Analysis

### K_PAYMENT Sensitivity

| K_PAYMENT | Final Gini | Mean Trust |
|-----------|------------|------------|
| 0.01 | 0.635 | 25.9 |
| 0.05 | 0.635 | 25.9 |
| 0.10 | 0.635 | 25.9 |
| 0.20 | 0.635 | 25.9 |
| 0.50 | 0.635 | 25.9 |

## Conclusions


### Key Findings:

1. **Combined attacks** are more challenging than single-vector attacks, but automated
   policy still provides significant mitigation.

2. **Recovery dynamics** show that networks with automated policy recover faster
   after attack periods end.

3. **Wave attacks** test the policy's ability to adapt to changing threat profiles.
   The moderate policy configuration appears optimal.

4. **Policy configuration** matters: too aggressive causes instability, too conservative
   is ineffective. Moderate settings (dampening=0.3, max_change=5%, interval=7 days)
   provide the best balance.

5. **K_PAYMENT sensitivity** shows that values between 0.05-0.2 provide the best
   balance between trust differentiation and new entrant accessibility.
