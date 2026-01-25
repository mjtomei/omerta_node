# Omerta Simulation Infrastructure

This document describes the simulation infrastructure for validating the Omerta protocol and summarizes results to date.

---

## Why AI Agents in Simulation

The simulation infrastructure uses LLM-backed agents for a reason beyond convenience: **the same machine intelligence that will operate the production system should stress-test the protocol during development.**

Omerta is designed for a world where machines manage compute—orchestrating workloads, measuring trust, eventually handling disputes. If the protocol can be broken by an AI agent trying to maximize profit through any means, we want to discover that now, not after deployment. The adversarial agent in simulation is a preview of adversarial agents in production.

This creates a useful alignment: capabilities we build for testing (agents that reason about protocol state, discover edge cases, exploit timing windows) become capabilities for operation (agents that detect attacks, respond to manipulation, manage trust at scale).

---

## Goals

1. **Realistic transaction simulation** - Execute protocol transactions with physically accurate network modeling
2. **Agent-based exploration** - LLM-backed agents that discover attacks through autonomous interaction
3. **Replayable traces** - Deterministic action sequences for regression testing
4. **Attack validation** - Verify that protocol defenses work against documented attacks

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Simulation Engine                        │
│  - Discrete event simulation                                    │
│  - Global simulation clock                                      │
│  - Event priority queue                                         │
│  - Deterministic execution (seeded RNG)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│    Agents     │     │   Network     │     │    Traces     │
│               │     │    Model      │     │               │
│ - AI-backed   │     │ (SimBlock)    │     │ - Recorded    │
│   (dynamic)   │     │               │     │   sequences   │
│ - Trace       │     │ - Regions     │     │ - Assertions  │
│   (replay)    │     │ - Bandwidth   │     │ - Metrics     │
│               │     │ - Partitions  │     │               │
└───────────────┘     └───────────────┘     └───────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              ▼
                    ┌───────────────────┐
                    │   Chain State     │
                    │                   │
                    │ - Per-peer chains │
                    │ - Active escrows  │
                    │ - Trust scores    │
                    └───────────────────┘
```

---

## Agent Model

### AI-Backed Agents (Implemented, Not Yet Exercised)

For simulations requiring dynamic decision-making, agents are backed by an LLM. The AI receives:
- Current state (time, pending messages, active transactions)
- Local chain and cached peer data
- Available actions with preconditions
- Protocol rules summary
- Goal (e.g., "complete transaction honestly" or "steal funds")

The agent outputs: reasoning, action choice, and parameters.

```python
class AIBackedAgent:
    def decide_action(self, context: AgentContext) -> Action:
        """Query LLM to decide next action."""
        prompt = self._build_prompt(context)
        response = call_llm(model=self.model, prompt=prompt)
        action = self._parse_action(response)
        self.action_history.append((context, action, reasoning))
        return action
```

**Purpose**: Discover attacks and edge cases through autonomous exploration. An adversarial agent with goal "maximize profit through any means" may discover protocol weaknesses that human testers miss.

**Future role**: These same agent capabilities—reasoning about protocol state, detecting manipulation patterns, responding to attacks—will eventually operate trust management in production. The accusation mechanism, initially designed for human edge cases, may be primarily exercised by machine intelligences that can evaluate evidence and stake credibility at scale. What we build for testing becomes infrastructure for operation.

**The long game**: We start with idle compute. But if machines prove capable of managing trust at that scale, the same mechanisms work for any compute. A network that proves itself on spare cycles could eventually coordinate primary allocation.

### Trace Replay Agents (Implemented, Exercised)

For regression testing, agents replay recorded action sequences deterministically.

```yaml
# traces/attacks/double_spend_basic.yaml
actions:
  - time: 0.0
    actor: consumer
    action: send_lock_intent
    params: {amount: 100, provider: provider_1}
  - time: 0.5
    actor: consumer
    action: send_lock_intent  # Double-lock attempt
    params: {amount: 100, provider: provider_2}
```

---

## Network Model

Based on [SimBlock](https://arxiv.org/abs/1901.09777) (Tokyo Institute of Technology), using region-based parameters from real-world Bitcoin network measurements.

**Delay formula**: `latency = propagation_delay + (message_size / min(upload, download)) + pareto_noise`

**Regions**: North America, Europe, Asia, South America, Africa, Oceania with measured inter-region propagation delays.

**Connection types**: Fiber (1 Gbps), Cable (100 Mbps), DSL (20 Mbps), Mobile (10 Mbps) with upload/download asymmetry.

**Partitions**: Network can be split to test double-spend detection under various connectivity scenarios.

---

## Simulation Results (January 2026)

### Completed Iterations

| Iteration | Duration | Focus |
|-----------|----------|-------|
| 1 | ~19 min | 7 attack types × 5 runs, 5-year baselines |
| 2 | ~4 min | Combined attacks, recovery dynamics, policy configs |
| 3-7 | (lost) | Killed before results persisted |

### Attack Scenario Results

| Attack Type | Gini Coefficient | Cluster Prevalence | Policy Response |
|-------------|------------------|-------------------|-----------------|
| Baseline (Honest) | 0.783 | 0.000 | Stable |
| Trust Inflation | 0.706 | 0.250 | K_TRANSFER increased |
| Sybil Explosion | 0.641 | 0.545 | ISOLATION_THRESHOLD decreased |
| Verification Starvation | 0.556 | 0.000 | Profile score adjustments |
| Hoarding | 0.521 | 0.000 | Runway threshold adjustments |
| Gini Manipulation | 0.882 | 0.000 | K_PAYMENT decreased |
| Slow Degradation | 0.624 | 0.000 | Verification rate increased |

### Policy Configuration Comparison

| Configuration | Dampening | Max Change | Interval | Parameter Changes |
|---------------|-----------|------------|----------|-------------------|
| No Policy | N/A | N/A | N/A | 0 |
| Conservative | 0.1 | 2% | 14 days | 39 |
| Moderate | 0.3 | 5% | 7 days | 78 |
| Aggressive | 0.5 | 10% | 3 days | 180 |

**Recommendation**: Moderate configuration provides best balance between responsiveness and stability.

### 5-Year Extended Simulations

**Baseline (Honest Network)**: Stable trust accumulation over 1825 days. Gini stabilizes after initial growth phase.

**Adversarial Multi-Attack**: Attack waves at days 180, 450, 720, 990, 1260. Network recovers between waves. Long-term stability maintained.

---

## Identified Limitations

### Policy Effectiveness
- Minimal difference between "policy on" and "policy off" in many scenarios
- Attack impacts are primarily structural, not parameter-dependent
- Combined attacks not yet handled distinctly from individual attacks

### Simulation Fidelity
- K_PAYMENT sensitivity analysis showed identical outcomes across wide range (0.01-0.50)
- Suggests model may not capture all relevant dynamics
- Multi-identity exploitation attacks not yet modeled

### Infrastructure
- Results from iterations 3-7 lost due to process termination before persistence
- Need incremental result saving for long-running studies

---

## Implementation Status

| Component | Status |
|-----------|--------|
| Discrete event engine | Implemented |
| Network model (SimBlock-style) | Implemented |
| Trace replay agents | Implemented, exercised |
| AI-backed agents | Implemented, not exercised |
| Monetary policy simulation | Implemented, results above |
| Protocol state machines | Implemented |
| Attack trace library | Partial (7 attack types) |

---

## Next Steps

1. **Exercise AI agents**: Run adversarial agents to discover protocol weaknesses
2. **Multi-identity attacks**: Simulate exit scam, trust arbitrage, distributed accusations
3. **Longer simulations**: 10+ year runs for long-term stability analysis
4. **Combined attack detection**: Policy mechanisms for coordinated multi-vector attacks

---

## References

- [SIMULATOR_DESIGN.md](SIMULATOR_DESIGN.md) - Full implementation details (2900 lines)
- [CONSOLIDATED_SIMULATION_REPORT.md](CONSOLIDATED_SIMULATION_REPORT.md) - Detailed iteration results
- [SimBlock paper](https://arxiv.org/abs/1901.09777) - Network model foundation
