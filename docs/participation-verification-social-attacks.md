# Social and Psychological Attack Vectors

Trust scores are digital reputations. They're vulnerable to the same manipulation tactics humans have used against each other for millennia. This document maps real-world reputation attacks to our system.

---

## 1. Reputation Destruction Attacks

### 1.1 Character Assassination

**Real world:** Systematic campaign to destroy someone's reputation through accumulated accusations, whether true or not.

**In our system:**
```
Attacker wants to destroy Provider P:
  Week 1: Publish assertion "P was slow" (minor)
  Week 2: Publish assertion "P delivered wrong specs"
  Week 3: Get ally to publish "P seems unreliable"
  Week 4: Point to "pattern of problems"

Each individual assertion seems minor.
Accumulated, they create narrative of untrustworthiness.
```

**Why it works:** Humans (and algorithms) pattern-match. Multiple weak signals aggregate into strong perception.

**Defenses:**
- Require specific evidence hashes for each assertion
- Weight assertions by verifier's direct transaction history with subject
- Track assertion provenance (who tends to assert together)
- Allow subject to attach rebuttals to assertions
- Decay old assertions faster if not corroborated

---

### 1.2 Whisper Campaign

**Real world:** Spreading doubt through private channels that can't be tracked or rebutted.

**In our system:**
```
Attacker privately messages potential consumers:
  "Just FYI, I had problems with Provider P"
  "You didn't hear this from me, but P is sketchy"

These never appear on-chain.
P has no way to know or respond.
Consumers avoid P based on "private tips."
```

**Why it works:** Private communications bypass the transparent on-chain record.

**Defenses:**
- Make on-chain assertions the primary trust signal
- Discount claims that aren't backed by on-chain evidence
- Consumer education: "If it's not on-chain, it's just gossip"
- Hard to fully prevent—social channels always exist

---

### 1.3 Guilt by Association

**Real world:** Damage reputation by linking to disreputable people/groups.

**In our system:**
```
Provider P transacted with Bad Actor B (unknowingly)
Attacker publishes: "P has connections to B"
Even if P is honest, association creates doubt

Or: Attacker deliberately transacts with P
Then attacker does something bad
Now P is "associated with" attacker
```

**Why it works:** Trust graphs are public. Any connection can be weaponized.

**Defenses:**
- Don't weight indirect graph connections heavily
- Require direct interaction for assertions to count
- Time-bound associations (old connections matter less)
- Allow explicit disassociation statements

---

### 1.4 Scapegoating

**Real world:** Blame one party for systemic problems to protect others.

**In our system:**
```
Network has reliability issues (nobody's fault)
Cartel coordinates: "It's all Provider P's fault"
Multiple assertions all blame P
P becomes the scapegoat
Real issues never addressed, cartel protected
```

**Why it works:** Simple narratives are compelling. One villain is easier than systemic analysis.

**Defenses:**
- Statistical anomaly detection (is P really worse than baseline?)
- Compare P's metrics to network-wide metrics
- Look for coordinated timing of blame

---

## 2. Reputation Inflation Attacks

### 2.1 Astroturfing

**Real world:** Fake grassroots support—manufactured appearance of organic popularity.

**In our system:**
```
Provider P wants to appear trusted:
  Creates 50 aged identities (sock puppets)
  Each publishes glowing assertion about P
  Creates appearance of broad community trust

Real users see "50 people trust P" and follow
```

**Why it works:** Social proof is powerful. We assume crowds are right.

**Defenses:**
- Weight by transaction volume, not assertion count
- Cluster analysis (sock puppets often behave similarly)
- Require meaningful stake to publish assertions
- Track assertion diversity (same wording = suspicious)

---

### 2.2 Clique/Cabal Formation

**Real world:** In-groups that protect each other and exclude outsiders.

**In our system:**
```
Group of 10 providers form alliance:
  All give each other high trust scores
  All give outsiders low or no scores
  Block new entrants from gaining reputation

Creates closed economy that newcomers can't penetrate
```

**Why it works:** Mutual benefit creates stable coalitions. Gatekeeping protects incumbents.

**Defenses:**
- Detect closed subgraphs with few external connections
- Weight fresh external assessments higher
- Ensure new participants can earn trust without clique approval
- Identity age counts independent of clique membership

---

### 2.3 Halo Effect Exploitation

**Real world:** One positive attribute creates overall positive perception.

**In our system:**
```
Provider P is genuinely good at CPU compute
P gets high trust scores for CPU
P also offers GPU compute (actually poor quality)
Consumers assume GPU is also good (halo effect)
P exploits this perception gap
```

**Why it works:** Humans generalize. "Good at X" becomes "good overall."

**Defenses:**
- Context-specific trust scores (CPU trust vs GPU trust)
- Assertions specify what was verified
- Don't aggregate different capability scores into single number
- Require verification of each claimed capability separately

---

### 2.4 Authority Exploitation

**Real world:** Trusted position used to push false information.

**In our system:**
```
Well-known identity (high meta-trust) goes rogue:
  Has history of accurate assessments
  Suddenly starts publishing false assertions
  Others believe due to historical accuracy

Or: Authority is bribed/compromised
```

**Why it works:** We defer to authorities to save cognitive effort. Past accuracy predicts future accuracy—until it doesn't.

**Defenses:**
- Continuous verification (don't stop checking authorities)
- Anomaly detection (authority suddenly changes behavior)
- No single authority should dominate trust calculation
- Recent assertions weighted higher (catch behavioral changes)

---

## 3. Social Pressure Attacks

### 3.1 Groupthink / Conformity Pressure

**Real world:** People conform to perceived group consensus even against their own judgment.

**In our system:**
```
First few assertions about P say "trust 0.8"
Later verifiers see this consensus
Their own check suggests 0.6, but:
  "Maybe I measured wrong"
  "Everyone else says 0.8"
  "I'll just agree to avoid conflict"

Publishes 0.8 despite personal evidence of 0.6
```

**Why it works:** Conformity is deeply human. Disagreeing with group is costly.

**Defenses:**
- Commit-reveal scheme (commit before seeing others)
- Blind verification (don't show existing scores before publishing)
- Reward independent assessment, not agreement
- Track who provides novel information vs who copies

---

### 3.2 Social Proof Herding

**Real world:** "Everyone's doing it, so it must be right."

**In our system:**
```
Attacker seeds a few positive assertions about Bad Provider
Creates appearance of momentum
Legitimate users see "5 people trust this provider"
Assume others did due diligence
Add their own positive assertion without checking
Cascade of unverified trust
```

**Why it works:** We use others' actions as information shortcut.

**Defenses:**
- Display "verified" vs "unverified" assertions differently
- Require evidence for high-weight assertions
- Show skeptical information prominently (age, transaction count)
- Prompt users: "Have you personally verified this provider?"

---

### 3.3 Tribalism / In-Group Bias

**Real world:** Favor own group, distrust outsiders.

**In our system:**
```
Communities form around shared characteristics:
  "Linux users" trust each other
  "GPU miners" trust each other

Cross-group trust is low by default
Outsiders can't penetrate established communities
Creates fragmented trust graphs
```

**Why it works:** Shared identity creates trust shortcuts. "One of us" = safe.

**Defenses:**
- Ensure trust algorithm doesn't over-weight in-group
- Encourage cross-group verification
- Identity age matters regardless of group membership
- Objective verification transcends group boundaries

---

### 3.4 Moral Panic

**Real world:** Coordinated campaign creating fear about a group or practice.

**In our system:**
```
Rumor spreads: "Providers in region X are all scammers"
Coordinated assertions downgrade all X providers
Fear spreads through social channels
Legitimate X providers can't recover
Self-fulfilling: X providers leave, only scammers remain
```

**Why it works:** Fear is contagious. Categorical thinking is easy.

**Defenses:**
- Don't allow categorical assertions (only specific providers)
- Statistical comparison (are X providers actually worse?)
- Cool-down periods for trust score changes
- Require individual evidence, not group membership

---

## 4. Manipulation of Perception

### 4.1 Gaslighting

**Real world:** Making someone doubt their own observations.

**In our system:**
```
Consumer C verifies Provider P, finds problems
C publishes negative assertion
Coordinated response:
  "That's not what we saw"
  "Your measurements must be wrong"
  "Nobody else had this problem"

C doubts own observation, maybe retracts
```

**Why it works:** We doubt ourselves when contradicted by many.

**Defenses:**
- Cryptographic commitment to measurements (can't be changed)
- Encourage standing by verified observations
- Display "lone dissenter" assessments (often they're right)
- Don't require retraction; let assertions stand

---

### 4.2 Moving Goalposts

**Real world:** Changing standards to prevent someone from ever succeeding.

**In our system:**
```
Provider P is new, working to build trust
Clique sets standard: "Need 100 transactions for trust"
P achieves 100 transactions
Clique: "Actually, need 200 transactions"
P achieves 200
Clique: "Also need 6 months age"
...and so on
```

**Why it works:** Subjective standards can be infinitely adjusted.

**Defenses:**
- Objective, published standards for trust factors
- Age and transactions count regardless of who approves
- Can't change historical rules retroactively
- Algorithmic trust has defined inputs

---

### 4.3 Concern Trolling

**Real world:** Pretending to help while actually harming.

**In our system:**
```
Attacker poses as helpful community member:
  "I'm worried about Provider P, has anyone else noticed issues?"
  "Just asking questions about P's reliability"
  "I hope P is okay, but these numbers concern me"

Creates doubt without making falsifiable claims
Hard to counter "just asking questions"
```

**Why it works:** Plausible deniability. Can't be accused of attack.

**Defenses:**
- Require specific, falsifiable claims for assertions
- Track pattern of "questions" that always target same providers
- Don't let vague concern count as negative assertion

---

### 4.4 Tone Policing

**Real world:** Discrediting message based on how it's delivered, not content.

**In our system:**
```
Legitimate whistleblower reports fraud, but:
  Uses harsh language
  Seems "emotional" or "unprofessional"

Others dismiss report: "They seem unhinged"
Fraud continues because messenger was discredited
```

**Why it works:** Easier to attack presentation than address content.

**Defenses:**
- Focus on evidence, not tone of assertion
- Structured assertion format (hard to inject tone)
- Separate evidence hashes from commentary
- Let cryptographic proofs speak for themselves

---

## 5. Exploitation of Forgiveness

### 5.1 Redemption Exploitation

**Real world:** Abuse systems designed to give second chances.

**In our system:**
```
Bad actor exploits trust
Gets caught, trust drops
Waits for decay period / redemption window
Rebuilds just enough trust
Exploits again
Repeat cycle
```

**Why it works:** Forgiveness mechanisms assume good faith.

**Defenses:**
- Track pattern of trust drops (repeated = permanent penalty)
- Longer recovery periods for each offense
- Some actions are unforgivable (permanent identity blacklist)
- Recovery requires more proof than initial trust building

---

### 5.2 Strategic Incompetence

**Real world:** Claim ignorance to avoid responsibility.

**In our system:**
```
Provider underdelivers
When caught: "Sorry, technical difficulties"
Gets benefit of the doubt
Repeats pattern with different excuse each time
"Accidental" failures accumulate value
```

**Why it works:** Hard to distinguish malice from incompetence.

**Defenses:**
- Track failure patterns regardless of excuse
- Outcomes matter more than intentions
- Consistent underperformance = low trust, no matter why
- Statistical detection of "too many coincidences"

---

## 6. Information Control

### 6.1 Gatekeeping

**Real world:** Control access to reputation-building opportunities.

**In our system:**
```
Cartel controls high-value compute jobs
Only routes jobs to cartel members
Outsiders can't build transaction history
Without transaction history, can't build trust
Can't compete, cartel maintains control
```

**Why it works:** Reputation requires opportunity. Control opportunity, control reputation.

**Defenses:**
- Ensure jobs are distributed by algorithm, not gatekeepers
- Identity age accrues regardless of job access
- Multiple ways to demonstrate capability (challenges, benchmarks)
- Consumer diversity prevents single gatekeeper

---

### 6.2 Selective Memory / History Erasure

**Real world:** Forget inconvenient truths, amplify convenient ones.

**In our system:**
```
Provider P had problems 6 months ago
P is now better, but old assertions remain
Attacker keeps referencing old assertions
Refuses to acknowledge improvement

Or opposite:
P was good 6 months ago
P is now bad
Allies only reference old positive assertions
```

**Why it works:** Which history you emphasize shapes perception.

**Defenses:**
- Time-weight recent assertions higher
- Clear visibility into assertion timestamps
- Mandatory decay of old assertions
- Current verification overrides historical claims

---

### 6.3 Sockpuppet Consensus Manufacturing

**Real world:** One person pretending to be many to fake agreement.

**In our system:**
```
Attacker controls identities A, B, C, D, E
All publish same assessment of Provider P
Appears to be 5-person consensus
Actually single attacker
```

**Why it works:** We trust agreement. Fake agreement = fake trust.

**Defenses:**
- Behavioral analysis (same patterns, timing)
- Require diverse transaction history per identity
- Sybil detection via network analysis
- Don't count near-identical assertions multiple times

---

## 7. Defense Philosophy

### 7.1 Core Principles

1. **Objective truth exists.** Providers either deliver compute or they don't. Ground trust in verifiable measurements, not social consensus.

2. **Evidence over assertion.** Assertions without evidence are gossip. Weight evidence hashes heavily.

3. **Time reveals truth.** Manipulation is expensive to sustain. Long-term behavior is more informative than short-term.

4. **Diversity resists capture.** Many independent verifiers are harder to corrupt than a few.

5. **Transparency enables accountability.** All assertions on-chain means patterns are detectable.

### 7.2 Structural Defenses

| Defense | Attacks Mitigated |
|---------|-------------------|
| Commit-reveal for assertions | Groupthink, copying, front-running |
| Evidence hashes required | Character assassination, concern trolling |
| Time-weighted assertions | Selective memory, redemption exploitation |
| Transaction history required | Astroturfing, sockpuppets |
| Behavioral clustering analysis | Cabals, sockpuppets, coordinated attacks |
| Context-specific trust | Halo effect |
| Blind verification option | Conformity pressure |
| Statistical anomaly detection | Scapegoating, moral panic |
| Identity age as factor | Sybil attacks, astroturfing |
| Maximum trust caps | Long-con, authority exploitation |

### 7.3 Cultural Defenses

Technical defenses aren't enough. The community culture matters:

1. **Celebrate dissent.** Lone dissenters are often right. Don't punish disagreement.

2. **Verify, don't trust.** Even respected authorities can be wrong. Check yourself.

3. **Evidence is king.** "I heard" means nothing. "Here's the measurement" means everything.

4. **Assume good faith initially, but verify.** New participants deserve a chance, but not blind trust.

5. **Patterns matter more than incidents.** One failure isn't damning. Repeated failures are.

---

## 8. Open Questions

1. **How to balance forgiveness vs exploitation?** Too forgiving = exploitation. Too harsh = no second chances.

2. **How to detect coordination without central surveillance?** Pattern detection typically requires global view.

3. **How to resist social pressure technically?** Commit-reveal helps, but social channels exist outside the system.

4. **How to educate users about manipulation tactics?** Technical users might understand; general users might not.

5. **How to prevent trust stratification?** Early entrants have advantages. How to keep system accessible?

---

## 9. Red Team Scenarios

### Scenario A: Hostile Takeover

```
Well-funded attacker wants to control network:
1. Creates 100 identities 1 year before attack
2. Builds modest reputation on each
3. Coordinates to downgrade all non-controlled providers
4. Consumers forced to use attacker's providers
5. Attacker now controls significant compute

Detection: Cluster analysis, anomalous coordination timing
Prevention: No single cluster should dominate trust graph
```

### Scenario B: Targeted Destruction

```
Competitor wants to destroy specific provider:
1. Whisper campaign in social channels
2. Sockpuppet assertions with varied wording
3. Concern trolling in public forums
4. Coordinated negative verification logs
5. Target's trust score collapses

Detection: Statistical anomaly (sudden drop without baseline change)
Prevention: Rate-limit trust score changes, require diverse evidence
```

### Scenario C: Trust Laundering

```
Bad actor wants to clean reputation:
1. Transfers assets to new identity
2. Gets allies to vouch for new identity
3. Old identity abandoned
4. New identity has clean slate
5. Repeat when caught

Detection: Behavioral similarity, asset flow tracking
Prevention: Value accrues to old identities, new starts from zero
```

### Scenario D: Manufactured Consensus

```
Cartel wants to control "truth":
1. Creates network of seemingly-independent scorers
2. All score providers similarly
3. Outsiders defer to apparent consensus
4. Cartel controls which providers succeed

Detection: Independence testing (do scorers ever disagree?)
Prevention: Reward novel information, penalize pure agreement
```

---

## 10. Summary

Human trust systems are vulnerable to millennia of evolved manipulation tactics. Our digital trust system inherits these vulnerabilities. Pure technical solutions are insufficient—we also need:

1. **Structural incentives** that make manipulation expensive
2. **Detection mechanisms** for coordination and anomalies
3. **Cultural norms** that value verification over social proof
4. **Education** about manipulation tactics
5. **Humility** about our system's limitations

The goal isn't a manipulation-proof system (impossible). It's a system where manipulation is expensive, detectable, and less effective than honest participation.
