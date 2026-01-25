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

## Parameters

```omt
parameters (
    # Verification timeouts
    VM_ALLOCATION_TIMEOUT = 300 seconds "Provider must allocate VM within 5 min of lock"
    CONNECTIVITY_CHECK_TIMEOUT = 60 seconds "Witnesses must verify connectivity within 1 min"
    CONNECTIVITY_VOTE_TIMEOUT = 30 seconds "Time to collect connectivity votes"
    ABORT_VOTE_TIMEOUT = 30 seconds "Time to collect abort votes"

    # Monitoring parameters
    MONITORING_CHECK_INTERVAL = 60 seconds "Periodic VM health check interval"
    MISUSE_INVESTIGATION_TIMEOUT = 120 seconds "Time to investigate misuse accusation"

    # Thresholds
    CONNECTIVITY_THRESHOLD = 0.67 fraction "Fraction of witnesses that must verify connectivity"
    ABORT_THRESHOLD = 0.67 fraction "Fraction needed to abort session"
    ATTESTATION_THRESHOLD = 3 count "Minimum witnesses for valid attestation"

    # Witness selection parameters
    WITNESS_COUNT = 5 count "Number of witnesses (from escrow lock)"
    MIN_HIGH_TRUST_WITNESSES = 2 count "Minimum high-trust witnesses required"
    MAX_PRIOR_INTERACTIONS = 3 count "Maximum prior interactions with witness"
)
```

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

## Block Types (Chain Records)

```omt
block ATTESTATION by [Witness] (
    session_id              hash
    connectivity_verified   bool
    actual_duration_seconds uint
    termination_reason      string
    witnesses               list<peer_id>
    timestamp               timestamp
)
```

---

## Message Types

```omt
# --- Provider -> Witnesses ---
message VM_ALLOCATED from Provider to [Witness] signed (
    session_id                  hash
    provider                    peer_id
    consumer                    peer_id
    vm_wireguard_pubkey         bytes
    consumer_wireguard_endpoint string
    cabal_wireguard_endpoints   list<string>
    allocated_at                timestamp
    lock_result_hash            hash
    timestamp                   timestamp
)

message VM_CANCELLED from Provider to [Witness] signed (
    session_id              hash
    provider                peer_id
    cancelled_at            timestamp
    reason                  TerminationReason
    actual_duration_seconds uint
    timestamp               timestamp
)

message MISUSE_ACCUSATION from Provider to [Witness] signed (
    session_id  hash
    provider    peer_id
    evidence    string
    timestamp   timestamp
)

# --- Provider -> Consumer ---
message VM_READY from Provider to [Consumer] (
    session_id  hash
    vm_info     dict
    timestamp   timestamp
)

message SESSION_TERMINATED from Provider to [Consumer] (
    session_id  hash
    reason      TerminationReason
    timestamp   timestamp
)

# --- Consumer -> Provider ---
message CANCEL_REQUEST from Consumer to [Provider] signed (
    session_id  hash
    consumer    peer_id
    timestamp   timestamp
)

# --- Witness <-> Witness ---
message VM_CONNECTIVITY_VOTE from Witness to [Witness, Provider] signed (
    session_id                  hash
    witness                     peer_id
    can_reach_vm                bool
    can_see_consumer_connected  bool
    timestamp                   timestamp
)

message ABORT_VOTE from Witness to [Witness] signed (
    session_id  hash
    witness     peer_id
    reason      string
    timestamp   timestamp
)

message ATTESTATION_SHARE from Witness to [Witness] (
    attestation  dict
)

# --- Witness -> Consumer/Provider ---
message ATTESTATION_RESULT from Witness to [Consumer, Provider] (
    attestation  dict
)
```

---

## State Machines

### Actor: Provider

```omt
actor Provider "Allocates VM, notifies cabal, handles termination" (
    store (
        session_id           hash
        consumer             peer_id
        witnesses            list<peer_id>
        lock_result          dict
        lock_completed_at    timestamp
        vm_info              dict
        vm_allocated_at      timestamp
        vm_allocated_msg     dict
        notified_at          timestamp
        verification_passed  bool
        connectivity_votes   list<dict>
        termination_reason   TerminationReason
        cancelled_at         timestamp
        vm_cancelled_msg     dict
        cancellation_sent_at timestamp
        attestation          dict
    )

    trigger start_session(session_id hash, consumer peer_id, witnesses list<peer_id>, lock_result dict) in [WAITING_FOR_LOCK] "Called after escrow lock succeeds"
    trigger allocate_vm(vm_info dict) in [VM_PROVISIONING] "VM allocation completes"
    trigger cancel_session(reason TerminationReason) in [VM_RUNNING] "Initiate session cancellation"

    state WAITING_FOR_LOCK initial "Waiting for escrow lock to complete"
    state VM_PROVISIONING "Allocating VM resources"
    state NOTIFYING_CABAL "Sending VM_ALLOCATED to cabal"
    state WAITING_FOR_VERIFICATION "Waiting for cabal to verify connectivity"
    state VM_RUNNING "Session active, VM accessible"
    state HANDLING_CANCEL "Processing cancellation request"
    state SENDING_CANCELLATION "Notifying cabal of termination"
    state WAITING_FOR_ATTESTATION "Waiting for cabal attestation"
    state SESSION_COMPLETE "Attestation received, ready for settlement"
    state SESSION_ABORTED terminal "Session was aborted before completion"

    # Entry from escrow lock
    WAITING_FOR_LOCK -> VM_PROVISIONING on start_session (
        store session_id, consumer, witnesses, lock_result
        STORE(lock_completed_at, NOW())
    )

    # VM allocation timeout
    VM_PROVISIONING -> SESSION_ABORTED on timeout(VM_ALLOCATION_TIMEOUT) (
        STORE(termination_reason, TerminationReason.ALLOCATION_FAILED)
    )

    # VM allocation success
    VM_PROVISIONING -> NOTIFYING_CABAL on allocate_vm (
        store vm_info
        STORE(vm_allocated_at, NOW())
    )

    # Notify cabal and consumer
    NOTIFYING_CABAL -> WAITING_FOR_VERIFICATION auto (
        vm_allocated_msg = {session_id LOAD(session_id), provider peer_id, consumer LOAD(consumer), vm_info LOAD(vm_info), allocated_at LOAD(vm_allocated_at), lock_result_hash HASH(LOAD(lock_result)), timestamp NOW()}
        BROADCAST(witnesses, VM_ALLOCATED)
        SEND(consumer, VM_READY)
        STORE(notified_at, NOW())
        STORE(connectivity_votes, [])
    )

    # Collect connectivity votes
    WAITING_FOR_VERIFICATION -> WAITING_FOR_VERIFICATION on VM_CONNECTIVITY_VOTE (
        APPEND(connectivity_votes, message.payload)
    )

    # All votes received - check threshold
    WAITING_FOR_VERIFICATION -> VM_RUNNING auto when LENGTH(connectivity_votes) >= LENGTH(witnesses) and count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) >= CONNECTIVITY_THRESHOLD (
        STORE(verification_passed, true)
    )

    # Connectivity verification failed
    WAITING_FOR_VERIFICATION -> SENDING_CANCELLATION auto when LENGTH(connectivity_votes) >= LENGTH(witnesses) and count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) < CONNECTIVITY_THRESHOLD (
        STORE(verification_passed, false)
        STORE(termination_reason, TerminationReason.CONNECTIVITY_FAILED)
    )

    # Timeout - check if enough positive votes
    WAITING_FOR_VERIFICATION -> VM_RUNNING on timeout(CONNECTIVITY_CHECK_TIMEOUT) when LENGTH(connectivity_votes) > 0 and count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) >= CONNECTIVITY_THRESHOLD (
        STORE(verification_passed, true)
    )

    WAITING_FOR_VERIFICATION -> SENDING_CANCELLATION on timeout(CONNECTIVITY_CHECK_TIMEOUT) when LENGTH(connectivity_votes) == 0 or count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) < CONNECTIVITY_THRESHOLD (
        STORE(verification_passed, false)
        STORE(termination_reason, TerminationReason.CONNECTIVITY_FAILED)
    )

    # Consumer cancel request
    VM_RUNNING -> HANDLING_CANCEL on CANCEL_REQUEST when message.sender == LOAD(consumer) (
        STORE(termination_reason, TerminationReason.CONSUMER_REQUEST)
        STORE(cancelled_at, NOW())
    )

    # Provider-initiated cancel
    VM_RUNNING -> HANDLING_CANCEL on cancel_session (
        store reason
        STORE(termination_reason, reason)
        STORE(cancelled_at, NOW())
    )

    # Process cancellation
    HANDLING_CANCEL -> SENDING_CANCELLATION auto

    # Send cancellation to cabal
    SENDING_CANCELLATION -> WAITING_FOR_ATTESTATION auto (
        vm_cancelled_msg = {session_id LOAD(session_id), provider peer_id, cancelled_at LOAD(cancelled_at), reason LOAD(termination_reason), actual_duration_seconds LOAD(cancelled_at) - LOAD(vm_allocated_at), timestamp NOW()}
        BROADCAST(witnesses, VM_CANCELLED)
        SEND(consumer, SESSION_TERMINATED)
        STORE(cancellation_sent_at, NOW())
    )

    # Receive attestation
    WAITING_FOR_ATTESTATION -> SESSION_COMPLETE on ATTESTATION_RESULT (
        STORE(attestation, message.attestation)
    )
)
```

### Actor: Witness

```omt
actor Witness "Verifies VM accessibility, monitors session, creates attestation" (
    store (
        session_id                hash
        consumer                  peer_id
        provider                  peer_id
        other_witnesses           list<peer_id>
        vm_allocated_msg          dict
        vm_allocated_at           timestamp
        witness                   peer_id
        can_reach_vm              bool
        can_see_consumer_connected bool
        vote_data                 dict
        vote_signature            signature
        my_connectivity_vote      dict
        connectivity_votes        list<dict>
        votes_sent_at             timestamp
        connectivity_verified     bool
        abort_reason              string
        abort_votes               list<dict>
        abort_votes_sent_at       timestamp
        session_aborted           bool
        vm_cancelled_msg          dict
        actual_duration_seconds   uint
        termination_reason        TerminationReason
        misuse_accusation         dict
        attestation               dict
        attestation_signatures    list<dict>
        attestation_sent_at       timestamp
    )

    trigger setup_session(session_id hash, consumer peer_id, provider peer_id, other_witnesses list<peer_id>) in [AWAITING_ALLOCATION] "Initialize witness with session info after escrow lock"

    state AWAITING_ALLOCATION initial "Waiting for VM_ALLOCATED from provider"
    state VERIFYING_VM "Checking VM connectivity"
    state COLLECTING_VOTES "Collecting connectivity votes from other witnesses"
    state EVALUATING_CONNECTIVITY "Deciding if VM is accessible"
    state MONITORING "Session running, periodic health checks"
    state HANDLING_MISUSE "Investigating misuse accusation"
    state VOTING_ABORT "Voting to abort session"
    state COLLECTING_ABORT_VOTES "Collecting abort votes from other witnesses"
    state ATTESTING "Creating attestation after session ends"
    state COLLECTING_ATTESTATION_SIGS "Multi-signing attestation"
    state PROPAGATING_ATTESTATION "Sending attestation to parties"
    state DONE terminal "Attestation complete"

    # Setup (called externally after escrow lock)
    AWAITING_ALLOCATION -> AWAITING_ALLOCATION on setup_session (
        store session_id, consumer, provider, other_witnesses
    )

    # Receive VM allocation from provider
    AWAITING_ALLOCATION -> VERIFYING_VM on VM_ALLOCATED (
        STORE(vm_allocated_msg, message.payload)
        STORE(vm_allocated_at, message.payload.allocated_at)
    )

    # Perform connectivity check and send vote
    VERIFYING_VM -> COLLECTING_VOTES auto (
        can_reach_vm = check_vm_connectivity(vm_allocated_msg.consumer_wireguard_endpoint)
        can_see_consumer_connected = check_consumer_connected(session_id)
        STORE(witness, peer_id)
        vote_data = {session_id LOAD(session_id), witness peer_id, can_reach_vm LOAD(can_reach_vm), can_see_consumer_connected LOAD(can_see_consumer_connected), timestamp NOW()}
        vote_signature = SIGN(LOAD(vote_data))
        my_connectivity_vote = {...LOAD(vote_data), signature LOAD(vote_signature)}
        BROADCAST(other_witnesses, VM_CONNECTIVITY_VOTE)
        SEND(provider, VM_CONNECTIVITY_VOTE)
        STORE(connectivity_votes, [LOAD(my_connectivity_vote)])
        STORE(votes_sent_at, NOW())
    )

    # Collect votes from other witnesses
    COLLECTING_VOTES -> COLLECTING_VOTES on VM_CONNECTIVITY_VOTE when message.payload.witness != peer_id (
        APPEND(connectivity_votes, message.payload)
    )

    # All votes received
    COLLECTING_VOTES -> EVALUATING_CONNECTIVITY auto when LENGTH(connectivity_votes) >= LENGTH(other_witnesses) + 1

    # Timeout waiting for votes
    COLLECTING_VOTES -> EVALUATING_CONNECTIVITY on timeout(CONNECTIVITY_VOTE_TIMEOUT)

    # Evaluate connectivity - success
    EVALUATING_CONNECTIVITY -> MONITORING auto when LENGTH(connectivity_votes) > 0 and count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) >= CONNECTIVITY_THRESHOLD (
        STORE(connectivity_verified, true)
    )

    # Evaluate connectivity - failure
    EVALUATING_CONNECTIVITY -> VOTING_ABORT auto when LENGTH(connectivity_votes) == 0 or count_positive_votes(connectivity_votes) / LENGTH(connectivity_votes) < CONNECTIVITY_THRESHOLD (
        STORE(connectivity_verified, false)
        STORE(abort_reason, "vm_unreachable")
    )

    # Session ends normally - provider sends cancellation
    MONITORING -> ATTESTING on VM_CANCELLED (
        STORE(vm_cancelled_msg, message.payload)
        STORE(actual_duration_seconds, message.payload.actual_duration_seconds)
        STORE(termination_reason, message.payload.reason)
    )

    # Misuse accusation received
    MONITORING -> HANDLING_MISUSE on MISUSE_ACCUSATION (
        STORE(misuse_accusation, message.payload)
    )

    # Investigate misuse - evidence found
    HANDLING_MISUSE -> VOTING_ABORT auto when LOAD(misuse_accusation).evidence != "" (
        STORE(abort_reason, "consumer_misuse")
    )

    # Investigate misuse - no evidence
    HANDLING_MISUSE -> MONITORING auto when LOAD(misuse_accusation).evidence == ""

    # Send abort vote
    VOTING_ABORT -> COLLECTING_ABORT_VOTES auto (
        abort_vote_data = {session_id LOAD(session_id), witness peer_id, reason LOAD(abort_reason), timestamp NOW()}
        abort_vote_signature = SIGN(LOAD(abort_vote_data))
        my_abort_vote = {...LOAD(abort_vote_data), signature LOAD(abort_vote_signature)}
        BROADCAST(other_witnesses, ABORT_VOTE)
        STORE(abort_votes, [LOAD(my_abort_vote)])
        STORE(abort_votes_sent_at, NOW())
    )

    # Collect abort votes
    COLLECTING_ABORT_VOTES -> COLLECTING_ABORT_VOTES on ABORT_VOTE when message.payload.witness != peer_id (
        APPEND(abort_votes, message.payload)
    )

    # Evaluate abort votes - threshold met
    COLLECTING_ABORT_VOTES -> ATTESTING auto when LENGTH(abort_votes) / (LENGTH(other_witnesses) + 1) >= ABORT_THRESHOLD (
        STORE(session_aborted, true)
        STORE(termination_reason, LOAD(abort_reason))
    )

    # Evaluate abort votes - threshold not met, return to monitoring
    COLLECTING_ABORT_VOTES -> MONITORING on timeout(ABORT_VOTE_TIMEOUT) when LENGTH(abort_votes) / (LENGTH(other_witnesses) + 1) < ABORT_THRESHOLD

    # Evaluate abort votes - timeout with threshold met
    COLLECTING_ABORT_VOTES -> ATTESTING on timeout(ABORT_VOTE_TIMEOUT) when LENGTH(abort_votes) / (LENGTH(other_witnesses) + 1) >= ABORT_THRESHOLD (
        STORE(session_aborted, true)
        STORE(termination_reason, LOAD(abort_reason))
    )

    # Create attestation
    ATTESTING -> COLLECTING_ATTESTATION_SIGS auto (
        attestation = {session_id LOAD(session_id), vm_allocated_hash HASH(LOAD(vm_allocated_msg)), vm_cancelled_hash HASH(LOAD(vm_cancelled_msg)), connectivity_verified LOAD(connectivity_verified), actual_duration_seconds LOAD(actual_duration_seconds), termination_reason LOAD(termination_reason), cabal_votes LOAD(connectivity_votes), cabal_signatures [], created_at NOW()}
        my_signature = SIGN(LOAD(attestation))
        STORE(attestation_signatures, [{witness peer_id, signature LOAD(my_signature)}])
        BROADCAST(other_witnesses, ATTESTATION_SHARE)
        STORE(attestation_sent_at, NOW())
    )

    # Collect attestation signatures
    COLLECTING_ATTESTATION_SIGS -> COLLECTING_ATTESTATION_SIGS on ATTESTATION_SHARE (
        APPEND(attestation_signatures, message.payload.attestation.cabal_signatures)
    )

    # Threshold signatures collected
    COLLECTING_ATTESTATION_SIGS -> PROPAGATING_ATTESTATION auto when LENGTH(attestation_signatures) >= ATTESTATION_THRESHOLD

    # Send attestation to parties
    PROPAGATING_ATTESTATION -> DONE auto (
        final_attestation = {...LOAD(attestation), cabal_signatures LOAD(attestation_signatures)}
        SEND(consumer, ATTESTATION_RESULT)
        SEND(provider, ATTESTATION_RESULT)
        APPEND(chain, ATTESTATION)
    )
)
```

### Actor: Consumer

```omt
actor Consumer "Connects to VM, uses service" (
    store (
        session_id          hash
        provider            peer_id
        vm_info             dict
        connected_at        timestamp
        termination_reason  TerminationReason
        attestation         dict
    )

    trigger setup_session(session_id hash, provider peer_id) in [WAITING_FOR_VM] "Initialize consumer with session info"
    trigger request_cancel() in [CONNECTED] "Request to end session early"

    state WAITING_FOR_VM initial "Waiting for VM to be ready"
    state CONNECTING "Connecting to VM via wireguard"
    state CONNECTED "Using the VM"
    state REQUESTING_CANCEL "Requesting session end"
    state SESSION_ENDED terminal "Session terminated"

    # Setup (called externally)
    WAITING_FOR_VM -> WAITING_FOR_VM on setup_session (
        store session_id, provider
    )

    # VM ready
    WAITING_FOR_VM -> CONNECTING on VM_READY (
        STORE(vm_info, message.vm_info)
    )

    # Connect to VM
    CONNECTING -> CONNECTED auto (
        STORE(connected_at, NOW())
    )

    # Session terminated by provider
    CONNECTED -> SESSION_ENDED on SESSION_TERMINATED (
        STORE(termination_reason, message.reason)
    )

    # Receive attestation while connected
    CONNECTED -> CONNECTED on ATTESTATION_RESULT (
        STORE(attestation, message.attestation)
    )

    # Request cancel
    CONNECTED -> REQUESTING_CANCEL on request_cancel

    # Send cancel request
    REQUESTING_CANCEL -> CONNECTED auto (
        SEND(provider, CANCEL_REQUEST)
    )

    # Receive attestation after session ended
    SESSION_ENDED -> SESSION_ENDED on ATTESTATION_RESULT (
        STORE(attestation, message.attestation)
    )
)
```


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
