# Transaction 01: Cabal Attestation

Witnesses (cabal) verify VM allocation, monitor session, and attest to service delivery.

**See also:** [Protocol Format](../../FORMAT.md) for primitive operations and state machine semantics.

## Overview

After escrow is locked (Transaction 00), the provider allocates a VM and notifies the cabal. The cabal verifies the VM is accessible via wireguard to both the consumer and the cabal members. This attestation is required for settlement.

**Actors:**
- **Provider** - allocates VM, notifies cabal of allocation and termination
- **Consumer** - connects to VM, uses service
- **Cabal (Witnesses)** - verify VM accessibility, can vote to abort, attest to session delivery

**Flow:**
1. Provider allocates VM, connects to consumer and cabal wireguards
2. Provider sends VM_ALLOCATED to cabal with connection details
3. Cabal members verify wireguard connectivity to VM
4. Cabal can vote to abort (return deposit) if verification fails
5. Session runs, burn rate accrues
6. Provider sends VM_CANCELLED when session ends (by either party or fault)
7. Cabal creates attestation of actual session duration and termination reason

---

{{PARAMETERS}}

---

## Settlement Conditions

From [Protocol Format](../../FORMAT.md#settlement-conditions):

| Condition | Escrow Action | Trust Signal |
|-----------|---------------|--------------|
| **COMPLETED_NORMAL** | Full release per burn formula | Trust credit for provider |
| **CONSUMER_TERMINATED_EARLY** | Pro-rated partial release | Neutral (consumer's choice) |
| **PROVIDER_TERMINATED** | No release for remaining time | Reliability signal (tracked) |
| **SESSION_FAILED** | Investigate if pattern emerges | No automatic penalty |

---

{{BLOCKS}}

---

{{MESSAGES}}

---

{{STATE_MACHINES}}

---

## Consumer Misbehavior Handling

Consumer misbehavior is limited by design:
- Provider owns the compute (can terminate at will)
- Compute is ephemeral (nothing persists after termination)
- Timeouts prevent indefinite resource consumption
- No consumer signature required - if consumer connects but doesn't acknowledge, cabal can still attest and provider gets paid

**Misuse accusation flow:**
1. Provider suspects consumer misuse (e.g., mining crypto on CPU instance)
2. Provider notifies cabal with evidence
3. Cabal members can observe connection from inside VM (ssh over wireguard)
4. If misuse confirmed, session terminated with CONSUMER_MISUSE reason
5. Provider retains payment for time used

---

## Verification Requirements

For attestation to be valid:
1. `VM_ALLOCATED` must reference valid `LOCK_RESULT` from Transaction 00
2. At least THRESHOLD witnesses must sign `CABAL_ATTESTATION`
3. `actual_duration_seconds` must be ≤ time between `allocated_at` and `cancelled_at`
4. Termination reason must be one of the valid enum values

---

## Resource Verification

Connectivity verification (wireguard reachability) proves the VM exists, but not that resources match claims. A provider could claim 10 VMs but only have 2 machines, multiplexing responses.

### The Core Problem

No proof-of-work or proof-of-resource can guarantee allocation. If a provider claims 10 VMs:
- VDFs can run in parallel on fewer machines (each gets less CPU, but all complete)
- Memory-hard functions can share RAM across multiplexed VMs
- Any computation can be time-sliced

**Solution: Probabilistic detection through simultaneous verification.**

### Simultaneous Challenge Protocol

The only way to catch resource inflation: exercise all claimed resources at the same moment.

```
Provider claims: 10 VMs for various consumers

Coordinated verification window (randomized timing):
  T+0:     Witnesses signal "challenge window open"
  T+0.001: All 10 VMs receive challenge simultaneously
           Challenge = sign(nonce + timestamp) requiring immediate CPU
  T+0.100: Deadline for responses (100ms)

If provider has 10 real VMs:
  All 10 respond in ~20ms (network RTT + minimal compute)

If provider has 2 machines faking 10 VMs:
  2 respond in ~20ms
  8 respond in ~100-500ms (queued, context switching)
  Or 8 timeout entirely
```

**Key properties:**
- Random timing prevents preparation
- Challenge requires fresh computation (can't precompute)
- Multiple witnesses verify independently
- Response time distribution reveals multiplexing

### Hardware Entropy Fingerprinting

Different physical machines produce different timing characteristics due to manufacturing variation:

```
hardware_profile = hash(
    memory_timing_profile(),    # Cache hierarchy reveals DIMM/controller
    cpu_jitter_profile(),       # Instruction timing variance
    disk_latency_profile(),     # Seek patterns unique to drive
    rdrand_samples(),           # Hardware RNG tied to physical CPU
)
```

**Detection patterns:**
- Same provider's "different VMs" with identical hardware profiles → same machine
- Hardware profile changes between sessions → suspicious (should be stable)
- All VMs slow down at same moments → shared CPU (timing correlation)
- All VMs fail simultaneously → same machine or network

### Correlation Detection

Even without simultaneous challenges, statistical patterns reveal shared hardware:

```
For sessions from same provider's "different" VMs:

1. Timing correlation
   response_times = [vm.response_times for vm in claimed_vms]
   if correlation(response_times) > 0.8:
       flag("VMs show correlated slowdowns")

2. Failure correlation
   if simultaneous_failures(vms):
       flag("VMs fail together")

3. Network fingerprint
   if all_same_ttl(vms) and correlated_jitter(vms):
       flag("VMs have identical network path")
```

### Integration with Attestation

During cabal attestation:

1. **Initial verification** (existing): Wireguard connectivity check
2. **Resource verification** (new): Simultaneous challenge to all provider's active VMs
3. **Ongoing monitoring**: Periodic challenges during session
4. **Hardware fingerprint**: Collected at session start, compared across sessions

Witnesses coordinate challenge timing so provider can't serve requests sequentially.

---

## Collusion Detection

Consumer-provider collusion to fake sessions is addressed through graph analysis and behavioral signals.

### Graph Analysis (Clique Detection)

From network transaction graph, detect suspicious patterns:

```
1. Isolated clusters
   Components with few external connections are suspicious.
   Real providers serve diverse consumers.

2. Reciprocal relationships
   Consumer A uses Provider B, and B uses A → suspicious

3. Transaction timing
   Regular intervals suggest scripted collusion
   Real usage has natural variance

4. Perfect success rates
   100% success over many sessions is statistically improbable
```

### Behavioral Similarity Detection

Identities controlled by same operator show correlated behavior:

```
Signals to compare across identities:
- Assertion timing (always assert within minutes of each other?)
- Assertion targets (always score same providers?)
- Score correlation (always give similar scores?)
- Transaction patterns (similar timing, amounts, counterparties?)

similarity_score = correlation across dimensions
if similarity_score > 0.8:
    flag("Likely same operator or coordinated")
```

### Trust Flow Analysis

Model trust assertions as flow through network:

```
Suspicious patterns:
- Circular flow: A→B→C→A (trust laundering)
- Concentrated sources: One identity seeding trust to many
- Isolated sinks: Receive trust but never give (Sybil targets)
```

### Verification Sampling

Random third-party verification catches collusion that graph analysis misses:

```
Verification questions:
- Did this VM actually run? (not a fake transaction)
- Did the consumer actually use resources? (not self-dealing)
- Are these two parties actually independent? (not sybils)
- Does transaction volume match claimed resources? (not inflated)

Panel selection excludes:
- Parties with transaction history with consumer or provider
- Parties in same cluster as either party
- Parties with low trust scores
```

---

## Attack Analysis

### Attack: Fake VM Claims

**Threat:** Provider claims VMs that don't exist or share resources with other claimed VMs.

**Detection:**
- Simultaneous challenge protocol reveals multiplexing
- Hardware fingerprints reveal shared machines
- Timing correlation detects shared resources

**Mitigation:** Response time thresholds, fingerprint uniqueness requirements.

**Residual risk:** Sophisticated attacker with enough real machines to satisfy challenges.

### Attack: Consumer-Provider Collusion

**Threat:** Consumer and provider collude to fake sessions, split trust rewards.

**Detection:**
- Graph analysis detects isolated cliques
- Behavioral similarity flags coordinated identities
- Random verification sampling

**Mitigation:** Trust requires diverse transaction partners, verification origination duties.

**Residual risk:** Patient attackers who transact legitimately with others to build cover.

### Attack: Witness Bribery

**Threat:** Provider bribes witnesses to attest to fake sessions.

**Detection:**
- Witness selection is deterministic from chain state (can't choose friendly witnesses)
- Multiple witnesses required (must bribe threshold)
- Witnesses from different trust clusters

**Mitigation:** Witness selection algorithm, cluster diversity requirements.

**Residual risk:** Provider who has bribed many potential witnesses over time.

### Attack: Timing Attack on Challenges

**Threat:** Provider predicts challenge timing and prepares responses.

**Detection:**
- Challenge timing includes randomness from multiple witnesses
- Challenges require fresh nonce (can't precompute)

**Mitigation:** Distributed nonce generation, unpredictable timing windows.

**Residual risk:** Attacker who compromises enough witnesses to predict timing.

---

## Open Questions

1. How do witnesses verify wireguard connectivity without being able to use the VM?
   - **Proposed:** Witnesses connect to VM's wireguard, verify handshake completes, ping test

2. What constitutes "consumer misuse" and how is it proven?
   - **Proposed:** Resource usage significantly exceeding bid (e.g., full CPU on partial allocation), witnesses can observe via monitoring endpoint

3. How long do witnesses wait before voting to abort on connectivity failure?
   - **Proposed:** CONNECTIVITY_CHECK_TIMEOUT (60s) for initial check, then vote within CONNECTIVITY_VOTE_TIMEOUT (30s)

4. Should there be periodic re-attestation during long sessions?
   - **Proposed:** Yes, MONITORING_CHECK_INTERVAL (60s) with simultaneous challenges

5. How are simultaneous challenges coordinated across witnesses?
   - **Proposed:** Witnesses commit to challenge timing, reveal simultaneously, challenge fires when all reveals collected

6. What response time threshold indicates multiplexing?
   - **Proposed:** Calibrate per-resource-class, flag if response time > 2x expected or high variance across provider's VMs

7. How stable should hardware fingerprints be across sessions?
   - **Proposed:** Core signature stable (same machine), timing characteristics may vary with load
