# Transaction 00: Escrow Lock / Top-up

Lock funds with distributed witness consensus for a compute session. Also handles mid-session top-ups using the same mechanism.

**See also:** [Protocol Format](../../FORMAT.md) for primitive operations and state machine semantics.

## Overview

Consumer wants to pay Provider for a service. This transaction locks the funds by distributed witness consensus. Settlement (releasing the funds) is handled by [Transaction 02](../02_escrow_settle.md).

**This transaction handles two cases:**
1. **Initial Lock** - No existing escrow for this session
2. **Top-up** - Adding funds to an existing active escrow

**Actors:**
- **Consumer** - party paying for service
- **Provider** - party providing service, selects witnesses
- **Witnesses (Cabal)** - verify consumer has sufficient balance, reach consensus on lock

**Flow (Initial Lock):**
1. Consumer sends LOCK_INTENT to Provider with checkpoint reference
2. Provider selects witnesses deterministically, sends commitment to Consumer
3. Consumer verifies witness selection, sends WITNESS_REQUEST to witnesses
4. Witnesses check consumer's balance, deliberate, vote
5. Witnesses multi-sign result, send to Consumer for counter-signature
6. Consumer counter-signs, lock is finalized and broadcast

**Flow (Top-up):**
1. Consumer sends TOPUP_INTENT to existing Cabal with additional amount
2. Cabal verifies consumer has sufficient *additional* balance (not counting already-locked funds)
3. Cabal multi-signs top-up result
4. Consumer counter-signs, top-up is finalized
5. Total escrow = previous amount + top-up amount

---

## Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `WITNESS_COUNT` | 5 count | Initial witnesses to recruit |
| `WITNESS_THRESHOLD` | 3 count | Minimum for consensus |
| `WITNESS_COMMITMENT_TIMEOUT` | 30 seconds | Seconds for provider to respond with witnesses |
| `LOCK_TIMEOUT` | 300 seconds | Seconds for consumer to complete lock (provider waiting) |
| `PRELIMINARY_TIMEOUT` | 30 seconds | Seconds to collect preliminaries |
| `CONSENSUS_TIMEOUT` | 60 seconds | Seconds to reach consensus |
| `RECRUITMENT_TIMEOUT` | 180 seconds | Seconds for full recruitment |
| `CONSUMER_SIGNATURE_TIMEOUT` | 60 seconds | Seconds for consumer to counter-sign |
| `LIVENESS_CHECK_INTERVAL` | 300 seconds | Seconds between liveness checks |
| `LIVENESS_RESPONSE_TIMEOUT` | 30 seconds | Seconds to respond to ping |
| `REPLACEMENT_TIMEOUT` | 120 seconds | Seconds to get replacement witness ack |
| `MAX_CHAIN_AGE` | 3600 seconds | Max age of chain knowledge |
| `CONSENSUS_THRESHOLD` | 0.67 fraction | Fraction needed to decide |
| `MAX_RECRUITMENT_ROUNDS` | 3 count | Max times to recruit more witnesses |
| `MIN_HIGH_TRUST_WITNESSES` | 2 count | Minimum high-trust witnesses for fairness |
| `MAX_PRIOR_INTERACTIONS` | 5 count | Max prior interactions with consumer for fairness |
| `HIGH_TRUST_THRESHOLD` | 1.0 fraction | Trust score threshold for high-trust classification |

---

## Block Types (Chain Records)

```
BALANCE_LOCK {
  session_id: SimpleType(name='hash', line=0, column=0)
  amount: SimpleType(name='uint', line=0, column=0)
  lock_result_hash: SimpleType(name='hash', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

BALANCE_TOPUP {
  session_id: SimpleType(name='hash', line=0, column=0)
  previous_total: SimpleType(name='uint', line=0, column=0)
  topup_amount: SimpleType(name='uint', line=0, column=0)
  new_total: SimpleType(name='uint', line=0, column=0)
  topup_result_hash: SimpleType(name='hash', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

WITNESS_COMMITMENT {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  amount: SimpleType(name='uint', line=0, column=0)
  observed_balance: SimpleType(name='uint', line=0, column=0)
  witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

WITNESS_REPLACEMENT {
  session_id: SimpleType(name='hash', line=0, column=0)
  old_witness: SimpleType(name='peer_id', line=0, column=0)
  new_witness: SimpleType(name='peer_id', line=0, column=0)
  reason: SimpleType(name='string', line=0, column=0)
  remaining_witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

```

---

## Message Types

```
# Consumer -> Provider
LOCK_INTENT {
  consumer: SimpleType(name='peer_id', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  amount: SimpleType(name='uint', line=0, column=0)
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer_nonce: SimpleType(name='bytes', line=0, column=0)
  provider_chain_checkpoint: SimpleType(name='hash', line=0, column=0)
  checkpoint_timestamp: SimpleType(name='timestamp', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by consumer
}

# Provider -> Consumer
WITNESS_SELECTION_COMMITMENT {
  session_id: SimpleType(name='hash', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  provider_nonce: SimpleType(name='bytes', line=0, column=0)
  provider_chain_segment: SimpleType(name='bytes', line=0, column=0)
  selection_inputs: SimpleType(name='SelectionInputs', line=0, column=0)
  witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by provider
}

# Provider -> Consumer
LOCK_REJECTED {
  session_id: SimpleType(name='hash', line=0, column=0)
  reason: SimpleType(name='string', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by provider
}

# Consumer -> Witness
WITNESS_REQUEST {
  consumer: SimpleType(name='peer_id', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  amount: SimpleType(name='uint', line=0, column=0)
  session_id: SimpleType(name='hash', line=0, column=0)
  my_chain_head: SimpleType(name='hash', line=0, column=0)
  witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by consumer
}

# Consumer -> Witness
CONSUMER_SIGNED_LOCK {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer_signature: SimpleType(name='signature', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

# Witness -> Witness
WITNESS_PRELIMINARY {
  session_id: SimpleType(name='hash', line=0, column=0)
  witness: SimpleType(name='peer_id', line=0, column=0)
  verdict: SimpleType(name='WitnessVerdict', line=0, column=0)
  observed_balance: SimpleType(name='uint', line=0, column=0)
  observed_chain_head: SimpleType(name='hash', line=0, column=0)
  reject_reason: SimpleType(name='string', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
WITNESS_CHAIN_SYNC_REQUEST {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  requesting_witness: SimpleType(name='peer_id', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
WITNESS_CHAIN_SYNC_RESPONSE {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  chain_data: SimpleType(name='bytes', line=0, column=0)
  chain_head: SimpleType(name='hash', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
WITNESS_FINAL_VOTE {
  session_id: SimpleType(name='hash', line=0, column=0)
  witness: SimpleType(name='peer_id', line=0, column=0)
  vote: SimpleType(name='WitnessVerdict', line=0, column=0)
  observed_balance: SimpleType(name='uint', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
WITNESS_RECRUIT_REQUEST {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  provider: SimpleType(name='peer_id', line=0, column=0)
  amount: SimpleType(name='uint', line=0, column=0)
  existing_witnesses: ListType(element_type=SimpleType(name='peer_id', line=0, column=0), line=0, column=0)
  existing_votes: ListType(element_type=SimpleType(name='WITNESS_FINAL_VOTE', line=0, column=0), line=0, column=0)
  reason: SimpleType(name='string', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Consumer
LOCK_RESULT_FOR_SIGNATURE {
  result: SimpleType(name='LockResult', line=0, column=0)
}

# Witness -> Network
BALANCE_UPDATE_BROADCAST {
  consumer: SimpleType(name='peer_id', line=0, column=0)
  lock_result: SimpleType(name='LockResult', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

# Witness -> Witness, Consumer
LIVENESS_PING {
  session_id: SimpleType(name='hash', line=0, column=0)
  from_witness: SimpleType(name='peer_id', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Witness -> Witness
LIVENESS_PONG {
  session_id: SimpleType(name='hash', line=0, column=0)
  from_witness: SimpleType(name='peer_id', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

# Consumer -> Witness
TOPUP_INTENT {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer: SimpleType(name='peer_id', line=0, column=0)
  additional_amount: SimpleType(name='uint', line=0, column=0)
  current_lock_result_hash: SimpleType(name='hash', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by consumer
}

# Witness -> Consumer
TOPUP_RESULT_FOR_SIGNATURE {
  topup_result: SimpleType(name='TopUpResult', line=0, column=0)
}

# Consumer -> Witness
CONSUMER_SIGNED_TOPUP {
  session_id: SimpleType(name='hash', line=0, column=0)
  consumer_signature: SimpleType(name='signature', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
}

# Witness -> Witness
TOPUP_VOTE {
  session_id: SimpleType(name='hash', line=0, column=0)
  witness: SimpleType(name='peer_id', line=0, column=0)
  vote: SimpleType(name='WitnessVerdict', line=0, column=0)
  additional_amount: SimpleType(name='uint', line=0, column=0)
  observed_balance: SimpleType(name='uint', line=0, column=0)
  timestamp: SimpleType(name='timestamp', line=0, column=0)
  signature: bytes  # signed by witness
}

```

---

## Sequence of States

1. **Pre-escrow**: Consumer has balance, wants to secure payment
2. **Selecting**: Consumer selects witnesses using fairness criteria
3. **Recruiting**: Consumer sends requests, witnesses do initial checks
4. **Deliberating**: Witnesses communicate, share findings, sync chains if needed
5. **Voting**: Witnesses vote on accept/reject
6. **Escalating**: If split, accepting witnesses recruit more
7. **Finalizing**: Witnesses multi-sign result
8. **Propagating**: Result broadcast to network
9. **Locked/Failed**: Terminal states

---

### ACTOR: Consumer

*Party paying for service*

```
STATES: [IDLE, SENDING_LOCK_INTENT, WAITING_FOR_WITNESS_COMMITMENT, VERIFYING_PROVIDER_CHAIN, VERIFYING_WITNESSES, SENDING_REQUESTS, WAITING_FOR_RESULT, REVIEWING_RESULT, SIGNING_RESULT, LOCKED, FAILED, SENDING_TOPUP, WAITING_FOR_TOPUP_RESULT, REVIEWING_TOPUP_RESULT, SIGNING_TOPUP]

INITIAL: IDLE

EXTERNAL TRIGGERS:
  initiate_lock(provider: SimpleType(name='peer_id', line=0, column=0), amount: SimpleType(name='uint', line=0, column=0))
    allowed_in: [IDLE]
  initiate_topup(additional_amount: SimpleType(name='uint', line=0, column=0))
    allowed_in: [LOCKED]

STATE IDLE:
  # Waiting to initiate lock

STATE SENDING_LOCK_INTENT:
  # Sending lock intent to provider

STATE WAITING_FOR_WITNESS_COMMITMENT:
  # Waiting for provider witness selection

STATE VERIFYING_PROVIDER_CHAIN:
  # Verifying provider's chain segment

STATE VERIFYING_WITNESSES:
  # Verifying witness selection is correct

STATE SENDING_REQUESTS:
  # Sending requests to witnesses

STATE WAITING_FOR_RESULT:
  # Waiting for witness consensus

STATE REVIEWING_RESULT:
  # Reviewing lock result

STATE SIGNING_RESULT:
  # Counter-signing the lock

STATE LOCKED:
  # Funds successfully locked

STATE FAILED: [TERMINAL]
  # Lock failed

STATE SENDING_TOPUP:
  # Sending top-up request

STATE WAITING_FOR_TOPUP_RESULT:
  # Waiting for cabal top-up consensus

STATE REVIEWING_TOPUP_RESULT:
  # Reviewing top-up result

STATE SIGNING_TOPUP:
  # Counter-signing top-up

TRANSITIONS:
  IDLE --NamedTrigger(name='initiate_lock', line=0, column=0)--> [guard: BinaryExpr(left=Identifier(name='provider_chain_checkpoint', line=0, column=0), op=<BinaryOperator.NEQ: 6>, right=Literal(value=None, type='null', line=0, column=0), line=0, column=0)] SENDING_LOCK_INTENT
    action: store provider, amount
    action: STORE(consumer, Identifier(name='peer_id', line=0, column=0)...
    action: compute session_id = FunctionCallExpr(name='HASH', args=[Bin...
    ... and 2 more actions
  SENDING_LOCK_INTENT --auto--> WAITING_FOR_WITNESS_COMMITMENT
    action: SEND(Identifier(name='provider', line=0, column=0), LOCK_INT...
    action: STORE(intent_sent_at, FunctionCallExpr(name='NOW', args=[], ...
  WAITING_FOR_WITNESS_COMMITMENT --MessageTrigger(message_type='WITNESS_SELECTION_COMMITMENT', line=0, column=0)--> VERIFYING_PROVIDER_CHAIN
    action: store provider_nonce, provider_chain_segment, selection_inpu...
    action: STORE(proposed_witnesses, FieldAccessExpr(object=Identifier(...
    action: compute chain_segment_valid_and_contains_checkpoint = Binary...
  WAITING_FOR_WITNESS_COMMITMENT --MessageTrigger(message_type='LOCK_REJECTED', line=0, column=0)--> FAILED
    action: STORE(reject_reason, FieldAccessExpr(object=Identifier(name=...
  WAITING_FOR_WITNESS_COMMITMENT --TimeoutTrigger(parameter='WITNESS_COMMITMENT_TIMEOUT', line=0, column=0)--> FAILED
    action: STORE(reject_reason, Literal(value='provider_timeout', type=...
  VERIFYING_PROVIDER_CHAIN --auto--> [guard: Identifier(name='chain_segment_valid_and_contains_checkpoint', line=0, column=0)] VERIFYING_WITNESSES
    action: compute verified_chain_state = FunctionCallExpr(name='CHAIN_...
    action: compute witness_selection_valid = FunctionCallExpr(name='VER...
  VERIFYING_WITNESSES --auto--> [guard: Identifier(name='witness_selection_valid', line=0, column=0)] SENDING_REQUESTS
    action: STORE(witnesses, Identifier(name='proposed_witnesses', line=...
  SENDING_REQUESTS --auto--> WAITING_FOR_RESULT
    action: BROADCAST(witnesses, WITNESS_REQUEST)
    action: STORE(requests_sent_at, FunctionCallExpr(name='NOW', args=[]...
  WAITING_FOR_RESULT --MessageTrigger(message_type='LOCK_RESULT_FOR_SIGNATURE', line=0, column=0)--> REVIEWING_RESULT
    action: STORE(pending_result, FieldAccessExpr(object=Identifier(name...
    action: STORE(result_sender, FieldAccessExpr(object=Identifier(name=...
    action: compute result_valid_and_accepted = FunctionCallExpr(name='V...
  WAITING_FOR_RESULT --TimeoutTrigger(parameter='RECRUITMENT_TIMEOUT', line=0, column=0)--> FAILED
    action: STORE(reject_reason, Literal(value='witness_timeout', type='...
  REVIEWING_RESULT --auto--> [guard: Identifier(name='result_valid_and_accepted', line=0, column=0)] SIGNING_RESULT
  REVIEWING_RESULT --auto--> [guard: UnaryExpr(op=<UnaryOperator.NOT: 1>, operand=Identifier(name='result_valid_and_accepted', line=0, column=0), line=0, column=0)] FAILED
    action: STORE(reject_reason, Literal(value='lock_rejected', type='st...
  SIGNING_RESULT --auto--> LOCKED
    action: compute consumer_signature = FunctionCallExpr(name='SIGN', a...
    action: STORE(lock_result, StructLiteralExpr(fields={'consumer_signa...
    action: APPEND(chain, Identifier(name='BALANCE_LOCK', line=0, column...
    ... and 2 more actions
  LOCKED --MessageTrigger(message_type='LIVENESS_PING', line=0, column=0)--> LOCKED
    action: STORE(from_witness, Identifier(name='peer_id', line=0, colum...
    action: SEND(FieldAccessExpr(object=Identifier(name='message', line=...
  LOCKED --NamedTrigger(name='initiate_topup', line=0, column=0)--> SENDING_TOPUP
    action: store additional_amount
    action: compute current_lock_hash = FunctionCallExpr(name='HASH', ar...
  SENDING_TOPUP --auto--> WAITING_FOR_TOPUP_RESULT
    action: BROADCAST(witnesses, TOPUP_INTENT)
    action: STORE(topup_sent_at, FunctionCallExpr(name='NOW', args=[], l...
  WAITING_FOR_TOPUP_RESULT --MessageTrigger(message_type='TOPUP_RESULT_FOR_SIGNATURE', line=0, column=0)--> REVIEWING_TOPUP_RESULT
    action: STORE(pending_topup_result, FieldAccessExpr(object=Identifie...
    action: compute topup_result_valid = FunctionCallExpr(name='VALIDATE...
  WAITING_FOR_TOPUP_RESULT --TimeoutTrigger(parameter='CONSENSUS_TIMEOUT', line=0, column=0)--> LOCKED
    action: STORE(topup_failed_reason, Literal(value='timeout', type='st...
  REVIEWING_TOPUP_RESULT --auto--> [guard: Identifier(name='topup_result_valid', line=0, column=0)] SIGNING_TOPUP
  SIGNING_TOPUP --auto--> LOCKED
    action: compute consumer_signature = FunctionCallExpr(name='SIGN', a...
    action: STORE(topup_result, StructLiteralExpr(fields={'consumer_sign...
    action: APPEND(chain, Identifier(name='BALANCE_TOPUP', line=0, colum...
    ... and 2 more actions
```

### ACTOR: Provider

*Party providing service, selects witnesses*

```
STATES: [IDLE, VALIDATING_CHECKPOINT, SENDING_REJECTION, SELECTING_WITNESSES, SENDING_COMMITMENT, WAITING_FOR_LOCK, SERVICE_PHASE]

INITIAL: IDLE

STATE IDLE:
  # Waiting for lock request

STATE VALIDATING_CHECKPOINT:
  # Validating consumer's checkpoint reference

STATE SENDING_REJECTION:
  # Sending rejection due to invalid checkpoint

STATE SELECTING_WITNESSES:
  # Computing deterministic witness selection

STATE SENDING_COMMITMENT:
  # Sending witness selection to consumer

STATE WAITING_FOR_LOCK:
  # Waiting for lock to complete

STATE SERVICE_PHASE:
  # Lock complete, providing service

TRANSITIONS:
  IDLE --MessageTrigger(message_type='LOCK_INTENT', line=0, column=0)--> VALIDATING_CHECKPOINT
    action: store consumer, amount, session_id, consumer_nonce
    action: STORE(requested_checkpoint, FieldAccessExpr(object=Identifie...
    action: compute provider_nonce = FunctionCallExpr(name='RANDOM_BYTES...
  VALIDATING_CHECKPOINT --auto--> [guard: FunctionCallExpr(name='CHAIN_CONTAINS_HASH', args=[Identifier(name='chain', line=0, column=0), Identifier(name='requested_checkpoint', line=0, column=0)], line=0, column=0)] SELECTING_WITNESSES
    action: compute chain_state_at_checkpoint = FunctionCallExpr(name='C...
    action: compute provider_chain_segment = FunctionCallExpr(name='CHAI...
  SENDING_REJECTION --auto--> IDLE
    action: SEND(Identifier(name='consumer', line=0, column=0), LOCK_REJ...
  SELECTING_WITNESSES --auto--> SENDING_COMMITMENT
    action: compute witnesses = FunctionCallExpr(name='SELECT_WITNESSES'...
    action: STORE(selection_inputs, Identifier(name='chain_state_at_chec...
  SENDING_COMMITMENT --auto--> WAITING_FOR_LOCK
    action: SEND(Identifier(name='consumer', line=0, column=0), WITNESS_...
    action: STORE(commitment_sent_at, FunctionCallExpr(name='NOW', args=...
  WAITING_FOR_LOCK --MessageTrigger(message_type='BALANCE_UPDATE_BROADCAST', line=0, column=0)--> [guard: BinaryExpr(left=BinaryExpr(left=FieldAccessExpr(object=FieldAccessExpr(object=Identifier(name='message', line=0, column=0), field='lock_result', line=0, column=0), field='session_id', line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Identifier(name='session_id', line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=FieldAccessExpr(object=FieldAccessExpr(object=Identifier(name='message', line=0, column=0), field='lock_result', line=0, column=0), field='status', line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Identifier(name='ACCEPTED', line=0, column=0), line=0, column=0), line=0, column=0)] SERVICE_PHASE
    action: STORE(lock_result, FieldAccessExpr(object=Identifier(name='m...
  WAITING_FOR_LOCK --TimeoutTrigger(parameter='LOCK_TIMEOUT', line=0, column=0)--> IDLE
    action: STORE(session_id, Literal(value=None, type='null', line=0, c...
```

### ACTOR: Witness

*Verifies consumer balance, participates in consensus*

```
STATES: [IDLE, CHECKING_CHAIN_KNOWLEDGE, REQUESTING_CHAIN_SYNC, WAITING_FOR_CHAIN_SYNC, CHECKING_BALANCE, CHECKING_EXISTING_LOCKS, SHARING_PRELIMINARY, COLLECTING_PRELIMINARIES, EVALUATING_PRELIMINARIES, VOTING, COLLECTING_VOTES, EVALUATING_VOTES, BUILDING_RESULT, RECRUITING_MORE, WAITING_FOR_RECRUITS, SIGNING_RESULT, COLLECTING_SIGNATURES, PROPAGATING_RESULT, WAITING_FOR_CONSUMER_SIGNATURE, FINALIZING, ESCROW_ACTIVE, DONE, REJECTED, CHECKING_TOPUP_BALANCE, VOTING_TOPUP, COLLECTING_TOPUP_VOTES, BUILDING_TOPUP_RESULT, PROPAGATING_TOPUP, WAITING_FOR_CONSUMER_TOPUP_SIGNATURE]

INITIAL: IDLE

STATE IDLE:
  # Waiting for witness request

STATE CHECKING_CHAIN_KNOWLEDGE:
  # Checking if we have recent consumer chain data

STATE REQUESTING_CHAIN_SYNC:
  # Requesting chain data from peers

STATE WAITING_FOR_CHAIN_SYNC:
  # Waiting for chain sync response

STATE CHECKING_BALANCE:
  # Verifying consumer has sufficient balance

STATE CHECKING_EXISTING_LOCKS:
  # Checking for existing locks on balance

STATE SHARING_PRELIMINARY:
  # Sharing preliminary verdict with peers

STATE COLLECTING_PRELIMINARIES:
  # Collecting preliminary verdicts

STATE EVALUATING_PRELIMINARIES:
  # Evaluating preliminary consensus

STATE VOTING:
  # Casting final vote

STATE COLLECTING_VOTES:
  # Collecting final votes

STATE EVALUATING_VOTES:
  # Evaluating vote consensus

STATE BUILDING_RESULT:
  # Building final lock result

STATE RECRUITING_MORE:
  # Recruiting additional witnesses

STATE WAITING_FOR_RECRUITS:
  # Waiting for recruit responses

STATE SIGNING_RESULT:
  # Signing the lock result

STATE COLLECTING_SIGNATURES:
  # Collecting peer signatures

STATE PROPAGATING_RESULT:
  # Sending result to consumer

STATE WAITING_FOR_CONSUMER_SIGNATURE:
  # Waiting for consumer counter-signature

STATE FINALIZING:
  # Recording lock on chain and broadcasting

STATE ESCROW_ACTIVE:
  # Escrow locked, monitoring liveness

STATE DONE:
  # Lock process complete

STATE REJECTED:
  # Witness declined to participate

STATE CHECKING_TOPUP_BALANCE:
  # Verifying consumer has additional free balance

STATE VOTING_TOPUP:
  # Voting on top-up request

STATE COLLECTING_TOPUP_VOTES:
  # Collecting top-up votes from other witnesses

STATE BUILDING_TOPUP_RESULT:
  # Building the top-up result after consensus

STATE PROPAGATING_TOPUP:
  # Sending top-up result to consumer for signature

STATE WAITING_FOR_CONSUMER_TOPUP_SIGNATURE:
  # Waiting for consumer top-up signature

TRANSITIONS:
  IDLE --MessageTrigger(message_type='WITNESS_REQUEST', line=0, column=0)--> CHECKING_CHAIN_KNOWLEDGE
    action: store consumer, provider, amount, session_id, my_chain_head,...
    action: STORE(consumer, FieldAccessExpr(object=Identifier(name='mess...
    action: compute other_witnesses = FunctionCallExpr(name='REMOVE', ar...
    ... and 4 more actions
  CHECKING_CHAIN_KNOWLEDGE --auto--> CHECKING_BALANCE
    action: compute observed_balance = IndexAccessExpr(object=Identifier...
  CHECKING_BALANCE --auto--> [guard: BinaryExpr(left=Identifier(name='observed_balance', line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='amount', line=0, column=0), line=0, column=0)] CHECKING_EXISTING_LOCKS
  CHECKING_BALANCE --auto--> [guard: BinaryExpr(left=Identifier(name='observed_balance', line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='amount', line=0, column=0), line=0, column=0)] SHARING_PRELIMINARY
    action: STORE(verdict, Identifier(name='REJECT', line=0, column=0))
    action: STORE(reject_reason, Literal(value='insufficient_balance', t...
  CHECKING_EXISTING_LOCKS --auto--> SHARING_PRELIMINARY
    action: STORE(verdict, Identifier(name='ACCEPT', line=0, column=0))
  SHARING_PRELIMINARY --auto--> COLLECTING_PRELIMINARIES
    action: BROADCAST(other_witnesses, WITNESS_PRELIMINARY)
    action: STORE(preliminary_sent_at, FunctionCallExpr(name='NOW', args...
  COLLECTING_PRELIMINARIES --MessageTrigger(message_type='WITNESS_PRELIMINARY', line=0, column=0)--> COLLECTING_PRELIMINARIES
    action: APPEND(preliminaries, FieldAccessExpr(object=Identifier(name...
  COLLECTING_PRELIMINARIES --auto--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='preliminaries', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=BinaryExpr(left=Identifier(name='WITNESS_THRESHOLD', line=0, column=0), op=<BinaryOperator.SUB: 2>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0)] VOTING
    action: compute consensus_direction = FunctionCallExpr(name='COMPUTE...
  COLLECTING_PRELIMINARIES --TimeoutTrigger(parameter='PRELIMINARY_TIMEOUT', line=0, column=0)--> VOTING
    action: compute consensus_direction = FunctionCallExpr(name='COMPUTE...
  VOTING --auto--> COLLECTING_VOTES
    action: BROADCAST(other_witnesses, WITNESS_FINAL_VOTE)
  COLLECTING_VOTES --MessageTrigger(message_type='WITNESS_FINAL_VOTE', line=0, column=0)--> COLLECTING_VOTES
    action: APPEND(votes, FieldAccessExpr(object=Identifier(name='messag...
  COLLECTING_VOTES --auto--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='WITNESS_THRESHOLD', line=0, column=0), line=0, column=0)] BUILDING_RESULT
  COLLECTING_VOTES --TimeoutTrigger(parameter='CONSENSUS_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='WITNESS_THRESHOLD', line=0, column=0), line=0, column=0)] BUILDING_RESULT
  BUILDING_RESULT --auto--> SIGNING_RESULT
    action: compute result = FunctionCallExpr(name='BUILD_LOCK_RESULT', ...
  SIGNING_RESULT --auto--> PROPAGATING_RESULT
    action: SEND(Identifier(name='consumer', line=0, column=0), LOCK_RES...
    action: STORE(propagated_at, FunctionCallExpr(name='NOW', args=[], l...
  PROPAGATING_RESULT --MessageTrigger(message_type='CONSUMER_SIGNED_LOCK', line=0, column=0)--> ESCROW_ACTIVE
    action: STORE(consumer_signature, FieldAccessExpr(object=Identifier(...
    action: STORE(total_escrowed, Identifier(name='amount', line=0, colu...
    action: APPEND(chain, Identifier(name='WITNESS_COMMITMENT', line=0, ...
    ... and 1 more actions
  PROPAGATING_RESULT --TimeoutTrigger(parameter='CONSENSUS_TIMEOUT', line=0, column=0)--> DONE
    action: STORE(reject_reason, Literal(value='consumer_signature_timeo...
  ESCROW_ACTIVE --MessageTrigger(message_type='TOPUP_INTENT', line=0, column=0)--> CHECKING_TOPUP_BALANCE
    action: STORE(topup_intent, Identifier(name='message', line=0, colum...
    action: compute topup_observed_balance = IndexAccessExpr(object=Iden...
  CHECKING_TOPUP_BALANCE --auto--> [guard: BinaryExpr(left=BinaryExpr(left=Identifier(name='topup_observed_balance', line=0, column=0), op=<BinaryOperator.SUB: 2>, right=Identifier(name='total_escrowed', line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=FieldAccessExpr(object=Identifier(name='topup_intent', line=0, column=0), field='additional_amount', line=0, column=0), line=0, column=0)] VOTING_TOPUP
    action: STORE(topup_verdict, Identifier(name='accept', line=0, colum...
  CHECKING_TOPUP_BALANCE --auto--> [guard: BinaryExpr(left=BinaryExpr(left=Identifier(name='topup_observed_balance', line=0, column=0), op=<BinaryOperator.SUB: 2>, right=Identifier(name='total_escrowed', line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=FieldAccessExpr(object=Identifier(name='topup_intent', line=0, column=0), field='additional_amount', line=0, column=0), line=0, column=0)] ESCROW_ACTIVE
    action: STORE(topup_verdict, Identifier(name='reject', line=0, colum...
    action: STORE(topup_reject_reason, Literal(value='insufficient_free_...
  VOTING_TOPUP --auto--> COLLECTING_TOPUP_VOTES
    action: STORE(topup_votes, ListLiteralExpr(elements=[], line=0, colu...
    action: BROADCAST(other_witnesses, TOPUP_VOTE)
  COLLECTING_TOPUP_VOTES --MessageTrigger(message_type='TOPUP_VOTE', line=0, column=0)--> COLLECTING_TOPUP_VOTES
    action: APPEND(topup_votes, FieldAccessExpr(object=Identifier(name='...
  COLLECTING_TOPUP_VOTES --auto--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='topup_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=BinaryExpr(left=Identifier(name='WITNESS_THRESHOLD', line=0, column=0), op=<BinaryOperator.SUB: 2>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0)] BUILDING_TOPUP_RESULT
  COLLECTING_TOPUP_VOTES --TimeoutTrigger(parameter='PRELIMINARY_TIMEOUT', line=0, column=0)--> [guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='topup_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=BinaryExpr(left=Identifier(name='WITNESS_THRESHOLD', line=0, column=0), op=<BinaryOperator.SUB: 2>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0)] BUILDING_TOPUP_RESULT
  COLLECTING_TOPUP_VOTES --TimeoutTrigger(parameter='CONSENSUS_TIMEOUT', line=0, column=0)--> ESCROW_ACTIVE
    action: STORE(topup_failed_reason, Literal(value='vote_timeout', typ...
  BUILDING_TOPUP_RESULT --auto--> PROPAGATING_TOPUP
    action: compute topup_result = FunctionCallExpr(name='BUILD_TOPUP_RE...
    action: SEND(Identifier(name='consumer', line=0, column=0), TOPUP_RE...
  PROPAGATING_TOPUP --MessageTrigger(message_type='CONSUMER_SIGNED_TOPUP', line=0, column=0)--> ESCROW_ACTIVE
    action: STORE(total_escrowed, BinaryExpr(left=Identifier(name='total...
  PROPAGATING_TOPUP --TimeoutTrigger(parameter='CONSENSUS_TIMEOUT', line=0, column=0)--> ESCROW_ACTIVE
    action: STORE(topup_failed_reason, Literal(value='consumer_signature...
  ESCROW_ACTIVE --MessageTrigger(message_type='LIVENESS_PING', line=0, column=0)--> ESCROW_ACTIVE
    action: STORE(from_witness, Identifier(name='peer_id', line=0, colum...
    action: SEND(FieldAccessExpr(object=Identifier(name='message', line=...
```


---

## Witness Selection Criteria

### Provider-Driven, Consumer-Verifiable Selection

**Key insight:** The provider selects witnesses, not the consumer. This prevents:
- Consumer using Sybil witnesses
- Consumer pre-bribing witnesses
- Consumer selecting witnesses with stale/no knowledge of their chain

The selection must be **verifiable** by consumer to prevent provider manipulation.

### Chain State Agreement

**Problem:** Consumer needs to verify provider's witness selection, but consumer doesn't store provider's chain (too much overhead).

**Solution:** Use keepalive chain hashes as checkpoints.

1. Consumer's chain contains hashes of provider's chain head from past keepalive messages
2. Consumer picks a hash H from *before* this economic interaction started
3. Provider must compute witness selection using only chain state at H
4. Provider sends their chain (or relevant segment) to consumer
5. Consumer verifies chain validity, finds H, recomputes selection

**Why use a hash from before the interaction:**
- Provider couldn't have manipulated their chain state for this specific transaction
- The hash was recorded before provider knew this lock would happen
- Prevents provider from adding Sybil witnesses just before selection

### Selection Protocol

```
# Phase 1: Consumer specifies checkpoint
Consumer looks up: provider_chain_hash H from own chain (before interaction)
Consumer → Provider: LOCK_INTENT {
  amount,
  consumer_nonce,
  provider_chain_checkpoint: H,
  checkpoint_timestamp: T  # when consumer recorded H
}

# Phase 2: Provider computes and shares
Provider loads chain state as of H
Provider computes: witnesses = SELECT_WITNESSES(seed, chain_state_at_H, criteria)
Provider → Consumer: WITNESS_SELECTION_COMMITMENT {
  provider_nonce,
  provider_chain_segment,  # chain data from H to current (or just to H)
  witnesses,
  selection_inputs        # all data used in selection
}

# Phase 3: Consumer verifies
Consumer verifies:
  1. provider_chain_segment is valid (signatures, hashes chain correctly)
  2. H exists in the chain at expected position
  3. Recompute SELECT_WITNESSES with same inputs → same witnesses
  4. Witnesses meet minimum fairness criteria
```

### Deterministic Selection Function

```
SELECT_WITNESSES(seed, chain_state, criteria):
  # Extract candidates from chain state (peers known to provider at checkpoint)
  candidates = chain_state.known_peers

  # Filter candidates
  eligible = candidates - criteria.exclude
  eligible = [c for c in eligible
              where INTERACTION_COUNT(chain_state, c, criteria.max_prior_interaction_with)
                    <= criteria.max_interactions]

  # Separate by trust level (trust as computed at checkpoint)
  high_trust = [c for c in eligible where TRUST(chain_state, c) >= HIGH_TRUST_THRESHOLD]
  low_trust = [c for c in eligible where TRUST(chain_state, c) < HIGH_TRUST_THRESHOLD]

  # Sort each pool deterministically (by peer_id)
  high_trust = SORT(high_trust, by=peer_id)
  low_trust = SORT(low_trust, by=peer_id)

  # Deterministic "random" selection using seed
  rng = SEEDED_RNG(seed)

  # Select required high-trust witnesses
  selected = SEEDED_SAMPLE(rng, high_trust, criteria.min_high_trust)

  # Fill remaining with mix
  remaining_needed = criteria.count - LENGTH(selected)
  remaining_pool = SORT((high_trust - selected) + low_trust, by=peer_id)
  selected = selected + SEEDED_SAMPLE(rng, remaining_pool, remaining_needed)

  RETURN selected
```

### Why This Works

| Attack | How Provider Selection Prevents It |
|--------|-----------------------------------|
| Sybil witnesses | Consumer doesn't control candidate list or selection |
| Pre-bribery | Consumer doesn't know witnesses until after committing nonce |
| Double-lock | Provider's witnesses check consumer's chain (provider has incentive for accuracy) |
| Witness selection manipulation | Deterministic selection from seed + checkpoint from past - neither party controls outcome |
| Provider chain manipulation | Checkpoint H is from before interaction - provider couldn't have prepared |

### What Consumer Verifies

1. **Chain segment is valid** - Proper signatures, hashes link correctly
2. **Checkpoint H exists** - At the position/time consumer recorded it
3. **Selection recomputable** - Same inputs → same witnesses
4. **Minimum criteria met** - MIN_HIGH_TRUST_WITNESSES, diversity requirements
5. **Checkpoint is old enough** - From before provider could have anticipated this transaction

---

## Top-up Flow

Top-up uses the same escrow lock mechanism for mid-session additional funding. This is needed when:
- Session duration exceeds initial deposit
- Consumer wants to extend session
- Provider requires additional collateral

### Why Same Transaction Works

1. **Same cabal**: Top-up uses the existing witness set (cabal) from the session, no need for new witness selection
2. **Same verification**: Witnesses verify consumer has sufficient *additional* balance
3. **Additive escrow**: New total = previous locked + additional amount
4. **Same counter-signature**: Consumer must still counter-sign to authorize

### Top-up Differences from Initial Lock

| Aspect | Initial Lock | Top-up |
|--------|--------------|--------|
| Witness selection | Deterministic from seed | Use existing cabal |
| Balance check | Total balance ≥ amount | Free balance ≥ additional |
| Provider involvement | Selects witnesses | Just receives notification |
| Session ID | Generated new | Existing session |
| Result record | LOCK_RESULT | TOPUP_RESULT |

### Top-up Failure Handling

If top-up fails (insufficient balance, witness unavailable, etc.):
- Session continues with existing escrow
- Provider may choose to terminate if insufficient funds
- No penalty for failed top-up attempt

---

## Attack Analysis

### Attack: Double-Lock with Colluding Witnesses

**Description:** Consumer locks funds with one set of witnesses, then attempts to lock the same funds with a different set before the first lock propagates.

**Attacker role:** Consumer (possibly with colluding witnesses)

**Sequence:**
1. Consumer has 100 coins, initiates LOCK_1 for 80 coins with Provider A (Witnesses A, B, C)
2. Before LOCK_1 completes or propagates, Consumer initiates LOCK_2 for 80 coins with Provider B (Witnesses D, E, F)
3. If both locks complete before either witness set learns of the other, Consumer has committed 160 coins with only 100

**Harm:** Consumer can defraud two providers simultaneously; one will never get paid

**Detection:** When BALANCE_UPDATE_BROADCAST messages conflict, honest peers see the double-lock

**On-chain proof:** Two LOCK_RESULT records with overlapping amounts from same consumer, timestamps close together

**Defense:**
- Witnesses check for existing pending locks during CHECKING_EXISTING_LOCKS state
- Chain sync ensures witnesses have recent view of consumer's commitments
- MAX_CHAIN_AGE parameter limits how stale witness data can be
- Consumer counter-signature means consumer explicitly authorized both (evidence of intent)
- **Provider-driven selection:** Providers choose witnesses from their known peers - likely to have better/fresher knowledge of network state than consumer's Sybils would

**Residual risk:** If witnesses don't know about each other's locks until after both complete, double-lock can succeed. Mitigation requires network propagation time << lock completion time.

---

### Attack: Witness Selection Manipulation

**Description:** ~~Consumer selects witnesses who will approve the lock despite insufficient balance or who will collude in future settlement fraud.~~ **MITIGATED by provider-driven selection.**

**Attacker role:** Consumer

**Original attack:**
1. Consumer creates many Sybil identities, builds trust slowly
2. When initiating lock, SELECT_WITNESSES returns Consumer's Sybils
3. Sybil witnesses approve lock regardless of actual balance
4. Provider provides service, settlement witnesses (Sybils) burn funds or refund to Consumer

**Why provider-driven selection prevents this:**
- Provider builds candidate list, not consumer
- Consumer's Sybils won't be in provider's candidate list (provider doesn't know them)
- Deterministic selection from seed prevents either party from manipulating which witnesses are chosen
- Consumer can only verify selection was correct, not influence it

**Residual risk:** Provider could collude with their own Sybil witnesses to harm consumer. But provider is receiving service payment - they have no incentive to reject valid locks. Consumer can abort if proposed witnesses look suspicious (all unknown to consumer, all recently created, etc.).

---

### Attack: Provider Witness Selection Manipulation

**Description:** Provider selects witnesses who will collude against consumer at settlement time.

**Attacker role:** Provider

**Sequence:**
1. Provider builds candidate list containing only their Sybil identities
2. Consumer verifies selection algorithm but all candidates are Sybils
3. Lock proceeds with Sybil witnesses
4. At settlement, Sybil witnesses claim consumer didn't pay or service was complete, settle in provider's favor

**Harm:** Consumer loses locked funds unfairly

**Detection:** Consumer can inspect candidate list before proceeding

**On-chain proof:** WITNESS_SELECTION_COMMITMENT includes candidate_list - shows provider's choices

**Defense:**
- Consumer verifies candidate list includes peers consumer knows/trusts
- Minimum diversity requirements (candidates from different trust clusters)
- Consumer can reject and refuse to proceed if candidate list looks suspicious
- Consumer's nonce prevents provider from pre-computing which witnesses will be selected

**Residual risk:** Consumer must do due diligence on candidate list. New consumers with few known peers may not be able to evaluate.

---

### Attack: Witness Denial of Service

**Description:** Attacker floods witnesses with fake WITNESS_REQUEST messages to exhaust their resources.

**Attacker role:** External / Consumer

**Sequence:**
1. Attacker sends WITNESS_REQUEST to many witnesses simultaneously
2. Witnesses begin CHECKING_CHAIN_KNOWLEDGE, CHECKING_BALANCE for fake requests
3. Legitimate requests get delayed or dropped

**Harm:** Network performance degrades; legitimate locks fail or timeout

**Detection:** High volume of requests from single source; requests that never complete

**On-chain proof:** None directly (attack is off-chain resource exhaustion)

**Defense:**
- Rate limiting per source identity
- Require small proof-of-work in WITNESS_REQUEST
- Witnesses prioritize requests from identities with history
- WITNESS_REQUEST requires valid signature from known peer

**Residual risk:** Attackers with many identities can still cause some degradation

---

### Attack: Chain Sync Poisoning

**Description:** Malicious witness provides false chain data during WITNESS_CHAIN_SYNC_RESPONSE.

**Attacker role:** Witness

**Sequence:**
1. Honest witness enters REQUESTING_CHAIN_SYNC because they lack recent consumer data
2. Malicious witness responds with fabricated chain showing higher balance than reality
3. Honest witness proceeds to approve lock based on false data
4. Lock completes for funds that don't exist

**Harm:** Provider provides service for lock that will fail at settlement

**Detection:** Conflict detected when trying to settle - witnesses see different balances

**On-chain proof:** WITNESS_CHAIN_SYNC_RESPONSE signature proves who provided the data

**Defense:**
- Multiple witnesses must provide chain sync data, not just one
- Cross-verify chain hashes against multiple sources
- Require chain data to be signed by the consumer (only consumer can author their chain)
- Track which witness provided which data - assign blame if false

**Residual risk:** First-interaction scenarios where no witness has consumer's chain

---

### Attack: Preliminary Verdict Manipulation

**Description:** Malicious witness lies about their preliminary verdict to manipulate consensus direction.

**Attacker role:** Witness

**Sequence:**
1. Malicious witness actually sees sufficient balance (should ACCEPT)
2. Malicious witness sends WITNESS_PRELIMINARY with verdict: REJECT, fake reject_reason
3. This shifts consensus toward rejection or triggers unnecessary recruitment rounds
4. Either lock fails (DOS) or escalation wastes resources

**Harm:** Legitimate locks fail; wasted time and resources; can target specific consumers

**Detection:** Other witnesses with same chain view would see conflicting verdicts

**On-chain proof:** WITNESS_PRELIMINARY messages show the lie (signed, timestamped)

**Defense:**
- Require witnesses to include observed_chain_head in preliminary
- Other witnesses can verify: "you saw same chain head but different verdict?"
- Repeated false verdicts damage witness reputation/trust
- Balance disagreement detection in EVALUATING_PRELIMINARIES catches some cases

**Residual risk:** If malicious witness claims different chain head, harder to prove lie

---

### Attack: Consumer Abandonment

**Description:** Consumer initiates lock, witnesses do work, then Consumer never signs the result.

**Attacker role:** Consumer

**Sequence:**
1. Consumer sends WITNESS_REQUEST, witnesses deliberate and reach consensus
2. Witnesses send LOCK_RESULT_FOR_CONSUMER_SIGNATURE
3. Consumer never responds
4. After CONSUMER_SIGNATURE_TIMEOUT, lock fails

**Harm:** Witnesses wasted effort; can be used to probe witness set without commitment

**Detection:** Timeout in WAITING_FOR_CONSUMER_SIGNATURE state

**On-chain proof:** WITNESS_COMMITMENT_EXPIRED record; signed WITNESS_REQUEST proves consumer initiated

**Defense:**
- Rate limit how often consumer can initiate locks that timeout
- Track "abandonment ratio" in consumer's reputation
- Require small deposit from consumer before witnesses start work (separate protocol)

**Residual risk:** First-time consumers can't be distinguished from attackers

---

### Fault: Network Partition During Deliberation

**Description:** Network splits during witness deliberation, subsets can't communicate.

**Faulty actor:** Network

**Fault type:** Network partition

**Sequence:**
1. 5 witnesses selected, begin CHECKING_CHAIN_KNOWLEDGE
2. Network partitions: Witnesses A, B, C can communicate; D, E can communicate; no cross-group
3. Each group collects preliminaries only from its partition
4. Neither reaches WITNESS_THRESHOLD

**Impact:** Lock fails despite sufficient witnesses and valid balance

**Recovery:** PRELIMINARY_TIMEOUT triggers; groups have <CONSENSUS_THRESHOLD; lock naturally fails

**Residual risk:** If partition resolves late, some witnesses may have voted ACCEPT, others timed out. Inconsistent state possible.

**Mitigation:** Ensure all state transitions to failure are idempotent; witnesses who timed out can safely ignore late messages.

---

### Fault: Witness Crash During Signing

**Description:** Witness crashes after voting ACCEPT but before signing the result.

**Faulty actor:** Witness

**Fault type:** Crash

**Sequence:**
1. 5 witnesses all vote ACCEPT
2. Witness A crashes before SIGNING_RESULT state
3. Only 4 signatures possible
4. If WITNESS_THRESHOLD = 3, lock still succeeds
5. If crashed witness was critical (e.g., threshold = 5), lock fails

**Impact:** Lock may fail despite consensus

**Recovery:** CONSENSUS_TIMEOUT in COLLECTING_SIGNATURES; if enough signatures, proceed; otherwise fail gracefully

**Residual risk:** Borderline cases where exactly WITNESS_THRESHOLD witnesses must sign and one crashes

**Mitigation:** Set WITNESS_COUNT > WITNESS_THRESHOLD to allow for some failures

---

### Fault: Stale Chain Data at Multiple Witnesses

**Description:** Multiple witnesses have outdated view of consumer's chain.

**Faulty actor:** Witnesses (not malicious, just stale)

**Fault type:** Stale data

**Sequence:**
1. Consumer's balance changed recently
2. Multiple selected witnesses last saw consumer's chain before the change
3. All enter REQUESTING_CHAIN_SYNC
4. No witness has fresh data to share
5. All timeout and REJECT due to "no_chain_knowledge_available"

**Impact:** Legitimate lock fails

**Recovery:** Consumer can retry with different witnesses

**Residual risk:** If consumer is new or inactive, many retries may be needed

**Mitigation:** Consumer should maintain relationships with diverse peers; network should have good chain propagation; consider allowing consumer to provide their own chain (with verification)

---

### Attack: Witness Bribery at Vote Time

**Description:** Consumer bribes witnesses off-chain to vote ACCEPT for an invalid lock.

**Attacker role:** Consumer + Witnesses

**Sequence:**
1. Consumer has 0 balance but wants to lock 100
2. Consumer bribes 3 witnesses off-chain to vote ACCEPT
3. Bribed witnesses see 0 balance but vote ACCEPT anyway
4. Lock succeeds fraudulently

**Harm:** Provider provides service, will never get paid

**Why provider-driven selection makes this harder:**
- Consumer doesn't know which witnesses will be selected until after committing their nonce
- Consumer can't pre-bribe witnesses before selection
- Would need to bribe witnesses during the short deliberation window
- Provider's witnesses are from provider's network - less likely to know/trust consumer

**Detection:** At settlement, balance won't exist; looking back, witnesses' observed_balance vs actual creates evidence

**On-chain proof:** WITNESS_FINAL_VOTE includes observed_balance; if witness claimed balance that didn't exist, provable

**Defense:**
- Provider-driven selection (consumer doesn't choose witnesses)
- Require observed_balance in vote matches actual chain state
- If settlement fails, examine votes: did witness claim false balance?
- Punish witnesses whose observed_balance claims are proven false
- Stake/bond requirement for witnesses

**Residual risk:** Consumer could still attempt real-time bribery during deliberation, but time window is short and consumer doesn't know witnesses in advance

---

### Attack: Replay Attack on WITNESS_REQUEST

**Description:** Attacker replays an old WITNESS_REQUEST to trigger redundant work.

**Attacker role:** External

**Sequence:**
1. Attacker observes legitimate WITNESS_REQUEST message
2. Later, attacker replays the same message to the same or different witnesses
3. Witnesses do duplicate work

**Harm:** Resource waste; possibly confusion if old lock somehow completes

**Detection:** session_id + timestamp should be unique; witnesses track seen session_ids

**On-chain proof:** None needed if prevented

**Defense:**
- session_id = HASH(consumer + provider + timestamp) ensures uniqueness
- Witnesses STORE seen session_ids, reject duplicates
- Timestamp must be within acceptable window of current time

**Residual risk:** Negligible if defenses implemented

---

### Attack: Provider Impersonation in WITNESS_REQUEST

**Description:** Consumer names fake provider to lock funds, preventing legitimate use.

**Attacker role:** Consumer

**Sequence:**
1. Consumer creates WITNESS_REQUEST naming Provider X (who has no agreement with Consumer)
2. Lock completes, funds locked "for" Provider X
3. Consumer's funds now locked, preventing other legitimate locks
4. (Or: Consumer later claims service wasn't provided, gets refund)

**Harm:** Self-DOS; or fraud if settlement allows consumer to reclaim

**Detection:** Provider X never requested service; settlement requires provider participation

**On-chain proof:** No SERVICE_REQUEST from Provider X; provider.signature missing from settlement

**Defense:**
- Settlement requires both consumer and provider signatures
- Provider must acknowledge escrow exists before providing service
- Locks without provider acknowledgment should auto-expire

**Residual risk:** Funds locked temporarily, reducing consumer's liquidity

---

## Protocol Enhancements Required

Based on the above attack analysis, the following enhancements should be added to the protocol:

### 1. Session ID Deduplication

**Problem:** Replay attacks on WITNESS_REQUEST

**Enhancement:** Witnesses must track seen session_ids and reject duplicates.

### 2. Multi-Source Chain Sync Verification

**Problem:** Single malicious witness can poison chain sync

**Enhancement:** Require chain data from multiple sources, verify consistency.

### 3. Consumer-Provided Chain With Verification

**Problem:** Stale data when no witness has recent chain

**Enhancement:** Allow consumer to include their signed chain in WITNESS_REQUEST.

### 4. Abandonment Rate Tracking

**Problem:** Consumer can DOS witnesses by initiating and abandoning locks

**Enhancement:** Track abandonment ratio per consumer.

### 5. Observed Balance Accountability

**Problem:** Witnesses can claim false observed_balance in votes

**Enhancement:** Make observed_balance claims provable/disprovable.

### 6. Candidate List Verification

**Problem:** Provider could fill candidate list with Sybils

**Enhancement:** Consumer must be able to verify candidate list is reasonable.
