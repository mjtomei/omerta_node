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

| Parameter | Value | Description |
|-----------|-------|-------------|
| `VM_ALLOCATION_TIMEOUT` | 300 seconds | Provider must allocate VM within 5 min of lock |
| `CONNECTIVITY_CHECK_TIMEOUT` | 60 seconds | Witnesses must verify connectivity within 1 min |
| `CONNECTIVITY_VOTE_TIMEOUT` | 30 seconds | Time to collect connectivity votes |
| `ABORT_VOTE_TIMEOUT` | 30 seconds | Time to collect abort votes |
| `MONITORING_CHECK_INTERVAL` | 60 seconds | Periodic VM health check interval |
| `MISUSE_INVESTIGATION_TIMEOUT` | 120 seconds | Time to investigate misuse accusation |
| `CONNECTIVITY_THRESHOLD` | 0.67 fraction | Fraction of witnesses that must verify connectivity |
| `ABORT_THRESHOLD` | 0.67 fraction | Fraction needed to abort session |
| `ATTESTATION_THRESHOLD` | 3 count | Minimum witnesses for valid attestation |
| `WITNESS_COUNT` | 5 count | Number of witnesses (from escrow lock) |
| `MIN_HIGH_TRUST_WITNESSES` | 2 count | Minimum high-trust witnesses required |
| `MAX_PRIOR_INTERACTIONS` | 3 count | Maximum prior interactions with witness |

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

```
ATTESTATION {
  session_id: hash
  connectivity_verified: bool
  actual_duration_seconds: uint
  termination_reason: string
  witnesses: list[peer_id]
  timestamp: timestamp
}

```

---

## Message Types

```
# Provider -> Witness
VM_ALLOCATED {
  session_id: hash
  provider: peer_id
  consumer: peer_id
  vm_wireguard_pubkey: bytes
  consumer_wireguard_endpoint: string
  cabal_wireguard_endpoints: list[string]
  allocated_at: timestamp
  lock_result_hash: hash
  timestamp: timestamp
  signature: bytes  # signed by provider
}

# Provider -> Witness
VM_CANCELLED {
  session_id: hash
  provider: peer_id
  cancelled_at: timestamp
  reason: TerminationReason
  actual_duration_seconds: uint
  timestamp: timestamp
  signature: bytes  # signed by provider
}

# Provider -> Witness
MISUSE_ACCUSATION {
  session_id: hash
  provider: peer_id
  evidence: string
  timestamp: timestamp
  signature: bytes  # signed by provider
}

# Provider -> Consumer
VM_READY {
  session_id: hash
  vm_info: dict
  timestamp: timestamp
}

# Provider -> Consumer
SESSION_TERMINATED {
  session_id: hash
  reason: TerminationReason
  timestamp: timestamp
}

# Consumer -> Provider
CANCEL_REQUEST {
  session_id: hash
  consumer: peer_id
  timestamp: timestamp
  signature: bytes  # signed by consumer
}

# Witness -> Witness, Provider
VM_CONNECTIVITY_VOTE {
  session_id: hash
  witness: peer_id
  can_reach_vm: bool
  can_see_consumer_connected: bool
  timestamp: timestamp
  signature: bytes  # signed by witness
}

# Witness -> Witness
ABORT_VOTE {
  session_id: hash
  witness: peer_id
  reason: string
  timestamp: timestamp
  signature: bytes  # signed by witness
}

# Witness -> Witness
ATTESTATION_SHARE {
  attestation: dict
}

# Witness -> Consumer, Provider
ATTESTATION_RESULT {
  attestation: dict
}

```

---

### ACTOR: Provider

*Allocates VM, notifies cabal, handles termination*

```
STATES: [WAITING_FOR_LOCK, VM_PROVISIONING, NOTIFYING_CABAL, WAITING_FOR_VERIFICATION, VM_RUNNING, HANDLING_CANCEL, SENDING_CANCELLATION, WAITING_FOR_ATTESTATION, SESSION_COMPLETE, SESSION_ABORTED]

INITIAL: WAITING_FOR_LOCK

EXTERNAL TRIGGERS:
  start_session(session_id: hash, consumer: peer_id, witnesses: list[peer_id], lock_result: dict)
    allowed_in: [WAITING_FOR_LOCK]
  allocate_vm(vm_info: dict)
    allowed_in: [VM_PROVISIONING]
  cancel_session(reason: TerminationReason)
    allowed_in: [VM_RUNNING]

STATE WAITING_FOR_LOCK:
  # Waiting for escrow lock to complete

STATE VM_PROVISIONING:
  # Allocating VM resources

STATE NOTIFYING_CABAL:
  # Sending VM_ALLOCATED to cabal

STATE WAITING_FOR_VERIFICATION:
  # Waiting for cabal to verify connectivity

STATE VM_RUNNING:
  # Session active, VM accessible

STATE HANDLING_CANCEL:
  # Processing cancellation request

STATE SENDING_CANCELLATION:
  # Notifying cabal of termination

STATE WAITING_FOR_ATTESTATION:
  # Waiting for cabal attestation

STATE SESSION_COMPLETE:
  # Attestation received, ready for settlement

STATE SESSION_ABORTED: [TERMINAL]
  # Session was aborted before completion

TRANSITIONS:
  WAITING_FOR_LOCK --start_session--> VM_PROVISIONING
    action: {'store': ['session_id', 'consumer', 'witnesses', 'lock_resu...
    action: {'store': {'lock_completed_at': 'current_time'}}
  VM_PROVISIONING --timeout(VM_ALLOCATION_TIMEOUT)--> SESSION_ABORTED
    action: {'store': {'termination_reason': 'TerminationReason.ALLOCATI...
  VM_PROVISIONING --allocate_vm--> NOTIFYING_CABAL
    action: {'store': ['vm_info']}
    action: {'store': {'vm_allocated_at': 'current_time'}}
  NOTIFYING_CABAL --auto--> WAITING_FOR_VERIFICATION
    action: {'compute': 'vm_allocated_msg', 'from': '{session_id: LOAD(s...
    action: {'send': {'message': 'VM_ALLOCATED', 'to': 'each(witnesses)'...
    action: {'send': {'message': 'VM_READY', 'to': 'consumer'}}
    ... and 2 more actions
  WAITING_FOR_VERIFICATION --VM_CONNECTIVITY_VOTE--> WAITING_FOR_VERIFICATION
    action: {'append': {'connectivity_votes': 'message.payload'}}
  WAITING_FOR_VERIFICATION --auto--> [guard: LENGTH (connectivity_votes) >= LENGTH (witnesses)  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) >= CONNECTIVITY_THRESHOLD] VM_RUNNING
    action: {'store': {'verification_passed': 'true'}}
  WAITING_FOR_VERIFICATION --auto--> [guard: LENGTH (connectivity_votes) >= LENGTH (witnesses)  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) < CONNECTIVITY_THRESHOLD] SENDING_CANCELLATION
    action: {'store': {'verification_passed': 'false'}}
    action: {'store': {'termination_reason': 'TerminationReason.CONNECTI...
  WAITING_FOR_VERIFICATION --timeout(CONNECTIVITY_CHECK_TIMEOUT)--> [guard: LENGTH (connectivity_votes) > 0  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) >= CONNECTIVITY_THRESHOLD] VM_RUNNING
    action: {'store': {'verification_passed': 'true'}}
  WAITING_FOR_VERIFICATION --timeout(CONNECTIVITY_CHECK_TIMEOUT)--> [guard: LENGTH (connectivity_votes) == 0  or count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) < CONNECTIVITY_THRESHOLD] SENDING_CANCELLATION
    action: {'store': {'verification_passed': 'false'}}
    action: {'store': {'termination_reason': 'TerminationReason.CONNECTI...
  VM_RUNNING --CANCEL_REQUEST--> [guard: message.sender == LOAD (consumer)] HANDLING_CANCEL
    action: {'store': {'termination_reason': 'TerminationReason.CONSUMER...
    action: {'store': {'cancelled_at': 'current_time'}}
  VM_RUNNING --cancel_session--> HANDLING_CANCEL
    action: {'store': ['reason']}
    action: {'store': {'termination_reason': 'reason'}}
    action: {'store': {'cancelled_at': 'current_time'}}
  HANDLING_CANCEL --auto--> SENDING_CANCELLATION
  SENDING_CANCELLATION --auto--> WAITING_FOR_ATTESTATION
    action: {'compute': 'vm_cancelled_msg', 'from': '{session_id: LOAD(s...
    action: {'send': {'message': 'VM_CANCELLED', 'to': 'each(witnesses)'...
    action: {'send': {'message': 'SESSION_TERMINATED', 'to': 'consumer'}...
    ... and 1 more actions
  WAITING_FOR_ATTESTATION --ATTESTATION_RESULT--> SESSION_COMPLETE
    action: {'store_from_message': {'attestation': 'attestation'}}
```

### ACTOR: Witness

*Verifies VM accessibility, monitors session, creates attestation*

```
STATES: [AWAITING_ALLOCATION, VERIFYING_VM, COLLECTING_VOTES, EVALUATING_CONNECTIVITY, MONITORING, HANDLING_MISUSE, VOTING_ABORT, COLLECTING_ABORT_VOTES, ATTESTING, COLLECTING_ATTESTATION_SIGS, PROPAGATING_ATTESTATION, DONE]

INITIAL: AWAITING_ALLOCATION

EXTERNAL TRIGGERS:
  setup_session(session_id: hash, consumer: peer_id, provider: peer_id, other_witnesses: list[peer_id])
    allowed_in: [AWAITING_ALLOCATION]

STATE AWAITING_ALLOCATION:
  # Waiting for VM_ALLOCATED from provider

STATE VERIFYING_VM:
  # Checking VM connectivity

STATE COLLECTING_VOTES:
  # Collecting connectivity votes from other witnesses

STATE EVALUATING_CONNECTIVITY:
  # Deciding if VM is accessible

STATE MONITORING:
  # Session running, periodic health checks

STATE HANDLING_MISUSE:
  # Investigating misuse accusation

STATE VOTING_ABORT:
  # Voting to abort session

STATE COLLECTING_ABORT_VOTES:
  # Collecting abort votes from other witnesses

STATE ATTESTING:
  # Creating attestation after session ends

STATE COLLECTING_ATTESTATION_SIGS:
  # Multi-signing attestation

STATE PROPAGATING_ATTESTATION:
  # Sending attestation to parties

STATE DONE: [TERMINAL]
  # Attestation complete

TRANSITIONS:
  AWAITING_ALLOCATION --setup_session--> AWAITING_ALLOCATION
    action: {'store': ['session_id', 'consumer', 'provider', 'other_witn...
  AWAITING_ALLOCATION --VM_ALLOCATED--> VERIFYING_VM
    action: {'store_from_message': {'vm_allocated_msg': 'payload'}}
    action: {'store_from_message': {'vm_allocated_at': 'payload.allocate...
  VERIFYING_VM --auto--> COLLECTING_VOTES
    action: {'compute': 'can_reach_vm', 'from': 'check_vm_connectivity()...
    action: {'compute': 'can_see_consumer_connected', 'from': 'check_con...
    action: {'store': {'witness': 'peer_id'}}
    ... and 7 more actions
  COLLECTING_VOTES --VM_CONNECTIVITY_VOTE--> [guard: message.payload.witness != peer_id] COLLECTING_VOTES
    action: {'append': {'connectivity_votes': 'message.payload'}}
  COLLECTING_VOTES --auto--> [guard: LENGTH (connectivity_votes) >= LENGTH (other_witnesses) + 1] EVALUATING_CONNECTIVITY
  COLLECTING_VOTES --timeout(CONNECTIVITY_VOTE_TIMEOUT)--> EVALUATING_CONNECTIVITY
  EVALUATING_CONNECTIVITY --auto--> [guard: LENGTH (connectivity_votes) > 0  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) >= CONNECTIVITY_THRESHOLD] MONITORING
    action: {'store': {'connectivity_verified': 'true'}}
  EVALUATING_CONNECTIVITY --auto--> [guard: LENGTH (connectivity_votes) == 0  or count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) < CONNECTIVITY_THRESHOLD] VOTING_ABORT
    action: {'store': {'connectivity_verified': 'false'}}
    action: {'store': {'abort_reason': 'vm_unreachable'}}
  MONITORING --VM_CANCELLED--> ATTESTING
    action: {'store_from_message': {'vm_cancelled_msg': 'payload'}}
    action: {'store_from_message': {'actual_duration_seconds': 'payload....
    action: {'store_from_message': {'termination_reason': 'payload.reaso...
  MONITORING --MISUSE_ACCUSATION--> HANDLING_MISUSE
    action: {'store_from_message': {'misuse_accusation': 'payload'}}
  HANDLING_MISUSE --auto--> [guard: LOAD (misuse_accusation).evidence != ""] VOTING_ABORT
    action: {'store': {'abort_reason': 'consumer_misuse'}}
  HANDLING_MISUSE --auto--> [guard: LOAD (misuse_accusation).evidence == ""] MONITORING
  VOTING_ABORT --auto--> COLLECTING_ABORT_VOTES
    action: {'compute': 'abort_vote_data', 'from': '{session_id: LOAD(se...
    action: {'compute': 'abort_vote_signature', 'from': 'SIGN(LOAD(abort...
    action: {'compute': 'my_abort_vote', 'from': '{...LOAD(abort_vote_da...
    ... and 3 more actions
  COLLECTING_ABORT_VOTES --ABORT_VOTE--> [guard: message.payload.witness != peer_id] COLLECTING_ABORT_VOTES
    action: {'append': {'abort_votes': 'message.payload'}}
  COLLECTING_ABORT_VOTES --auto--> [guard: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) >= ABORT_THRESHOLD] ATTESTING
    action: {'store': {'session_aborted': 'true'}}
    action: {'store': {'termination_reason': 'LOAD(abort_reason)'}}
  COLLECTING_ABORT_VOTES --timeout(ABORT_VOTE_TIMEOUT)--> [guard: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) < ABORT_THRESHOLD] MONITORING
  COLLECTING_ABORT_VOTES --timeout(ABORT_VOTE_TIMEOUT)--> [guard: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) >= ABORT_THRESHOLD] ATTESTING
    action: {'store': {'session_aborted': 'true'}}
    action: {'store': {'termination_reason': 'LOAD(abort_reason)'}}
  ATTESTING --auto--> COLLECTING_ATTESTATION_SIGS
    action: {'compute': 'attestation', 'from': '{session_id: LOAD(sessio...
    action: {'compute': 'my_signature', 'from': 'SIGN(LOAD(attestation))...
    action: {'store': {'attestation_signatures': '[{witness: peer_id, si...
    ... and 2 more actions
  COLLECTING_ATTESTATION_SIGS --ATTESTATION_SHARE--> COLLECTING_ATTESTATION_SIGS
    action: {'append': {'attestation_signatures': 'message.payload.attes...
  COLLECTING_ATTESTATION_SIGS --auto--> [guard: LENGTH (attestation_signatures) >= ATTESTATION_THRESHOLD] PROPAGATING_ATTESTATION
  PROPAGATING_ATTESTATION --auto--> DONE
    action: {'compute': 'final_attestation', 'from': '{...LOAD(attestati...
    action: {'send': {'message': 'ATTESTATION_RESULT', 'to': 'consumer'}...
    action: {'send': {'message': 'ATTESTATION_RESULT', 'to': 'provider'}...
    ... and 1 more actions
```

### ACTOR: Consumer

*Connects to VM, uses service*

```
STATES: [WAITING_FOR_VM, CONNECTING, CONNECTED, REQUESTING_CANCEL, SESSION_ENDED]

INITIAL: WAITING_FOR_VM

EXTERNAL TRIGGERS:
  setup_session(session_id: hash, provider: peer_id)
    allowed_in: [WAITING_FOR_VM]
  request_cancel()
    allowed_in: [CONNECTED]

STATE WAITING_FOR_VM:
  # Waiting for VM to be ready

STATE CONNECTING:
  # Connecting to VM via wireguard

STATE CONNECTED:
  # Using the VM

STATE REQUESTING_CANCEL:
  # Requesting session end

STATE SESSION_ENDED: [TERMINAL]
  # Session terminated

TRANSITIONS:
  WAITING_FOR_VM --setup_session--> WAITING_FOR_VM
    action: {'store': ['session_id', 'provider']}
  WAITING_FOR_VM --VM_READY--> CONNECTING
    action: {'store_from_message': {'vm_info': 'vm_info'}}
  CONNECTING --auto--> CONNECTED
    action: {'store': {'connected_at': 'current_time'}}
  CONNECTED --SESSION_TERMINATED--> SESSION_ENDED
    action: {'store_from_message': {'termination_reason': 'reason'}}
  CONNECTED --ATTESTATION_RESULT--> CONNECTED
    action: {'store_from_message': {'attestation': 'attestation'}}
  CONNECTED --request_cancel--> REQUESTING_CANCEL
  REQUESTING_CANCEL --auto--> CONNECTED
    action: {'send': {'message': 'CANCEL_REQUEST', 'to': 'provider'}}
  SESSION_ENDED --ATTESTATION_RESULT--> SESSION_ENDED
    action: {'store_from_message': {'attestation': 'attestation'}}
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

## Attack Analysis

TODO: Add attack analysis following template in FORMAT.md

---

## Open Questions

1. How do witnesses verify wireguard connectivity without being able to use the VM?
2. What constitutes "consumer misuse" and how is it proven?
3. How long do witnesses wait before voting to abort on connectivity failure?
4. Should there be periodic re-attestation during long sessions?
