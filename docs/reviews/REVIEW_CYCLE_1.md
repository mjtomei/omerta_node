# Review Cycle 1: Technical Review

Date: January 2026

## Review Questions

The following 10 questions were posed to a critical reviewer agent:

1. What claims of novelty are made that have actually been done before?
2. What are the weakest contributions claimed?
3. Are the simulations methodologically sound?
4. What citations are missing that should be included?
5. What logical gaps exist in the arguments?
6. What contradicting evidence exists for the claims made?
7. What attack vectors are not adequately addressed?
8. What assumptions are unstated or unjustified?
9. What claims lack sufficient evidence?
10. What alternative explanations exist for the findings?

## Review Findings

### 1. Novelty Claims Already Done Before

- **Local trust computation**: EigenTrust [3] and PeerTrust [4] explored similar concepts in the early 2000s. The claim of "computing trust locally relative to each observer" extends but does not originate these ideas.
- **Age-based Sybil resistance**: Temporal defenses have been discussed since Douceur's original Sybil attack paper [6] and implemented in systems like Freenet's Web of Trust.
- **Trust propagation with decay**: Standard technique in graph-based trust systems dating to PageRank and EigenTrust.

### 2. Weakest Contributions

- Contributions 8, 9, 10 (framing contributions) are rhetorical rather than technical
- "Application to compute markets" (contribution 8) is integration work, not novel mechanism design
- The "resurgence thesis" (contribution 9) is a framing choice, not a falsifiable claim

### 3. Simulation Methodology Issues

- Uses Erdős-Rényi random graphs, but real P2P networks follow scale-free (Barabási-Albert) distributions
- Small sample sizes (50-100 nodes) may not represent behavior at scale
- No confidence intervals reported
- Static attack strategies don't model adaptive adversaries
- Missing long-con attack simulations (patient attackers building trust over years)

### 4. Missing Citations

- **FIRE** [Huynh et al., 2006]: Multi-source trust integration directly relevant to Omerta's approach
- **Subjective Logic** [Jøsang, 2016]: Mathematical foundations for trust uncertainty
- **PowerTrust** [Zhou & Hwang, 2007]: Power-law distributions in feedback patterns
- **Budish** [2018/2024]: Economic limits of blockchain - directly supports the cost-benefit argument
- **Gans & Gandal** [2019]: Proof-of-stake economic analysis
- **Seuken & Parkes** [2014]: Limitations of reputation systems
- **Jackson** [2008]: Social and economic networks theory

### 5. Logical Gaps

- **Detection ≠ Prevention**: Paper conflates 100% detection rate with security. Detection happens *after* double-spend; during detection window, both recipients believe they have valid payments.
- **Convergence not proven**: Claims local trust computation converges but provides no formal proof.
- **Bootstrap problem underspecified**: How are initial trusted participants selected? What prevents genesis-block manipulation?

### 6. Contradicting Evidence

- **Existing compute market struggles**: Golem, iExec, Render Network have operated for years with poor utilization, suggesting challenges beyond trust mechanisms.
- **Douceur impossibility**: Sybil attacks are fundamentally unsolvable without trusted identity verification - the paper acknowledges but may understate this limitation.

### 7. Attack Vectors Not Adequately Addressed

- Long-con attacks (build trust over years, then exploit)
- Adaptive attackers who learn detection patterns
- Economic attacks on parameter tuning (trigger policy adjustments to destabilize)
- Coordinated multi-identity exploitation

### 8. Unstated Assumptions

- Network connectivity remains high enough for gossip propagation
- Participants have stable internet connections
- Compute verification is actually possible during execution
- AI demand will continue growing faster than efficiency improvements

### 9. Claims Lacking Evidence

- "Machine intelligence creates unbounded demand" - speculative, based on extrapolation
- "Village trust mechanisms scale digitally" - analogy, not proof
- Optimal parameter values - chosen by intuition, not derived

### 10. Alternative Explanations

- Economic viability may depend more on user experience and network effects than trust mechanisms
- The 2000-2010 trust systems research may have quieted because the problems were harder than anticipated, not because blockchain distracted researchers
