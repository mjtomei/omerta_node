# Transaction 01: Cabal Attestation

Witnesses (cabal) verify VM allocation, monitor session, and attest to service delivery.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

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

## Settlement Conditions

From [Protocol Format](../FORMAT.md#settlement-conditions):

| Condition | Escrow Action | Trust Signal |
|-----------|---------------|--------------|
| **COMPLETED_NORMAL** | Full release per burn formula | Trust credit for provider |
| **CONSUMER_TERMINATED_EARLY** | Pro-rated partial release | Neutral (consumer's choice) |
| **PROVIDER_TERMINATED** | No release for remaining time | Reliability signal (tracked) |
| **SESSION_FAILED** | Investigate if pattern emerges | No automatic penalty |

---

## Record Types

```
VM_ALLOCATED {
  session_id: hash
  provider: peer_id
  consumer: peer_id
  vm_wireguard_pubkey: bytes
  consumer_wireguard_endpoint: string
  cabal_wireguard_endpoints: [string]
  allocated_at: timestamp
  provider_signature: signature
}

VM_CONNECTIVITY_VOTE {
  session_id: hash
  witness: peer_id
  can_reach_vm: bool
  can_see_consumer_connected: bool
  timestamp: timestamp
  signature: signature
}

VM_CANCELLED {
  session_id: hash
  provider: peer_id
  cancelled_at: timestamp
  reason: CONSUMER_REQUEST | PROVIDER_VOLUNTARY | VM_DIED | TIMEOUT | CONSUMER_MISUSE
  actual_duration_seconds: uint
  provider_signature: signature
}

CABAL_ATTESTATION {
  session_id: hash
  vm_allocated_hash: hash       # Hash of VM_ALLOCATED message
  vm_cancelled_hash: hash       # Hash of VM_CANCELLED message
  connectivity_verified: bool
  actual_duration_seconds: uint
  termination_reason: string
  cabal_votes: [peer_id → bool]
  cabal_signatures: [signature]
  created_at: timestamp
}

ABORT_VOTE {
  session_id: hash
  witness: peer_id
  reason: string                # e.g., "vm_unreachable", "consumer_not_connected"
  timestamp: timestamp
  signature: signature
}
```

---

## State Machines

### Provider States

```
ACTOR: Provider

STATES: [VM_PROVISIONING, VM_RUNNING, VM_TERMINATED]

STATE VM_PROVISIONING:
  # Entry: Escrow lock succeeded, now allocating VM
  actions:
    - TODO: Allocate VM
    - TODO: Connect wireguards
    - TODO: Send VM_ALLOCATED to cabal

STATE VM_RUNNING:
  # Entry: VM allocated and verified by cabal
  actions:
    - TODO: Monitor VM health
    - TODO: Handle top-up requests

  on CANCEL_REQUEST from Consumer:
    → TODO

STATE VM_TERMINATED:
  # Entry: Session ended
  actions:
    - TODO: Send VM_CANCELLED to cabal
```

### Witness (Cabal) States

```
ACTOR: Witness

STATES: [AWAITING_ALLOCATION, VERIFYING_VM, MONITORING, ATTESTING]

STATE AWAITING_ALLOCATION:
  on VM_ALLOCATED from Provider:
    → next_state: VERIFYING_VM

STATE VERIFYING_VM:
  actions:
    - TODO: Check wireguard connectivity to VM
    - TODO: Verify consumer is connected
    - TODO: Send VM_CONNECTIVITY_VOTE to other witnesses

  # If verification fails, can vote to abort

STATE MONITORING:
  # Session is running, monitor for issues
  actions:
    - TODO: Periodic connectivity checks
    - TODO: Handle misuse accusations

STATE ATTESTING:
  on VM_CANCELLED from Provider:
    → actions:
      - TODO: Create and sign CABAL_ATTESTATION
      - TODO: Share with other witnesses for multi-sign
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
