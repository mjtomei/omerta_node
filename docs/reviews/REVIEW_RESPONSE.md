# Review Response Document

This document tracks responses to critical reviews and flags decisions requiring further discussion.

---

## Response to Review Cycle 1

### R1.1 Novelty Claims (addressed)

**Review finding**: Local trust computation, age-based Sybil resistance, and trust propagation with decay were done before.

**Response**:
- Restructured Section 1.3 to distinguish "Adapted from prior work" vs "Novel contributions"
- Added Section 1.0 "Brief History of Trust Systems" acknowledging EigenTrust, FIRE, Subjective Logic, PowerTrust
- Reframed paper as "practical synthesis" rather than claiming false novelty
- Still claim genuine novelty for: trust from verified transactions only, automated monetary policy, double-spend resolution via currency weight

### R1.2 Weak Contributions (addressed)

**Review finding**: Contributions 8-10 are rhetorical, not technical.

**Response**: Relabeled as "Framing contributions (not technical novelty)" in Section 1.3.

### R1.3 Simulation Methodology (partially addressed)

**Review finding**: Erdős-Rényi topology, small samples, no confidence intervals, static attackers.

**Response**:
- Added Barabási-Albert scale-free topology option to simulation code
- Acknowledged limitations in paper

**Not yet addressed**:
- Confidence intervals not added
- Long-con attack simulations not implemented
- Adaptive attacker simulations not implemented
- Sample sizes remain 50-100 nodes

**Concern for discussion**: Should we invest time in larger-scale simulations and confidence intervals, or is the current directional evidence sufficient for a practical implementation paper?

### R1.4 Missing Citations (addressed)

**Response**: Added citations [35-41] for FIRE, Subjective Logic, PowerTrust, Budish, Gans & Gandal, Seuken & Parkes, Jackson.

### R1.5 Logical Gaps (partially addressed)

**Review finding**: Detection ≠ prevention; convergence not proven; bootstrap underspecified.

**Response**:
- Added explicit clarification in Section 7.6.1 that detection happens after double-spend, not before
- Acknowledged convergence proof is missing in Limitations section

**Not yet addressed**:
- Formal convergence proof
- Bootstrap problem specification

**Concern for discussion**: The bootstrap problem (who are the initial trusted participants?) is genuinely underspecified. Options include:
1. Specify genesis participants explicitly (centralized start)
2. Use proof-of-work or proof-of-stake for initial period only
3. Bridge from existing identity systems
4. Leave unspecified as deployment decision

Which approach should we document?

### R1.6 Contradicting Evidence (addressed)

**Response**: Added limitations acknowledging Golem/iExec struggles and Douceur impossibility.

### R1.7 Attack Vectors (partially addressed)

**Review finding**: Long-con, adaptive, economic attacks on parameters, coordinated multi-identity.

**Response**: Acknowledged in Limitations section but not simulated.

**Concern for discussion**: How much simulation of sophisticated attacks is appropriate for a practical implementation paper vs. an academic security paper?

### R1.8-R1.10 Assumptions, Evidence, Alternatives (addressed)

**Response**: Added explicit acknowledgments in Limitations that AI demand thesis is speculative and that alternative explanations exist for compute market struggles.

---

## Response to Review Cycle 2

### R2.11 Clarity Issues (partially addressed)

**Review finding**: Currency weight, trust vs effective trust, Section 7.6 transitions unclear.

**Response**: Not directly addressed yet.

**Concern for discussion**: Should we add a glossary or terminology section? The distinction between trust_base, effective_trust, and currency_weight is important but potentially confusing.

### R2.12 Verbose Sections (addressed)

**Response**:
- Condensed Section 8.6 "vision" paragraph (removed TCP/UDP analogy)
- Merged Section 8.7 "What Omerta provides" into single paragraph
- Condensed Section 8.7 AI enablement (removed redundant table)
- Condensed Section 8.8 from ~40 lines to ~15 lines

### R2.13 Repetition (partially addressed)

**Review finding**: Spectrum and village metaphors over-repeated; key insights under-emphasized.

**Response**: Reduced some repetition through verbosity cuts.

**Not yet addressed**: Under-emphasized points (detection window risk, EigenTrust differences, economic numbers) not yet highlighted more prominently.

**Concern for discussion**: The "spectrum" framing is core to the paper's argument. How much repetition is appropriate for reinforcement vs. annoying?

### R2.14 Structural Changes (not addressed)

**Review finding**: Consider moving Section 1.0 to Section 2; reorganize Section 7; consolidate Section 8.

**Response**: Not implemented.

**Concern for discussion**: Major structural changes would require significant rewriting. Is this worth doing for a practical implementation document?

### R2.15 Punch Lines (addressed)

**Response**: Added 7 punch lines at suggested locations:
- "Trust is the API you pay for but never see—until it fails." (Section 1.2)
- "Blockchain solved the Byzantine Generals Problem. Compute markets don't have Byzantine generals—they have landlords and tenants." (Section 2.3)
- "If you have the key, you ARE the identity—there is no 'stealing,' only 'being.'" (Section 6.5)
- "Humans run out of ideas; machines run out of compute." (Section 7.5)
- "The village knew; the internet forgot; we're teaching it to remember." (Section 8.7)
- "AI is both the demand and the supply..." (Section 8.7)
- "We don't need zero trust. We need enough trust—earned, local, and proportional to what's at stake." (Conclusion)

---

## Uncertain Decisions Requiring Discussion

### Design Decisions

#### D1: Trust exclusively from transactions vs. incorporating witness reports

**Current choice**: Derive trust only from verified on-chain transactions, excluding subjective ratings and witness reports.

**Alternative**: FIRE [35] and other systems incorporate witness reputation—third-party reports about entities you haven't transacted with directly.

**Uncertainty**: Excluding witness reports eliminates the fake feedback attack surface but limits information for trust computation. A new consumer cannot benefit from warnings others might provide about bad providers.

**Question**: Is the fake feedback attack surface serious enough to justify losing witness information? Or should we allow optional witness reports with heavy credibility discounting?

#### D2: Local trust computation vs. global scores

**Current choice**: Each observer computes trust relative to their own network position.

**Alternative**: EigenTrust [3] computes global scores visible to everyone.

**Uncertainty**: Local computation prevents trust arbitrage but makes the system harder to reason about. Two observers may compute very different trust scores for the same entity.

**Question**: Should we provide tools that help users understand why their trust scores differ from others? Or does the complexity argue for global scores?

#### D3: Age derate vs. age bonus

**Current choice**: Age removes a penalty from young identities but never adds trust to old ones.

**Alternative**: Age could provide positive trust bonus, rewarding longevity.

**Uncertainty**: Derate-only prevents "aging" attacks where dormant identities accumulate trust through existence. But patient legitimate participants don't get credit for patience.

**Question**: Is there a hybrid approach? E.g., age derate for first year, then no effect, then small bonus after 5+ years?

#### D4: "Both keep coins" double-spend resolution

**Current choice**: When double-spend is detected, both recipients keep the coins (inflationary) and attacker is penalized.

**Alternative**: Claw back from one or both recipients; wait for global agreement before any finality.

**Uncertainty**: "Both keep" avoids punishing innocent recipients but creates inflation and may incentivize attacker-recipient collusion.

**Question**: Should high-value transactions require "wait for agreement" by default? What threshold defines "high-value"?

#### D5: 5× penalty multiplier

**Current choice**: Attackers lose 5× what they attempted to double-spend.

**Alternative**: Lower multipliers (2×, 3×) or multipliers proportional to network connectivity.

**Uncertainty**: 5× ensures attacks are unprofitable even at 50% detection, but may be too harsh for honest mistakes (wallet bugs).

**Question**: Should there be a mechanism to distinguish malice from error? Appeal process?

### Simulation Methodology

#### S1: Network topology models

**Current state**: Added Barabási-Albert scale-free option alongside Erdős-Rényi.

**Uncertainty**: Real P2P networks may follow neither model exactly. Geographic clustering, churn dynamics, and varying power-law exponents could affect results.

**Question**: Is directional evidence from idealized topologies sufficient, or do we need empirical network data?

#### S2: Sample sizes and statistical power

**Current state**: 50-100 node simulations.

**Uncertainty**: Results may not scale to 10,000+ nodes. No formal statistical power analysis.

**Question**: What scale of simulation is appropriate for a practical implementation paper? Is it worth the compute investment to run 10,000-node simulations?

#### S3: Missing adversarial scenarios

**Not simulated**:
1. Long-con attacks (build trust over years, then exploit)
2. Adaptive attackers (observe detection, adjust strategy)
3. Coordinated multi-identity attacks
4. Economic attacks on parameter tuning

**Question**: Should we implement these simulations, or is acknowledging them as limitations sufficient?

### Theoretical Gaps

#### T1: Convergence proof

**Current state**: We claim local trust computation converges but don't prove it.

**Question**: Is a formal convergence proof necessary for a practical implementation paper? Or is empirical convergence in simulations sufficient?

#### T2: Privacy-trust tradeoff quantification

**Current state**: We claim Omerta trades privacy for trust but don't quantify.

**Question**: Is a formal information-theoretic analysis needed? What would it add?

### Empirical Claims

#### E1: Machine intelligence creates unbounded demand

**Current state**: Speculative thesis based on AI capability extrapolation.

**Question**: Should we soften this claim further, or is the current "speculative" framing sufficient?

#### E2: Village trust scales digitally

**Current state**: Analogy, not proof.

**Question**: Is the village analogy helpful for intuition, or does it over-promise?

---

## Summary of Outstanding Items

**High priority (affects core claims)**:
- D1: Witness reports decision
- D4: Double-spend resolution for high-value transactions
- Bootstrap problem specification

**Medium priority (affects rigor)**:
- S2: Sample size decisions
- S3: Which adversarial scenarios to simulate
- T1: Whether to add convergence proof

**Lower priority (polish)**:
- R2.11: Terminology clarity
- R2.13: Emphasis balance
- R2.14: Structural reorganization

---

*This document will be updated as decisions are made.*
