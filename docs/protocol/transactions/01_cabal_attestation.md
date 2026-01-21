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
  session_id: SimpleType(name='hash', line=0, column=0)
  connectivity_verified: SimpleType(name='bool', line=0, column=0)
  actual_duration_seconds: SimpleType(name='uint', line=0, column=0)
  termination_reason: SimpleType(name='string', line=0, column=0)
  witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

```

---

## Message Types

```
# Provider -> Witness
VM_ALLOCATED {
  session_id: SimpleType(name='hash', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  vm_wireguard_pubkey: SimpleType(name='bytes', line=0, column=0)
  consumer_wireguard_endpoint: SimpleType(name='string', line=0, column=0)
  cabal_wireguard_endpoints: ListType(element_type=SimpleType(name='string', line=0, column=0), line=0, column=0)
  allocated_at: SimpleType(name='timestamp', line=0, column=0)
  lock_result_hash: SimpleType(name='hash', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by provider
}

# Provider -> Witness
VM_CANCELLED {
  session_id: SimpleType(name='hash', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  cancelled_at: SimpleType(name='timestamp', line=0, column=0)
  reason: SimpleType(name='TerminationReason', line=0, column=0)
  actual_duration_seconds: SimpleType(name='uint', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by provider
}

# Provider -> Witness
MISUSE_ACCUSATION {
  session_id: SimpleType(name='hash', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  evidence: SimpleType(name='string', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by provider
}

# Provider -> Consumer
VM_READY {
  session_id: SimpleType(name='hash', line=0, column=0)
  vm_info: SimpleType(name='dict', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

# Provider -> Consumer
SESSION_TERMINATED {
  session_id: SimpleType(name='hash', line=0, column=0)
  reason: SimpleType(name='TerminationReason', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

# Consumer -> Provider
CANCEL_REQUEST {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by consumer
}

# Witness -> Witness, Provider
VM_CONNECTIVITY_VOTE {
  session_id: SimpleType(name='hash', line=0, column=0)
  witness: SimpleType(name='peer_id', line=0, column=0)
  can_reach_vm: SimpleType(name='bool', line=0, column=0)
  can_see_consumer_connected: SimpleType(name='bool', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
ABORT_VOTE {
  session_id: SimpleType(name='hash', line=0, column=0)
  witness: SimpleType(name='peer_id', line=0, column=0)
  reason: SimpleType(name='string', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
ATTESTATION_SHARE {
  attestation: SimpleType(name='dict', line=0, column=0)
}

# Witness -> Consumer, Provider
ATTESTATION_RESULT {
  attestation: SimpleType(name='dict', line=0, column=0)
}

```

---

### ACTOR: Provider

*Allocates VM, notifies cabal, handles termination*

```
STATES: [WAITING_FOR_LOCK, VM_PROVISIONING, NOTIFYING_CABAL, WAITING_FOR_VERIFICATION, VM_RUNNING, HANDLING_CANCEL, SENDING_CANCELLATION, WAITING_FOR_ATTESTATION, SESSION_COMPLETE, SESSION_ABORTED]

INITIAL: WAITING_FOR_LOCK

EXTERNAL TRIGGERS:
  start_session(session_id: SimpleType(name='hash', line=0, column=0), consumer: SimpleType(name='peer_id', line=0, column=0), witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0), lock_result: SimpleType(name='dict', line=0, column=0))
    allowed_in: [WAITING_FOR_LOCK]
  allocate_vm(vm_info: SimpleType(name='dict', line=0, column=0))
    allowed_in: [VM_PROVISIONING]
  cancel_session(reason: SimpleType(name='TerminationReason', line=0, column=0))
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
  WAITING_FOR_LOCK --NamedTrigger(name='start_session', line=0, column=0)--> VM_PROVISIONING
    action: store session_id, consumer, witnesses, lock_result
    action: STORE(lock_completed_at, FunctionCallExpr(name='NOW', args=[...
  VM_PROVISIONING --TimeoutTrigger(parameter='VM_ALLOCATION_TIMEOUT', line=0, column=0)--> SESSION_ABORTED
    action: STORE(termination_reason, FieldAccessExpr(object=Identifier(...
  VM_PROVISIONING --NamedTrigger(name='allocate_vm', line=0, column=0)--> NOTIFYING_CABAL
    action: store vm_info
    action: STORE(vm_allocated_at, FunctionCallExpr(name='NOW', args=[],...
  NOTIFYING_CABAL --auto--> WAITING_FOR_VERIFICATION
    action: compute vm_allocated_msg = StructLiteralExpr(fields={'sessio...
    action: BROADCAST(witnesses, VM_ALLOCATED)
    action: SEND(Identifier(name='consumer', line=0, column=0), VM_READY...
    ... and 2 more actions
  WAITING_FOR_VERIFICATION --MessageTrigger(message_type='VM_CONNECTIVITY_VOTE', line=0, column=0)--> WAITING_FOR_VERIFICATION
    action: APPEND(connectivity_votes, FieldAccessExpr(object=Identifier...
  WAITING_FOR_VERIFICATION --auto--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='witnesses', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] VM_RUNNING
    action: STORE(verification_passed, Literal(value=True, type='bool', ...
  WAITING_FOR_VERIFICATION --auto--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='witnesses', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] SENDING_CANCELLATION
    action: STORE(verification_passed, Literal(value=False, type='bool',...
    action: STORE(termination_reason, FieldAccessExpr(object=Identifier(...
  WAITING_FOR_VERIFICATION --TimeoutTrigger(parameter='CONNECTIVITY_CHECK_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GT: 8>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] VM_RUNNING
    action: STORE(verification_passed, Literal(value=True, type='bool', ...
  WAITING_FOR_VERIFICATION --TimeoutTrigger(parameter='CONNECTIVITY_CHECK_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.OR: 12>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] SENDING_CANCELLATION
    action: STORE(verification_passed, Literal(value=False, type='bool',...
    action: STORE(termination_reason, FieldAccessExpr(object=Identifier(...
  VM_RUNNING --MessageTrigger(message_type='CANCEL_REQUEST', line=0, column=0)--> [guard: BinaryExpr(left=FieldAccessExpr(object=Identifier(name='message', line=0, column=0), field='sender', line=0, column=0), op=<BinaryOperator.EQ: 5>, right=FunctionCallExpr(name='LOAD', args=[Identifier(name='consumer', line=0, column=0)], line=0, column=0), line=0, column=0)] HANDLING_CANCEL
    action: STORE(termination_reason, FieldAccessExpr(object=Identifier(...
    action: STORE(cancelled_at, FunctionCallExpr(name='NOW', args=[], li...
  VM_RUNNING --NamedTrigger(name='cancel_session', line=0, column=0)--> HANDLING_CANCEL
    action: store reason
    action: STORE(termination_reason, Identifier(name='reason', line=0, ...
    action: STORE(cancelled_at, FunctionCallExpr(name='NOW', args=[], li...
  HANDLING_CANCEL --auto--> SENDING_CANCELLATION
  SENDING_CANCELLATION --auto--> WAITING_FOR_ATTESTATION
    action: compute vm_cancelled_msg = StructLiteralExpr(fields={'sessio...
    action: BROADCAST(witnesses, VM_CANCELLED)
    action: SEND(Identifier(name='consumer', line=0, column=0), SESSION_...
    ... and 1 more actions
  WAITING_FOR_ATTESTATION --MessageTrigger(message_type='ATTESTATION_RESULT', line=0, column=0)--> SESSION_COMPLETE
    action: STORE(attestation, FieldAccessExpr(object=Identifier(name='m...
```

### ACTOR: Witness

*Verifies VM accessibility, monitors session, creates attestation*

```
STATES: [AWAITING_ALLOCATION, VERIFYING_VM, COLLECTING_VOTES, EVALUATING_CONNECTIVITY, MONITORING, HANDLING_MISUSE, VOTING_ABORT, COLLECTING_ABORT_VOTES, ATTESTING, COLLECTING_ATTESTATION_SIGS, PROPAGATING_ATTESTATION, DONE]

INITIAL: AWAITING_ALLOCATION

EXTERNAL TRIGGERS:
  setup_session(session_id: SimpleType(name='hash', line=0, column=0), consumer: SimpleType(name='peer_id', line=0, column=0), provider: SimpleType(name='peer_id', line=0, column=0), other_witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0))
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
  AWAITING_ALLOCATION --NamedTrigger(name='setup_session', line=0, column=0)--> AWAITING_ALLOCATION
    action: store session_id, consumer, provider, other_witnesses
  AWAITING_ALLOCATION --MessageTrigger(message_type='VM_ALLOCATED', line=0, column=0)--> VERIFYING_VM
    action: STORE(vm_allocated_msg, FieldAccessExpr(object=Identifier(na...
    action: STORE(vm_allocated_at, FieldAccessExpr(object=FieldAccessExp...
  VERIFYING_VM --auto--> COLLECTING_VOTES
    action: compute can_reach_vm = FunctionCallExpr(name='check_vm_conne...
    action: compute can_see_consumer_connected = FunctionCallExpr(name='...
    action: STORE(witness, Identifier(name='peer_id', line=0, column=0))
    ... and 7 more actions
  COLLECTING_VOTES --MessageTrigger(message_type='VM_CONNECTIVITY_VOTE', line=0, column=0)--> [guard: BinaryExpr(left=FieldAccessExpr(object=FieldAccessExpr(object=Identifier(name='message', line=0, column=0), field='payload', line=0, column=0), field='witness', line=0, column=0), op=<BinaryOperator.NEQ: 6>, right=Identifier(name='peer_id', line=0, column=0), line=0, column=0)] COLLECTING_VOTES
    action: APPEND(connectivity_votes, FieldAccessExpr(object=Identifier...
  COLLECTING_VOTES --auto--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0)] EVALUATING_CONNECTIVITY
  COLLECTING_VOTES --TimeoutTrigger(parameter='CONNECTIVITY_VOTE_TIMEOUT', line=0, column=0)--> EVALUATING_CONNECTIVITY
  EVALUATING_CONNECTIVITY --auto--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GT: 8>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] MONITORING
    action: STORE(connectivity_verified, Literal(value=True, type='bool'...
  EVALUATING_CONNECTIVITY --auto--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.OR: 12>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)] VOTING_ABORT
    action: STORE(connectivity_verified, Literal(value=False, type='bool...
    action: STORE(abort_reason, Literal(value='vm_unreachable', type='st...
  MONITORING --MessageTrigger(message_type='VM_CANCELLED', line=0, column=0)--> ATTESTING
    action: STORE(vm_cancelled_msg, FieldAccessExpr(object=Identifier(na...
    action: STORE(actual_duration_seconds, FieldAccessExpr(object=FieldA...
    action: STORE(termination_reason, FieldAccessExpr(object=FieldAccess...
  MONITORING --MessageTrigger(message_type='MISUSE_ACCUSATION', line=0, column=0)--> HANDLING_MISUSE
    action: STORE(misuse_accusation, FieldAccessExpr(object=Identifier(n...
  HANDLING_MISUSE --auto--> [guard: BinaryExpr(left=FieldAccessExpr(object=FunctionCallExpr(name='LOAD', args=[Identifier(name='misuse_accusation', line=0, column=0)], line=0, column=0), field='evidence', line=0, column=0), op=<BinaryOperator.NEQ: 6>, right=Literal(value='', type='string', line=0, column=0), line=0, column=0)] VOTING_ABORT
    action: STORE(abort_reason, Literal(value='consumer_misuse', type='s...
  HANDLING_MISUSE --auto--> [guard: BinaryExpr(left=FieldAccessExpr(object=FunctionCallExpr(name='LOAD', args=[Identifier(name='misuse_accusation', line=0, column=0)], line=0, column=0), field='evidence', line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Literal(value='', type='string', line=0, column=0), line=0, column=0)] MONITORING
  VOTING_ABORT --auto--> COLLECTING_ABORT_VOTES
    action: compute abort_vote_data = StructLiteralExpr(fields={'session...
    action: compute abort_vote_signature = FunctionCallExpr(name='SIGN',...
    action: compute my_abort_vote = StructLiteralExpr(fields={'signature...
    ... and 3 more actions
  COLLECTING_ABORT_VOTES --MessageTrigger(message_type='ABORT_VOTE', line=0, column=0)--> [guard: BinaryExpr(left=FieldAccessExpr(object=FieldAccessExpr(object=Identifier(name='message', line=0, column=0), field='payload', line=0, column=0), field='witness', line=0, column=0), op=<BinaryOperator.NEQ: 6>, right=Identifier(name='peer_id', line=0, column=0), line=0, column=0)] COLLECTING_ABORT_VOTES
    action: APPEND(abort_votes, FieldAccessExpr(object=Identifier(name='...
  COLLECTING_ABORT_VOTES --auto--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='abort_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='ABORT_THRESHOLD', line=0, column=0), line=0, column=0)] ATTESTING
    action: STORE(session_aborted, Literal(value=True, type='bool', line...
    action: STORE(termination_reason, FunctionCallExpr(name='LOAD', args...
  COLLECTING_ABORT_VOTES --TimeoutTrigger(parameter='ABORT_VOTE_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='abort_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='ABORT_THRESHOLD', line=0, column=0), line=0, column=0)] MONITORING
  COLLECTING_ABORT_VOTES --TimeoutTrigger(parameter='ABORT_VOTE_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='abort_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='ABORT_THRESHOLD', line=0, column=0), line=0, column=0)] ATTESTING
    action: STORE(session_aborted, Literal(value=True, type='bool', line...
    action: STORE(termination_reason, FunctionCallExpr(name='LOAD', args...
  ATTESTING --auto--> COLLECTING_ATTESTATION_SIGS
    action: compute attestation = StructLiteralExpr(fields={'session_id'...
    action: compute my_signature = FunctionCallExpr(name='SIGN', args=[F...
    action: STORE(attestation_signatures, ListLiteralExpr(elements=[Stru...
    ... and 2 more actions
  COLLECTING_ATTESTATION_SIGS --MessageTrigger(message_type='ATTESTATION_SHARE', line=0, column=0)--> COLLECTING_ATTESTATION_SIGS
    action: APPEND(attestation_signatures, FieldAccessExpr(object=FieldA...
  COLLECTING_ATTESTATION_SIGS --auto--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='attestation_signatures', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='ATTESTATION_THRESHOLD', line=0, column=0), line=0, column=0)] PROPAGATING_ATTESTATION
  PROPAGATING_ATTESTATION --auto--> DONE
    action: compute final_attestation = StructLiteralExpr(fields={'cabal...
    action: SEND(Identifier(name='consumer', line=0, column=0), ATTESTAT...
    action: SEND(Identifier(name='provider', line=0, column=0), ATTESTAT...
    ... and 1 more actions
```

### ACTOR: Consumer

*Connects to VM, uses service*

```
STATES: [WAITING_FOR_VM, CONNECTING, CONNECTED, REQUESTING_CANCEL, SESSION_ENDED]

INITIAL: WAITING_FOR_VM

EXTERNAL TRIGGERS:
  setup_session(session_id: SimpleType(name='hash', line=0, column=0), provider: SimpleType(name='peer_id', line=0, column=0))
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
  WAITING_FOR_VM --NamedTrigger(name='setup_session', line=0, column=0)--> WAITING_FOR_VM
    action: store session_id, provider
  WAITING_FOR_VM --MessageTrigger(message_type='VM_READY', line=0, column=0)--> CONNECTING
    action: STORE(vm_info, FieldAccessExpr(object=Identifier(name='messa...
  CONNECTING --auto--> CONNECTED
    action: STORE(connected_at, FunctionCallExpr(name='NOW', args=[], li...
  CONNECTED --MessageTrigger(message_type='SESSION_TERMINATED', line=0, column=0)--> SESSION_ENDED
    action: STORE(termination_reason, FieldAccessExpr(object=Identifier(...
  CONNECTED --MessageTrigger(message_type='ATTESTATION_RESULT', line=0, column=0)--> CONNECTED
    action: STORE(attestation, FieldAccessExpr(object=Identifier(name='m...
  CONNECTED --NamedTrigger(name='request_cancel', line=0, column=0)--> REQUESTING_CANCEL
  REQUESTING_CANCEL --auto--> CONNECTED
    action: SEND(Identifier(name='provider', line=0, column=0), CANCEL_R...
  SESSION_ENDED --MessageTrigger(message_type='ATTESTATION_RESULT', line=0, column=0)--> SESSION_ENDED
    action: STORE(attestation, FieldAccessExpr(object=Identifier(name='m...
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
