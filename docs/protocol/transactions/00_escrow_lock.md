# Transaction 00: Escrow Lock / Top-up

Lock funds with distributed witness consensus for a compute session. Also handles mid-session top-ups using the same mechanism.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

## Overview

Consumer wants to pay Provider for a service. This transaction locks the funds by distributed witness consensus. Settlement (releasing the funds) is handled by [Transaction 02](02_escrow_settle.md).

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

## Record Types

```
WITNESS_COMMITMENT {
  session_id: hash
  consumer: peer_id
  provider: peer_id
  amount: uint
  observed_balance: uint
  observed_chain_head: hash
  witnesses: [peer_id]
  timestamp: uint
  signatures: [signature]  # multi-signed by witnesses
}

WITNESS_COMMITMENT_EXPIRED {
  session_id: hash
  timestamp: uint
}

LOCK_RESULT {
  session_id: hash
  consumer: peer_id
  provider: peer_id
  amount: uint
  status: ACCEPTED | REJECTED
  observed_balance: uint
  witnesses: [peer_id]
  witness_signatures: [signature]  # multi-signed by witnesses
  consumer_signature: signature    # consumer must counter-sign
  timestamp: uint
}

WITNESS_LIVENESS_CHECK {
  session_id: hash
  checker: peer_id
  timestamp: uint
  signature: bytes
}

WITNESS_LIVENESS_ACK {
  session_id: hash
  witness: peer_id
  timestamp: uint
  signature: bytes
}

WITNESS_REPLACEMENT {
  session_id: hash
  old_witness: peer_id
  new_witness: peer_id
  reason: string  # "offline" | "unresponsive" | "misbehavior"
  remaining_witnesses: [peer_id]
  remaining_signatures: [signature]
  timestamp: uint
}

ESCROW_WITNESS_SET {
  session_id: hash
  current_witnesses: [peer_id]
  witness_signatures: [signature]
  consumer_signature: signature
  timestamp: uint
}

BALANCE_LOCK {
  session_id: hash
  amount: uint
  lock_result_hash: hash
  timestamp: uint
}

BALANCE_TOPUP {
  session_id: hash
  previous_total: uint          # amount locked before this top-up
  topup_amount: uint            # additional amount being locked
  new_total: uint               # previous_total + topup_amount
  topup_result_hash: hash
  timestamp: uint
}
```

---

## Message Types

```
LOCK_INTENT {
  consumer: peer_id
  provider: peer_id
  amount: uint
  session_id: hash
  consumer_nonce: bytes
  provider_chain_checkpoint: hash   # hash of provider's chain from consumer's past keepalive
  checkpoint_timestamp: uint        # when consumer recorded this checkpoint
  timestamp: uint
  signature: bytes
}

WITNESS_SELECTION_COMMITMENT {
  session_id: hash
  provider: peer_id
  provider_nonce: bytes
  provider_chain_segment: bytes     # provider's chain data for consumer to verify
  selection_inputs: {               # all data used in witness selection
    known_peers: [peer_id]
    trust_scores: map[peer_id → float]
    interaction_counts: map[peer_id → uint]
  }
  witnesses: [peer_id]
  timestamp: uint
  signature: bytes
}

LOCK_REJECTED {
  session_id: hash
  reason: string
  timestamp: uint
  signature: bytes
}

WITNESS_REQUEST {
  consumer: peer_id
  provider: peer_id
  amount: uint
  session_id: hash
  my_chain_head: hash
  witnesses: [peer_id]  # full list so witnesses know each other
  timestamp: uint
  signature: bytes
}

WITNESS_PRELIMINARY {
  session_id: hash
  witness: peer_id
  verdict: ACCEPT | REJECT | NEED_MORE_INFO
  observed_balance: uint
  observed_chain_head: hash
  reject_reason: string | null
  timestamp: uint
  signature: bytes
}

WITNESS_CHAIN_SYNC_REQUEST {
  session_id: hash
  consumer: peer_id
  requesting_witness: peer_id
  timestamp: uint
  signature: bytes
}

WITNESS_CHAIN_SYNC_RESPONSE {
  session_id: hash
  consumer: peer_id
  chain_data: bytes  # relevant portion of consumer's chain
  chain_head: hash
  timestamp: uint
  signature: bytes
}

WITNESS_FINAL_VOTE {
  session_id: hash
  witness: peer_id
  vote: ACCEPT | REJECT
  observed_balance: uint
  timestamp: uint
  signature: bytes
}

WITNESS_RECRUIT_REQUEST {
  session_id: hash
  consumer: peer_id
  provider: peer_id
  amount: uint
  existing_witnesses: [peer_id]
  existing_votes: [WITNESS_FINAL_VOTE]
  reason: string  # why more witnesses needed
  timestamp: uint
  signature: bytes
}

LOCK_RESULT_MSG {
  result: LOCK_RESULT
}

BALANCE_UPDATE_BROADCAST {
  consumer: peer_id
  lock_result: LOCK_RESULT
  timestamp: uint
}

LOCK_RESULT_FOR_CONSUMER_SIGNATURE {
  result: LOCK_RESULT  # without consumer_signature filled in yet
}

CONSUMER_SIGNED_LOCK {
  session_id: hash
  consumer_signature: signature
  timestamp: uint
}

# --- Top-up Messages (for mid-session additional funding) ---

TOPUP_INTENT {
  session_id: hash              # existing session
  consumer: peer_id
  additional_amount: uint       # how much MORE to lock
  current_lock_result_hash: hash  # hash of existing LOCK_RESULT
  timestamp: uint
  signature: bytes
}

TOPUP_RESULT {
  session_id: hash
  consumer: peer_id
  provider: peer_id
  previous_total: uint          # amount locked before
  additional_amount: uint       # amount being added
  new_total: uint               # total now locked
  observed_balance: uint        # consumer's balance after this lock
  witnesses: [peer_id]          # same cabal as original lock
  witness_signatures: [signature]
  consumer_signature: signature
  timestamp: uint
}

TOPUP_RESULT_FOR_CONSUMER_SIGNATURE {
  result: TOPUP_RESULT          # without consumer_signature filled in yet
}

CONSUMER_SIGNED_TOPUP {
  session_id: hash
  consumer_signature: signature
  timestamp: uint
}

LIVENESS_PING {
  session_id: hash
  from_witness: peer_id
  timestamp: uint
  signature: bytes
}

LIVENESS_PONG {
  session_id: hash
  from_witness: peer_id
  timestamp: uint
  signature: bytes
}

WITNESS_OFFLINE_ALERT {
  session_id: hash
  reporter: peer_id
  offline_witness: peer_id
  last_seen: uint
  timestamp: uint
  signature: bytes
}

WITNESS_REPLACEMENT_REQUEST {
  session_id: hash
  offline_witness: peer_id
  current_witnesses: [peer_id]
  lock_result: LOCK_RESULT
  timestamp: uint
  signatures: [signature]  # from remaining witnesses
}

WITNESS_REPLACEMENT_ACK {
  session_id: hash
  new_witness: peer_id
  timestamp: uint
  signature: bytes
}
```

---

## Parameters

```
WITNESS_COUNT = 5                    # initial witnesses to recruit
WITNESS_THRESHOLD = 3                # minimum for consensus
WITNESS_COMMITMENT_TIMEOUT = 30      # seconds for provider to respond with witnesses
LOCK_TIMEOUT = 300                   # seconds for consumer to complete lock (provider waiting)
# Note: Checkpoint age is consumer's choice - older = more protection against provider manipulation
CONSENSUS_THRESHOLD = 0.67           # fraction needed to decide
MAX_CHAIN_AGE = 3600                 # seconds - max age of chain knowledge
PRELIMINARY_TIMEOUT = 30             # seconds to collect preliminaries
CONSENSUS_TIMEOUT = 60               # seconds to reach consensus
RECRUITMENT_TIMEOUT = 120            # seconds for full recruitment
MAX_RECRUITMENT_ROUNDS = 3           # max times to recruit more witnesses
MIN_HIGH_TRUST_WITNESSES = 2         # fairness: minimum high-trust witnesses
MAX_PRIOR_INTERACTIONS = 5           # fairness: max prior interactions with consumer
CONSUMER_SIGNATURE_TIMEOUT = 60      # seconds for consumer to counter-sign
LIVENESS_CHECK_INTERVAL = 300        # seconds between liveness checks (5 min)
LIVENESS_RESPONSE_TIMEOUT = 30       # seconds to respond to ping
REPLACEMENT_TIMEOUT = 120            # seconds to get replacement witness ack
ESCROW_LIVENESS_INTERVAL = 600       # seconds for consumer-side liveness check
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

### Step 0: Witness Recruitment with Distributed Consensus

#### ACTOR: Consumer

```
STATES: [IDLE, SENDING_LOCK_INTENT, WAITING_FOR_WITNESS_COMMITMENT, VERIFYING_WITNESSES, SENDING_REQUESTS, WAITING_FOR_RESULT, REVIEWING_RESULT, SIGNING_RESULT, LOCKED, FAILED]

STATE IDLE:
  actions:
    (none)

  on INITIATE_LOCK { provider, amount }:
    - STORE("provider", provider)
    - STORE("amount", amount)
    - STORE("session_id", HASH(my_id + provider + NOW()))
    - STORE("consumer_nonce", RANDOM_BYTES(32))

    - # Find checkpoint: provider's chain hash from before this interaction
    - # Look in our chain for PEER_HASH records for this provider
    - checkpoint = READ(my_chain, "PEER_HASH where peer == provider, before interaction start")
    - IF(checkpoint == NULL) THEN
        - STORE("reject_reason", "no_prior_provider_checkpoint")
        → next_state: FAILED
    - STORE("provider_checkpoint", checkpoint.hash)
    - STORE("checkpoint_timestamp", checkpoint.timestamp)

    → next_state: SENDING_LOCK_INTENT

STATE SENDING_LOCK_INTENT:
  actions:
    - provider = LOAD("provider")
    - intent = LOCK_INTENT {
        consumer: my_id,
        provider: provider,
        amount: LOAD("amount"),
        session_id: LOAD("session_id"),
        consumer_nonce: LOAD("consumer_nonce"),
        provider_chain_checkpoint: LOAD("provider_checkpoint"),
        checkpoint_timestamp: LOAD("checkpoint_timestamp"),
        timestamp: NOW()
      }
    - intent.signature = SIGN(intent)
    - SEND(provider, intent)

  after(0):
    → next_state: WAITING_FOR_WITNESS_COMMITMENT

STATE WAITING_FOR_WITNESS_COMMITMENT:
  actions:
    (none)

  on WITNESS_SELECTION_COMMITMENT from provider:
    - STORE("provider_nonce", message.provider_nonce)
    - STORE("provider_chain_segment", message.provider_chain_segment)
    - STORE("selection_inputs", message.selection_inputs)
    - STORE("proposed_witnesses", message.witnesses)
    → next_state: VERIFYING_PROVIDER_CHAIN

  on LOCK_REJECTED from provider:
    - STORE("reject_reason", message.reason)
    → next_state: FAILED

  after(WITNESS_COMMITMENT_TIMEOUT):
    - STORE("reject_reason", "provider_timeout")
    → next_state: FAILED

STATE VERIFYING_PROVIDER_CHAIN:
  actions:
    - chain_segment = LOAD("provider_chain_segment")
    - checkpoint = LOAD("provider_checkpoint")

    - # Verify chain segment is valid (signatures, hash links)
    - IF(NOT VERIFY_CHAIN_SEGMENT(chain_segment)) THEN
        - STORE("reject_reason", "invalid_chain_segment")
        → next_state: FAILED

    - # Verify our checkpoint exists in the chain
    - IF(NOT CHAIN_CONTAINS_HASH(chain_segment, checkpoint)) THEN
        - STORE("reject_reason", "checkpoint_not_in_chain")
        → next_state: FAILED

    - # Extract chain state at checkpoint
    - chain_state_at_checkpoint = CHAIN_STATE_AT(chain_segment, checkpoint)
    - STORE("verified_chain_state", chain_state_at_checkpoint)

  after(0):
    → next_state: VERIFYING_WITNESSES

STATE VERIFYING_WITNESSES:
  actions:
    - chain_state = LOAD("verified_chain_state")
    - selection_inputs = LOAD("selection_inputs")

    - # Recompute witness selection using verified chain state
    - seed = HASH(LOAD("session_id") + LOAD("provider_nonce") + LOAD("consumer_nonce"))
    - computed_witnesses = SELECT_WITNESSES(
        seed: seed,
        chain_state: chain_state,
        criteria: {
          count: WITNESS_COUNT,
          min_high_trust: MIN_HIGH_TRUST_WITNESSES,
          max_prior_interaction_with: my_id,
          max_interactions: MAX_PRIOR_INTERACTIONS,
          exclude: [my_id, LOAD("provider")]
        }
      )

    - IF(computed_witnesses != LOAD("proposed_witnesses")) THEN
        - STORE("reject_reason", "witness_selection_mismatch")
        → next_state: FAILED

    - # Verify minimum criteria met
    - witnesses = LOAD("proposed_witnesses")
    - IF(LENGTH(witnesses) < WITNESS_THRESHOLD) THEN
        - STORE("reject_reason", "insufficient_witnesses")
        → next_state: FAILED

    - STORE("witnesses", witnesses)

  after(0):
    → next_state: SENDING_REQUESTS

STATE SENDING_REQUESTS:
  actions:
    - witnesses = LOAD("witnesses")
    - request = WITNESS_REQUEST {
        consumer: my_id,
        provider: LOAD("provider"),
        amount: LOAD("amount"),
        session_id: LOAD("session_id"),
        my_chain_head: READ(my_chain, "head_hash"),
        witnesses: witnesses,
        timestamp: NOW()
      }
    - request.signature = SIGN(request)
    - BROADCAST(witnesses, request)

  after(0):
    → next_state: WAITING_FOR_RESULT

STATE WAITING_FOR_RESULT:
  actions:
    (none)

  on LOCK_RESULT_FOR_CONSUMER_SIGNATURE from sender:
    - STORE("pending_result", message.result)
    - STORE("result_sender", sender)
    → next_state: REVIEWING_RESULT

  after(RECRUITMENT_TIMEOUT):
    → next_state: FAILED

STATE REVIEWING_RESULT:
  actions:
    - result = LOAD("pending_result")
    - # Verify this is what we requested
    - IF(result.session_id != LOAD("session_id")) THEN
        - STORE("reject_reason", "session_id_mismatch")
        → next_state: FAILED
    - IF(result.consumer != my_id) THEN
        - STORE("reject_reason", "consumer_mismatch")
        → next_state: FAILED
    - IF(result.amount != LOAD("amount")) THEN
        - STORE("reject_reason", "amount_mismatch")
        → next_state: FAILED
    - IF(result.provider != LOAD("provider")) THEN
        - STORE("reject_reason", "provider_mismatch")
        → next_state: FAILED

    - # Verify witness signatures
    - valid_witness_sigs = 0
    - FOR i, sig in result.witness_signatures:
        - witness = result.witnesses[i]
        - IF(VERIFY_SIG(witness.public_key, result, sig)) THEN
            - valid_witness_sigs = valid_witness_sigs + 1

    - STORE("valid_witness_sigs", valid_witness_sigs)

  after(0):
    - IF(LOAD("valid_witness_sigs") < WITNESS_THRESHOLD) THEN
        - STORE("reject_reason", "insufficient_witness_signatures")
        → next_state: FAILED
    - ELSE
        - IF(LOAD("pending_result").status == "ACCEPTED") THEN
            → next_state: SIGNING_RESULT
        - ELSE
            - # Witnesses rejected - we don't sign, just acknowledge
            - STORE("reject_reason", LOAD("pending_result"))
            → next_state: FAILED

STATE SIGNING_RESULT:
  actions:
    - result = LOAD("pending_result")
    - # Consumer counter-signs to authorize the lock
    - consumer_sig = SIGN(result)
    - result.consumer_signature = consumer_sig
    - STORE("lock_result", result)

    - # Record on my chain
    - APPEND(my_chain, BALANCE_LOCK {
        session_id: result.session_id,
        amount: result.amount,
        lock_result_hash: HASH(result),
        timestamp: NOW()
      })

    - # Send signed result back to witnesses
    - witnesses = LOAD("witnesses")
    - signed_msg = CONSUMER_SIGNED_LOCK {
        session_id: result.session_id,
        consumer_signature: consumer_sig,
        timestamp: NOW()
      }
    - BROADCAST(witnesses, signed_msg)

  after(0):
    → next_state: LOCKED

STATE LOCKED:
  actions:
    (none)
    - # Consumer is now in locked state, proceed to service

  on LIVENESS_PING from witness:
    - # Respond to witness liveness checks
    - pong = LIVENESS_PONG {
        session_id: message.session_id,
        from_witness: my_id,
        timestamp: NOW()
      }
    - pong.signature = SIGN(pong)
    - SEND(witness, pong)
    → next_state: LOCKED

  on WITNESS_REPLACEMENT_REQUEST from witness:
    - # Witnesses are replacing an offline witness
    - # Verify and acknowledge
    - STORE("pending_replacement", message)
    - # Could add validation states here
    → next_state: LOCKED

  after(ESCROW_LIVENESS_INTERVAL):
    - # Periodic check that witnesses are still around
    - # (Could trigger consumer-side liveness checking)
    → next_state: LOCKED

STATE FAILED:
  actions:
    - STORE("witnesses", [])
    - STORE("pending_result", NULL)
    → next_state: IDLE
```

#### ACTOR: Provider (Witness Selection Phase)

```
STATES: [IDLE, VALIDATING_CHECKPOINT, SELECTING_WITNESSES, SENDING_COMMITMENT, WAITING_FOR_LOCK, SERVICE_PHASE]

STATE IDLE:
  actions:
    (none)

  on LOCK_INTENT from consumer:
    - STORE("consumer", consumer)
    - STORE("amount", message.amount)
    - STORE("session_id", message.session_id)
    - STORE("consumer_nonce", message.consumer_nonce)
    - STORE("requested_checkpoint", message.provider_chain_checkpoint)
    - STORE("checkpoint_timestamp", message.checkpoint_timestamp)
    - STORE("provider_nonce", RANDOM_BYTES(32))
    → next_state: VALIDATING_CHECKPOINT

STATE VALIDATING_CHECKPOINT:
  actions:
    - checkpoint = LOAD("requested_checkpoint")

    - # Verify checkpoint exists in our chain
    - IF(NOT CHAIN_CONTAINS_HASH(my_chain, checkpoint)) THEN
        - # Consumer has a hash we don't recognize - reject
        - SEND(LOAD("consumer"), LOCK_REJECTED { reason: "unknown_checkpoint" })
        → next_state: IDLE

    - # Extract chain state at checkpoint
    - # (Checkpoint age is consumer's choice - their protection, not ours)
    - chain_state = CHAIN_STATE_AT(my_chain, checkpoint)
    - STORE("chain_state_at_checkpoint", chain_state)

    - # Extract chain segment to send to consumer for verification
    - chain_segment = CHAIN_SEGMENT(my_chain, from: checkpoint, to: checkpoint)
    - STORE("chain_segment", chain_segment)

  after(0):
    → next_state: SELECTING_WITNESSES

STATE SELECTING_WITNESSES:
  actions:
    - chain_state = LOAD("chain_state_at_checkpoint")

    - # Compute deterministic selection using chain state at checkpoint
    - seed = HASH(LOAD("session_id") + LOAD("provider_nonce") + LOAD("consumer_nonce"))
    - witnesses = SELECT_WITNESSES(
        seed: seed,
        chain_state: chain_state,
        criteria: {
          count: WITNESS_COUNT,
          min_high_trust: MIN_HIGH_TRUST_WITNESSES,
          max_prior_interaction_with: LOAD("consumer"),
          max_interactions: MAX_PRIOR_INTERACTIONS,
          exclude: [my_id, LOAD("consumer")]
        }
      )
    - STORE("witnesses", witnesses)

    - # Capture all inputs used for selection (for consumer verification)
    - selection_inputs = {
        known_peers: chain_state.known_peers,
        trust_scores: chain_state.trust_scores,
        interaction_counts: chain_state.interaction_counts
      }
    - STORE("selection_inputs", selection_inputs)

  after(0):
    → next_state: SENDING_COMMITMENT

STATE SENDING_COMMITMENT:
  actions:
    - consumer = LOAD("consumer")
    - commitment = WITNESS_SELECTION_COMMITMENT {
        session_id: LOAD("session_id"),
        provider: my_id,
        provider_nonce: LOAD("provider_nonce"),
        provider_chain_segment: LOAD("chain_segment"),
        selection_inputs: LOAD("selection_inputs"),
        witnesses: LOAD("witnesses"),
        timestamp: NOW()
      }
    - commitment.signature = SIGN(commitment)
    - SEND(consumer, commitment)

  after(0):
    → next_state: WAITING_FOR_LOCK

STATE WAITING_FOR_LOCK:
  actions:
    (none)

  on BALANCE_UPDATE_BROADCAST from sender:
    - # Check if this is the lock we're waiting for
    - result = message.lock_result
    - IF(result.session_id == LOAD("session_id") AND result.status == "ACCEPTED") THEN
        - STORE("lock_result", result)
        → next_state: SERVICE_PHASE

  after(LOCK_TIMEOUT):
    - # Consumer didn't complete lock
    - STORE("session_id", NULL)
    → next_state: IDLE

STATE SERVICE_PHASE:
  actions:
    (none)
    - # Provider now provides service
    - # Settlement protocol follows (Step 1)
```

---

#### ACTOR: Witness

```
STATES: [
  IDLE,
  CHECKING_CHAIN_KNOWLEDGE,
  REQUESTING_CHAIN_SYNC,
  WAITING_FOR_CHAIN_SYNC,
  CHECKING_BALANCE,
  CHECKING_EXISTING_LOCKS,
  SHARING_PRELIMINARY,
  COLLECTING_PRELIMINARIES,
  EVALUATING_PRELIMINARIES,
  VOTING,
  COLLECTING_VOTES,
  EVALUATING_VOTES,
  RECRUITING_MORE,
  WAITING_FOR_RECRUITS,
  SIGNING_RESULT,
  COLLECTING_SIGNATURES,
  PROPAGATING,
  DONE,
  REJECTED
]

STATE IDLE:
  actions:
    (none)

  on WITNESS_REQUEST from consumer:
    - STORE("request", message)
    - STORE("consumer", consumer)
    - STORE("other_witnesses", REMOVE(message.witnesses, my_id))
    - STORE("preliminaries", [])
    - STORE("votes", [])
    - STORE("signatures", [])
    - STORE("recruitment_round", 0)
    → next_state: CHECKING_CHAIN_KNOWLEDGE

  on WITNESS_RECRUIT_REQUEST from witness:
    - STORE("request", {
        consumer: message.consumer,
        provider: message.provider,
        amount: message.amount,
        session_id: message.session_id,
        witnesses: message.existing_witnesses + [my_id]
      })
    - STORE("consumer", message.consumer)
    - STORE("other_witnesses", message.existing_witnesses)
    - STORE("preliminaries", [])
    - STORE("votes", message.existing_votes)
    - STORE("signatures", [])
    - STORE("recruitment_round", LOAD("recruitment_round") + 1)
    → next_state: CHECKING_CHAIN_KNOWLEDGE

STATE CHECKING_CHAIN_KNOWLEDGE:
  actions:
    - consumer = LOAD("consumer")
    - last_seen = READ(my_chain, "PEER_HASH where peer == consumer, most_recent")
    - STORE("last_seen_record", last_seen)

  after(0):
    - last_seen = LOAD("last_seen_record")
    - IF(last_seen == NULL) THEN
        → next_state: REQUESTING_CHAIN_SYNC
    - ELSE
        - age = NOW() - last_seen.timestamp
        - IF(age > MAX_CHAIN_AGE) THEN
            → next_state: REQUESTING_CHAIN_SYNC
        - ELSE
            → next_state: CHECKING_BALANCE

STATE REQUESTING_CHAIN_SYNC:
  actions:
    - consumer = LOAD("consumer")
    - other_witnesses = LOAD("other_witnesses")
    - sync_request = WITNESS_CHAIN_SYNC_REQUEST {
        session_id: LOAD("request").session_id,
        consumer: consumer,
        requesting_witness: my_id,
        timestamp: NOW()
      }
    - sync_request.signature = SIGN(sync_request)
    - BROADCAST(other_witnesses, sync_request)

  after(0):
    → next_state: WAITING_FOR_CHAIN_SYNC

STATE WAITING_FOR_CHAIN_SYNC:
  actions:
    (none)

  on WITNESS_CHAIN_SYNC_RESPONSE from sender:
    - # Verify and store the chain data
    - STORE("synced_chain_head", message.chain_head)
    - STORE("synced_chain_data", message.chain_data)
    → next_state: CHECKING_BALANCE

  after(PRELIMINARY_TIMEOUT):
    - # No one could help, reject
    - STORE("reject_reason", "no_chain_knowledge_available")
    - STORE("verdict", "REJECT")
    → next_state: SHARING_PRELIMINARY

STATE CHECKING_BALANCE:
  actions:
    - consumer = LOAD("consumer")
    - request = LOAD("request")
    - # Use synced chain if we got one, otherwise our cached version
    - IF(LOAD("synced_chain_data") != NULL) THEN
        - chain_data = LOAD("synced_chain_data")
    - ELSE
        - chain_data = LOAD("cached_chains")[consumer]
    - balance = READ(chain_data, "available_balance")
    - STORE("observed_balance", balance)
    - STORE("observed_chain_head", READ(chain_data, "head_hash"))

  after(0):
    - balance = LOAD("observed_balance")
    - request = LOAD("request")
    - IF(balance < request.amount) THEN
        - STORE("reject_reason", "insufficient_balance")
        - STORE("verdict", "REJECT")
        → next_state: SHARING_PRELIMINARY
    - ELSE
        → next_state: CHECKING_EXISTING_LOCKS

STATE CHECKING_EXISTING_LOCKS:
  actions:
    - consumer = LOAD("consumer")
    - IF(LOAD("synced_chain_data") != NULL) THEN
        - chain_data = LOAD("synced_chain_data")
    - ELSE
        - chain_data = LOAD("cached_chains")[consumer]
    - existing_locks = READ(chain_data, "pending_locks")
    - total_locked = SUM(existing_locks.amounts)
    - STORE("total_locked", total_locked)

  after(0):
    - balance = LOAD("observed_balance")
    - total_locked = LOAD("total_locked")
    - request = LOAD("request")
    - IF(balance - total_locked < request.amount) THEN
        - STORE("reject_reason", "balance_already_locked")
        - STORE("verdict", "REJECT")
    - ELSE
        - STORE("verdict", "ACCEPT")
        - STORE("reject_reason", NULL)
    → next_state: SHARING_PRELIMINARY

STATE SHARING_PRELIMINARY:
  actions:
    - request = LOAD("request")
    - other_witnesses = LOAD("other_witnesses")
    - preliminary = WITNESS_PRELIMINARY {
        session_id: request.session_id,
        witness: my_id,
        verdict: LOAD("verdict"),
        observed_balance: LOAD("observed_balance"),
        observed_chain_head: LOAD("observed_chain_head"),
        reject_reason: LOAD("reject_reason"),
        timestamp: NOW()
      }
    - preliminary.signature = SIGN(preliminary)
    - BROADCAST(other_witnesses, preliminary)
    - # Add own preliminary to collection
    - STORE("preliminaries", [preliminary])

  after(0):
    → next_state: COLLECTING_PRELIMINARIES

STATE COLLECTING_PRELIMINARIES:
  actions:
    (none)

  on WITNESS_PRELIMINARY from sender:
    - prelims = LOAD("preliminaries")
    - STORE("preliminaries", prelims + [message])
    - other_witnesses = LOAD("other_witnesses")
    - IF(LENGTH(prelims) + 1 >= LENGTH(other_witnesses) + 1) THEN
        → next_state: EVALUATING_PRELIMINARIES
    - ELSE
        → next_state: COLLECTING_PRELIMINARIES

  on WITNESS_CHAIN_SYNC_REQUEST from sender:
    - # Another witness needs chain data
    - consumer = LOAD("consumer")
    - IF(LOAD("cached_chains")[consumer] != NULL) THEN
        - response = WITNESS_CHAIN_SYNC_RESPONSE {
            session_id: message.session_id,
            consumer: consumer,
            chain_data: LOAD("cached_chains")[consumer],
            chain_head: READ(LOAD("cached_chains")[consumer], "head_hash"),
            timestamp: NOW()
          }
        - response.signature = SIGN(response)
        - SEND(sender, response)
    → next_state: COLLECTING_PRELIMINARIES

  after(PRELIMINARY_TIMEOUT):
    → next_state: EVALUATING_PRELIMINARIES

STATE EVALUATING_PRELIMINARIES:
  actions:
    - prelims = LOAD("preliminaries")
    - accept_count = COUNT(prelims where verdict == "ACCEPT")
    - reject_count = COUNT(prelims where verdict == "REJECT")
    - total = LENGTH(prelims)

    - # Check if we have enough for consensus
    - IF(accept_count / total >= CONSENSUS_THRESHOLD) THEN
        - STORE("consensus_direction", "ACCEPT")
    - ELSE IF(reject_count / total >= CONSENSUS_THRESHOLD) THEN
        - STORE("consensus_direction", "REJECT")
    - ELSE
        - STORE("consensus_direction", "SPLIT")

    - # Check for balance disagreements
    - balances = [p.observed_balance for p in prelims]
    - IF(MAX(balances) != MIN(balances)) THEN
        - # Witnesses see different balances - need to resolve
        - STORE("balance_disagreement", true)
        - # Use the most recent chain head as authoritative
        - STORE("authoritative_balance", balance from prelim with most recent chain)
    - ELSE
        - STORE("balance_disagreement", false)

  after(0):
    - direction = LOAD("consensus_direction")
    - IF(direction == "SPLIT") THEN
        - IF(LOAD("recruitment_round") < MAX_RECRUITMENT_ROUNDS) THEN
            - IF(LOAD("verdict") == "ACCEPT") THEN
                → next_state: RECRUITING_MORE
            - ELSE
                → next_state: VOTING
        - ELSE
            → next_state: VOTING
    - ELSE
        → next_state: VOTING

STATE RECRUITING_MORE:
  actions:
    - request = LOAD("request")
    - all_witnesses = request.witnesses
    - # Select new witnesses not already involved
    - new_witnesses = SELECT_WITNESSES({
        count: 2,
        exclude: all_witnesses + [request.consumer, request.provider]
      })
    - STORE("recruited_witnesses", new_witnesses)

    - prelims = LOAD("preliminaries")
    - votes_so_far = [WITNESS_FINAL_VOTE from p for p in prelims]

    - recruit_request = WITNESS_RECRUIT_REQUEST {
        session_id: request.session_id,
        consumer: request.consumer,
        provider: request.provider,
        amount: request.amount,
        existing_witnesses: all_witnesses,
        existing_votes: votes_so_far,
        reason: "consensus_split",
        timestamp: NOW()
      }
    - recruit_request.signature = SIGN(recruit_request)
    - BROADCAST(new_witnesses, recruit_request)

    - # Update our witness list
    - STORE("other_witnesses", LOAD("other_witnesses") + new_witnesses)

  after(0):
    → next_state: WAITING_FOR_RECRUITS

STATE WAITING_FOR_RECRUITS:
  actions:
    (none)

  on WITNESS_PRELIMINARY from sender:
    - prelims = LOAD("preliminaries")
    - STORE("preliminaries", prelims + [message])
    → next_state: WAITING_FOR_RECRUITS

  after(PRELIMINARY_TIMEOUT):
    → next_state: EVALUATING_PRELIMINARIES

STATE VOTING:
  actions:
    - request = LOAD("request")
    - other_witnesses = LOAD("other_witnesses")
    - vote = WITNESS_FINAL_VOTE {
        session_id: request.session_id,
        witness: my_id,
        vote: LOAD("verdict"),
        observed_balance: LOAD("observed_balance"),
        timestamp: NOW()
      }
    - vote.signature = SIGN(vote)
    - BROADCAST(other_witnesses, vote)
    - STORE("votes", [vote])

  after(0):
    → next_state: COLLECTING_VOTES

STATE COLLECTING_VOTES:
  actions:
    (none)

  on WITNESS_FINAL_VOTE from sender:
    - votes = LOAD("votes")
    - STORE("votes", votes + [message])
    - other_witnesses = LOAD("other_witnesses")
    - IF(LENGTH(votes) + 1 >= LENGTH(other_witnesses) + 1) THEN
        → next_state: EVALUATING_VOTES
    - ELSE
        → next_state: COLLECTING_VOTES

  after(CONSENSUS_TIMEOUT):
    → next_state: EVALUATING_VOTES

STATE EVALUATING_VOTES:
  actions:
    - votes = LOAD("votes")
    - accept_count = COUNT(votes where vote == "ACCEPT")
    - reject_count = COUNT(votes where vote == "REJECT")
    - total = LENGTH(votes)

    - IF(accept_count >= WITNESS_THRESHOLD AND accept_count / total >= CONSENSUS_THRESHOLD) THEN
        - STORE("final_result", "ACCEPTED")
    - ELSE
        - STORE("final_result", "REJECTED")

  after(0):
    → next_state: SIGNING_RESULT

STATE SIGNING_RESULT:
  actions:
    - request = LOAD("request")
    - votes = LOAD("votes")
    - result = LOCK_RESULT {
        session_id: request.session_id,
        consumer: request.consumer,
        provider: request.provider,
        amount: request.amount,
        status: LOAD("final_result"),
        observed_balance: LOAD("observed_balance"),
        witnesses: [v.witness for v in votes],
        signatures: [],
        timestamp: NOW()
      }
    - my_sig = SIGN(result)
    - result.signatures = [my_sig]
    - STORE("result", result)
    - STORE("signatures", [{witness: my_id, signature: my_sig}])

    - other_witnesses = LOAD("other_witnesses")
    - BROADCAST(other_witnesses, result)

  after(0):
    → next_state: COLLECTING_SIGNATURES

STATE COLLECTING_SIGNATURES:
  actions:
    (none)

  on LOCK_RESULT from sender:
    - # Another witness sharing their signed result
    - sigs = LOAD("signatures")
    - STORE("signatures", sigs + [{witness: sender, signature: message.signatures[-1]}])
    - IF(LENGTH(sigs) + 1 >= WITNESS_THRESHOLD) THEN
        → next_state: PROPAGATING
    - ELSE
        → next_state: COLLECTING_SIGNATURES

  after(CONSENSUS_TIMEOUT):
    - IF(LENGTH(LOAD("signatures")) >= WITNESS_THRESHOLD) THEN
        → next_state: PROPAGATING
    - ELSE
        → next_state: DONE  # couldn't get enough signatures, but we tried

STATE PROPAGATING:
  actions:
    - result = LOAD("result")
    - sigs = LOAD("signatures")
    - result.witness_signatures = [s.signature for s in sigs]
    - STORE("result", result)

    - # Send to consumer for counter-signature (not final yet!)
    - consumer = LOAD("consumer")
    - SEND(consumer, LOCK_RESULT_FOR_CONSUMER_SIGNATURE { result: result })

  after(0):
    → next_state: WAITING_FOR_CONSUMER_SIGNATURE

STATE WAITING_FOR_CONSUMER_SIGNATURE:
  actions:
    (none)

  on CONSUMER_SIGNED_LOCK from consumer:
    - result = LOAD("result")
    - # Verify consumer signature
    - IF(VERIFY_SIG(consumer.public_key, result, message.consumer_signature)) THEN
        - result.consumer_signature = message.consumer_signature
        - STORE("result", result)
        → next_state: FINALIZING
    - ELSE
        - # Invalid signature, stay waiting
        → next_state: WAITING_FOR_CONSUMER_SIGNATURE

  after(CONSUMER_SIGNATURE_TIMEOUT):
    - # Consumer didn't sign - lock fails
    - STORE("final_result", "CONSUMER_ABANDONED")
    → next_state: DONE

STATE FINALIZING:
  actions:
    - result = LOAD("result")

    - # NOW record on my chain (with consumer signature)
    - APPEND(my_chain, WITNESS_COMMITMENT {
        session_id: result.session_id,
        consumer: result.consumer,
        provider: result.provider,
        amount: result.amount,
        observed_balance: result.observed_balance,
        observed_chain_head: LOAD("observed_chain_head"),
        witnesses: result.witnesses,
        timestamp: NOW(),
        witness_signatures: result.witness_signatures,
        consumer_signature: result.consumer_signature
      })

    - # Broadcast to network for balance update
    - network_peers = LOAD("known_peers")
    - update = BALANCE_UPDATE_BROADCAST {
        consumer: result.consumer,
        lock_result: result,
        timestamp: NOW()
      }
    - BROADCAST(network_peers, update)

    - # Notify other witnesses that we're finalized
    - other_witnesses = LOAD("other_witnesses")
    - BROADCAST(other_witnesses, CONSUMER_SIGNED_LOCK {
        session_id: result.session_id,
        consumer_signature: result.consumer_signature,
        timestamp: NOW()
      })

  after(0):
    → next_state: ESCROW_ACTIVE

STATE ESCROW_ACTIVE:
  actions:
    (none)
    - # Escrow is locked, waiting for service completion
    - # Must maintain liveness with other witnesses

  on LIVENESS_PING from witness:
    - pong = LIVENESS_PONG {
        session_id: LOAD("result").session_id,
        from_witness: my_id,
        timestamp: NOW()
      }
    - pong.signature = SIGN(pong)
    - SEND(witness, pong)
    → next_state: ESCROW_ACTIVE

  on LIVENESS_PONG from witness:
    - # Record that witness is alive
    - alive_witnesses = LOAD("alive_witnesses") or {}
    - alive_witnesses[witness] = NOW()
    - STORE("alive_witnesses", alive_witnesses)
    → next_state: ESCROW_ACTIVE

  on WITNESS_OFFLINE_ALERT from witness:
    - STORE("offline_alert", message)
    → next_state: CHECKING_OFFLINE_WITNESS

  on SETTLEMENT_REQUEST from consumer_or_provider:
    - # Service complete, time to settle
    - STORE("settlement_request", message)
    → next_state: (Settlement states - Step 1)

  after(LIVENESS_CHECK_INTERVAL):
    → next_state: SENDING_LIVENESS_PINGS

STATE SENDING_LIVENESS_PINGS:
  actions:
    - session_id = LOAD("result").session_id
    - other_witnesses = LOAD("other_witnesses")
    - ping = LIVENESS_PING {
        session_id: session_id,
        from_witness: my_id,
        timestamp: NOW()
      }
    - ping.signature = SIGN(ping)
    - BROADCAST(other_witnesses, ping)
    - STORE("ping_sent_at", NOW())
    - STORE("expected_pongs", other_witnesses)

  after(0):
    → next_state: COLLECTING_LIVENESS_PONGS

STATE COLLECTING_LIVENESS_PONGS:
  actions:
    (none)

  on LIVENESS_PONG from witness:
    - alive_witnesses = LOAD("alive_witnesses") or {}
    - alive_witnesses[witness] = NOW()
    - STORE("alive_witnesses", alive_witnesses)
    - expected = LOAD("expected_pongs")
    - STORE("expected_pongs", REMOVE(expected, witness))
    → next_state: COLLECTING_LIVENESS_PONGS

  on LIVENESS_PING from witness:
    - # Respond while also collecting
    - pong = LIVENESS_PONG {
        session_id: LOAD("result").session_id,
        from_witness: my_id,
        timestamp: NOW()
      }
    - pong.signature = SIGN(pong)
    - SEND(witness, pong)
    → next_state: COLLECTING_LIVENESS_PONGS

  after(LIVENESS_RESPONSE_TIMEOUT):
    → next_state: EVALUATING_LIVENESS

STATE EVALUATING_LIVENESS:
  actions:
    - expected = LOAD("expected_pongs")
    - # Anyone still in expected_pongs didn't respond
    - IF(LENGTH(expected) > 0) THEN
        - STORE("unresponsive_witnesses", expected)
        → next_state: REPORTING_OFFLINE_WITNESS
    - ELSE
        → next_state: ESCROW_ACTIVE

  after(0):
    → next_state: ESCROW_ACTIVE

STATE REPORTING_OFFLINE_WITNESS:
  actions:
    - unresponsive = LOAD("unresponsive_witnesses")
    - other_witnesses = LOAD("other_witnesses")
    - FOR offline_witness in unresponsive:
        - alert = WITNESS_OFFLINE_ALERT {
            session_id: LOAD("result").session_id,
            reporter: my_id,
            offline_witness: offline_witness,
            last_seen: LOAD("alive_witnesses")[offline_witness] or 0,
            timestamp: NOW()
          }
        - alert.signature = SIGN(alert)
        - responsive_witnesses = REMOVE(other_witnesses, unresponsive)
        - BROADCAST(responsive_witnesses, alert)

  after(0):
    → next_state: CHECKING_OFFLINE_WITNESS

STATE CHECKING_OFFLINE_WITNESS:
  actions:
    - # Verify we also can't reach the allegedly offline witness
    - alert = LOAD("offline_alert")
    - IF(alert == NULL) THEN
        - alert = { offline_witness: LOAD("unresponsive_witnesses")[0] }
    - offline = alert.offline_witness
    - ping = LIVENESS_PING {
        session_id: LOAD("result").session_id,
        from_witness: my_id,
        timestamp: NOW()
      }
    - ping.signature = SIGN(ping)
    - SEND(offline, ping)
    - STORE("checking_witness", offline)

  after(LIVENESS_RESPONSE_TIMEOUT):
    - # Confirmed offline, need to replace
    → next_state: INITIATING_WITNESS_REPLACEMENT

  on LIVENESS_PONG from witness:
    - IF(witness == LOAD("checking_witness")) THEN
        - # They're actually alive, false alarm
        - STORE("offline_alert", NULL)
        → next_state: ESCROW_ACTIVE
    - ELSE
        → next_state: CHECKING_OFFLINE_WITNESS

STATE INITIATING_WITNESS_REPLACEMENT:
  actions:
    - offline = LOAD("checking_witness")
    - result = LOAD("result")
    - other_witnesses = LOAD("other_witnesses")
    - current_witnesses = REMOVE(result.witnesses, offline)

    - # Select replacement witness
    - new_witness = SELECT_WITNESSES({
        count: 1,
        exclude: result.witnesses + [result.consumer, result.provider]
      })[0]

    - replacement_req = WITNESS_REPLACEMENT_REQUEST {
        session_id: result.session_id,
        offline_witness: offline,
        current_witnesses: current_witnesses,
        lock_result: result,
        timestamp: NOW()
      }
    - replacement_req.signature = SIGN(replacement_req)

    - SEND(new_witness, replacement_req)
    - STORE("pending_replacement", new_witness)

  after(0):
    → next_state: WAITING_FOR_REPLACEMENT_ACK

STATE WAITING_FOR_REPLACEMENT_ACK:
  actions:
    (none)

  on WITNESS_REPLACEMENT_ACK from witness:
    - IF(witness == LOAD("pending_replacement")) THEN
        - # Update our witness list
        - offline = LOAD("checking_witness")
        - other_witnesses = LOAD("other_witnesses")
        - new_witnesses = REMOVE(other_witnesses, offline) + [witness]
        - STORE("other_witnesses", new_witnesses)

        - # Record replacement on chain
        - APPEND(my_chain, WITNESS_REPLACEMENT {
            session_id: LOAD("result").session_id,
            old_witness: offline,
            new_witness: witness,
            reason: "offline",
            remaining_witnesses: new_witnesses + [my_id],
            timestamp: NOW()
          })

        → next_state: ESCROW_ACTIVE
    - ELSE
        → next_state: WAITING_FOR_REPLACEMENT_ACK

  after(REPLACEMENT_TIMEOUT):
    - # Try another witness
    → next_state: INITIATING_WITNESS_REPLACEMENT

STATE DONE:
  actions:
    - STORE("request", NULL)
    - STORE("consumer", NULL)
    - STORE("other_witnesses", [])
    - STORE("preliminaries", [])
    - STORE("votes", [])
    - STORE("signatures", [])
    - STORE("result", NULL)
    → next_state: IDLE

STATE REJECTED:
  actions:
    - # This state is for when witness decides to not participate at all
    - # Different from voting REJECT
    - STORE("request", NULL)
    - STORE("consumer", NULL)
    → next_state: IDLE
```

#### ACTOR: Network Peer (Uninvolved)

```
STATES: [IDLE, PROCESSING_UPDATE]

STATE IDLE:
  actions:
    (none)

  on BALANCE_UPDATE_BROADCAST from sender:
    - STORE("pending_update", message)
    → next_state: PROCESSING_UPDATE

STATE PROCESSING_UPDATE:
  actions:
    - update = LOAD("pending_update")
    - result = update.lock_result

    - # Verify signatures
    - valid_sigs = 0
    - FOR sig in result.signatures:
        - witness = result.witnesses[sig_index]
        - IF(VERIFY_SIG(witness.public_key, result, sig)) THEN
            - valid_sigs = valid_sigs + 1

    - IF(valid_sigs >= WITNESS_THRESHOLD) THEN
        - # Update our cached view of consumer's balance
        - cached = LOAD("cached_chains")[result.consumer]
        - IF(result.status == "ACCEPTED") THEN
            - cached.pending_locks = cached.pending_locks + [{
                session_id: result.session_id,
                amount: result.amount
              }]
        - STORE("cached_chains")[result.consumer] = cached

        - # Optionally record that we saw this
        - APPEND(my_chain, PEER_HASH {
            peer: result.consumer,
            hash: HASH(result),
            timestamp: NOW()
          })

  after(0):
    → next_state: IDLE
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

### Top-up State Machine (Consumer)

```
STATES: [ACTIVE_SESSION, SENDING_TOPUP, WAITING_FOR_TOPUP_RESULT, SIGNING_TOPUP, TOPUP_COMPLETE]

STATE ACTIVE_SESSION:
  # Consumer has locked funds, session is running

  on NEED_TOPUP { additional_amount }:
    - STORE("additional_amount", additional_amount)
    - STORE("current_lock_hash", HASH(current_lock_result))
    → next_state: SENDING_TOPUP

STATE SENDING_TOPUP:
  actions:
    - intent = TOPUP_INTENT {
        session_id: LOAD("session_id"),
        consumer: my_id,
        additional_amount: LOAD("additional_amount"),
        current_lock_result_hash: LOAD("current_lock_hash"),
        timestamp: NOW()
      }
    - intent.signature = SIGN(intent)
    - witnesses = LOAD("witnesses")
    - BROADCAST(witnesses, intent)
  → next_state: WAITING_FOR_TOPUP_RESULT

STATE WAITING_FOR_TOPUP_RESULT:
  on TOPUP_RESULT_FOR_CONSUMER_SIGNATURE from Witness:
    - STORE("pending_topup_result", message.result)
    → next_state: SIGNING_TOPUP

  after(CONSENSUS_TIMEOUT):
    - # Top-up failed, session continues with current escrow
    → next_state: ACTIVE_SESSION

STATE SIGNING_TOPUP:
  actions:
    - result = LOAD("pending_topup_result")
    - # Verify result matches what we requested
    - IF(result.additional_amount != LOAD("additional_amount")) THEN
        → next_state: ACTIVE_SESSION  # Reject
    - result.consumer_signature = SIGN(result)
    - APPEND(my_chain, BALANCE_TOPUP from result)
    - BROADCAST(witnesses, CONSUMER_SIGNED_TOPUP)
  → next_state: TOPUP_COMPLETE

STATE TOPUP_COMPLETE:
  actions:
    - # Update local tracking of total escrowed
    - new_total = LOAD("total_escrowed") + LOAD("additional_amount")
    - STORE("total_escrowed", new_total)
  → next_state: ACTIVE_SESSION
```

### Top-up State Machine (Witness)

```
STATES: [ESCROW_ACTIVE, CHECKING_TOPUP_BALANCE, VOTING_TOPUP, PROPAGATING_TOPUP]

STATE ESCROW_ACTIVE:
  # Witness has active escrow commitment

  on TOPUP_INTENT from Consumer:
    - STORE("topup_intent", message)
    → next_state: CHECKING_TOPUP_BALANCE

STATE CHECKING_TOPUP_BALANCE:
  actions:
    - consumer = LOAD("consumer")
    - additional = LOAD("topup_intent").additional_amount
    - current_locked = LOAD("total_escrowed")

    - # Check consumer has sufficient FREE balance (not counting locked)
    - balance = READ(consumer_chain_cache, "balance")
    - free_balance = balance - current_locked
    - IF(free_balance < additional) THEN
        - STORE("topup_verdict", REJECT)
    - ELSE
        - STORE("topup_verdict", ACCEPT)
        - STORE("observed_balance", balance)

  → next_state: VOTING_TOPUP

STATE VOTING_TOPUP:
  actions:
    - # Similar to initial lock voting
    - # Exchange votes with other witnesses
    - # Reach consensus
  → next_state: PROPAGATING_TOPUP

STATE PROPAGATING_TOPUP:
  actions:
    - # Create TOPUP_RESULT with multi-sig
    - # Send to consumer for counter-signature
  → next_state: ESCROW_ACTIVE
```

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

### Attack: Provider Witness Selection Manipulation (NEW)

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

## Protocol Enhancements Required (from Attack Analysis)

Based on the above attack analysis, the following enhancements should be added to the protocol:

### 1. Session ID Deduplication

**Problem:** Replay attacks on WITNESS_REQUEST

**Enhancement:** Witnesses must track seen session_ids and reject duplicates.

```
# Add to Witness local state
seen_session_ids: Set[hash]

# Add to CHECKING_CHAIN_KNOWLEDGE state:
- IF(LOAD("request").session_id IN LOAD("seen_session_ids")) THEN
    → next_state: REJECTED
- STORE("seen_session_ids", LOAD("seen_session_ids") + [session_id])
```

### 2. Multi-Source Chain Sync Verification

**Problem:** Single malicious witness can poison chain sync

**Enhancement:** Require chain data from multiple sources, verify consistency.

```
# Modify WAITING_FOR_CHAIN_SYNC:
- Collect responses from multiple witnesses
- Verify chain heads match (or take majority)
- If consumer signed their chain, verify signature
```

### 3. Consumer-Provided Chain With Verification

**Problem:** Stale data when no witness has recent chain

**Enhancement:** Allow consumer to include their signed chain in WITNESS_REQUEST.

```
# Extend WITNESS_REQUEST message:
WITNESS_REQUEST {
  ...
  consumer_chain: bytes | null  # Optional: consumer's signed chain
  consumer_chain_signature: signature | null
}

# Witnesses verify consumer signature before trusting
```

### 4. Abandonment Rate Tracking

**Problem:** Consumer can DOS witnesses by initiating and abandoning locks

**Enhancement:** Track abandonment ratio per consumer.

```
# New record type:
LOCK_ABANDONED {
  session_id: hash
  consumer: peer_id
  witnesses: [peer_id]
  timestamp: uint
}

# Witnesses check consumer's abandonment history before accepting
```

### 5. Observed Balance Accountability

**Problem:** Witnesses can claim false observed_balance in votes

**Enhancement:** Make observed_balance claims provable/disprovable.

```
# Require witnesses to include chain hash with observed_balance
# At settlement, if claimed balance provably false:
#   - Witness loses stake/bond
#   - Witness trust severely damaged
```

### ~~6. Provider Acknowledgment Requirement~~ ✓ ADDRESSED

**Problem:** Consumer can lock funds for unwitting provider

**Solution:** Provider-driven witness selection inherently requires provider participation. Provider receives LOCK_INTENT, selects witnesses, and commits. Lock cannot proceed without provider's active involvement.

### 7. Candidate List Verification (NEW)

**Problem:** Provider could fill candidate list with Sybils

**Enhancement:** Consumer must be able to verify candidate list is reasonable.

```
# Consumer verification in VERIFYING_WITNESSES:
- Check that candidate list includes at least N peers consumer recognizes
- Check diversity: candidates from multiple trust clusters
- Check minimum trust levels in candidate list
- Optionally: require some candidates from a "public pool" of well-known witnesses
```

---

## Next Steps

- [ ] Implement the protocol enhancements identified above
- [ ] Design Step 1: Settlement/Release protocol with distributed witness consensus
- [ ] Attack analysis for Step 1
- [ ] Design other transaction types (age verification, balance transfer, etc.)
