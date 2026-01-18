# Response to Human Review (Sections through 4)

Date: 2026-01-17

---

## Table of Contents Comments

**"Why is double spend in simulation but not in attack analysis and defenses?"**

Good catch. Double-spend should be in Section 6 (Attack Analysis) since it's a fundamental attack vector. Currently it only appears in Section 7 (Simulation Results).

*Change*: Add Section 6.7 "Double-Spend Attacks" with the attack description, defenses, and cross-reference to the simulation results in 7.6.

---

**"Discussion may be mixing too many ideas."**

Agree. Section 8 currently covers: trust-cost spectrum, blockchain critique, Omerta's position, FHE comparison, social layer, interoperability, village analogy, machine intelligence, philosophy of law, methodology, limitations, and success factors. That's 12+ topics.

*Change*: Consider splitting Section 8 into "8. Discussion" (technical/economic analysis) and "9. Broader Context" (philosophy of law, village analogy, machine intelligence thesis). Or consolidate related subsections.

---

**"References section should have working links to references."**

*Change*: Add URLs/DOIs to all references where available. Most academic papers have stable links via DOI, arXiv, or Semantic Scholar.

---

## Abstract Comments

**"Initial question in abstract is not answered by this system because you trust the bootstrap nodes for bootstrap and identity attestation, and there is some centralized monetary policy."**

You're right. The "whom do you trust?" question implies we've eliminated trust, but we haven't—we've relocated it. The bootstrap nodes and monetary policy are trusted elements.

*Change*: Reframe the opening. Instead of implying we solved the trust problem, acknowledge we're exploring the middle ground. Something like: "Every decentralized system requires trust somewhere. The question is where to place it, how much to require, and at what cost."

---

**"Second paragraph is meaningless to someone not in the field and requires chasing citations."**

Agree. The EigenTrust/FIRE/TidalTrust name-dropping serves insiders but alienates general readers.

*Change*: Remove the citation-heavy paragraph from abstract. The abstract should be self-contained. Move detailed prior work discussion to Section 2.

---

**"The ideal is that there are global trust scores. The fact that the system still works with local scoring is a feature and mathematically interesting if it is true, but local scores are only approximations of some ideal global scoring mechanism."**

This is an important conceptual clarification. Local scores aren't the goal—they're a practical compromise because global scores require global consensus.

*Change*: Reframe local trust as a practical approximation of an ideal global score, not as inherently superior. The mathematical question is: how close do local approximations get to the global ideal?

---

**"But you don't need to say what you are extending in the abstract. You can state what we are doing more plainly."**

*Change*: Remove "extends prior work" framing from abstract. State what we do directly.

---

**"It is not true that only provable things impact trust scores because all misbehavior is in some way alleged."**

Correct. Even "verified" transactions involve assertions by parties who could be lying. The difference is we collect evidence and design for fallibility.

*Change*: Replace "only provably harmful actions affect scores" with something like "trust adjustments require evidence, and mechanisms account for the possibility that evidence itself may be contested or fabricated."

---

**"Last two paragraphs are strong, but is it true that we aren't saying this work is stronger? Don't we have a table that says it is?"**

Good point. The comparison table does claim Omerta has advantages. The humility framing contradicts the comparison claims.

*Change*: Be consistent. Either claim the advantages confidently or soften the comparison table. I'd suggest: keep the comparison table but frame it as "Omerta makes different tradeoffs that may be advantageous for compute markets specifically" rather than claiming universal superiority.

---

**"The general point about cost of the compute is true, but it's not true that the electricity cost of running a machine 24/7 is zero."**

You're absolutely right. Gaming PCs can draw 500W+ under load. That's real money.

*Change*: Replace "zero marginal cost" with "low marginal cost" or "cost below commercial alternatives." Add acknowledgment that software will need transparency about actual costs (electricity, bandwidth, wear) with user control mechanisms.

---

**"How do you know the primary customer will be machine intelligence workloads?"**

You're right to push back. It's a thesis, not a fact. The stronger claim is that machine intelligence amplifies human capability to use distributed compute.

*Change*: Reframe from "primary customers will be machine intelligence" to "machine intelligence dramatically increases the utility of distributed compute by enabling humans to orchestrate complex parallel workloads they couldn't manage manually."

---

**"Personally, I don't like the term AI because it feels demeaning. Please use machine intelligence or another term of your choice instead."**

*Change*: Global replace "AI" with "machine intelligence" throughout the paper.

---

## Introduction Comments

**"What is the incentive to defect in a decentralized computing system?"**

The defection model may be wrong. It's not primarily game-theoretic defection—it's:
1. Rare bad actors (bad apples)
2. Technical skill barriers
3. UX friction

*Change*: Reframe the problem statement. Instead of "incentive to defect," focus on: (a) protecting against rare malicious actors, (b) reducing technical barriers, (c) making participation easy enough to be worthwhile.

---

**"1.0 - This seems too early to be talking about related works."**

*Change*: Rename Section 1.0 to something like "Historical Context" or "Background" rather than treating it as a mini-related-works. Keep the narrative about why prior systems weren't deployed, but move citation-heavy comparisons to Section 2.

---

**"1.1 - This is a very strong claim. We should work to make this as true as possible. But maybe it is too strong given our stance on monetary policy."**

The "no special actors with elevated permission" claim is undermined by centralized monetary policy.

*Change*: Either (a) soften the claim to acknowledge monetary policy exception, or (b) strengthen the monetary policy mechanism to be more distributed. I recommend option (b)—we should invest effort in making monetary policy as distributed as possible to support this claim.

---

**"1.2 - The exchange coordination point should be more obsequious."**

You're right—the exchange delisting was a genuine community success, unlike the rollbacks.

*Change*: Acknowledge the exchange coordination more positively: "The community demonstrated genuine coordinated action when exchanges delisted contentious tokens—a legitimate exercise of collective values."

---

**"What does it mean for trust to be an API?"**

The metaphor isn't landing.

*Change*: Either explain the API metaphor clearly or replace it. The intended meaning: trust is an invisible interface layer that enables transactions, and you only notice it when it fails.

---

**"I feel like we should have mentioned FHE earlier than the first time we did."**

*Change*: Introduce the trust-cost spectrum (including FHE, MPC, blockchain, reputation) in Section 1.1 as the conceptual framework, rather than introducing FHE as a surprise in 1.2.

---

**"There is something special about the goods being traded that make a trust based system work better."**

This is a key insight that deserves expansion. Compute is:
- Revocable (you can always reclaim your machine)
- Low-stakes per transaction (bits of time, energy, wear)
- Often unused anyway (sunk cost)

*Change*: Expand on why compute is uniquely suited to trust-based systems compared to, say, financial assets or physical goods.

---

## Section 1.3 Comments

**"Is this just a practical synthesis? Do we use the same decay mechanisms? Do we have any new mechanisms?"**

This is the core question. We need to be honest about what's genuinely novel vs. adapted.

*Change*: Audit each mechanism to determine if it's (a) directly borrowed, (b) adapted with modifications, or (c) genuinely new. Be specific. If we lack novelty in some areas, we should either develop new mechanisms or be honest about being a synthesis.

---

**"'currency weight' doesn't mean anything on its own"**

*Change*: Replace "currency weight" with a brief description: "trust-proportional currency valuation that determines double-spend resolution severity."

---

**"You don't need the Framing contributions sub-bullet."**

*Change*: Remove the "Framing contributions" subsection. Keep the machine intelligence acknowledgment but integrate it elsewhere.

---

**"I don't like paragraphs that are dedicated to describing all the sections."**

*Change*: Remove the section roadmap paragraph. Let the paper flow naturally.

---

## Section 2 (Related Work) Comments

**"This section could use an introduction of what the subsections will contain to make the writing flow better."**

*Change*: Add a brief narrative introduction to Section 2 explaining the landscape we're surveying, in expository style.

---

**"One of the key differences between all these mechanisms and ours which I did not see mentioned anywhere yet is that rating is not supposed to be done by humans in our system."**

This is a major differentiator that's currently buried or missing. Human rating systems have fundamentally different dynamics than machine-automated rating.

*Change*: Add a prominent discussion of automated vs. human rating. This could be a new contribution: "machine-native trust measurement" where the expectation is that feedback is generated programmatically, with human oversight only for edge cases.

---

**"I don't think there is a difference between transaction metadata and transaction records."**

*Change*: Clarify or remove the distinction if it's not meaningful.

---

**"Did FIRE influence Omerta's design? I have never heard of it before."**

If FIRE didn't actually influence the design, we shouldn't claim we "borrowed" from it.

*Change*: Be honest about influences. Only cite as influences works that actually influenced the design.

---

**"How are high trust nodes different from power nodes?"**

Trust likely follows a power law, so we'll have power nodes in practice.

*Change*: Acknowledge that trust distribution will likely follow a power law, and discuss whether this is a feature (natural meritocracy) or a risk (centralization).

---

**"We still have a fake feedback attack surface."**

True. We've reduced it, not eliminated it.

*Change*: Replace claims of eliminating fake feedback with "reduced fake feedback attack surface through statistical analysis and anomaly detection."

---

**"TrustChain seems like it needs more attention. Are there any ideas we can reuse from here?"**

This needs serious investigation.

*Proposed action*: Read the TrustChain paper thoroughly. Specifically investigate:
- Their consensus mechanism
- Their cluster and graph analysis
- Their double-spend detection
- Whether we can adopt their implementations

---

**"The why this matters is simultaneously too insulting and too weak."**

*Change*: Rewrite "Why this matters" to be respectful of prior academic work while still making our case for practical contribution.

---

## Section 2.2 Comments

**"We can have an option in the network to only interact with attested identities at different levels of strictness."**

Good feature idea for implementation.

*Proposed action*: Add identity attestation levels as a feature. Design profiling mechanisms with transparency about costs/benefits of different filtering strategies.

---

**"I thought we were also requiring computational investment in the network."**

You're right—aging should require active participation, not just time passing.

*Change*: Clarify that effective aging requires computational contribution, not just existence. This limits the "pre-age identities" attack to well-resourced adversaries who must actually contribute.

---

## Section 2.3 Comments

**"It is not really true that we only require pairwise trust."**

Correct. Individual pairwise interactions have network-wide ripple effects.

*Change*: Reframe. We don't solve Byzantine faults, but we do need majority-honest behavior. The trust measurement exists precisely because pairwise interactions affect the whole economy.

---

**"It seems like FBA deserves more attention and analysis in relation to our own work."**

*Proposed action*: Deep-dive on FBA. Are we solving the same problem with a better top-tier selection mechanism?

---

## Section 2.4 Comments

**"MPC and circuit encryption style work seems like one of the more relevant comparisons."**

*Change*: Expand Section 2.4 significantly. Include overhead numbers, specific use cases where high-cost methods are justified, and why most workloads don't need them.

---

## Section 2.5 Comments

**"The altruistic distributed computing projects are one of the closest things we have to an ancestor."**

*Change*: Make the BOINC/Folding@home heritage more explicit. We're building on their vision with better UX and economic incentives.

---

**"We should be more explicit about the benefit we expect to get even though we are not taking a cut explicitly."**

*Change*: Add honest discussion of creator benefits: cheaper compute, research access to real systems, naturally higher trust scores for early participants.

---

## Section 2.6 Comments

**"What are some of the use cases where computational economics has been successful?"**

*Change*: Add concrete examples of ABM success stories to justify the methodology choice.

---

## Section 3 (System Architecture) Comments

**"This section seems to be lacking on specifics. We should develop the ideas and code more to shore this up."**

This is a major action item. Section 3 needs concrete implementation details.

*Proposed action*:
1. Read TrustChain paper thoroughly for reusable components
2. Prototype chain and market code
3. Rewrite Section 3 based on actual implementation

---

## Section 4 (Trust Model) Comments

**"This first point is good and what I wish you brought up earlier in related work and the intro."**

*Change*: Move the key insight (trust from verified transactions, not ratings) earlier—into the introduction.

---

**"What is Tbase? Trust in an identity? What is Ttransactions?"**

The formulas are introduced without context.

*Change*: Add clear definitions before formulas. Explain what each variable represents and why the reader should care.

---

**"What do some common graphs of trust over time look like for different types of users?"**

*Proposed action*: Generate trust trajectory visualizations from simulations showing different user archetypes (honest newcomer, established provider, attacker, etc.).

---

**"Why is the derate linear? How does the choice of this function compared to others impact users?"**

*Proposed action*: Run simulations comparing different derate functions (linear, exponential, step) and document tradeoffs.

---

**"What does it mean for trust to not be global? How can that possibly work?"**

This is the fundamental question about local trust. We need either:
(a) A clear explanation of how local trust works mathematically, or
(b) Adoption of a global trust mechanism like TrustChain's

*Proposed action*: Either develop rigorous theory for local trust convergence or adopt global trust approach.

---

**"4.4 - What does this function even mean? It is supposed to be a guiding principal of the design, but there is no impact_multiplier value that we have derived."**

The parameterized infractions formula is aspirational, not implemented.

*Change*: Either (a) derive actual values through simulation/analysis, or (b) remove the formula and describe the principle qualitatively.

---

## Summary of Major Action Items

### Immediate Text Changes
1. Global replace "AI" → "machine intelligence"
2. Reframe abstract opening (acknowledge trust is relocated, not eliminated)
3. Remove citation-heavy paragraph from abstract
4. Reframe local trust as approximation of global ideal
5. Replace "zero marginal cost" with "low marginal cost"
6. Clarify that aging requires computational contribution
7. Add honest discussion of creator benefits
8. Remove section roadmap paragraph
9. Add narrative introduction to Section 2

### Research/Investigation Required
1. **TrustChain deep-dive**: Read paper, evaluate reusable components for consensus, graph analysis, double-spend detection
2. **FBA analysis**: Are we solving the same problem with better top-tier selection?
3. **MPC/FHE overhead analysis**: Get real numbers for comparison
4. **ABM success stories**: Find concrete examples to justify methodology

### Implementation/Simulation Work
1. **Section 3 rewrite**: Prototype chain and market code first, then document
2. **Section 4 formulas**: Derive actual parameters through simulation
3. **Trust trajectory visualizations**: Generate graphs for different user types (honest newcomer, established provider, attacker)
4. **Derate function comparison**: Simulate linear vs. exponential vs. step functions
5. **Identity attestation levels**: Design and implement the feature
6. **Local vs. global trust**: Either develop rigorous theory or adopt global approach

### Design Decisions Needed
1. **Monetary policy**: How distributed should it be? Worth the effort to make the "no elevated permissions" claim hold?
2. **Automated vs. human rating**: This is a key differentiator—how do we make it central to the design?
3. **Power law trust distribution**: Feature or bug? How do we handle inevitable concentration?
