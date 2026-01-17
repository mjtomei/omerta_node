# Review Cycle 3: Comprehensive Literature Search + Technical and Text Quality Review

Date: January 2026

## Phase 1: Literature Search Summary

The reviewer conducted an extensive literature search before evaluating the paper. Key findings:

### Trust and Reputation Systems
- **EigenTrust** (Kamvar et al., 2003) - Foundational PageRank-style trust algorithm
- **MeritRank** (2022) - Recent work on Sybil-tolerant reputation that bounds rather than prevents attacks
- **Advogato Trust Metric** - Flow-based attack-resistant trust with known vulnerabilities
- **Trust Transitivity in Social Networks** (Richters & Peixoto, 2011) - Critical findings on absolute trust requirements
- **TidalTrust** - Computes trust relative to querying user (personalized)
- **Personalized EigenTrust (PET)** - Local/personalized variant of EigenTrust
- **BarterCast** - Computed trust from actual file transfer records

### Sybil Resistance
- **Douceur's original Sybil attack paper** - Foundational impossibility result
- **SybilGuard and SybilLimit** - Social graph defenses
- **ReCon** - Reputation-based consensus for Sybil resistance

### Consensus and Blockchain Economics
- **Stellar Consensus Protocol** (Mazières) - Federated Byzantine Agreement
- **"The Sum of Its Parts"** (Distributed Computing, 2022) - Critical analysis of FBA systems
- **Nothing-at-stake analysis** - Economic security of PoS

### Mechanism Design
- **Tadelis (2016)** - Comprehensive review of reputation in online marketplaces
- **Dellarocas (2005)** - Mechanism design for moral hazard
- **Whitewashing attacks literature** - Identity reset vulnerabilities
- **Friedman & Resnick** - Whitewashing and newcomer problem

### Simulation Methodology
- **Fagiolo et al. (2007)** - Critical guide to ABM validation
- **ABIDES-Economist** - Modern agent-based economic simulation

### Volunteer Computing
- **BOINC** (Anderson, 2019) - Comprehensive platform analysis including result verification
- **Homogeneous redundancy** - Result verification in volunteer computing

---

## Phase 2: Review Findings

### Technical Questions

#### 1. Novelty Claims Already Done Before

a) **"Trust from verified transactions only" (contribution #5)**: BarterCast and related systems computed trust from actual file transfer records. Advogato derived trust from certification actions rather than ratings.

b) **"Local trust computation"**: Explored in Personalized EigenTrust (PET) and TidalTrust, which compute trust relative to querying user.

c) **"Currency weight scales with network performance"**: Echoes work on trust network analysis with subjective logic showing how network structure affects trust propagation.

d) **Age-based Sybil resistance**: Standard practice, implemented in Freenet's Web of Trust.

#### 2. Weakest Contributions

a) **"The resurgence thesis" (contribution #9)**: Framing observation, not technical contribution. Speculative and unfalsifiable.

b) **"AI-assisted design methodology" (contribution #10)**: Transparency, not a contribution.

c) **"Application to compute markets" (contribution #8)**: Domain application overstated as "novel contribution."

d) **"Automated monetary policy" (contribution #6)**: Simulation results show "limited impact on final outcomes" - weak if it doesn't work well.

#### 3. Simulation Methodology Issues

a) **Insufficient detail for reproducibility**: Missing number of agents, runs, variance measures, confidence intervals, seeds, complete parameters.

b) **Missing validation against stylized facts**: No comparison to real P2P network data or existing compute marketplace behavior.

c) **Cherry-picked scenarios**: Attack scenarios appear designed rather than systematically derived. No combinations or adaptive attackers.

d) **Overfitting concern**: No held-out test set or cross-validation.

e) **Agent sophistication unclear**: Are attackers optimizing? Using RL? Fixed strategies?

f) **Missing baseline comparisons**: No comparison to EigenTrust, FIRE, or blockchain alternatives under same attacks.

#### 4. Missing Citations

**Critical:**
- **MeritRank (2022)**: Sybil tolerance through bounding attacks
- **"The Sum of Its Parts" (2022)**: Critical analysis of FBA systems
- **Richters & Peixoto (2011)**: Trust transitivity requirements - "non-zero fraction of absolute trust required"
- **Friedman & Resnick**: Whitewashing attacks and newcomer problem
- **SybilLimit (Yu et al., 2008)**: Improved bounds over SybilGuard
- **CanDID**: Sybil-resistant decentralized identity
- **BOINC homogeneous redundancy**: Result verification in volunteer computing
- **Nash equilibrium and free-riding in P2P literature**
- **TidalTrust / Personalized EigenTrust**: Local trust computation prior art
- **BarterCast**: Trust from transactions prior art
- **Tadelis (2016)**: Comprehensive reputation review
- **Advogato trust metric analysis**: Shows security proof flaws

#### 5. Logical Gaps

a) **"Unbounded AI demand"**: No evidence. Jumps from "large demand" to "unbounded" without justification.

b) **Local trust → global stability**: Doesn't prove locally rational behavior produces globally desirable outcomes. Game theory shows Nash equilibria can be globally suboptimal.

c) **Age as credential**: Can be purchased (buy old accounts) or pre-accumulated. Not quantified.

d) **"Village trust at global scale"**: Villages had repeated interactions; global networks have one-shot interactions. Analogy breaks down.

e) **Detection → security**: 100% detection doesn't mean security. What about irrational attackers or those who don't value future participation?

#### 6. Contradicting Evidence

a) **Trust transitivity limitations**: Richters & Peixoto found trust propagation requires "non-zero fraction of absolute trust" - Omerta doesn't address this.

b) **Advogato vulnerabilities**: Research showed attacker can gain trust proportional to *square* of attack cost, not linear.

c) **Decentralized compute market struggles**: Golem and iExec struggled despite years of operation.

d) **EigenTrust attack vulnerabilities**: "Vulnerable to community structure and targeted attacks based on eigenvector centrality." May apply to Omerta.

e) **FBA "open membership" limits**: "The Sum of Its Parts" found only approved nodes become relevant for consensus.

#### 7. Attack Vectors Not Adequately Addressed

- **Collusion with rational adversaries**: k-resilient equilibria where coalitions coordinate optimally
- **Whitewashing attacks**: Extensive literature not addressed
- **Strategic timing attacks**: Timing misbehavior with partitions or high-value transactions
- **Reputation bootstrapping attacks**: Cold-start vulnerabilities
- **Marketplace manipulation**: Wash trading, spoofing
- **Verification oracle attacks**: Compromised or colluding verifiers
- **Long-range attacks**: Old keys used for attacks
- **Eclipse attacks**: Isolating nodes from honest network

#### 8. Unstated/Unjustified Assumptions

- Gossip network properties
- Attacker rationality (ignores nation-states, ideological adversaries)
- Churn rates
- Compute verifiability (what workloads are actually verifiable?)
- Transaction costs
- Social graph reflects real trust
- Parameter stability
- AI capability trajectory

#### 9. Claims Lacking Evidence

- "Dramatically lower cost" - no quantitative comparison
- "100% detection rate" - under what conditions?
- "Sub-200ms finality" - no real-world validation
- "200% increase in compute" - no validation against real data
- "AI enables fair trust at scale" - asserted but never demonstrated
- "Machine intelligence guarantees undersupply" - speculative claim as fact
- "Working system" - implementation status unclear

#### 10. Alternative Explanations

- Simulation results may reflect parameter tuning
- Attack scenario selection bias
- Economic value from market fragmentation, not value creation
- Double-spend stability from overly harsh penalties
- AI demand thesis as motivated reasoning

---

### Text Quality Questions

#### 11. Unclear Ideas

- Trust assertion mechanics (Section 4.1)
- Cluster detection specifics (Section 6.1)
- "Currency weight" concept (Section 7.6.5)
- Order book without global consensus (Section 3.3)
- Verification process details (Section 3.4)
- Transfer burn economic implications (Section 5.2)
- What AI actually does in the system (Section 8.7)

#### 12. Verbose Sections

- Section 8.7 "Scaling Trust: From Villages" (~1000 words for simple analogy)
- Section 1.0 "Brief History" longer than necessary
- Section 8.4 repeats trust-cost spectrum
- Trust spectrum discussion appears 6+ times (Abstract, 1.2, 8.1, 8.4, 8.6, Section 9)
- Lines 61-69 (historical episodes) could be footnote
- Lines 455-497 (machine intelligence demand) repeats same point

#### 13. Repetition Issues

**Over-repeated:**
- Trust-cost spectrum (6+ times)
- FHE analogy (3 times)
- Village visibility observation (3 times)
- AI-as-enabler claim (4+ times without substantiation)

**Under-emphasized:**
- Limitations section buried at end
- Detection ≠ prevention distinction
- Bootstrap problem (mentioned once, no solution)
- Attack economics never quantified
- Parameter sensitivity given "limited impact" finding
- What makes compute markets different (core premise)

#### 14. Structural Suggestions

- Move limitations earlier (Section 2 or 3)
- Consolidate trust-cost spectrum to one treatment
- Add "System Overview" figure
- Separate simulation methodology from results
- Create "Assumptions" section
- Restructure Section 8 by topic
- Give machine intelligence demand thesis standalone section
- Add "Threat Model" section

#### 15. Suggested Punch Lines

**Existing good lines noted:**
- "Trust is the API you pay for but never see—until it fails."
- "Blockchain solved the Byzantine Generals Problem. Compute markets don't have Byzantine generals—they have landlords and tenants."
- "Humans run out of ideas; machines run out of compute."
- "The village knew; the internet forgot; we're teaching it to remember."

**Suggested additions:**
- Opening: "Every decentralized system claims to be trustless. None actually are—they just hide who you're trusting."
- Detection point: "We don't stop the crime; we make sure it doesn't pay."
- Economic model: "Your reputation is your stake. No tokens required."
- Bootstrap: "Every network starts as a village. The question is whether it can grow into a city."
- Limitations: "Omerta doesn't solve Sybil attacks—no system does. We make them expensive enough to matter."

#### 16. Section Flow and Transitions

Do the sections and subsections properly flow into each other in a way that is not too abrupt? Identify:
- Transitions that feel jarring or disconnected
- Sections that end without setting up what comes next
- Subsections that begin without context from what preceded them
- Missing bridging sentences or paragraphs
- Topics that appear to jump without logical connection

#### 17. Recommended Figures/Tables

a) **System Architecture Diagram**: On-chain data, trust computation, payments, market, session lifecycle

b) **Trust-Cost Spectrum Visualization**: 2D plot positioning all approaches

c) **Trust Propagation Example**: Small network graph with numerical examples

d) **Payment Split Curves**: provider_share vs. trust_score for different K_PAYMENT values

e) **Attack Economics Table**: Setup Cost | Time Required | Expected Gain | Expected Loss | ROI

f) **Simulation Network Topology**: Visualization for reproducibility

g) **Double-Spend Timeline**: Sequence diagram of detection flow

h) **Comparison Table with Baselines**: Omerta vs. EigenTrust vs. blockchain on key metrics

i) **Demand Curve Visualization**: Human-only vs. human+AI markets

---

## Summary

**Strengths:**
- Honest acknowledgment of limitations and prior work
- Clear writing in most sections
- Novel framing of trust-cost tradeoff
- Thoughtful domain analysis

**Critical Weaknesses:**
1. Simulation methodology lacks rigor
2. Several "novel" contributions have prior art
3. Unbounded AI demand thesis unsupported
4. Key attacks underaddressed (whitewashing, collusion, cold-start)
5. Implementation status unclear
6. Excessive repetition
7. Limitations buried

**Recommendation:** Major revision required.
