# Manipulation Detection and Prevention

Concrete mechanisms to detect and prevent trust manipulation. These are implementable defenses, not just principles.

---

## 0. Identity-Bound VM Access

VM access is tied directly to the consumer's on-chain identity private key. No key = no access. This makes identity theft useless.

### Core Concept

```
Traditional VM access:
  Provider gives you password/key → Anyone with password can access
  Identity theft: Steal credentials → Access VM → Exploit trust

Identity-bound access:
  Your on-chain private key IS your VM credential
  Identity theft: Steal identity... but can't access VM without private key
  If you have private key, you ARE the identity
```

### Authentication Methods

**SSH with Identity Key**: The consumer's on-chain public key is installed in the VM's authorized_keys. Password authentication is disabled. Only the holder of the matching private key can log in.

**Challenge-Response**: For API access, the VM generates a random challenge (nonce). The consumer signs it with their identity private key. The VM verifies the signature against the on-chain public key.

**Mutual TLS**: The consumer generates a certificate containing their identity ID, signed by their identity private key. The VM verifies the certificate against the on-chain public key.

**One-Time Tokens**: Consumer generates short-lived tokens (e.g., 60 seconds) signed by their identity key. VM verifies signature and checks for replay.

### Provider-Side Enforcement

When a session activates, the provider configures the VM:
1. Disable password authentication
2. Clear any existing authorized keys
3. Add ONLY the consumer's identity public key
4. Configure API auth to require identity signature
5. Log all access attempts

### Why This Defeats Identity Theft

```
Without identity-bound access:
  1. Attacker steals identity record (public key, history)
  2. Rents VM using stolen identity's reputation
  3. Provider gives access credentials
  4. Attacker uses VM, exploits trust
  ✗ Identity theft successful

With identity-bound access:
  1. Attacker steals identity record
  2. Tries to rent VM using stolen identity
  3. Provider configures VM for stolen identity's public key
  4. Attacker can't log in - doesn't have private key
  ✓ Identity theft useless
```

**The only way to use an identity is to have its private key. If you have the private key, you ARE the identity. There's no "stealing" - only "being."**

### Session-Derived Keys

For additional security, derive session-specific keys from the identity key. The identity key never touches the VM directly - only a derived key specific to that session. Same security, better compartmentalization.

---

## 1. Graph Analysis

### 1.1 Collusion Detection via Clustering

Identify tightly-connected subgraphs that don't interact with the broader network.

**Method**: Find strongly connected components in the trust graph. For each component, calculate the ratio of external edges to internal edges. Clusters with very few external connections (e.g., <10% external) are suspicious.

**What it catches**: Collusion rings, cabals, sock puppet networks

### 1.2 Behavioral Similarity Detection

Identify identities that behave too similarly to be independent.

**Signals to compare**:
- Assertion timing patterns (do they always assert within minutes of each other?)
- Assertion targets (do they always score the same providers?)
- Score correlation (do they always give similar scores?)
- Transaction patterns (similar timing, amounts, counterparties?)

**Similarity score**: Calculate correlation across multiple behavioral dimensions. High correlation (>0.8) suggests coordination or same operator.

**What it catches**: Sock puppets, coordinated manipulation campaigns

### 1.3 Trust Flow Analysis

Track where trust "flows" in the network to detect manipulation.

**Method**: Model trust assertions as flow. Look for:
- Circular flow (A→B→C→A)
- Concentrated sources (one identity seeding trust to many)
- Isolated sinks (identities that receive but never give trust)
- Sudden flow changes (abrupt shifts in trust patterns)

**What it catches**: Trust laundering, reputation pumping schemes

---

## 2. Statistical Anomaly Detection

### 2.1 Assertion Pattern Anomalies

Detect unusual assertion patterns that suggest manipulation.

**Anomalies to detect**:
- Burst activity (many assertions in short time)
- Coordinated timing (multiple asserters at same time)
- Score clustering (many identical scores)
- Target concentration (one subject getting unusual attention)

### 2.2 Verification Result Anomalies

Detect unusual verification patterns.

**Anomalies to detect**:
- Selective verification (provider only passes when certain verifiers check)
- Result inconsistency (different verifiers get wildly different results)
- Timing manipulation (verification always happens at convenient times)
- Coverage gaps (provider avoids certain types of checks)

### 2.3 Economic Anomalies

Detect unusual economic patterns.

**Anomalies to detect**:
- Wash trading (circular payments between related identities)
- Price manipulation (unusual bid/ask patterns)
- Volume spikes (sudden activity increases)
- Burn avoidance (patterns suggesting trust score gaming)

---

## 3. Reputation Decay and Freshness

### 3.1 Time-Weighted Assertions

Recent assertions matter more than old ones.

**Decay function**: Assertions lose weight over time. A 6-month-old assertion might count at 50% of its original weight. A 1-year-old assertion might count at 25%.

**Why it matters**: Prevents relying on stale information. Forces continuous good behavior.

### 3.2 Activity Requirements

Reputation requires ongoing participation.

**Requirements**:
- Minimum transaction frequency to maintain trust level
- Minimum verification coverage to remain credible
- Inactivity decay (trust slowly drops without activity)

**What it prevents**: Reputation squatting, abandoned identity exploitation

### 3.3 Recovery Limitations

After trust damage, recovery is slow.

**Mechanisms**:
- Longer recovery periods for repeat offenders
- Some actions are unforgivable (permanent blacklist)
- Recovery requires more proof than initial trust building
- Track pattern of trust drops (repeated drops = permanent penalty)

---

## 4. Verification Coverage Requirements

### 4.1 Self-Reported Coverage Metrics

Providers track and report their own verification coverage.

**Metrics to track**:
- What percentage of sessions were verified?
- How many unique verifiers?
- What types of verification (resource, liveness, benchmark)?
- How recent is the verification?

**Why self-report?**: Providers with low coverage look suspicious. Honest providers want high coverage to prove legitimacy.

### 4.2 Coverage as Trust Factor

Verification coverage directly affects trust calculation.

**Impact**:
- Low coverage (<20%) = significant trust penalty
- Medium coverage (20-50%) = neutral
- High coverage (>50%) = trust bonus
- Zero coverage = maximum suspicion

### 4.3 Verification Diversity Requirements

Can't rely on a few friendly verifiers.

**Requirements**:
- Minimum number of unique verifiers
- Verifiers must be independent (low similarity scores)
- Verifiers must have their own credibility
- Recent verification required (not just historical)

---

## 5. Economic Defenses

### 5.1 Minimum Burn Floor

Even high-trust providers have minimum burn.

**Mechanism**: Trust score of 0.95 means 95% to provider, 5% burned. But maybe cap at 90% provider maximum, ensuring at least 10% always burns.

**Why it matters**: Ensures network always benefits from transactions, prevents 100% extraction.

### 5.2 Transaction Cost for Assertions

Publishing assertions should have a cost.

**Options**:
- Small burn required to publish assertion
- Stake that can be slashed if assertion proven wrong
- Rate limiting (only N assertions per time period)

**What it prevents**: Assertion spam, cheap reputation attacks

### 5.3 Trust Score Change Limits

Prevent sudden, dramatic trust changes.

**Mechanisms**:
- Maximum trust change per day (e.g., ±10%)
- Require multiple independent sources for large changes
- Cool-down periods between changes
- Appeals/dispute period before major downgrades

---

## 6. Sybil Defenses

### 6.1 Identity Age Weighting

New identities have little influence.

**Mechanism**: Trust assertions from young identities (<30 days) are heavily discounted. Assertions from aged identities (>180 days) get full weight.

**What it prevents**: Creating many new identities to flood assertions

### 6.2 Transaction History Requirements

Assertions require skin in the game.

**Mechanism**: To assert about provider P, you should have transaction history with P. Weight assertions by transaction volume between asserter and subject.

**What it prevents**: Drive-by reputation attacks from uninvolved parties

### 6.3 Resource Commitment

Making identities should cost something.

**Options**:
- Burn to create identity
- Stake to activate identity
- Proof of unique hardware
- Social vouching from existing members

---

## 7. Commit-Reveal Schemes

### 7.1 Blind Assertions

Prevent copying by hiding assertions until reveal.

**Process**:
1. Commit phase: Publish hash of (assertion + salt)
2. Wait period: Minimum time before reveal allowed
3. Reveal phase: Publish actual assertion + salt
4. Verify: Hash of revealed matches committed

**What it prevents**: Score copying, front-running, groupthink

### 7.2 Blind Verification

Prevent verification gaming by hiding which verifier.

**Process**:
1. Verifier doesn't announce they're checking
2. Verification happens normally
3. Results published after the fact
4. Provider can't game because they don't know when/who

---

## 8. Dispute and Appeal Mechanisms

### 8.1 Assertion Challenges

Allow subjects to challenge assertions about them.

**Process**:
1. Subject flags assertion as disputed
2. Subject provides counter-evidence
3. Third parties can weigh in
4. Network observes but doesn't adjudicate
5. Each participant decides how to weight disputed assertions

### 8.2 Evidence Requirements

Significant assertions need backing.

**Requirements**:
- Link to verification logs
- Specific claims (not vague accusations)
- Reproducible methodology
- Timestamp and context

**What it prevents**: Vague reputation attacks, unsubstantiated claims

---

## 9. Privacy Protections

### 9.1 Assertion Aggregation

Prevent individual assertion deanonymization.

**Mechanism**: Don't reveal exactly who said what. Instead, show aggregated trust scores with noise added.

### 9.2 Transaction Privacy

Prevent economic surveillance.

**Options**:
- Aggregate transaction reports (not individual)
- Delayed publication
- Encrypted transaction details with selective reveal

---

## 10. Delegated Escrow Protocol

Instead of relying solely on a central authority, escrow responsibility can be delegated to trusted network members.

### Core Concept

```
Central escrow:
  Consumer → [Central Authority] → Provider
  Single point of trust and failure

Delegated escrow:
  Consumer → [Delegate Pool] → Provider
  Trust distributed among M-of-N delegates
```

### Delegate Selection

Delegates are selected from the consumer's trust graph based on:
- Minimum trust score (e.g., ≥0.70)
- Minimum identity age (e.g., ≥90 days)
- Minimum successful escrow history (e.g., ≥10 completions)
- Maximum single delegate share (e.g., ≤40% of escrow)
- Diversity requirement (delegates shouldn't be too connected to each other)

### M-of-N Threshold

Escrow release requires agreement from M of N delegates (e.g., 2-of-3, 3-of-5). This prevents any single delegate from stealing funds or blocking release.

### Piecewise Payment

For long sessions, delegates can release payments incrementally:
- Hourly release during active session
- Each release requires M-of-N signature agreement
- Provider gets paid as they work, not just at end
- Consumer protected if session ends early

### Delegate Incentives

Delegates receive a small fee (e.g., 0.1% of escrow) for successful completion. This compensates them for the service and risk.

### Failure Handling

If a delegate becomes unresponsive:
- If remaining delegates ≥ threshold, proceed without them
- If below threshold, use pre-signed time-locked releases
- Remaining delegates can vote on redistribution
- Worst case: escalate to broader network dispute

### Benefits

- No single point of failure
- Uses existing trust infrastructure
- Piecewise payments protect both parties
- Decentralization without smart contracts

---

## 11. Session State Machine

Sessions follow a simple state machine:

```
ADVERTISED → ACTIVE → TERMINATED
```

**Advertised**: Provider has put VM info on-chain. VM is available.

**Active**: Consumer has claimed the session. Escrow is locked. Consumer can access VM.

**Terminated**: Anyone can call terminate. Escrow is released based on usage time and trust score.

### Termination

A single `terminate` function anyone can call:
- If consumer calls: Normal end, pay for time used
- If provider calls: Session ended early, pay for time used
- If timeout: Automatic termination, pay for time used

### Escrow Release on Termination

When terminated:
1. Calculate duration (start to end time)
2. Calculate payment (duration × hourly rate, capped at escrowed amount)
3. Split payment by trust score (provider gets trust%, burn gets rest)
4. Refund unused escrow to consumer
5. Pay delegate fees if using delegated escrow

---

## 12. Defense Summary

| Defense | Attacks Mitigated |
|---------|-------------------|
| Identity-bound VM access | Identity theft, credential stealing |
| Graph clustering analysis | Collusion rings, sock puppets |
| Behavioral similarity detection | Coordinated manipulation |
| Trust flow analysis | Trust laundering |
| Statistical anomaly detection | Various manipulation patterns |
| Time-weighted assertions | Stale reputation exploitation |
| Activity requirements | Reputation squatting |
| Verification coverage requirements | Selective verification gaming |
| Minimum burn floor | Complete extraction |
| Assertion costs | Spam, cheap attacks |
| Trust change limits | Sudden manipulation |
| Identity age weighting | Sybil attacks |
| Transaction history requirements | Drive-by attacks |
| Commit-reveal schemes | Copying, front-running |
| Evidence requirements | Vague accusations |
| Delegated escrow | Central point of failure |
| Session state machine | Dispute clarity |
