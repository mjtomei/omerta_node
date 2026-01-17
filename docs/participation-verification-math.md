# Trust Score Mathematics (Revised)

Trust is computed from on-chain facts, not asserted. Assertions are violation reports. Trust grows indefinitely. Statistical detection is built into the math.

---

## 1. Fundamental Principles

1. **Trust is unbounded**: Trust accumulates over time with no ceiling. More history = more trust.

2. **Assertions are violation reports**: Participants don't assert "X has trust 0.8". They report "X did bad thing Y with severity Z". Trust is computed, not claimed.

3. **All computation is from chain data**: Anyone can compute anyone's trust using the same open algorithm on the same data.

4. **Statistical detection is explicit**: Sybil clusters, collusion rings, and anomalies are detected algorithmically and downweighted mathematically.

5. **Meta-trust is emergent**: No separate meta-trust tracking. Accuracy of accusations emerges from the data.

6. **Payment asymptotes to 100%**: High trust approaches full payment, but some burn always remains.

---

## 2. Trust Accumulation

Trust accumulates from two sources, with age as a derate factor:

```
T_base = T_transactions + T_assertions
T_effective = T_base × age_derate

Where:
  - T_transactions decays based on recency of transactions
  - T_assertions can be positive (commendations) or negative (violations)
  - age_derate is a 0.0 to 1.0 multiplier (see Section 2.1)
```

### 2.1 Age as Derate Factor (Not Trust Source)

**Design principle**: Age should never **add** trust by itself. Age is a **derate factor** that penalizes young identities, not a source of trust for old ones.

**Rationale**: If age added trust, attackers could create many idle identities, wait, and exploit accumulated age-based trust without contributing to the network.

```
age_derate(identity) = min(1.0, identity_age / AGE_MATURITY_DAYS)

Where:
  - identity_age = days since identity creation
  - AGE_MATURITY_DAYS = days until identity reaches full trust potential (e.g., 90-180)
  - Result: 0.0 to 1.0 multiplier

Effective trust becomes:
  T_effective = (T_transactions + T_assertions) × age_derate
```

**Effects**:
- New identity (day 0): age_derate = 0.0, cannot earn anything regardless of activity
- Young identity (day 30, AGE_MATURITY_DAYS=90): age_derate = 0.33, earns 33% of normal
- Mature identity (day 90+): age_derate = 1.0, earns full rate
- Dormant identity (any age): Still gets age_derate = 1.0, but has no T_transactions, so T_effective = 0

**Why this is better than age-as-trust**:
1. Idle identities gain nothing - they need activity to build trust
2. Age cannot be exploited - it only removes a penalty, doesn't add value
3. Attackers cannot pre-stage identities - they still need to do real work
4. Honest participants reach full earning potential after maturity period

### 2.2 Trust from Transactions

Each verified transaction adds trust, weighted by size and recency.

```
T_transactions = Σ_i (credit_i × recency(age_i))

credit_i = BASE_CREDIT × resource_weight × duration × verification_score × cluster_weight_i

recency(age) = e^(-age / TAU_TRANSACTION)
```

**Resource weights**: Defined per resource class. More valuable resources earn more trust per hour.

**Verification score**: 0 to 1 based on session verification (see Section 5).

**Cluster weight**: Downweighting for Sybil-like patterns (see Section 4).

### 2.3 Trust from Assertions

Assertions add or subtract trust based on their score. They decay over time.

```
T_assertions = Σ_i (score_i × credibility_i × decay(age_i))

decay(age) = RESIDUAL + (1 - RESIDUAL) × e^(-age / TAU_ASSERTION)
```

**Score**: The assertion's score [-1, 1]:
- Negative scores subtract from trust (violations)
- Positive scores add to trust (commendations)

**Credibility**: Weight of the asserter (see Section 3).

**Asymmetry option**: Negative assertions can decay slower than positive ones:
```
decay_negative(age) = RESIDUAL_NEG + (1 - RESIDUAL_NEG) × e^(-age / TAU_NEGATIVE)
decay_positive(age) = RESIDUAL_POS + (1 - RESIDUAL_POS) × e^(-age / TAU_POSITIVE)
```

---

## 3. Assertions as Reports

Assertions are signed reports of specific incidents—positive or negative.

### 3.1 Assertion Structure

```
Assertion {
  asserter: IdentityID
  subject: IdentityID
  score: float [-1, 1]         # -1 = severe violation, +1 = excellent behavior
  classification: enum {
    # Negative classifications (score should be negative)
    RESOURCE_MISMATCH,         # Claimed resources != delivered
    SESSION_ABANDONMENT,       # Dropped session unexpectedly
    PAYMENT_DISPUTE,           # Payment/escrow issues
    VERIFICATION_FAILURE,      # Failed verification checks
    MALICIOUS_BEHAVIOR,        # Active harm
    NETWORK_DISAGREEMENT,      # State disagreement with consensus

    # Positive classifications (score should be positive)
    EXCELLENT_SERVICE,         # Exceeded expectations
    RELIABLE_UPTIME,           # Consistent availability
    FAST_RESOLUTION,           # Quick problem resolution
    HELPFUL_BEHAVIOR,          # Assisted others in network

    # Neutral
    UNCLASSIFIED               # Requires high trust to use
  }
  evidence_hash: bytes         # Link to supporting data
  reasoning: string            # Human-readable explanation
  timestamp: uint64
  signature: bytes
}
```

### 3.1.1 Parameterized Infraction Severity

**Design principle**: All infractions should have gray areas. Severity scales with potential network impact, not fixed values.

**Infraction severity is computed, not asserted**:

```
effective_score = base_score × impact_multiplier × context_multiplier

Where:
  base_score = classification default (see table below)
  impact_multiplier = f(transaction_value, resources_affected, duration)
  context_multiplier = g(repeat_offense, attacker_trust, victim_count)
```

**Base scores by classification** (defaults, adjustable by governance):

| Classification | Base Score | Impact Factors |
|---------------|------------|----------------|
| RESOURCE_MISMATCH | -0.3 | × (claimed - delivered) / claimed |
| SESSION_ABANDONMENT | -0.2 | × session_value / avg_session_value |
| PAYMENT_DISPUTE | -0.4 | × dispute_amount / avg_transaction |
| VERIFICATION_FAILURE | -0.5 | × verification_confidence |
| MALICIOUS_BEHAVIOR | -0.8 | × damage_estimate / network_daily_volume |
| NETWORK_DISAGREEMENT | -0.3 | × stake_at_risk / total_stake |

**Impact multiplier calculation**:

```
impact_multiplier = clamp(
  log(1 + transaction_value / BASELINE_TRANSACTION) ×
  log(1 + resources_affected / BASELINE_RESOURCES) ×
  duration_factor,
  MIN_IMPACT_MULTIPLIER,
  MAX_IMPACT_MULTIPLIER
)

duration_factor = 1.0 + (violation_duration / BASELINE_DURATION)
```

**Context multiplier for repeat offenders**:

```
context_multiplier = 1.0 + (repeat_count × REPEAT_PENALTY_RATE)

Where repeat_count = number of similar violations in REPEAT_LOOKBACK_DAYS
```

**Gray area examples**:

| Scenario | Base | Impact | Context | Final Score |
|----------|------|--------|---------|-------------|
| Small resource mismatch, first offense | -0.3 | 0.5 | 1.0 | -0.15 |
| Large resource mismatch, first offense | -0.3 | 1.5 | 1.0 | -0.45 |
| Small mismatch, 3rd offense | -0.3 | 0.5 | 1.3 | -0.20 |
| Massive fraud, first offense | -0.8 | 2.0 | 1.0 | -1.0 (capped) |

**Measurable parameters** (determined empirically):

| Parameter | Description | How to Measure |
|-----------|-------------|----------------|
| BASELINE_TRANSACTION | Median transaction value | 30-day rolling median |
| BASELINE_RESOURCES | Typical resources per session | Network statistics |
| BASELINE_DURATION | Expected session duration | Historical average |
| REPEAT_PENALTY_RATE | How much worse repeats are | Simulation tuning |
| MIN_IMPACT_MULTIPLIER | Floor for minor infractions | Policy decision |
| MAX_IMPACT_MULTIPLIER | Cap for severe infractions | Policy decision |

**Benefits of parameterized severity**:

1. **Proportional punishment**: Small mistakes don't destroy trust
2. **Deterrence scales**: Larger attacks risk larger penalties
3. **Tunable via governance**: Parameters can adjust as network evolves
4. **Empirically measurable**: All factors are observable on-chain
5. **No false binaries**: Every infraction has appropriate gray area

---

**Score interpretation** (after applying multipliers):
```
-1.0: Maximum severity (capped)
-0.5 to -0.8: Significant problem requiring investigation
-0.2 to -0.5: Moderate issue, normal decay applies
-0.1 to -0.2: Minor issue, quick recovery possible
 0.0: Neutral (no assertion needed)
+0.2 to +0.5: Good/very good behavior
+1.0: Maximum positive (capped)
```

These represent computed scores after applying impact and context multipliers.

### 3.2 Accuser Credibility

Credibility is simply a function of trust. Everything else emerges from the solver.

```
credibility(accuser) = log(1 + T_accuser) / log(1 + T_REFERENCE)
```

This means:
- Low trust accusers have low credibility
- High trust accusers have credibility > 1.0
- Credibility grows logarithmically (diminishing returns)

**Why this is sufficient:**

The accuser's trust already incorporates all penalties:
- Refuted accusations → trust penalty (Section 4.4)
- Accusation spam → trust penalty (Section 4.4)
- Targeting/harassment → trust penalty (Section 4.4)
- Coordination with others → trust penalty via similarity detection (Section 4.2)
- Sybil cluster membership → trust divided by cluster size (Section 4.1)

Bad accusers lose trust. Lower trust = lower credibility. Their future accusations carry less weight. The system is self-correcting through the iterative solver—no separate accuracy tracking needed.

### 3.3 Unclassified Assertions

Only high-trust participants can file UNCLASSIFIED assertions:

```
can_file_unclassified(accuser) = T_accuser > UNCLASSIFIED_THRESHOLD
```

This allows testing new violation categories before formalizing them.

### 3.4 Accusations as Verification Signals

Accusations don't directly damage trust. They signal that a subject should be verified more carefully by others.

**Single accusation rule:**
```
For each (accuser, subject) pair:
  only the FIRST accusation in a time window has effect
  subsequent accusations are ignored until window expires

Window duration = ACCUSATION_WINDOW
```

**Accusation triggers verification:**
```
When subject S receives accusation:
  verification_frequency(S) increases temporarily
  other participants who transact with S are expected to verify more carefully
  verification results (pass/fail) are the actual trust signal
```

**Resolution outcomes:**

```
If others verify S and find problems:
  - S's trust drops (from failed verifications, not from accusation)
  - Accuser's credibility rises (accusation was accurate)

If others verify S and find nothing wrong:
  - S's trust is unaffected (or rises slightly from successful verifications)
  - Accuser's credibility drops (accusation was inaccurate)
  - Accuser marked as having "pending unverified accusation" against S
```

**Pending accusation penalty:**
```
If accuser has pending unverified accusation against subject:
  - Cannot make new accusations against subject
  - Future accusations against ANY target are weighted less
  - Must wait for window to expire or for others to verify

unverified_accusation_penalty = count(pending_unverified) × PENDING_PENALTY_WEIGHT
```

**Why this works:**

1. **Cannot spam accusations** - Only first one counts per window
2. **Burden shifts to network** - Others verify, not accuser repeating
3. **Accuser has skin in game** - Wrong accusations hurt credibility
4. **Subject gets fair hearing** - Increased verification, not immediate punishment
5. **Manufactured crisis fails** - Attacker can accuse once, but if victim passes verification, attacker loses credibility

### 3.5 Verification Frequency Adjustment

Accusations increase verification sampling rate for the subject.

```
accusation_boost(subject) = Σ (credibility(accuser) × recency(accusation))

adjusted_rate(subject) = min(
  BASE_VERIFICATION_RATE × (1 + accusation_boost),
  MAX_VERIFICATION_RATE
)
```

The subject either:
- Passes increased verification → vindicated, accusers lose credibility
- Fails increased verification → trust drops from failures, accusers gain credibility

### 3.6 Transaction History Requirement

Can only accuse providers you've actually transacted with.

```
can_accuse(accuser, subject) =
  exists transaction where accuser was consumer and subject was provider
  AND transaction.day > subject.creation_day

accusation_weight_modifier = min(transaction_count(accuser, subject) / MIN_TRANSACTIONS_FOR_FULL_WEIGHT, 1.0)
```

This prevents:
- Random attacks on competitors you've never used
- Manufactured crisis by outsiders
- Sybil swarm accusations (sybils would need to actually transact first)

---

## 4. Statistical Detection

### 4.1 Sybil Cluster Detection

Detect tightly-connected subgraphs with unusual patterns.

**Build transaction graph:**
```
G = (V, E) where:
  V = all identities
  E = edges weighted by transaction volume between pairs
```

**Compute clustering coefficient:**
```
clustering(i) = (edges among neighbors of i) / (possible edges among neighbors)
```

**Detect suspicious clusters:**
```
For each connected component C:
  internal_volume = Σ transactions within C
  external_volume = Σ transactions between C and rest of network

  isolation_score = internal_volume / (internal_volume + external_volume)

  if isolation_score > ISOLATION_THRESHOLD and |C| > 1:
    mark C as suspicious cluster
```

**Cluster weight applied to trust:**
```
cluster_weight(i) = 1.0 if i not in suspicious cluster
cluster_weight(i) = 1.0 / |cluster| if i in suspicious cluster

Effect: Trust from within-cluster transactions is divided among cluster members.
```

### 4.2 Behavioral Similarity Detection

Detect identities that behave too similarly.

**Feature vector for each identity:**
```
features(i) = [
  transaction_timing_histogram,     # When do they transact?
  assertion_timing_histogram,       # When do they accuse?
  counterparty_distribution,        # Who do they interact with?
  resource_class_distribution,      # What do they rent?
  session_duration_distribution,    # How long are sessions?
]
```

**Similarity score:**
```
similarity(i, j) = cosine_similarity(features(i), features(j))
```

**Similarity penalty:**
```
For pairs with similarity > SIMILARITY_THRESHOLD:
  similarity_penalty(i) = Σ_j max(0, similarity(i,j) - SIMILARITY_THRESHOLD)

  effective_trust(i) = T(i) / (1 + similarity_penalty(i))
```

### 4.3 Coordination Detection

Detect accusers who act in coordination.

**Temporal correlation:**
```
For each pair of accusers (i, j):
  accusations_i = list of (accused, timestamp) by i
  accusations_j = list of (accused, timestamp) by j

  temporal_correlation = correlation of timestamps when both accuse same target
```

**Target correlation:**
```
target_overlap(i, j) = |targets(i) ∩ targets(j)| / |targets(i) ∪ targets(j)|
```

**Coordination score:**
```
coordination(i) = max over all j of: temporal_correlation(i,j) × target_overlap(i,j)
```

High coordination → reduced credibility (see Section 3.2).

### 4.4 Assertion Analysis

Assertions themselves are analyzed for accuracy and abuse patterns.

**Assertion accuracy:**
```
For each assertion with score S about subject X:

  time_passes...

  X's trust trajectory reveals ground truth:
    - If X's trust dropped significantly → negative assertions were accurate
    - If X's trust remained stable/grew → negative assertions were inaccurate
    - If X later had verified violations → positive assertions were inaccurate
    - If X continued good behavior → positive assertions were accurate

  divergence = S - normalized_outcome

  If |divergence| > ACCURACY_THRESHOLD:
    accuracy_penalty = |divergence| × DIVERGENCE_PENALTY_WEIGHT
```

**Asserter trust impact:**
```
For each asserter i:
  accurate_count = assertions where |divergence| < ACCURACY_THRESHOLD
  inaccurate_count = assertions where |divergence| >= ACCURACY_THRESHOLD

  accuracy_ratio = accurate_count / (accurate_count + inaccurate_count + 1)

  If accuracy_ratio < MIN_ACCURACY_RATIO:
    T_accuracy_penalty = (MIN_ACCURACY_RATIO - accuracy_ratio) × ACCURACY_PENALTY_WEIGHT
```

**Assertion spam detection:**
```
For each asserter i:
  assertion_rate = assertions in last 30 days
  network_assertion_rate = average assertions per identity per 30 days

  if assertion_rate > SPAM_THRESHOLD × network_assertion_rate:
    spam_penalty = (assertion_rate / network_assertion_rate - SPAM_THRESHOLD) × SPAM_PENALTY_WEIGHT
```

**Targeted assertion detection:**
```
For each asserter i:
  negative_assertions = assertions with score < 0
  targets = set of identities with negative assertions from i
  assertions_per_target = distribution

  concentration = max(assertions_per_target) / sum(assertions_per_target)

  if concentration > TARGETING_THRESHOLD and max(assertions_per_target) > MIN_ASSERTIONS_FOR_TARGETING:
    targeting_penalty = concentration × TARGETING_PENALTY_WEIGHT
```

**Unsupported assertion penalty:**
```
For assertions without evidence_hash or with invalid evidence:
  unsupported_penalty = UNSUPPORTED_PENALTY_BASE × |score|
```

### 4.5 Asserter Trust Adjustment

Total assertion-related trust adjustment for asserter:

```
T_asserter_penalty = -(
  T_accuracy_penalty +        # From inaccurate assertions
  spam_penalty +              # From assertion spam
  targeting_penalty +         # From targeting single identity
  unsupported_penalty         # From unsupported assertions
)

This contributes to T_assertions for the asserter (as a negative assertion about themselves).
```

Bad asserters hurt themselves. Inaccurate positive assertions (vouching for bad actors) and inaccurate negative assertions (false accusations) both result in penalties.

### 4.6 Anomaly Detection

Flag unusual patterns for human review.

**Volume anomalies:**
```
For each identity i:
  recent_volume = transactions in last ANOMALY_WINDOW days
  historical_volume = average transactions per ANOMALY_WINDOW days

  if recent_volume > historical_volume × VOLUME_SPIKE_THRESHOLD:
    flag as anomaly
```

**Accusation anomalies:**
```
For each identity i:
  accusations_received_rate = accusations in last ACCUSATION_RATE_WINDOW days

  if accusations_received_rate > ACCUSATION_SPIKE_THRESHOLD × network_average:
    flag for review
```

Anomalies don't automatically affect trust—they're signals for investigation.

### 4.7 Circular Flow Detection

Detect wealth cycling between identities to identify controlled identity networks.

**Build transfer graph:**
```
G_transfer = (V, E) where:
  V = all identities
  E = directed edges weighted by net transfer volume (transfers only, not payments)
```

**Detect cycles:**
```
For each identity i:
  incoming_sources = identities that transferred to i
  outgoing_targets = identities that i transferred to

  For each cycle C containing i (up to MAX_CYCLE_LENGTH):
    cycle_volume = min(transfer volumes along cycle edges)
    cycle_participants = identities in C

    For each participant p in C:
      circular_flow_score(p) += cycle_volume / |C|
```

**Circular flow ratio:**
```
For each identity i:
  total_transfer_volume(i) = all transfers sent + received
  circular_volume(i) = sum of cycle volumes involving i

  circular_ratio(i) = circular_volume(i) / (total_transfer_volume(i) + 1)

  if circular_ratio(i) > CIRCULAR_THRESHOLD:
    flag as suspicious circular flow
```

**Circular flow penalty:**
```
If circular_ratio(i) > CIRCULAR_THRESHOLD:
  circular_penalty(i) = (circular_ratio(i) - CIRCULAR_THRESHOLD) × CIRCULAR_PENALTY_WEIGHT

  effective_trust(i) = T(i) / (1 + circular_penalty(i))
```

**What this catches:**
- W → P₁ → P₂ → W patterns (wealth cycling through sock puppets)
- Identity rotation networks (wealth moves in circles, net position unchanged)
- Wash trading (artificial volume from circular transfers)

**What this doesn't catch (by design):**
- Legitimate economic cycles (A pays B, B pays C, C pays A for services)
- Payments aren't included in transfer graph, only raw transfers

**Parameters:**
- MAX_CYCLE_LENGTH: Maximum cycle size to detect (default: 5)
- CIRCULAR_THRESHOLD: Ratio above which flow is suspicious (default: 0.3)
- CIRCULAR_PENALTY_WEIGHT: How much to penalize (default: 2.0)

---

## 5. Sessions and Verification

This is an ephemeral compute swarm. Either party can terminate at any time. Verification is about anti-collusion, not quality assurance.

### 5.1 Session Model

```
Session lifecycle:
  1. Consumer requests resources (bid)
  2. Provider accepts (ask matched)
  3. Escrow locked
  4. Compute runs
  5. Session terminates (by either party, or completion)
  6. Escrow released based on outcome
```

**Either party can terminate at any time.** This is the fundamental quality defense:
- Consumer sees bad quality → kills job → finds another provider
- Provider has resource constraints → kills VM → consumer finds another
- No one is forced to continue a bad session

### 5.2 Session Outcomes

```
Session outcome types:

COMPLETED_NORMAL
  - Session ran for expected duration
  - Consumer released escrow
  - Trust credit for provider

CONSUMER_TERMINATED_EARLY
  - Consumer killed session before completion
  - Partial escrow release (pro-rated)
  - Neutral signal (consumer's choice)

PROVIDER_TERMINATED
  - Provider killed consumer's VM
  - No escrow release for remaining time
  - Tracked as reliability signal (not punishment)

SESSION_FAILED
  - Technical failure (network, hardware)
  - Investigated if pattern emerges
  - No automatic penalty
```

### 5.3 Market Defense Against Quality Degradation

Quality assurance is the consumer's job, not the trust system's:

```
Bad provider delivers poor quality
  → Consumer notices (they're using the compute)
  → Consumer terminates session
  → Consumer finds another provider
  → Bad provider loses business naturally
  → Transaction volume drops
  → Trust decays from reduced activity
```

The trust system tracks **what happened**, not **how good it was**. Quality is implicit in:
- Do consumers return to this provider?
- Do sessions complete or terminate early?
- What's the provider's retention rate?

### 5.4 Verification Purpose: Anti-Collusion

Verification proves transactions are **real**, not that they're **good**:

```
Verification questions:
  - Did this VM actually run? (not a fake transaction)
  - Did the consumer actually use resources? (not self-dealing)
  - Are these two parties actually independent? (not sybils)
  - Does the transaction volume match claimed resources? (not inflated)
```

Random sampling catches collusion. Quality is caught by consumer exit.

### 5.5 Verification Initiation

Any participant can initiate a verification on any transaction:
- **Random verification** - Participant chooses to verify a random transaction (civic duty)
- **Consumer-triggered** - Consumer verifies their own session

Both work the same way. The initiator sends verification requests in secret to uninvolved parties.

**Initiating a verification:**
```
Initiator selects transaction to verify
Initiator sends secret requests to panel of uninvolved parties
Panel members are not revealed to transaction parties
```

**Panel selection (by initiator):**
```
eligible_verifiers = identities where:
  trust > VERIFIER_THRESHOLD
  no_transaction_history(verifier, consumer)
  no_transaction_history(verifier, provider)
  not in same cluster as either party

panel = weighted_random_sample(eligible_verifiers,
                               size=VERIFICATION_PANEL_SIZE,
                               weight=trust)
```

### 5.6 Verification Voting (Commit-Reveal)

Votes are secret until all collected. Transaction parties cannot see early results.

```
Phase 1 - COMMIT:
  Each panelist submits: hash(vote + secret_nonce)
  Commits recorded but votes hidden
  Provider/consumer cannot see how voting is going

Phase 2 - REVEAL (after all commits or REVEAL_DEADLINE):
  Panelists reveal: vote + secret_nonce
  Hash verified against commit
  Votes tallied
```

**Outcome determination:**
```
outcome = PASS if votes_pass > votes_fail else FAIL

Trust impact:
  unanimous_pass:   full positive credit
  majority_pass:    partial positive credit
  majority_fail:    trust penalty (severity based on margin)
  unanimous_fail:   larger trust penalty
```

**Panelist accountability:**
```
Panelists who vote against majority:
  - If their minority votes correlate with later problems → credibility boost
  - If consistently wrong → credibility drops
```

### 5.7 What Verifiers Check

```
1. Did the session actually occur?
2. Did resources match what was claimed in the bid?
3. Are the parties independent (not sybils)?
4. Is the transaction volume plausible?
```

### 5.8 Verification as Network Service

Verification is civic duty. No fee. Free riders are detectable.

**The key metric: verification origination**
```
Everyone is expected to randomly initiate verifications.
How many verifications you originate is tracked.

If you benefit from network security but never originate verifications,
you're free-riding. This is visible and hurts your profile score.
```

Consumer-triggered checks are just one reason to initiate. Good citizens also initiate random verifications to keep the network secure.

### 5.9 False Positive Handling

```
Voting prevents single-verifier false flags.
Majority required for any trust impact.
Pattern of failed checks matters more than single result.
Provider's history provides context.
```

### 5.10 Profile Score

The profile score aggregates behavioral signals to assess network citizenship.

**Components:**

```
profile_score(identity) = Σ (component_i × weight_i)

Components:
  verification_origination:    weight = WEIGHT_VERIFICATION_ORIGINATION
  session_completion:          weight = WEIGHT_SESSION_COMPLETION
  consumer_retention:          weight = WEIGHT_CONSUMER_RETENTION
  transaction_diversity:       weight = WEIGHT_TRANSACTION_DIVERSITY
  accusation_record:           weight = WEIGHT_ACCUSATION_RECORD
  activity_consistency:        weight = WEIGHT_ACTIVITY_CONSISTENCY
```

**Verification Origination:**
```
Tracks how many verifications you initiate vs your network activity.

verifications_originated = number of verifications you initiated
expected_verifications = your_transaction_volume × EXPECTED_VERIFICATION_RATE

origination_ratio = verifications_originated / expected_verifications

If < ORIGINATION_FREERIDER_THRESHOLD:   score = 0.0 (severe free-riding)
If < ORIGINATION_BELOW_AVG_THRESHOLD:   score = 0.5 (below average)
If ≥ ORIGINATION_GOOD_THRESHOLD:        score = 1.0 (good citizen)
If > ORIGINATION_ACTIVE_THRESHOLD:      score = ORIGINATION_ACTIVE_BONUS (active contributor)
```

High activity but low verification origination = free rider.
The network's security depends on participants initiating checks.

**Session Completion:**
```
session_completion = normal_completions / total_sessions

Measures reliability for providers, reasonable behavior for consumers.

score = session_completion  # 0.0 to 1.0 directly
```

**Consumer Retention:**
```
For providers:
  unique_returning_consumers = consumers who transacted more than once
  total_unique_consumers = all consumers ever

  consumer_retention = unique_returning_consumers / total_unique_consumers

Returning consumers signal quality without needing explicit ratings.

score = min(consumer_retention × RETENTION_SCORE_MULTIPLIER, 1.0)
```

**Transaction Diversity:**
```
For each identity:
  unique_counterparties = distinct parties transacted with
  total_transactions = all transactions

  diversity = unique_counterparties / sqrt(total_transactions)

Low diversity suggests sybil behavior or captive relationships.

score = min(diversity, 1.0)
```

**Accusation Record:**
```
accusations_made_accurate = accusations where subject later failed checks
accusations_made_inaccurate = accusations where subject passed checks
accusations_received_verified = accusations against me that were verified true
accusations_received_refuted = accusations against me that were not verified

accuracy = accurate / (accurate + inaccurate) if any made, else 0.5
defense = refuted / (verified + refuted) if any received, else 0.5

accusation_record = (accuracy + defense) / 2
score = accusation_record
```

**Activity Consistency:**
```
Measures steady participation vs burst/dormant patterns.

activity_variance = stddev(monthly_transaction_counts) / mean(monthly_transaction_counts)

Consistent activity is less suspicious than bursts.

score = 1.0 / (1.0 + activity_variance)
```

**Profile Score Impact:**
```
Profile score modifies effective trust:

effective_trust = base_trust × profile_modifier

profile_modifier = PROFILE_MIN_MODIFIER + (profile_score / max_possible_profile_score)

Range: PROFILE_MIN_MODIFIER (terrible) to PROFILE_MAX_MODIFIER (excellent)
```

### 5.11 Provider Reliability Signal

Provider-terminated sessions aren't punished but are tracked:

```
reliability_score(provider) = completed_sessions / total_sessions

This affects:
  - Consumer's willingness to use provider (market signal)
  - Bid matching (reliability shown alongside price)
  - NOT direct trust score (that would punish legitimate resource constraints)
```

Low reliability is a market signal, not a trust violation. Some providers may offer cheap but unreliable compute - that's a valid market position.

### 5.12 Reliability Score Model

Consumers need to translate reliability scores into expected value calculations. The system provides sufficient data for this.

**Reliability metrics exposed:**
```
For each provider:
  completion_rate = completed_sessions / total_sessions
  mean_completion_fraction = avg(actual_duration / expected_duration)

  termination_events = [
    {
      cancelled_rate: price of terminated session,
      usurping_rate: price of replacement session (null if none),
      time_fraction: how far into session termination occurred,
      time_to_replacement: seconds until new session started (null if none)
    },
    ...
  ]
```

This allows consumers to model cancellation probability given market conditions:

```
For a session at rate R, estimate P(cancellation | market_rate M):

  historical_cancellations = termination_events where usurping_rate != null

  # Build model: at what price ratio does this provider cancel?
  cancellation_threshold(provider) = distribution of (usurping_rate / cancelled_rate)

  # Predict: if market rate rises to M, will my session at R be cancelled?
  P(cancellation) = P(M/R > provider's typical cancellation threshold)
```

**Example analysis:**
```
Provider X termination history:
  - Cancelled $0.80 session for $1.50 (ratio: 1.88)
  - Cancelled $1.00 session for $2.20 (ratio: 2.20)
  - Cancelled $0.90 session for $1.60 (ratio: 1.78)
  - Completed session at $1.00 when market was $1.40 (held)

Model: Provider X cancels when usurping_rate > 1.7 × current_rate

Consumer bidding $1.00 can estimate:
  If market rate stays < $1.70: likely safe
  If market rate spikes to $2.00+: ~80% cancellation risk
```

**Consumer expected value calculation:**
```
For a job requiring duration D at price P:

  P(completion) = f(provider.completion_rate, D)

  # Longer jobs have higher cancellation risk
  # Model as: P(completion) = completion_rate ^ (D / mean_session_duration)

  E[cost_if_cancelled] = restart_cost + wasted_compute

  expected_value = P(completion) × value_of_result
                 - P(cancellation) × E[cost_if_cancelled]
                 - P × D

Consumer bids based on expected value, factoring in provider reliability.
```

**Example:**
```
Provider A: 95% completion rate, $1.00/hour
Provider B: 80% completion rate, $0.70/hour

Job: 4 hours, restart cost = $2 if cancelled

Provider A:
  P(completion) ≈ 0.95^1.5 ≈ 0.93
  Expected cost = $4.00 + 0.07 × $2 = $4.14

Provider B:
  P(completion) ≈ 0.80^1.5 ≈ 0.72
  Expected cost = $2.80 + 0.28 × $2 = $3.36

Provider B is cheaper in expectation despite lower reliability,
IF consumer's job can tolerate restarts.
```

**Market equilibrium:**
- Unreliable providers must offer lower prices to attract jobs
- Consumers with restart-tolerant workloads get cheaper compute
- Consumers with critical workloads pay premium for reliable providers
- No explicit penalty needed - market prices in the risk

**Refund on early termination:**
```
When provider terminates early:
  - Consumer receives pro-rated refund for unused time
  - No additional penalty (reliability score is the consequence)
  - Consumer can immediately seek replacement session
```

---

## 6. The Iterative Trust Solver

Trust computation is iterative because credibility depends on trust.

### 6.1 Fixed Point Equation

```
T = f(chain_data, T)

Where:
  T is the vector of all trust scores
  f computes trust from chain data, using T for credibility weights
```

### 6.2 Iterative Solution

```
Initialize:
  T^(0) = T_age + T_transactions (no assertion component yet)

Iterate:
  For each identity i:
    credibility_j = g(T^(k)_j) for all asserters j
    T_assertions_i = compute from assertions weighted by credibility
    T^(k+1)_i = T_age_i + T_transactions_i + T_assertions_i

  Apply cluster detection and similarity penalties

Converge when:
  ||T^(k+1) - T^(k)|| / ||T^(k)|| < CONVERGENCE_EPSILON

  max_iterations = SOLVER_MAX_ITERATIONS
```

### 6.3 Convergence Guarantee

Convergence is guaranteed because:
1. T_age and T_transactions are fixed (from chain data)
2. Credibility is bounded: log(1+T)/log(1+T_ref) is bounded
3. Violation impact is bounded by sum of severities
4. Decay ensures old data has diminishing impact

The system is a contraction mapping under reasonable parameters.

---

## 7. Coin Velocity Requirements

Hoarding coins signals intent to exit. High trust requires economic participation.

### 7.1 Balance-to-Activity Ratio

```
runway(i) = coin_balance(i) / avg_daily_outflow(i)

avg_daily_outflow = (payments + burns + transfers_out) over last VELOCITY_LOOKBACK_DAYS / VELOCITY_LOOKBACK_DAYS
```

**Interpretation:**
- Low runway: Normal reserves relative to activity
- High runway: Suspicious accumulation with low activity
- Infinite runway: Very suspicious - holding coins with zero outflow

### 7.2 Hoarding Penalty

```
if runway(i) > RUNWAY_THRESHOLD:
  hoarding_penalty = log(runway(i) / RUNWAY_THRESHOLD) × HOARDING_PENALTY_WEIGHT

  effective_trust(i) = T(i) / (1 + hoarding_penalty)
```

Trust reduction scales logarithmically with runway excess. Higher runway = more trust reduction.

### 7.3 Exemptions

Hoarding penalty does not apply to:
- New identities (< NEW_IDENTITY_EXEMPTION_DAYS old) still accumulating
- Identities with total lifetime volume below minimum threshold

```
hoarding_exempt(i) = age(i) < NEW_IDENTITY_EXEMPTION_DAYS OR lifetime_volume(i) < MIN_VOLUME_FOR_HOARDING_CHECK
```

### 7.4 Disposal Mechanism

To reduce balance without gaining trust, identities can burn coins via disposal bids.

```
Disposal bid:
  price = negative (provider burns)
  trust_multiplier = 0        # No trust gained
  purpose = "disposal"
```

This allows:
- Reducing balance to avoid hoarding penalty
- Donating compute to research without gaming trust
- Economic participation without strategic benefit

See Section 10.4 for full disposal bid specification.

---

## 8. Transaction Security

Large transactions require additional protection against exit scams.

### 8.1 Transaction Size Classification

```
transaction_value = payment_amount + resource_value

small_transaction:  value < SMALL_TRANSACTION_THRESHOLD
medium_transaction: SMALL_TRANSACTION_THRESHOLD <= value < LARGE_TRANSACTION_THRESHOLD
large_transaction:  value >= LARGE_TRANSACTION_THRESHOLD
```

### 8.2 Delayed Release Escrow

Large transactions use time-locked escrow release.

```
For large_transaction:
  immediate_release = payment × IMMEDIATE_RELEASE_FRACTION
  delayed_release = payment × (1 - IMMEDIATE_RELEASE_FRACTION)

  delayed_release unlocks after:
    delay = max(ESCROW_BASE_DELAY × (1 - trust_factor), ESCROW_MIN_DELAY)
    trust_factor = min(T_provider / TRUST_FOR_MIN_DELAY, 1.0)
```

Delay scales inversely with provider trust. Higher trust = faster release.

### 8.3 Delayed Release Conditions

Delayed portion releases automatically unless:

```
release_blocked if:
  - Consumer files VERIFICATION_FAILURE assertion before release_time
  - Evidence hash provided and validated
  - Dispute resolution in progress

If blocked:
  - Funds held until dispute resolved
  - Resolved in consumer favor: funds returned
  - Resolved in provider favor: funds released + consumer penalty
```

### 8.4 Adaptive Thresholds

Thresholds adjust based on identity's transaction history.

```
effective_large_threshold(i) = LARGE_THRESHOLD × (1 + log(1 + transaction_count(i)) / 10)
```

Identities with extensive history can transact larger amounts without delay.

---

## 9. Payment Split

Payment approaches 100% to provider but never reaches it.

### 9.1 Asymptotic Payment Function

```
provider_share = 1 - 1/(1 + K_PAYMENT × T)
```

Provider share approaches 100% asymptotically as trust increases, but never reaches it. K_PAYMENT controls how quickly the curve approaches 100%.

### 9.2 Minimum Burn

Even at infinite trust, there's always some burn:

```
burn = total_payment × (1 - provider_share)
     = total_payment / (1 + K_PAYMENT × T)

As T → ∞, burn → 0 but never reaches 0
```

### 9.3 Delegate Fees

```
delegate_fee = total_payment × DELEGATE_FEE_RATE × num_delegates
provider_payment = (total_payment - delegate_fee) × provider_share
burn = total_payment - delegate_fee - provider_payment
```

---

## 10. Daily Distribution

### 10.1 Distribution Share

```
daily_share(i) = effective_trust(i) / Σ_j effective_trust(j) × DAILY_MINT

effective_trust(i) = T(i) × activity_factor(i) × cluster_weight(i)
```

### 10.2 Activity Factor

Must be active to receive distribution:

```
activity_factor = min(recent_transactions / ACTIVITY_THRESHOLD, 1.0)

recent = ACTIVITY_LOOKBACK_DAYS
```

### 10.3 Multi-Identity Attack Analysis

**Important distinction**: The system is designed to prevent *honest activity* from benefiting by splitting across identities. However, **attacks that exploit trust can benefit from multiple identities**. This section documents both cases.

#### 10.3.1 Honest Activity Splitting (No Benefit)

**Design requirement**: Splitting identical *honest* activity across N identities must yield ≤ reward of single identity doing all activity.

**Proof for honest activity**:

Consider an attacker with total work capacity W who can either:
- **Single identity**: Do all W work as one identity
- **Sybil attack**: Split work as W/N across N identities

**Case A: Single identity**
```
T_single = f(W)                    # Trust from work W
share_single = T_single / (T_total + T_single) × MINT
```

**Case B: N Sybil identities (detected as cluster)**
```
T_each = f(W/N)                    # Trust from work W/N per identity
cluster_weight = 1/N               # Cluster penalty from detection

effective_each = T_each × (1/N)    # Each identity's effective trust
effective_total = N × T_each × (1/N) = T_each

share_total = T_each / (T_total + T_each) × MINT
```

**For Sybil attack to be unprofitable, we need**:
```
share_total ≤ share_single

T_each / (T_total + T_each) ≤ T_single / (T_total + T_single)
```

**This holds when f(W/N) ≤ f(W)**, which is true for any non-negative trust function where more work = more trust.

**Additional protections for undetected Sybils**:

Even if Sybils evade cluster detection, these mechanisms ensure no benefit:

1. **Sublinear activity factor**: Activity factor caps at 1.0, so splitting 100 transactions across 10 identities (10 each) might not hit the ACTIVITY_THRESHOLD in each, while single identity easily exceeds it.

2. **Age derate**: Each new identity starts at age_derate = 0 and takes AGE_MATURITY_DAYS to reach 1.0. Single identity has full derate immediately.

3. **Transaction diversity penalty**: Sybils transacting with each other have low diversity scores.

4. **Verification overhead**: Each identity must be independently verified, increasing attacker cost.

**Formal requirement for parameters**:
```
For any work W and any N > 1:
  Σᵢ₌₁ᴺ reward(W/N, identity_i) ≤ reward(W, single_identity)

Where reward() incorporates:
  - Trust from work
  - Activity factor
  - Age derate
  - Cluster weight (if detected)
  - Profile score
```

This should be validated empirically through simulation with various attack scenarios.

#### 10.3.2 Trust Exploitation Attacks (Multi-Identity DOES Benefit)

**Critical acknowledgment**: When an attack exploits accumulated trust, having multiple identities **increases total reward**. These are known attack vectors requiring explicit defense.

**Attack Class 1: Exit Scam with Value Transfer**

```
Attack pattern:
  1. Build trust on identity A over time (legitimate activity)
  2. Accumulate coins on identity A (from payments, distribution)
  3. Create identity B, mature it to reduce transfer burns
  4. Transfer coins from A to B (before attack)
  5. Execute exit scam on A (exploit trust for maximum extraction)
  6. A's trust destroyed, but value preserved in B

Benefit from multiple identities:
  Single identity: Gain from scam, lose all accumulated coins when trust drops
  Multiple identities: Gain from scam + preserve previously earned coins in B
```

**Defense vectors to explore**:
- Retroactive clawback of transfers preceding trust collapse
- Transfer velocity limits based on trust trajectory
- Delayed transfer finality for large amounts

**Attack Class 2: Trust Arbitrage Across Communities**

```
Attack pattern:
  1. Build trust with Community A through honest behavior
  2. Create separate identity B in Community A
  3. Use A's reputation to gain access to Community C
  4. Exploit Community C (they see A's global trust)
  5. Transfer gains to B before C's accusations propagate back

Benefit from multiple identities:
  Single identity: Exploitation damages trust everywhere
  Multiple identities: Exploitation damages A, B continues unaffected
```

**Defense vectors to explore**:
- Local trust model (Section 13) limits cross-community trust transfer
- Longer propagation windows before trust can be leveraged in new communities
- Accusation propagation through network bridges

**Attack Class 3: Sacrificial Trust Burning**

```
Attack pattern:
  1. Build moderate trust on N identities (A₁, A₂, ... Aₙ)
  2. Use one identity (A₁) to vouch for malicious actor M
  3. M exploits network, A₁ takes credibility hit
  4. A₂...Aₙ continue operating, repeat with A₂
  5. Cycle through identities, each enabling one exploitation

Benefit from multiple identities:
  Single identity: One exploitation, then trusted status lost
  Multiple identities: N exploitations before all identities burned
```

**Defense vectors to explore**:
- Cluster detection for identities with correlated vouching patterns
- Exponential penalty for vouching for later-exposed bad actors
- Cool-down periods after any vouched identity causes damage

**Attack Class 4: Distributed Accusation Attacks**

```
Attack pattern:
  1. Create N identities, build minimum trust on each
  2. Coordinate accusations against target from all N
  3. Each individual accusation has low credibility
  4. Combined effect may trigger increased verification/scrutiny
  5. Target suffers reputation damage or operational friction

Benefit from multiple identities:
  Single identity: Low-credibility accusation easily dismissed
  Multiple identities: Appearance of consensus, harder to dismiss
```

**Defense vectors to explore**:
- Coordination detection (Section 4.3) for synchronized accusations
- Inverse credibility for accusations from similar behavioral profiles
- Accusation rate limiting per target across all accusers

**Attack Class 5: Insurance/Hedging via Identity Diversity**

```
Attack pattern:
  1. Operate N identities with different risk profiles
  2. Some identities take high-risk, high-reward actions
  3. Some identities maintain conservative, trust-building behavior
  4. Failed risky actions don't contaminate conservative identities
  5. Successful risky actions can transfer value to conservative ones

Benefit from multiple identities:
  Single identity: Must choose one risk profile
  Multiple identities: Portfolio approach, hedge across profiles
```

**Defense vectors to explore**:
- This may be acceptable behavior (legitimate risk management)
- If unacceptable, requires behavioral clustering across identities
- Transfer pattern analysis to detect value consolidation

**Attack Class 6: Identity Rotation / Spotlight Evasion**

```
Attack pattern:
  1. Wealthy user W has substantial coin holdings (visible, under scrutiny)
  2. W creates sock puppet P, matures with minimal activity over time
  3. W transfers large sum to P, accepting burn as "visibility tax"
  4. W now operates as P - same wealth, fresh identity, no spotlight
  5. Repeat: create P2, mature it, rotate when P gains attention
  6. Maintain multiple puppets maturing in parallel as escape hatches

Key insight:
  - Time gates (age derate) and activity requirements have FIXED COST
  - For wealthy users, this fixed cost is trivial relative to their holdings
  - Transfer burn is a one-time tax, not ongoing friction
  - Result: wealthy users can shed visibility at acceptable cost

Example:
  W has 100,000 OMC, under community scrutiny
  W matures puppet P over 6 months with 50 OMC of activity (0.05% of wealth)
  W transfers 50,000 OMC to P at 20% burn = 10,000 OMC cost (10% tax)
  P now operates with 40,000 OMC as "fresh" identity
  W retains 50,000 OMC, can repeat with P2, P3...

Benefit from multiple identities:
  Single identity: Wealth and behavior permanently visible
  Multiple identities: Can rotate between identities, shed history at will
```

**Defenses:**
- Amount-based transfer burns (Section 12.7): progressive burn based on transfer size
- Trust inheritance (Section 12.8): recipient's trust blends toward sender's, only downward
- Circular flow detection (Section 4.7): catches wealth cycling between controlled identities
- Large transfer delays: finality windows for transfers above threshold

#### 10.3.3 Absolute vs Tolerated Multi-Identity Protections

**Design principle**: Some protections must be absolute (no benefit from splitting), while others may tolerate some multi-identity advantage if the cost of enforcement exceeds the benefit.

**ABSOLUTE PROTECTIONS (Must Hold)**

These protections must mathematically guarantee no benefit from identity splitting:

**1. UBI/Daily Distribution - ABSOLUTE**

```
Untrustworthy behavior in ANY identity reduces UBI allocation across ALL linked identities.

Implementation:
  - Identity linkage detected via: transfer patterns, behavioral clustering,
    timing correlation, network topology
  - When linkage detected: effective_trust for distribution = min(T across linked set)
  - Alternatively: distribution computed as if linked identities were single entity

Result:
  For identities {A, B, C} detected as linked:
    combined_distribution ≤ max(distribution(A), distribution(B), distribution(C))

  No identity splitting can increase total UBI received.
```

**2. Trust from Activity - ABSOLUTE**

```
Same work split across N identities yields ≤ trust of single identity.

Already proven in Section 10.3.1:
  - Cluster detection divides trust by cluster size
  - Activity factor caps prevent threshold gaming
  - Age derate penalizes new identities
```

**3. Accusation Credibility - ABSOLUTE**

```
N low-credibility accusations should not sum to high credibility.

Implementation:
  - Coordination detection (Section 4.3) identifies linked accusers
  - Linked accusers' credibility is not additive
  - Only highest-credibility accuser counts, others are noise

Result:
  credibility(linked_set accusing X) = max(credibility(A), credibility(B), ...)
  Not: sum(credibility(A) + credibility(B) + ...)
```

**TOLERATED ADVANTAGES (Acceptable Tradeoffs)**

These areas may provide some multi-identity benefit, accepted as cost of not over-constraining legitimate use:

**1. Risk Diversification - TOLERATED**

```
Operating multiple identities with different risk profiles is legitimate.

Rationale:
  - Businesses may have separate legal entities
  - Individuals may separate personal/professional activities
  - Over-enforcement would harm legitimate structure

Constraint:
  - Transfer burns still apply
  - Each identity must independently build trust
  - No identity can leverage another's trust directly
```

**2. Community Separation - TOLERATED**

```
Building trust in separate communities without cross-contamination.

Rationale:
  - Local trust model (Section 13) already limits trust transfer
  - Communities that don't interact shouldn't share trust
  - Legitimate use: operator in multiple regions

Constraint:
  - Trust arbitrage attacks still penalized when detected
  - Bridge participants propagate reputation
```

**3. Recovery via New Identity - TOLERATED WITH PENALTY**

```
Starting fresh after trust damage, with significant cost.

Rationale:
  - People can rehabilitate
  - Over-punishment reduces network participation
  - New identity starts at age_derate = 0, takes time to mature

Constraint:
  - Old identity's coins trapped by transfer burns
  - Age derate means new identity earns nothing initially
  - Behavioral similarity may link to old identity
```

#### 10.3.4 Simulation Requirements

These attack classes should be explicitly modeled in simulations:

| Attack Class | Key Metrics | Success Criteria for Defense |
|--------------|-------------|------------------------------|
| Exit Scam + Transfer | Value preserved after scam | Clawback recovers >80% of transferred value |
| Trust Arbitrage | Cross-community exploitation rate | Local trust limits exploitation to <10% of global trust attacks |
| Sacrificial Burning | Exploitations per identity set | Cluster detection catches >90% of correlated vouchers |
| Distributed Accusations | False positive rate on targets | Coordination detection nullifies >95% of coordinated attacks |
| Insurance/Hedging | Risk-adjusted returns | No significant advantage vs single identity with same total capital |

**Open research questions**:

1. Can transfer graph analysis detect pre-attack value extraction?
2. What's the minimum cluster size that evades behavioral similarity detection?
3. How do we distinguish legitimate multi-identity use (e.g., business units) from attacks?
4. Should some multi-identity strategies be accepted as legitimate risk management?

---

## 11. Donation and Negative Bids

### 11.1 Zero-Price Donations

```
credit = base_credit × resource_weight × duration × verification_score
```

Same credit as commercial, just no payment.

### 11.2 Negative-Price Donations (Provider Burns)

```
burn_bonus = min(|bid_price| / market_rate, MAX_BURN_RATIO)
credit = base_credit × resource_weight × duration × verification_score × (1 + burn_bonus × BURN_MULTIPLIER)
```

### 11.3 Fiat-to-Trust Tracking

The network tracks:

```
current_fiat_rate = observed cloud costs per resource-hour
current_omc_rate = market rate in OMC per resource-hour
burn_cap_rate = MAX_BURN_RATIO × current_omc_rate

trust_per_dollar = (1 + MAX_BURN_RATIO × BURN_MULTIPLIER) × base_credit / current_fiat_rate
```

This is published for transparency about the cost of trust.

### 11.4 Disposal Bids (Zero Trust Gain)

For identities that want to reduce their coin balance without strategic benefit.

```
Disposal bid:
  bid_type = "disposal"
  price = negative (provider burns own coins)
  trust_multiplier = DISPOSAL_TRUST_MULTIPLIER
  verification = standard (still counts as real compute)

credit = base_credit × resource_weight × duration × verification_score × DISPOSAL_TRUST_MULTIPLIER
```

**Why not zero?**

Some minimal trust gain is appropriate because:
1. Real compute was provided
2. Verification still occurred
3. Zero would create gaming opportunities (disposal then re-donate for full credit)

DISPOSAL_TRUST_MULTIPLIER should be low enough that disposal is economically irrational for trust-building but useful for:
- Reducing hoarding penalty exposure
- Pure altruistic donation without strategic benefit
- Established providers who don't need more trust

### 11.5 Bid Type Summary

| Bid Type | Price | Trust Multiplier | Use Case |
|----------|-------|------------------|----------|
| Commercial | Positive | 1.0 | Normal rental market |
| Zero donation | Zero | 1.0 | Research donation, trust building |
| Negative donation | Negative | 1.0 + burn_bonus × 1.5 | Accelerated trust building |
| Disposal | Negative | 0.1 | Reduce balance, pure donation |

---

## 12. Transfer Burns

Transfers between identities are taxed based on trust, preventing reputation laundering and incentivizing compute donation.

### 12.1 Transfer Burn Rate

```
transfer_burn_rate = 1 / (1 + K_TRANSFER × min(T_sender, T_receiver))

amount_received = amount_sent × (1 - transfer_burn_rate)
```

Uses the minimum trust of sender and receiver. Either party being untrusted triggers high burn. K_TRANSFER typically equals K_PAYMENT for consistency.

### 12.2 Burn Rate Examples

| Sender Trust | Receiver Trust | Burn Rate | 100 OMC becomes |
|--------------|----------------|-----------|-----------------|
| 0 | 0 | 100% | 0 OMC |
| 0 | 500 | 100% | 0 OMC |
| 500 | 0 | 100% | 0 OMC |
| 50 | 50 | 67% | 33 OMC |
| 100 | 100 | 50% | 50 OMC |
| 500 | 500 | 17% | 83 OMC |
| 1000 | 1000 | 9% | 91 OMC |

### 12.3 Reputation Laundering Prevention

Without transfer burns:
1. Attacker builds trust on v1, accumulates coins
2. Exploits v1, trust drops to 0
3. Transfers coins to fresh identity v2
4. Starts over with coins intact

With transfer burns:
1. Same as above...
2. v1 (trust=0) tries to transfer to v2 (trust=0)
3. Burn rate = 100%, v2 receives nothing
4. Assets are trapped in burned identity

### 12.4 New Entrant Economics

Transfer burns create strong incentive to donate compute rather than buy coins.

**Option A: Buy coins externally, transfer in**
```
$100 → buy 100 OMC from someone
Transfer to new identity (trust=0)
Burn rate ≈ 100%
Result: 0 OMC, 0 trust
```

**Option B: Donate compute**
```
$100 → rent cloud compute
Donate to network (zero-price bid)
Verified compute builds trust
Result: 0 OMC, but trust earned
```

**Option C: Donate with negative bid (if you have coins)**
```
Acquire some coins (with burn)
Donate compute + burn coins (negative bid)
Accelerated trust from burn bonus
Result: coins burned, more trust earned
```

Option B is strictly better than Option A. The network rewards contribution over capital.

### 12.5 Exemptions

Transfer burns do NOT apply to:
- Escrow transactions (consumer → escrow → provider) - these use payment share instead
- Daily distribution - earned directly, no transfer
- Burn transactions - coins are destroyed, not transferred

Transfer burns DO apply to:
- Peer-to-peer transfers
- Withdrawals to external addresses (receiver trust = 0)
- Any movement of coins between identities

### 12.6 Economic Balance

The system should be tuned so that:

```
cost_to_earn_trust_via_transfer > cost_to_earn_trust_via_donation

Specifically:
  OMC_burned_in_transfer / trust_gained < cloud_cost / trust_gained_from_donation
```

Since transfers to low-trust receivers burn nearly 100%, and donations at market rate give full trust credit, donations are always more efficient for new entrants.

### 12.7 Transfer Amount Scaling

Large transfers face additional burns to prevent identity rotation attacks (Section 10.3.2, Attack Class 6).

**Problem:**
Trust-based burns have fixed cost structure. For wealthy users, the burn percentage is acceptable as a "visibility tax" to rotate between identities. A 20% burn on a large transfer is still worth it to escape scrutiny.

**Solution:**
Add progressive amount-based component to transfer burns.

**Combined transfer burn:**
```
trust_burn_rate = 1 / (1 + K_TRANSFER × min(T_sender, T_receiver))

amount_factor = amount / MEDIAN_NETWORK_BALANCE
amount_burn_rate = K_AMOUNT × log(1 + amount_factor) / log(AMOUNT_SCALE)

combined_burn_rate = min(1.0, trust_burn_rate + amount_burn_rate)

amount_received = amount_sent × (1 - combined_burn_rate)
```

**Amount burn examples:**

| Amount (× median) | Amount Burn Rate | Trust Burn (T=500) | Combined |
|-------------------|------------------|---------------------|----------|
| 0.1× | 0% | 17% | 17% |
| 1× | 5% | 17% | 22% |
| 10× | 10% | 17% | 27% |
| 100× | 15% | 17% | 32% |
| 1000× | 20% | 17% | 37% |

**Effect on identity rotation:**
```
Before (trust-only burns):
  W has 100,000 OMC (1000× median), T_W = 500
  W transfers to P (T_P = 200)
  Burn rate = 33% (based on min trust)
  P receives 67,000 OMC
  Cost: 33,000 OMC to shed visibility

After (with amount scaling):
  Same scenario
  Trust burn = 33%
  Amount burn = 20% (1000× median)
  Combined burn = min(1.0, 53%) = 53%
  P receives 47,000 OMC
  Cost: 53,000 OMC to shed visibility

  Each rotation costs majority of transfer, making repeated rotation expensive.
```

**Splitting doesn't help:**
```
If W splits 100,000 OMC into 10 transfers of 10,000:
  Amount factor for each = 100× median
  Amount burn = 15% per transfer
  After 10 transfers: ~85% × 10 × (10,000 × 0.67) = ~57,000 OMC
  Still significant burn, just spread across transfers

Plus: Multiple transfers to same recipient trigger circular flow detection (Section 4.7)
```

**Parameters:**
- MEDIAN_NETWORK_BALANCE: Rolling median (recalculated daily)
- K_AMOUNT: Amount scaling factor (default: 0.2)
- AMOUNT_SCALE: Logarithm base (default: 10, meaning 10× median = K_AMOUNT burn)

**Exemption consideration:**
Large legitimate transfers (business acquisitions, etc.) may request escrow-style transfers that are held for a delay period and visible on-chain, accepting transparency in exchange for reduced amount burns.

### 12.8 Trust Inheritance on Transfer

Large transfers force the recipient to inherit the sender's trust level, but only downward.

**Core principle:**
Trust reflects your own actions. If your wealth is dominated by received transfers rather than earned activity, your trust should reflect the trustworthiness of your funding sources—but you can never *buy* higher trust.

**Transfer trust impact:**
```
When P receives transfer of amount A from W:
  balance_before = P's balance before transfer
  balance_after = balance_before + A

  transfer_ratio = A / balance_after

  # Blend trust based on how much of new balance came from transfer
  blended_trust = transfer_ratio × T(W) + (1 - transfer_ratio) × T(P)

  # Only apply if it would DECREASE trust (can't buy trust)
  T(P)_new = min(T(P), blended_trust)
```

**Key properties:**

1. **Only decreases, never increases**: The `min()` ensures high-trust senders cannot gift trust to low-trust recipients. Trust must be earned, not transferred.

2. **Proportional to wealth dominance**: Small transfers have negligible impact. Large transfers that dominate your balance force significant trust inheritance.

3. **No complex provenance tracking**: Only the transfer ratio matters at time of transfer. No need to track coin lineage.

**Examples:**

*Low-trust sender, large transfer:*
```
P has 100 OMC, T(P) = 200
W has 100,000 OMC, T(W) = 50 (under scrutiny)

W transfers 9,900 OMC to P
transfer_ratio = 9900 / 10000 = 0.99

blended_trust = 0.99 × 50 + 0.01 × 200 = 51.5
T(P)_new = min(200, 51.5) = 51.5

Result: P's trust collapses from 200 → 51.5
P is now 99% "W's money" and inherits W's low trust
```

*High-trust sender, large transfer:*
```
P has 100 OMC, T(P) = 50
W has 100,000 OMC, T(W) = 800

W transfers 9,900 OMC to P
transfer_ratio = 0.99

blended_trust = 0.99 × 800 + 0.01 × 50 = 792.5
T(P)_new = min(50, 792.5) = 50

Result: P's trust unchanged at 50
Cannot buy trust from high-trust sender
```

*Small transfer from low-trust sender:*
```
P has 10,000 OMC, T(P) = 300
W has 100,000 OMC, T(W) = 20

W transfers 100 OMC to P
transfer_ratio = 100 / 10100 = 0.0099

blended_trust = 0.0099 × 20 + 0.9901 × 300 = 297.2
T(P)_new = min(300, 297.2) = 297.2

Result: Negligible impact (< 1% trust reduction)
Small transfers don't matter
```

**Effect on identity rotation attack:**
```
Attack scenario:
  W (wealthy, under scrutiny) wants to rotate to puppet P
  W has 100,000 OMC, T(W) = 500, but scrutiny reduces effective trust
  P has 50 OMC after minimal activity, T(P) = 100

  W transfers 50,000 OMC to P
  transfer_ratio = 50000 / 50050 = 0.999

  For trust inheritance, use W's effective trust (with scrutiny penalty)
  effective_T(W) = 500 × (1 - scrutiny_penalty) = 100

  blended_trust = 0.999 × 100 + 0.001 × 100 = 100
  T(P)_new = min(100, 100) = 100

  Result: P inherits W's scrutinized trust level
  Identity rotation provides no escape from scrutiny
```

**Interaction with transfer burns:**
Trust inheritance applies AFTER transfer burns. The recipient's trust is affected based on who sent the coins, regardless of how much was burned in transit.

**Multiple transfers:**
Each transfer is processed independently. If P receives from multiple sources, each transfer adjusts P's trust based on the ratio at that moment. A series of small transfers from low-trust sources will gradually erode P's trust.

---

## 13. Local Trust (Network-Weighted)

Trust is not global. It propagates through the transaction graph.

### 13.1 The Problem with Global Trust

If trust is a single number visible to everyone, an attacker can:
1. Build trust with Community A through honest behavior
2. Approach Community B, who sees the global trust score
3. Exploit Community B, who has no direct experience with the attacker

This is the **trust arbitrage attack**. It works because Community B is trusting based on someone else's experience.

### 13.2 Trust as Seen By Observer

Each identity sees a different trust score for each other identity, based on their position in the network.

```
T(subject, observer) = T_direct(subject, observer) + T_transitive(subject, observer)
```

**Direct trust** comes from personal experience:
```
T_direct(subject, observer) = Σ transactions where observer was counterparty to subject
                              × verification_score × recency_decay
```

**Transitive trust** comes through trusted intermediaries:
```
T_transitive(subject, observer) = Σ_intermediary (
  T(intermediary, observer) × T(subject, intermediary) × TRANSITIVITY_DECAY
)
```

### 13.3 Transitivity Decay

Trust attenuates with each hop through the network.

```
effective_trust(subject, observer, path_length) =
  raw_trust × TRANSITIVITY_DECAY^path_length
```

TRANSITIVITY_DECAY controls how quickly trust attenuates over network distance. Lower values mean trust is more local.

### 13.4 Path-Based Trust Computation

For observer O evaluating subject S:

```
1. Find all paths from O to S through transaction graph
2. For each path P:
   trust_contribution(P) = min(trust along each edge) × TRANSITIVITY_DECAY^|P|
3. T(S, O) = max(trust_contribution(P) for all P up to MAX_PATH_LENGTH)
```

Using max (not sum) prevents gaming by creating many weak paths.

### 13.5 Bootstrap for New Observers

New identities with no transaction history see a baseline:

```
T(subject, new_observer) = T_global(subject) × NEW_OBSERVER_DISCOUNT
```

As the new observer builds their own transaction graph, their local view replaces the discounted global view.

### 13.6 Implications for Trust Arbitrage

With local trust, the arbitrageur in Community A has:
- High trust as seen by Community A members (direct experience)
- Low trust as seen by Community B members (no path, or long path with high decay)

Community B sees the arbitrageur's global trust discounted by NEW_OBSERVER_DISCOUNT, or even less if there's no path connecting the communities.

The arbitrageur must build trust with Community B through actual transactions before they'll accept large jobs. This is exactly how human trust works.

### 13.7 Network Connectivity Effects

```
If communities A and B have bridge members (who transact with both):
  - Trust flows through bridges
  - Arbitrageur's bad behavior in B propagates back to A through bridges
  - Eventually A learns about B's experience

If communities are isolated:
  - Trust doesn't transfer
  - Each community must evaluate independently
  - This is the correct behavior
```

### 13.8 Computational Considerations

Full path computation is O(n²) or worse. Practical implementations can:
1. Cache trust scores and invalidate on new transactions
2. Limit path search to k shortest paths
3. Use random walks for approximation (like PageRank)
4. Pre-compute for frequently-queried pairs

---

## 14. Parameter Summary

All parameters are configurable at network genesis and modifiable through governance. Example values are suggestions only—actual values should be determined through simulation and empirical observation.

### Trust Accumulation
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| K_AGE | Trust per day at steady state | Higher = faster baseline accumulation |
| TAU_AGE | Days to reach steady age rate | Higher = slower initial ramp-up |
| BASE_CREDIT | Trust per hour of compute | Higher = faster trust from activity |
| TAU_TRANSACTION | Transaction recency half-life | Higher = older transactions matter more |
| ACTIVITY_THRESHOLD | Min transactions for full activity factor | Higher = more activity required |
| ACTIVITY_LOOKBACK_DAYS | Window for activity measurement | Shorter = more responsive to changes |

### Assertion & Violation
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| RESIDUAL | Permanent fraction of violation | Higher = violations never fully heal |
| TAU_ASSERTION | Assertion decay half-life | Higher = assertions matter longer |
| TAU_NEGATIVE / TAU_POSITIVE | Asymmetric decay rates | Different values = negative/positive decay differently |
| T_REFERENCE | Trust level for credibility = 1.0 | Higher = harder to reach full credibility |
| UNCLASSIFIED_THRESHOLD | Trust required for UNCLASSIFIED assertions | Higher = more exclusive |

### Statistical Detection
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| ISOLATION_THRESHOLD | Cluster isolation suspicion level | Higher = more tolerance for isolated groups |
| SIMILARITY_THRESHOLD | Behavioral similarity suspicion | Higher = more tolerance for similar behavior |
| ANOMALY_WINDOW | Window for volume anomaly detection | Shorter = more sensitive to short bursts |
| VOLUME_SPIKE_THRESHOLD | Multiplier for volume anomaly | Higher = less sensitive |
| ACCUSATION_SPIKE_THRESHOLD | Multiplier for accusation anomaly | Higher = less sensitive |
| ACCUSATION_RATE_WINDOW | Window for accusation rate measurement | Shorter = more responsive |

### Assertion Analysis
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| ACCURACY_THRESHOLD | Tolerance for prediction error | Higher = more tolerance for inaccuracy |
| DIVERGENCE_PENALTY_WEIGHT | Penalty per unit of divergence | Higher = harsher on divergent assertions |
| MIN_ACCURACY_RATIO | Minimum accuracy before penalty | Higher = stricter accuracy requirement |
| ACCURACY_PENALTY_WEIGHT | Penalty for poor accuracy | Higher = harsher on poor accuracy |
| SPAM_THRESHOLD | Assertion rate multiple for spam | Higher = more tolerance for high assertion rates |
| SPAM_PENALTY_WEIGHT | Penalty per excess assertion | Higher = harsher on spam |
| TARGETING_THRESHOLD | Concentration for harassment detection | Higher = more tolerance for focused accusations |
| TARGETING_PENALTY_WEIGHT | Penalty for targeted harassment | Higher = harsher on targeting |
| MIN_ASSERTIONS_FOR_TARGETING | Min assertions before targeting check | Higher = more tolerance before checking |
| UNSUPPORTED_PENALTY_BASE | Penalty per unsupported assertion | Higher = harsher on missing evidence |

### Coin Velocity
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| VELOCITY_LOOKBACK_DAYS | Window for outflow measurement | Shorter = more responsive to changes |
| RUNWAY_THRESHOLD | Days of reserves before penalty | Higher = more tolerance for hoarding |
| HOARDING_PENALTY_WEIGHT | Penalty scaling factor | Higher = harsher on hoarders |
| MIN_VOLUME_FOR_HOARDING_CHECK | Volume threshold for check | Higher = more exemptions |
| NEW_IDENTITY_EXEMPTION_DAYS | Days before hoarding check applies | Higher = more grace period |

### Transaction Security
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| SMALL_TRANSACTION_THRESHOLD | Max value for "small" transaction | Higher = more transactions qualify as small |
| LARGE_TRANSACTION_THRESHOLD | Min value for "large" transaction | Higher = fewer transactions delayed |
| IMMEDIATE_RELEASE_FRACTION | Fraction released immediately | Higher = faster payment, more risk |
| ESCROW_BASE_DELAY | Max delay for zero trust | Higher = more protection, slower commerce |
| TRUST_FOR_MIN_DELAY | Trust for minimum delay | Higher = requires more trust for fast release |
| ESCROW_MIN_DELAY | Minimum delay for large tx | Higher = more protection, slower commerce |

### Payment Curve
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| K_PAYMENT | Payment curve scaling | Higher = trust matters more for payment |
| DELEGATE_FEE_RATE | Fee per delegate | Higher = more delegate incentive, higher cost |

### Donation & Disposal
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| MAX_BURN_RATIO | Max burn as multiple of market rate | Higher = more trust acceleration possible |
| BURN_MULTIPLIER | Trust bonus per unit burn | Higher = more reward for burning |
| DISPOSAL_TRUST_MULTIPLIER | Trust fraction for disposal bids | Higher = more trust from disposal (potential gaming) |

### Transfer Burns
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| K_TRANSFER | Transfer burn curve scaling | Higher = trust matters more for transfers |
| K_AMOUNT | Amount-based burn scaling factor | Higher = larger transfers burn more |
| AMOUNT_SCALE | Logarithm base for amount scaling | Lower = more aggressive amount scaling |

### Circular Flow Detection
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| MAX_CYCLE_LENGTH | Maximum cycle size to detect | Higher = catches larger rings, more computation |
| CIRCULAR_THRESHOLD | Ratio threshold for suspicious flow | Lower = more aggressive detection, more false positives |
| CIRCULAR_PENALTY_WEIGHT | Penalty scaling for circular flows | Higher = harsher on detected cycles |

### Local Trust
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| TRANSITIVITY_DECAY | Trust decay per network hop | Lower = more local trust, less network effect |
| MAX_PATH_LENGTH | Maximum hops for trust propagation | Higher = more global trust, more computation |
| NEW_OBSERVER_DISCOUNT | Global trust discount for new identities | Lower = more conservative toward new observers |

### Accusation & Verification
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| ACCUSATION_WINDOW | Days before re-accusation allowed | Higher = less accusation spam, slower response |
| BASE_VERIFICATION_RATE | Default verification sampling rate | Higher = more verification, more overhead |
| MAX_VERIFICATION_RATE | Maximum verification rate when accused | Higher = more scrutiny for accused |
| PENDING_PENALTY_WEIGHT | Credibility penalty per pending accusation | Higher = harsher on unverified accusers |
| MIN_TRANSACTIONS_FOR_FULL_WEIGHT | Transactions for full accusation weight | Higher = requires more history |

### Third-Party Verification
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| VERIFIER_THRESHOLD | Minimum trust to be eligible verifier | Higher = fewer, more trusted verifiers |
| VERIFICATION_PANEL_SIZE | Number of verifiers per check | Higher = more robust, more overhead |
| COMMIT_DEADLINE | Time for commit phase | Longer = more participation, slower |
| REVEAL_DEADLINE | Time for reveal phase | Longer = more participation, slower |
| EXPECTED_VERIFICATION_RATE | Expected verifications per transaction | Higher = more civic duty expected |

### Profile Score
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| WEIGHT_VERIFICATION_ORIGINATION | Weight of verification behavior | Higher = civic duty matters more |
| WEIGHT_SESSION_COMPLETION | Weight of session reliability | Higher = completion matters more |
| WEIGHT_CONSUMER_RETENTION | Weight of repeat business | Higher = quality signal matters more |
| WEIGHT_TRANSACTION_DIVERSITY | Weight of counterparty diversity | Higher = punishes captive relationships more |
| WEIGHT_ACCUSATION_RECORD | Weight of accusation accuracy | Higher = assertion behavior matters more |
| WEIGHT_ACTIVITY_CONSISTENCY | Weight of consistent participation | Higher = punishes burst behavior more |
| RETENTION_SCORE_MULTIPLIER | Multiplier for retention score | Higher = easier to max retention score |
| PROFILE_MIN_MODIFIER | Minimum profile modifier | Lower = harsher on poor profiles |
| PROFILE_MAX_MODIFIER | Maximum profile modifier | Higher = more reward for good profiles |
| ORIGINATION_FREERIDER_THRESHOLD | Ratio below which is free-riding | Higher = stricter free-rider detection |
| ORIGINATION_BELOW_AVG_THRESHOLD | Ratio for below average | Higher = stricter below-average threshold |
| ORIGINATION_GOOD_THRESHOLD | Ratio for good citizen | Higher = harder to be "good" |
| ORIGINATION_ACTIVE_THRESHOLD | Ratio for active contributor | Higher = harder to get bonus |
| ORIGINATION_ACTIVE_BONUS | Bonus multiplier for active | Higher = more reward for high origination |

### Solver
| Parameter | Description | Tradeoff |
|-----------|-------------|----------|
| CONVERGENCE_EPSILON | Relative change for convergence | Lower = more precision, more iterations |
| SOLVER_MAX_ITERATIONS | Maximum iterations before stopping | Higher = more precision, more computation |

---

## 15. Simulation Scenarios

### 15.1 Trust System Scenarios

1. **Normal operation**: Honest providers accumulating trust over months
2. **Sybil cluster**: 10 fake identities transacting with each other
3. **Collusion ring**: 5 providers making false accusations against competitor
4. **Long-con**: Build trust for 6 months, then misbehave
5. **False accusation**: Malicious accusation against honest provider
6. **New entrant**: Breaking into established network
7. **Recovery**: Provider recovering from legitimate violation
8. **Donation bootstrapping**: New provider using negative bids to accelerate

### 15.2 Identity Rotation Scenarios

9. **Wealthy sock puppet attack**: W creates puppet P, matures with minimal investment, transfers large sum to escape scrutiny (Section 19.1)
10. **Trust inheritance validation**: Verify that large transfers cause recipient's trust to blend toward sender's trust
11. **Circular flow detection**: W → P₁ → P₂ → W wealth cycling patterns

### 15.3 Reliability Market Scenarios

12. **Provider threshold convergence**: Do providers converge to single optimal cancellation threshold? (Section 19.2)
13. **Consumer value differentiation**: How do high-value vs low-value consumers interact? (Section 19.3)
14. **Scarcity effects**: Under resource scarcity, are low-value users priced out? (Section 19.4)
15. **Restart cost model**: Validate that restart cost = wasted compute time, not dollar penalty
16. **Consumer distribution effects**: Does consumer mix affect provider equilibrium? (Section 19.6)
17. **Economic value of unreliable compute**: Does introducing home providers reduce $/useful_hr? (Section 19.7)

### 15.4 Simulation Code

| Scenario | Code Location |
|----------|--------------|
| Identity rotation attack | `/simulations/identity_rotation_attack.py` |
| Reliability market equilibrium | `/simulations/reliability_market_v2.py` |
| Provider convergence | `/simulations/reliability_market_equilibrium.py` |
| Basic reliability test | `/simulations/reliability_market_simulation.py` |
| Economic value (DC vs Home) | `/simulations/economic_value_simulation.py` |

---

## 16. Governance and Parameter Evolution

Parameters are policy decisions, not universal constants. Networks evolve their own governance.

### 16.1 Genesis Parameters

Network founder sets initial parameters at creation:

```
GenesisConfig {
  // Trust accumulation
  k_age: float
  tau_age: float
  base_credit: float
  tau_transaction: float

  // Payment curve
  k_payment: float

  // Transfer burns
  k_transfer: float

  // Local trust
  transitivity_decay: float
  max_path_length: int
  new_observer_discount: float

  // Escrow
  large_threshold: float
  immediate_release_fraction: float
  base_delay: int

  // Detection thresholds
  isolation_threshold: float
  similarity_threshold: float

  // Governance
  voting_threshold: float          # Trust required to vote
  proposal_threshold: float        # Trust required to propose
  approval_quorum: float           # Fraction of trust needed to approve
  change_delay: int                # Days before approved change takes effect
  max_parameter_change: float      # Maximum % change per proposal
}
```

### 16.2 Trust-Weighted Voting

Parameter changes are approved by trust-weighted vote.

```
vote_weight(identity) = effective_trust(identity)

total_votes_for = Σ vote_weight(i) for all i voting "yes"
total_votes_against = Σ vote_weight(i) for all i voting "no"
total_eligible = Σ vote_weight(i) for all i with trust > voting_threshold

approval = total_votes_for / (total_votes_for + total_votes_against)
quorum = (total_votes_for + total_votes_against) / total_eligible

passed = approval > 0.5 AND quorum > approval_quorum
```

### 16.3 Proposal Lifecycle

```
1. DRAFT
   - Anyone above proposal_threshold can create
   - Specify: parameter, current_value, proposed_value, rationale

2. DISCUSSION (7 days default)
   - Community reviews and debates
   - Proposer can amend

3. VOTING (7 days default)
   - Trust-weighted votes
   - Cannot amend during voting

4. APPROVED or REJECTED
   - If passed: enters delay period
   - If failed: archived

5. ACTIVE (after change_delay)
   - Parameter takes new value
   - Old value recorded in history
```

### 16.4 Change Limits

Prevent drastic parameter shifts:

```
max_change = current_value × max_parameter_change

|proposed_value - current_value| <= max_change

Example with max_parameter_change = 0.2 (20%):
  k_payment = 0.01
  Can change to: 0.008 - 0.012
  Cannot change to: 0.005 or 0.02 in one proposal
```

Larger changes require multiple sequential proposals.

### 16.5 Parameter Categories

Different parameters may have different governance rules:

| Category | Examples | Typical Threshold |
|----------|----------|-------------------|
| **Economic** | k_payment, k_transfer, base_credit | Higher quorum (60%) |
| **Security** | isolation_threshold, escrow settings | Higher quorum (60%) |
| **Tuning** | tau values, decay rates | Normal quorum (50%) |
| **Governance** | voting_threshold, quorum requirements | Highest quorum (75%) |

### 16.6 Emergency Procedures

For critical security issues:

```
emergency_proposal:
  requires: trust > emergency_threshold (top 1% of network)
  voting_period: 24 hours
  approval_required: 80%
  no change_delay

  automatically_expires: 30 days
  must be ratified by normal proposal to become permanent
```

### 16.7 Fork Rights

If governance fails, participants can fork:

```
Any participant can:
  1. Export their transaction history
  2. Create new network with different parameters
  3. Import history (others choose whether to follow)

The threat of fork constrains governance:
  - Extreme parameter changes → participants leave
  - Captured governance → honest participants fork
```

### 16.8 Parameter History

All changes are recorded on-chain:

```
ParameterChange {
  parameter: string
  old_value: float
  new_value: float
  proposal_id: hash
  votes_for: float
  votes_against: float
  effective_day: int
}
```

This allows:
- Auditing governance decisions
- Rolling back if needed
- Learning what works over time

### 16.9 Governance Evolution

Networks can evolve more sophisticated governance:

**Early stage (founder-controlled):**
- Founder has high trust from genesis
- Effectively controls parameters
- Fast iteration, high risk

**Growth stage (oligarchy):**
- Early participants have most trust
- Founder influence dilutes
- More conservative changes

**Mature stage (distributed):**
- Trust widely distributed
- No single entity dominates
- Changes require broad consensus

**Advanced stage (delegated):**
- Participants delegate votes to specialists
- "Trust funds" form around different philosophies
- More sophisticated monetary policy possible

---

## 17. Automated Monetary Policy

Beyond governance-driven parameter changes, some parameters can adjust automatically based on observable network metrics. This creates responsive monetary policy without requiring constant human intervention.

### 17.1 Policy Goals

The system should automatically balance:

1. **Trust integrity** - Maintain meaningful trust differentiation
2. **Network growth** - Enable new participants to join productively
3. **Economic stability** - Prevent inflation/deflation spirals
4. **Attack resistance** - Respond to detected manipulation attempts

### 17.2 Observable Metrics

The network continuously tracks:

```
Network-wide metrics:
  total_active_identities     # Identities with activity in lookback window
  total_trust_score           # Sum of all trust scores
  mean_trust_score            # Average trust per active identity
  trust_gini_coefficient      # Trust inequality measure

Transaction metrics:
  daily_transaction_volume    # Total transactions per day
  mean_transaction_value      # Average transaction size
  verification_rate           # Actual verification as fraction of expected
  session_completion_rate     # Sessions completing normally

Economic metrics:
  daily_burn_volume           # Coins burned via payments and transfers
  daily_mint_volume           # Coins minted via daily distribution
  coin_velocity               # Transactions / total supply
  hoarding_prevalence         # Fraction of identities above runway threshold
  large_transfer_volume       # Volume of transfers > 10× median
  gini_coefficient            # Wealth inequality measure

Security metrics:
  cluster_prevalence          # Fraction of identities in suspicious clusters
  accusation_rate             # Accusations per transaction
  verification_failure_rate   # Failed verifications as fraction of total
  anomaly_frequency           # How often anomalies are flagged
  circular_flow_volume        # Volume of detected circular transfers
  circular_flow_prevalence    # Fraction of identities with high circular_ratio
  identity_rotation_events    # Large transfers following identity maturation pattern
  wealth_concentration_delta  # Change in top-N% wealth share
```

### 17.3 Payment Curve (K_PAYMENT)

**What it controls:**
- How much of each payment goes to the provider vs burn
- Rate at which new participants can become economically viable

**Trigger conditions for adjustment:**

```
If trust_gini_coefficient > GINI_HIGH_THRESHOLD:
  # Trust too concentrated, newcomers can't compete
  Decrease K_PAYMENT slightly → lower trust earns more

If trust_gini_coefficient < GINI_LOW_THRESHOLD:
  # Trust too flat, not enough differentiation
  Increase K_PAYMENT slightly → trust matters more

If verification_failure_rate > FAILURE_HIGH_THRESHOLD:
  # Too many bad actors passing
  Decrease K_PAYMENT → untrusted providers get less

If mean_trust_score declining over time:
  # Network aging or trust decay too fast
  Review TAU values (see 17.4)
```

**Tradeoffs:**
- Higher K_PAYMENT rewards trust but discourages new entrants
- Lower K_PAYMENT enables growth but reduces trust incentive

### 17.4 Trust Decay (TAU parameters)

**What they control:**
- How quickly old activity stops mattering
- Balance between history and recent behavior

**Trigger conditions for adjustment:**

```
If mean_trust_score growing unboundedly:
  # Trust inflation
  Decrease TAU_TRANSACTION → faster decay

If mean_trust_score declining despite stable activity:
  # Trust deflation
  Increase TAU_TRANSACTION → slower decay

If recovery_time (time to rebuild after violation) too long:
  # Discourages rehabilitation
  Decrease TAU_NEGATIVE → negative decays faster

If repeat_offense_rate high:
  # Violations not sticky enough
  Increase TAU_NEGATIVE → violations last longer
```

**Tradeoffs:**
- Faster decay makes recent behavior matter more, enables faster recovery
- Slower decay provides more stability but creates trust dynasties

### 17.5 Transfer Burns (K_TRANSFER, K_AMOUNT)

**What it controls:**
- Cost of moving coins between identities
- Barrier to reputation laundering
- Barrier to identity rotation / spotlight evasion

**Trigger conditions for adjustment:**

```
If cluster_prevalence increasing:
  # Sybil attacks becoming more common
  Increase K_TRANSFER → harder to distribute coins to sybils

If new_entrant_retention_rate low:
  # New participants can't acquire coins
  Decrease K_TRANSFER for high-trust senders

If reputation_laundering_detected:
  # Old pattern: build trust, exploit, transfer
  Increase K_TRANSFER significantly

If identity_rotation_detected:
  # Wealthy users shedding visibility via transfers
  Increase K_AMOUNT → larger transfers burn more

If large_transfer_volume increasing:
  # Potential identity rotation or wealth consolidation
  Increase K_AMOUNT moderately

If legitimate_large_transfers being burned excessively:
  # Business acquisitions, legitimate wealth transfer
  Decrease K_AMOUNT OR increase escrow exemption usage
```

**Tradeoffs:**
- Higher K_TRANSFER prevents laundering but creates friction
- Lower K_TRANSFER enables commerce but enables attacks
- Higher K_AMOUNT prevents identity rotation but penalizes legitimate large transfers

### 17.5.1 Circular Flow Detection

**What it controls:**
- Detection of wealth cycling between controlled identities
- Penalty for artificial transaction volume

**Trigger conditions for adjustment:**

```
If circular_flow_volume increasing:
  # More wealth cycling detected
  Decrease CIRCULAR_THRESHOLD → more aggressive detection
  Increase CIRCULAR_PENALTY_WEIGHT → harsher penalties

If false_positive_rate (legitimate cycles flagged) high:
  # Detection too aggressive
  Increase CIRCULAR_THRESHOLD
  Decrease CIRCULAR_PENALTY_WEIGHT

If cycle_length_distribution shifting to longer cycles:
  # Attackers evading by using longer cycles
  Increase MAX_CYCLE_LENGTH (with computation cost)

If wash_trading_detected:
  # Artificial volume to game metrics
  Decrease CIRCULAR_THRESHOLD significantly
```

**Tradeoffs:**
- Lower CIRCULAR_THRESHOLD catches more attacks but may flag legitimate business cycles
- Higher MAX_CYCLE_LENGTH catches sophisticated attacks but increases computation

### 17.6 Verification Parameters

**What they control:**
- How much verification overhead the network bears
- Detection sensitivity for collusion

**Trigger conditions for adjustment:**

```
If verification_failure_rate low AND stable:
  # Over-verifying, wasting resources
  Decrease EXPECTED_VERIFICATION_RATE

If verification_failure_rate increasing:
  # More collusion detected
  Increase EXPECTED_VERIFICATION_RATE

If verifier_participation_rate low:
  # Not enough civic duty
  Increase WEIGHT_VERIFICATION_ORIGINATION in profile score

If mean_verification_time too long:
  # Deadlines too generous
  Decrease COMMIT_DEADLINE and REVEAL_DEADLINE
```

**Tradeoffs:**
- More verification catches more collusion but creates overhead
- Less verification is efficient but misses attacks

### 17.7 Detection Thresholds

**What they control:**
- Sensitivity of Sybil and collusion detection
- False positive vs false negative balance

**Trigger conditions for adjustment:**

```
If false_positive_rate (legitimate clusters flagged) high:
  # Detection too aggressive
  Increase ISOLATION_THRESHOLD
  Increase SIMILARITY_THRESHOLD

If confirmed_sybil_attacks increasing:
  # Detection not catching enough
  Decrease ISOLATION_THRESHOLD
  Decrease SIMILARITY_THRESHOLD

If honest_operators reporting harassment from detection:
  # Natural clusters being penalized
  Add cluster_age_exemption or increase thresholds
```

**Tradeoffs:**
- Lower thresholds catch more attacks but create more false positives
- Higher thresholds are less disruptive but miss sophisticated attacks

### 17.8 Automatic Adjustment Limits

All automatic adjustments are constrained:

```
AutomaticAdjustment {
  parameter: string
  current_value: float
  new_value: float

  constraints:
    max_change_per_day: MAX_AUTO_CHANGE_RATE      # e.g., 1% per day
    min_interval: MIN_AUTO_CHANGE_INTERVAL        # e.g., 7 days between changes
    requires_metric_persistence: METRIC_STABLE_DAYS  # e.g., metric must be anomalous for 14 days

  transparency:
    all adjustments logged on-chain
    triggering metric values recorded
    can be overridden by governance vote
}
```

### 17.9 Feedback Loops and Stability

Automatic adjustments must avoid runaway feedback loops:

**Dampening:**
```
Change rate proportional to (observed_metric - target) × DAMPENING_FACTOR

DAMPENING_FACTOR < 1.0 ensures gradual convergence
```

**Dead zones:**
```
No adjustment when metric is within DEAD_ZONE of target

Prevents oscillation around stable state
```

**Rate limiting:**
```
After any adjustment, wait MIN_AUTO_CHANGE_INTERVAL before next

Allows effects to propagate before measuring again
```

**Human override:**
```
Any automatic adjustment can be reversed by governance vote

Emergency brake if automation misbehaves
```

### 17.10 Parameter Interaction Matrix

Some parameters interact and shouldn't be adjusted independently:

| If you change... | Also consider... | Reason |
|------------------|------------------|--------|
| K_PAYMENT | K_TRANSFER | Maintain relative attractiveness of transfers vs earnings |
| TAU_TRANSACTION | TAU_ASSERTION | Keep assertion impact proportional to transaction history |
| EXPECTED_VERIFICATION_RATE | VERIFICATION_PANEL_SIZE | Total verification burden |
| ISOLATION_THRESHOLD | SIMILARITY_THRESHOLD | Combined Sybil detection sensitivity |
| BASE_VERIFICATION_RATE | MAX_VERIFICATION_RATE | Accused vs normal scrutiny ratio |

### 17.11 Bootstrapping Automatic Policy

Automatic adjustment starts disabled:

```
Network phases:

  GENESIS (days 0-90):
    - All parameters fixed at genesis values
    - Collect baseline metrics
    - No automatic adjustments

  OBSERVATION (days 90-180):
    - Metrics analyzed but adjustments not applied
    - Governance can manually adjust based on observations
    - System reports what it WOULD do automatically

  LIMITED_AUTO (days 180-365):
    - Only low-risk parameters can auto-adjust
    - TAU values, detection thresholds
    - Economic parameters (K_PAYMENT, K_TRANSFER) still governance-only

  FULL_AUTO (day 365+):
    - All parameters can auto-adjust within limits
    - Governance can still override
    - System has year of baseline data
```

---

## 18. Calibration Requirements

The formulas in this specification define relationships between parameters, but the **concrete values** require empirical calibration against real-world economics. This section defines calibration targets and open questions.

### 18.1 Trust Accumulation Targets

The system should be calibrated so that "reasonable" participation over "reasonable" time produces "reasonable" trust levels.

**Target scenario: Established community member**
```
Goal: Reach trust = 500 in 12 months
      (500 trust → 17% transfer burn between peers)

Activity: $50/month of compute activity
          (Either providing or consuming, at market rates)

This implies:
  BASE_CREDIT must be calibrated so that:
  $600 annual activity × credit_factors × recency_decay ≈ 500 trust
```

**Target scenario: Casual participant**
```
Goal: Reach trust = 100 in 12 months
      (100 trust → 50% transfer burn, still building reputation)

Activity: $10/month of compute activity

This is someone who occasionally uses the network but isn't a power user.
```

**Target scenario: Heavy participant**
```
Goal: Reach trust = 2000 in 24 months
      (2000 trust → 5% transfer burn, highly trusted)

Activity: $200/month of compute activity

This is a business or power user with significant network participation.
```

### 18.2 Mapping Dollars to Trust

**Unknown constants that need calibration:**

| Parameter | Description | Calibration Method |
|-----------|-------------|-------------------|
| BASE_CREDIT | Trust earned per unit of activity | Set so targets above are achievable |
| resource_weight | Multiplier by compute type (GPU vs CPU) | Based on market rate ratios |
| TAU_TRANSACTION | Decay rate for transaction trust | Set so 1-year-old activity retains ~37% weight |
| TAU_ASSERTION | Decay rate for assertion trust | Similar to TAU_TRANSACTION or faster |

**Concrete questions to answer:**

1. If I rent $10 of GPU compute at market rate, how much trust do I earn?
2. If I provide $10 of GPU compute (verified), how much trust do I earn?
3. How does trust from consuming compare to trust from providing?
4. What's the effective "dollar cost" to reach each trust tier?

### 18.3 Trust Tiers and Their Meaning

Once calibrated, trust levels should map to intuitive categories:

| Trust Level | Transfer Burn | Interpretation | Path to Reach |
|-------------|---------------|----------------|---------------|
| 0-50 | 67-95% | New/untrusted | Just joined |
| 50-100 | 50-67% | Beginner | 1-3 months casual use |
| 100-300 | 25-50% | Developing | 6-12 months regular use |
| 300-500 | 14-25% | Established | 12+ months active use |
| 500-1000 | 9-17% | Trusted | 1-2 years heavy use |
| 1000-2000 | 5-9% | Highly trusted | 2+ years heavy use |
| 2000+ | <5% | Pillar of community | Multi-year power user |

### 18.4 Activity Profiles

Define realistic activity patterns for calibration simulations:

**Casual consumer:**
```
- 5-10 compute sessions per month
- Average session: $1-2 (short tasks, experimentation)
- Monthly spend: ~$10-20
- Occasional gaps in activity (months with zero use)
```

**Regular consumer:**
```
- 20-50 compute sessions per month
- Average session: $2-5 (regular workloads)
- Monthly spend: ~$50-100
- Consistent month-over-month activity
```

**Provider (hobbyist):**
```
- Offers compute 10-20 hours/week
- Earns $20-50/month in payments
- May also consume occasionally
```

**Provider (professional):**
```
- Offers compute 40+ hours/week
- Earns $200-500/month in payments
- High verification rate, consistent availability
```

**Business consumer:**
```
- 100+ compute sessions per month
- Monthly spend: $500-2000
- SLA requirements, values reliability
```

### 18.5 Calibration Validation

Once parameters are set, validate with simulations:

**Test 1: Cohort progression**
```
Simulate 1000 users with realistic activity distributions
After 12 months:
  - Median trust should be ~100-200 (casual users)
  - 90th percentile should be ~500+ (active users)
  - Inactive users (dropped off) should decay toward 0
```

**Test 2: Transfer burn distribution**
```
For transfers between random pairs of 12-month-old users:
  - Median burn should be ~20-30% (established peers)
  - Transfers involving newcomers should burn 50%+
  - Transfers between power users should burn <10%
```

**Test 3: Attack cost validation**
```
To reach trust = 500 purely through Sybil activity:
  - Should cost more than legitimate participation
  - Cluster detection should trigger before reaching target
  - Economic cost should exceed expected attack profit
```

**Test 4: Recovery time**
```
If trusted user (trust=500) misbehaves and trust drops to 0:
  - Time to recover to trust=100 should be 3-6 months
  - Time to recover to trust=500 should be 12+ months
  - Cannot shortcut via wealth transfer (trust inheritance)
```

### 18.6 Median-Based Calibration

**Principle:** Trust accumulation should be calibrated relative to actual network activity, not fixed dollar amounts.

```
Target: Median active user reaches trust = 300 after 12 months

Where "median active user" = 50th percentile of monthly activity
among users with at least 1 transaction per month

This auto-adjusts as the network grows:
  - Early network (few users, low volume): median might be $20/month
  - Mature network (many users, high volume): median might be $100/month
  - Trust accumulation rate scales proportionally
```

**Implementation:**
```
MEDIAN_MONTHLY_ACTIVITY = rolling_median(
  monthly_activity for all users with activity > 0,
  window = 90 days
)

effective_credit(transaction) = BASE_CREDIT × (
  transaction_value / MEDIAN_MONTHLY_ACTIVITY
) × other_factors

This means:
  - User spending at median rate reaches target trust in target time
  - User spending 2× median reaches trust faster
  - User spending 0.5× median reaches trust slower (but still progresses)
```

### 18.7 Accessibility and Grants

**Problem:** Users with limited financial resources may struggle to build trust if trust requires spending money.

**Existing mechanisms that help:**

1. **Providing compute earns trust** - Users with hardware but not money can provide compute to earn trust. Even a modest laptop can contribute CPU cycles.

2. **UBI distribution** - All participants receive daily coin distribution proportional to trust, creating a bootstrapping path.

3. **Negative-bid donations** - Users can burn coins (received from UBI) to accelerate trust building without external funds.

**Additional accessibility mechanisms:**

**Trust grants for compute providers:**
```
New providers with limited history can receive "provisional trust"
if sponsored by established users:

sponsor_grant(new_user, sponsor, amount):
  - Sponsor stakes some of their trust as collateral
  - New user receives provisional_trust up to amount
  - Provisional trust decays over 90 days
  - If new user misbehaves, sponsor loses staked trust
  - If new user builds real trust, provisional trust converts

This lets established users vouch for newcomers they know personally.
```

**Compute-for-trust programs:**
```
Network-funded programs where users earn trust by:
  - Providing compute to public-good projects (research, etc.)
  - Participating in network maintenance tasks
  - Contributing to verification panels

These create trust-building paths that don't require spending money.
```

**Subsidized onboarding:**
```
During genesis or growth phases, the network may subsidize
new user activity:

  - First N transactions have boosted trust credit
  - Matching grants for small-value activity
  - Referral bonuses (existing user + new user both benefit)

Funded from network treasury (portion of burns and fees).
```

**Progressive trust thresholds:**
```
Some network features could have lower trust requirements
for users with demonstrated need:

  - Basic transfer burns reduced for low-balance accounts
  - Verification panel eligibility at lower trust for active participants
  - UBI distribution weighted slightly toward lower-trust users

This prevents a pure plutocracy while maintaining Sybil resistance.
```

### 18.8 Implementation Notes

**Bootstrapping:**
During network genesis, BASE_CREDIT may need temporary inflation to allow early participants to build trust faster. This should phase out as the network matures.

**Market rate tracking:**
Trust calculations reference "market rate" for compute. The network needs an oracle or rolling average of actual transaction prices to define this.

**Currency denomination:**
Trust calculations should be denominated in compute-hours or median-activity-units rather than fixed currency, so the system auto-adjusts to actual network economics.

**Recalibration:**
If real-world usage patterns diverge significantly from targets, parameters may need adjustment. The automated policy system (Section 17) should flag when trust distributions are outside expected ranges.

---

## 19. Simulation Results: Reliability Markets

Simulations were conducted to validate the reliability score model (Section 5.12) and understand market dynamics. Code is in `/simulations/reliability_market_v2.py`.

### 19.1 Identity Rotation Attack

**Attack scenario (Attack Class 6):**
```
Wealthy user W wants to escape scrutiny:
  1. W creates sock puppet P
  2. P matures with minimal activity (trivial cost relative to W's wealth)
  3. W transfers large amount to P
  4. P becomes W's new "clean" identity
```

**Without defenses:**
```
W has 100,000 OMC, T(W) = 500 (high trust but under scrutiny)
P has 50 OMC after minimal activity, T(P) = 100

W transfers 50,000 OMC to P
Result: P has 50,050 OMC with trust = 100 (escapes scrutiny)
```

**With trust inheritance (Section 12.8):**
```
Same scenario, but trust inheritance applies:

transfer_ratio = 50000 / 50050 = 0.999
blended_trust = 0.999 × T(W)_effective + 0.001 × T(P)

If W is under scrutiny penalty:
  T(W)_effective = 500 × (1 - scrutiny_penalty) = 100
  blended_trust = 0.999 × 100 + 0.001 × 100 = 100
  T(P)_new = min(100, 100) = 100

Result: P inherits W's scrutinized trust level
Spotlight follows the money
```

**Simulation confirms:** Trust inheritance successfully prevents identity rotation from escaping scrutiny. The recipient's trust drops to match the sender's effective trust level when the transfer dominates their balance.

### 19.2 Provider Threshold Convergence

**Question:** Do providers converge to a single optimal cancellation threshold, or do different reliability levels coexist?

**Setup:**
- 20 providers with initial thresholds uniformly distributed in [1.1, 4.0]
- Threshold = cancel if `competing_bid >= current_rate × threshold`
- Providers adapt toward strategies of better-performing providers

**Result: Full convergence**
```
Initial threshold std: 0.844
Final threshold std:   0.016 (98% reduction)
Equilibrium threshold: ~2.2

All providers converge to nearly identical cancellation behavior.
```

**Why convergence occurs:**
- Providers that deviate from optimal earn less
- Competition drives adaptation toward successful strategies
- No stable market segmentation emerges

**Implication:** The market naturally converges to a single reliability level. Explicit "reliable" vs "unreliable" tiers don't emerge spontaneously.

### 19.3 Consumer Value Differentiation

**Question:** How do consumers with different valuations interact in the market?

**Setup:**
- High-value consumers: $5/hr value (e.g., urgent workloads)
- Medium-value consumers: $2/hr value (e.g., research)
- Low-value consumers: $0.50/hr value (e.g., hobbyists)
- Each with both low and high checkpoint intervals

**Bid calculation:**
```
max_bid = value_per_hour × expected_efficiency
actual_bid = min(market_price, max_bid)
```

**Results:**

| Value Tier | Checkpoint | Rate Paid | Compute | Profit/hr |
|-----------|------------|----------|---------|-----------|
| High ($5) | Low | $1.04 | 199h | $3.96 |
| High ($5) | High | $1.02 | 198h | $3.97 |
| Med ($2) | Low | $1.00 | 197h | $1.00 |
| Med ($2) | High | $1.01 | 195h | $0.97 |
| Low ($0.5) | Low | $0.39 | 75h | $0.11 |
| **Low ($0.5)** | **High** | **---** | **0h** | **---** |

**Key findings:**

1. **Low-value + high-checkpoint users are priced out entirely.** They cannot bid high enough to compete.

2. **High-value users pay higher rates** ($1.04 vs $0.39) but earn more profit ($3.96 vs $0.11).

3. **Checkpoint interval matters less than value** for market access.

### 19.4 Scarcity Effects

**Question:** How does supply/demand ratio affect price discrimination?

| Scenario | Low-Value Compute |
|----------|------------------|
| Excess supply (20 providers, 8 consumers) | 67h |
| Balanced (20 providers, 20 consumers) | 61h |
| Scarcity (20 providers, 40 consumers) | **0h** |
| Extreme scarcity (20 providers, 60 consumers) | **0h** |

**Finding:** Under scarcity, low-value users are completely crowded out. High-value users outbid them for all available compute.

### 19.5 Effective Cost Equalization

**Question:** Do low-restart-cost users pay less per useful compute hour?

**Finding:** At equilibrium, **all consumer types pay similar effective rates** when accounting for efficiency:

- Low checkpoint: $1.31/useful_hr, 100% efficiency
- High checkpoint: $1.31/useful_hr, 99% efficiency

The bid calculation already compensates for expected waste, so effective costs equalize.

### 19.6 Consumer Distribution Effects

**Question:** Does the mix of consumer types affect provider equilibrium?

| Consumer Mix | Equilibrium Threshold |
|-------------|----------------------|
| All low-restart-cost | 2.08 |
| All high-restart-cost | 2.21 |
| Mixed | 2.16-2.37 |

**Finding:** More low-restart-cost consumers → slightly lower equilibrium threshold (6% difference).

**Mechanism:** Low-restart-cost consumers tolerate unreliability (minimal waste), so providers can be less picky without losing business. High-restart-cost consumers bid less for unreliable providers, rewarding reliability.

### 19.7 Economic Value of Unreliable Compute

**Question:** Does introducing unreliable home compute create economic value compared to datacenter-only markets?

**Setup:**
- Datacenter providers: $0.50/hr cost (capex + opex), 99.8% hourly reliability, **cannot** cancel for profit (SLA)
- Home providers: $0.08/hr cost (power only), 92% hourly reliability, **can** cancel for profit

**Results:**

| Scenario | $/useful_hr | Compute Delivered | Consumers Served |
|----------|-------------|-------------------|------------------|
| Datacenter only | $1.60 | 1,995h | 10/30 |
| DC + Home (mixed) | $0.92 | 5,747h | 30/30 |

**Economic value created:**
- **42% cost reduction**: $1.60 → $0.92 per useful compute hour
- **188% compute increase**: 1,995h → 5,747h delivered
- **3× consumers served**: 10 → 30 consumers get compute

**Provider profitability:**

| Provider Type | Revenue/hr | Cost/hr | Profit/hr | Margin |
|--------------|-----------|---------|-----------|--------|
| Datacenter | $1.47 | $0.50 | $0.97 | 66% |
| Home | $0.62 | $0.08 | $0.54 | 87% |

**Key insight:** Home providers earn **higher profit margins** despite lower revenue because their costs are dramatically lower (power only, no capex amortization).

**Completion rates:**

| Provider Type | Completion Rate | Cancellation Reasons |
|--------------|-----------------|---------------------|
| Datacenter | 99.5% | Hardware failures only |
| Home | 63% | Personal use + profit-seeking |

**Why this creates value:**

1. **Idle capacity utilization**: Home computers sit unused most of the time. Even at low prices, any revenue exceeds the marginal cost (power).

2. **Price competition**: Home providers bid lower, forcing datacenters to compete or lose volume. Consumers benefit from lower prices.

3. **Market expansion**: Low-value consumers ($0.50/hr value) can't afford datacenter prices ($0.55/hr minimum) but can afford home prices ($0.09/hr minimum).

4. **Risk transfer**: Consumers who can checkpoint frequently absorb unreliability in exchange for lower prices. Those who can't pay premium for datacenter reliability.

**Checkpoint interval effect:**

| Checkpoint Interval | Efficiency | Effective Cost |
|--------------------|-----------|----------------|
| Frequent (0.1h) | 100% | $0.93/useful_hr |
| Rare (1.0h) | 93% | $0.92/useful_hr |

Frequent checkpointing maintains efficiency even with unreliable providers.

### 19.8 Implications for System Design

**Market-based quality assurance works:**
- Consumers rationally discount bids based on provider reliability
- Providers converge to optimal reliability levels
- No explicit penalties needed - reliability score is sufficient signal

**Value differentiation is effective:**
- High-value users get priority access by bidding more
- Low-value users get access when supply exceeds demand
- Under scarcity, compute flows to highest-value uses

**Restart cost model:**
- Restart cost should be measured in **compute time**, not dollars
- `checkpoint_interval` determines work lost on cancellation
- Consumers who can checkpoint frequently tolerate unreliability

**No market segmentation:**
- Providers converge to single strategy
- "Reliable" vs "unreliable" tiers don't emerge naturally
- If segmentation is desired, it must be explicitly designed (e.g., SLA tiers)

### 19.9 Double-Spend Resolution

**The Core Challenge:**

Unlike blockchain where double-spend is mathematically prevented by PoW/PoS consensus, Omerta's trust-based system can only:
1. **Detect** double-spends after they occur
2. **Penalize** the attacker's trust score
3. **Resolve** which version becomes canonical

This raises the question: what happens after a double-spend is detected?

**Three Resolution Strategies:**

| Strategy | Mechanism | Trade-off |
|----------|-----------|-----------|
| **Both keep coins** | Accept inflation; penalize attacker's trust | Simple; enables trust→coins conversion |
| **Claw back** | Reverse one transaction | Complex; may hurt innocent recipients |
| **Prevent acceptance** | Wait for network agreement before finality | Adds latency; requires connectivity |

**Currency Weight as Network Function:**

The key insight: **the right strategy depends on network performance**.

| Network Quality | Optimal Strategy | Currency "Weight" |
|----------------|------------------|-------------------|
| High connectivity, high trust | Both keep + trust penalty | Lightest |
| Medium connectivity | Wait for peer agreement | Light |
| Low/intermittent connectivity | Longer confirmation times | Medium |
| Disconnected networks | Use blockchain bridge | Heavy |

**The "Both Keep Coins" Strategy:**

Works when:
- Trust penalties exceed value of stolen coins
- Fraud is rare (occasional inflation acceptable)
- Network is high-trust (reputation matters)
- Policy adapts to observed fraud rates

Economics:
```
attack_profitable = P(success) × coins_stolen > trust_penalty_cost

For defense:
trust_penalty_cost > coins_stolen × (P(success) / P(caught))

With high connectivity: P(caught) → 1
Therefore: trust_penalty_cost > coins_stolen × P(success)
```

**The "Wait for Agreement" Strategy:**

Finality rule: Don't consider payment final until threshold of recently-seen peers agree.

```
finality_threshold = fraction of recent peers who must confirm
confirmation_window = time to wait for peer responses
recent_peer_window = how far back to consider "recently seen"

Payment is final when:
  confirming_peers / recent_peers >= finality_threshold
```

Properties:
- **Incentivizes connectivity**: Vulnerability if disconnected → stay connected
- **Soft finality**: Fast enough for compute (seconds/minutes), not instant
- **No clawbacks**: Never accepted double-spent payment
- **Attacker still penalized**: Failed attempts detected and punished

**Network Partition Handling:**

When networks become disconnected:
```
Network A: Alice -> Bob (100 OMC)
    | partition |
Network B: Alice -> Carol (100 OMC)
```

Resolution: This is a **mesh failure**, not a currency failure.

- Networks that can't stay connected shouldn't share a currency
- Schisms reflect physical/social reality
- On reconnection: trust mechanism resolves (benefiting party loses trust)
- For cross-partition transfers: use heavier currency (blockchain bridge)

**Policy Parameters:**

| Parameter | Description | Adjustment Trigger |
|-----------|-------------|-------------------|
| `FINALITY_THRESHOLD` | Fraction of peers needed | Fraud rate changes |
| `CONFIRMATION_WINDOW` | Time to wait for confirmations | Network latency |
| `DOUBLE_SPEND_PENALTY` | Trust cost of detected double-spend | Attack frequency |
| `INFLATION_TOLERANCE` | Max acceptable from "both keep" | Economic stability |

These parameters are set by trusted governance, recorded on-chain, and adjusted based on observed network conditions.

**The Spectrum Experiment:**

Omerta demonstrates: **How light can a currency system be?**

Answer: **As light as network performance allows.**

```
Better mesh performance
    -> Higher peer agreement rates
    -> Lower confirmation times needed
    -> Lighter currency (faster, cheaper)
    -> More fraud tolerance acceptable

Worse mesh performance
    -> Lower peer agreement rates
    -> Higher confirmation times needed
    -> Heavier currency (slower, safer)
    -> Less fraud tolerance acceptable
```

The system degrades gracefully along the trust-cost spectrum. Cross-network transfers (between disconnected meshes) naturally flow through heavier currencies (blockchain bridges), which is the designed interoperability path.

**Parallels to Human Societies:**

This tradeoff between currency weight and network quality mirrors how human societies have always operated:

| Society Scale | Trust Mechanism | "Currency Weight" |
|--------------|-----------------|-------------------|
| Village (50 people) | Everyone knows everyone; gossip spreads instantly | Lightest: verbal agreements, handshakes |
| Town (5,000 people) | Reputation networks; know friends-of-friends | Light: written IOUs, local credit |
| City (500,000 people) | Institutions track reputation; courts enforce | Medium: contracts, banks, legal system |
| Nation (50M+ people) | Anonymous transactions; need verification | Heavy: regulated banks, government backing |
| Global | No shared social context | Heaviest: international law, SWIFT, blockchain |

**The Pattern:**

As communities grew beyond the scale where everyone could know everyone:
1. **Visibility decreased**: You can't track reputation by gossip alone
2. **Trust costs increased**: Verification became necessary
3. **Heavier mechanisms emerged**: Contracts, courts, banks, regulations

Each step up the scale required "heavier" trust mechanisms—more overhead, more formality, more cost—because the lightweight mechanisms that worked in villages don't scale to cities.

**What Omerta Provides:**

Omerta is a tool for **extending high-trust solutions to larger scales** by providing:

1. **Visibility at scale**: On-chain records make transaction history visible to anyone, replicating the "everyone knows" property of villages

2. **Gossip that doesn't decay**: In villages, reputation spreads by word of mouth. Omerta makes reputation computable from permanent records—gossip with perfect memory

3. **Investment/lock-in**: Building trust over time creates "skin in the game". Defection costs accumulated reputation, making high-trust behavior rational even among strangers

4. **Graduated trust**: New participants start with nothing, exactly like newcomers to a village. Trust is earned through demonstrated behavior over time

**The Scale-Trust Tradeoff:**

```
Traditional: Larger scale -> Less visibility -> Need heavier mechanisms

Omerta: Larger scale -> Maintained visibility -> Lighter mechanisms viable
```

By providing the visibility and lock-in that previously only existed in small communities, Omerta enables trust mechanisms to work at scales where they traditionally couldn't.

**The Experiment Restated:**

Omerta asks: if we provide village-level visibility at global scale, can we use village-weight trust mechanisms for global transactions?

The answer appears to be: **yes, to the extent that network performance allows**. The mesh network is the digital equivalent of physical proximity—nodes that can communicate quickly and reliably can use lighter trust mechanisms, just as neighbors who see each other daily can trust more easily than strangers across the world.

Network performance is the digital analog of physical proximity. Currency weight is the trust overhead required when proximity (physical or digital) is insufficient.

**The Freedom-Trust Tradeoff:**

This visibility comes at a cost: **reduced freedom in exchange for higher trust**.

| Property | High Freedom | High Trust |
|----------|--------------|------------|
| Transaction privacy | Anonymous | Visible on-chain |
| Identity persistence | Disposable pseudonyms | Long-lived reputation |
| Exit cost | Zero (walk away) | High (lose accumulated trust) |
| Entry barrier | None | Must earn trust over time |
| Behavioral constraints | None | Deviation is detected and penalized |

Villages had high trust precisely because they had low freedom:
- Everyone knew your business
- You couldn't easily leave
- Your reputation followed you everywhere
- Misbehavior had lasting consequences

Omerta recreates these properties digitally. This is not a bug—it's the mechanism by which trust scales. The system is explicitly trading freedom for trust.

**Avoiding the Pitfalls of Small Societies:**

While Omerta draws on village-level trust mechanisms, it explicitly aims to avoid the well-known pathologies of small, tight-knit communities:

| Village Pathology | Omerta Mitigation |
|-------------------|-------------------|
| Arbitrary social punishment | Only **provably anti-social** behavior affects trust scores |
| Gossip and rumor | All accusations are on-chain, auditable, require evidence |
| In-group favoritism | Algorithms treat all participants uniformly |
| Hidden power structures | Trust scores and compensation formulas are public |
| "That's just how it's done" | Every mechanism is documented and open to debate |

The goal is to **maximize freedom within the trust constraint**. Specifically:

1. **Only penalize provable misbehavior**: Trust scores decrease only for actions that are objectively measurable and demonstrably harmful (failed to deliver promised compute, attempted double-spend, etc.). Subjective judgments like "we don't like this person" have no mechanism to affect scores.

2. **Measure in the open**: All data used to compute trust scores is on-chain and visible. There are no hidden inputs, no secret algorithms, no "trust us" black boxes. Anyone can verify why a score is what it is.

3. **Explain the reasoning**: The formulas for trust accumulation, decay, and penalty are documented in detail (see Sections 5-12). Participants can predict exactly how their actions will affect their standing.

4. **Keep mechanisms debatable**: Because everything is transparent, the community can debate whether mechanisms are fair. If a rule produces perverse outcomes, that becomes visible and can be discussed. Governance can adjust parameters based on observed results.

5. **Preserve freedom for non-harmful behavior**: The system imposes no constraints on *what* compute is used for, *who* you transact with, or *how* you run your business—only on whether you fulfill the commitments you make.

The honest framing: Omerta trades privacy for trust, but aims to be a **fair surveillance system** rather than an arbitrary one. The surveillance is comprehensive but the rules are explicit, uniform, and challengeable. This distinguishes it from both the capricious social control of villages and the opaque algorithmic control of centralized platforms.

**Why Now: Machine Intelligence as Enabler:**

The reason we haven't been able to build fair, transparent trust systems at scale before is computational: **modeling, tracking, and adjusting parameters that sufficiently cover human behavior requires enormous reasoning capacity**.

| Challenge | Traditional Approach | With Machine Intelligence |
|-----------|---------------------|---------------------------|
| Defining "anti-social" | Static rules, lawyers, courts | Dynamic models that learn edge cases |
| Detecting misbehavior | Manual review, spot checks | Continuous automated analysis |
| Explaining decisions | "Trust us" or impenetrable legalese | Natural language explanations on demand |
| Adjusting parameters | Committees, years of debate | Rapid iteration with simulation validation |
| Handling novel attacks | Reactive patching after damage | Proactive pattern recognition |

Villages could be fair because the scope was small—a few hundred relationships, a handful of transaction types, elders who remembered everything. Scaling that to millions of participants with complex, evolving behavior patterns was computationally intractable.

Machine intelligence changes this:

1. **Behavioral modeling**: AI can analyze transaction patterns, identify anomalies, and distinguish honest mistakes from malicious intent at a scale no human committee could match.

2. **Parameter tuning**: The simulations in this document (Sections 19.1-19.9) would take humans months to design, run, and interpret. AI can explore parameter spaces continuously, finding stable configurations.

3. **Explanation generation**: When a participant asks "why is my trust score X?", AI can trace through the on-chain history and produce a human-readable explanation—something that would otherwise require expensive human auditors.

4. **Adversarial reasoning**: Attackers are creative. Defending against novel attacks requires reasoning about human behavior at a level that benefits enormously from machine intelligence.

5. **Governance support**: Debates about mechanism fairness can be informed by AI-generated analysis of outcomes, counterfactuals, and edge cases.

The irony is recursive: **machine intelligence both demands the compute that Omerta provides and enables the trust system that makes Omerta work**. AI systems need distributed compute; distributed compute needs trust mechanisms; trust mechanisms at scale need AI to operate fairly. This virtuous cycle suggests the timing is not coincidental—the technology is arriving together because each piece enables the others.

**Who should use this system:**

Those who value the trust benefits more than the freedom costs:
- Long-term participants building reputation
- Those who benefit from others' visible track records
- Communities that need cooperation among strangers
- Applications where counterparty risk matters

**Who should not:**

Those who value freedom more than trust:
- One-time anonymous transactions
- Privacy-critical applications
- Those who need to "start fresh" regularly
- Activities that benefit from untraceability

The honest framing: Omerta is not a privacy technology. It is an anti-privacy technology that trades surveillance for trust. Users should choose it knowingly, when that tradeoff serves their needs.

**Simulation Results:**

The double-spend simulation (`simulations/double_spend_simulation.py`) validates these concepts quantitatively:

**1. Detection Rate vs Network Connectivity:**

| Connectivity | Detection Rate | Avg Detection Time | Network Spread |
|--------------|----------------|-------------------|----------------|
| 0.1 | 100% | 0.046s | 97.6% |
| 0.5 | 100% | 0.042s | 98.0% |
| 1.0 | 100% | 0.042s | 98.0% |

*Finding*: In gossip networks, double-spends are always detected because conflicting transactions eventually propagate to nodes that have seen the other version. Connectivity affects speed, not completeness.

**2. "Both Keep Coins" Economic Stability:**

| Detection | Penalty Multiplier | Inflation | Attacker Profit | Stable? |
|-----------|-------------------|-----------|-----------------|---------|
| 50% | 1x | 11.2% | -$802 | NO |
| 50% | 5x | 1.9% | -$985 | YES |
| 90% | 1x | 5.5% | -$925 | NO |
| 90% | 5x | 1.1% | -$1000 | YES |
| 99% | 1x | 4.7% | -$943 | YES |

*Finding*: Attackers always lose money because trust penalties outweigh gains. The economy is stable (inflation < 5%) with penalty multiplier >= 5x, even at 50% detection. The "both keep coins" strategy is viable across a wide range of conditions.

**3. "Wait for Agreement" Finality:**

| Finality Threshold | Connectivity | Median Latency | Success Rate |
|-------------------|--------------|----------------|--------------|
| 50% | 0.3 | 0.14s | 100% |
| 70% | 0.5 | 0.14s | 100% |
| 90% | 0.7 | 0.14s | 100% |

*Finding*: Sub-200ms confirmation times achievable across all tested configurations. Higher thresholds don't significantly increase latency because peer confirmations arrive in parallel through the gossip network.

**4. Network Partition Behavior:**

| Duration | Attempts | Accepted During Partition | Detected After Healing | At Risk |
|----------|----------|---------------------------|------------------------|---------|
| 1s | 3 | 0 | 3 | $0 |
| 10s | 5 | 2 | 5 | $100 |
| 60s | 3 | 0 | 3 | $0 |

*Finding*: During partitions, double-spend attacks can temporarily succeed (both victims accept their transaction). However, ALL conflicts are detected when the partition heals. The "damage window" equals partition duration. Solution: use "wait for agreement" for high-value transactions during suspected partition conditions.

**5. Currency Weight Spectrum (Validated):**

| Connectivity | Detection | Threshold | Latency | Weight | Category |
|--------------|-----------|-----------|---------|--------|----------|
| 0.9 | 99% | 50% | 0.1s | 0.14 | Lightest (village) |
| 0.7 | 95% | 60% | 0.5s | 0.24 | Light (town) |
| 0.5 | 90% | 70% | 1.0s | 0.34 | Light (town) |
| 0.3 | 70% | 80% | 3.0s | 0.52 | Medium (city) |
| 0.1 | 50% | 90% | 10.0s | 0.80 | Heaviest (blockchain) |

*Conclusion*: Currency weight is indeed proportional to network performance. The simulation confirms the core hypothesis: better connectivity enables lighter trust mechanisms—the digital equivalent of physical proximity enabling village-level trust at global scale.

---

## 20. Open Questions

1. **Accusation validation**: How do we determine if an accusation was "correct" for accuracy scoring?

2. **Cluster detection parameters**: What isolation threshold balances false positives vs catching Sybils?

3. **Credibility curve**: Is logarithmic the right shape? Should high-trust accusers have even more weight?

4. **Cross-classification learning**: Can accusation patterns in one category inform trust in others?

5. **Cold start**: How do the first participants bootstrap without existing trust to weight accusations?

6. **Parameter governance**: Who adjusts parameters over time as the network evolves?
