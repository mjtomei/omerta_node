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

```omt
parameters (
    # Witness counts
    WITNESS_COUNT = 5 count "Initial witnesses to recruit"
    WITNESS_THRESHOLD = 3 count "Minimum for consensus"

    # Timeouts (seconds)
    WITNESS_COMMITMENT_TIMEOUT = 30 seconds "Seconds for provider to respond with witnesses"
    LOCK_TIMEOUT = 300 seconds "Seconds for consumer to complete lock (provider waiting)"
    PRELIMINARY_TIMEOUT = 30 seconds "Seconds to collect preliminaries"
    CONSENSUS_TIMEOUT = 60 seconds "Seconds to reach consensus"
    RECRUITMENT_TIMEOUT = 180 seconds "Seconds for full recruitment"
    CONSUMER_SIGNATURE_TIMEOUT = 60 seconds "Seconds for consumer to counter-sign"
    LIVENESS_CHECK_INTERVAL = 300 seconds "Seconds between liveness checks"
    LIVENESS_RESPONSE_TIMEOUT = 30 seconds "Seconds to respond to ping"
    REPLACEMENT_TIMEOUT = 120 seconds "Seconds to get replacement witness ack"
    MAX_CHAIN_AGE = 3600 seconds "Max age of chain knowledge"

    # Thresholds
    CONSENSUS_THRESHOLD = 0.67 fraction "Fraction needed to decide"

    # Limits
    MAX_RECRUITMENT_ROUNDS = 3 count "Max times to recruit more witnesses"
    MIN_HIGH_TRUST_WITNESSES = 2 count "Minimum high-trust witnesses for fairness"
    MAX_PRIOR_INTERACTIONS = 5 count "Max prior interactions with consumer for fairness"
    HIGH_TRUST_THRESHOLD = 1.0 fraction "Trust score threshold for high-trust classification"
)
```

---

## Block Types (Chain Records)

```omt
block BALANCE_LOCK by [Consumer, Witness] (
    session_id       hash
    amount           uint
    lock_result_hash hash
    timestamp        timestamp
)

block BALANCE_TOPUP by [Consumer, Witness] (
    session_id       hash
    previous_total   uint
    topup_amount     uint
    new_total        uint
    topup_result_hash hash
    timestamp        timestamp
)

block WITNESS_COMMITMENT by [Witness] (
    session_id       hash
    consumer         peer_id
    provider         peer_id
    amount           uint
    observed_balance uint
    witnesses        list<peer_id>
    timestamp        timestamp
)

block WITNESS_REPLACEMENT by [Witness] (
    session_id          hash
    old_witness         peer_id
    new_witness         peer_id
    reason              string
    remaining_witnesses list<peer_id>
    timestamp           timestamp
)
```

---

## Message Types

```omt
# --- Consumer -> Provider ---
message LOCK_INTENT from Consumer to [Provider] signed (
    consumer                   peer_id
    provider                   peer_id
    amount                     uint
    session_id                 hash
    consumer_nonce             bytes
    provider_chain_checkpoint  hash
    checkpoint_timestamp       timestamp
    timestamp                  timestamp
)

# --- Provider -> Consumer ---
message WITNESS_SELECTION_COMMITMENT from Provider to [Consumer] signed (
    session_id             hash
    provider               peer_id
    provider_nonce         bytes
    provider_chain_segment bytes
    selection_inputs       SelectionInputs
    witnesses              list<peer_id>
    timestamp              timestamp
)

message LOCK_REJECTED from Provider to [Consumer] signed (
    session_id  hash
    reason      string
    timestamp   timestamp
)

# --- Consumer -> Witnesses ---
message WITNESS_REQUEST from Consumer to [Witness] signed (
    consumer      peer_id
    provider      peer_id
    amount        uint
    session_id    hash
    my_chain_head hash
    witnesses     list<peer_id>
    timestamp     timestamp
)

message CONSUMER_SIGNED_LOCK from Consumer to [Witness] (
    session_id         hash
    consumer_signature signature
    timestamp          timestamp
)

# --- Witness <-> Witness ---
message WITNESS_PRELIMINARY from Witness to [Witness] signed (
    session_id          hash
    witness             peer_id
    verdict             WitnessVerdict
    observed_balance    uint
    observed_chain_head hash
    reject_reason       string
    timestamp           timestamp
)

message WITNESS_CHAIN_SYNC_REQUEST from Witness to [Witness] signed (
    session_id          hash
    consumer            peer_id
    requesting_witness  peer_id
    timestamp           timestamp
)

message WITNESS_CHAIN_SYNC_RESPONSE from Witness to [Witness] signed (
    session_id  hash
    consumer    peer_id
    chain_data  bytes
    chain_head  hash
    timestamp   timestamp
)

message WITNESS_FINAL_VOTE from Witness to [Witness] signed (
    session_id       hash
    witness          peer_id
    vote             WitnessVerdict
    observed_balance uint
    timestamp        timestamp
)

message WITNESS_RECRUIT_REQUEST from Witness to [Witness] signed (
    session_id         hash
    consumer           peer_id
    provider           peer_id
    amount             uint
    existing_witnesses list<peer_id>
    existing_votes     list<WITNESS_FINAL_VOTE>
    reason             string
    timestamp          timestamp
)

# --- Witness -> Consumer ---
message LOCK_RESULT_FOR_SIGNATURE from Witness to [Consumer] (
    result  LockResult
)

# --- Witness -> Network ---
message BALANCE_UPDATE_BROADCAST from Witness to [Network] (
    consumer     peer_id
    lock_result  LockResult
    timestamp    timestamp
)

# --- Liveness ---
message LIVENESS_PING from Witness to [Witness, Consumer] signed (
    session_id    hash
    from_witness  peer_id
    timestamp     timestamp
)

message LIVENESS_PONG from Witness to [Witness] signed (
    session_id    hash
    from_witness  peer_id
    timestamp     timestamp
)

# --- Top-up ---
message TOPUP_INTENT from Consumer to [Witness] signed (
    session_id               hash
    consumer                 peer_id
    additional_amount        uint
    current_lock_result_hash hash
    timestamp                timestamp
)

message TOPUP_RESULT_FOR_SIGNATURE from Witness to [Consumer] (
    topup_result  TopUpResult
)

message CONSUMER_SIGNED_TOPUP from Consumer to [Witness] (
    session_id         hash
    consumer_signature signature
    timestamp          timestamp
)

message TOPUP_VOTE from Witness to [Witness] signed (
    session_id        hash
    witness           peer_id
    vote              WitnessVerdict
    additional_amount uint
    observed_balance  uint
    timestamp         timestamp
)
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

## State Machines

### Actor: Consumer

```omt
actor Consumer "Party paying for service" (
    store (
        provider                 peer_id
        amount                   uint
        session_id               hash
        consumer_nonce           bytes
        provider_chain_checkpoint hash
        checkpoint_timestamp     timestamp
        provider_nonce           bytes
        provider_chain_segment   bytes
        selection_inputs         SelectionInputs
        proposed_witnesses       list<peer_id>
        verified_chain_state     ChainState
        witnesses                list<peer_id>
        intent_sent_at           timestamp
        requests_sent_at         timestamp
        pending_result           LockResult
        result_sender            peer_id
        lock_result              LockResult
        reject_reason            string
        total_escrowed           uint
        additional_amount        uint
        current_lock_hash        hash
        topup_sent_at            timestamp
        pending_topup_result     TopUpResult
        topup_result             TopUpResult
        topup_failed_reason      string
    )

    trigger initiate_lock(provider peer_id, amount uint) in [IDLE] "Start a new escrow lock"
    trigger initiate_topup(additional_amount uint) in [LOCKED] "Add funds to existing escrow"

    state IDLE initial "Waiting to initiate lock"
    state SENDING_LOCK_INTENT "Sending lock intent to provider"
    state WAITING_FOR_WITNESS_COMMITMENT "Waiting for provider witness selection"
    state VERIFYING_PROVIDER_CHAIN "Verifying provider's chain segment"
    state VERIFYING_WITNESSES "Verifying witness selection is correct"
    state SENDING_REQUESTS "Sending requests to witnesses"
    state WAITING_FOR_RESULT "Waiting for witness consensus"
    state REVIEWING_RESULT "Reviewing lock result"
    state SIGNING_RESULT "Counter-signing the lock"
    state LOCKED "Funds successfully locked"
    state FAILED terminal "Lock failed"
    state SENDING_TOPUP "Sending top-up request"
    state WAITING_FOR_TOPUP_RESULT "Waiting for cabal top-up consensus"
    state REVIEWING_TOPUP_RESULT "Reviewing top-up result"
    state SIGNING_TOPUP "Counter-signing top-up"

    # Initial lock flow
    IDLE -> SENDING_LOCK_INTENT on initiate_lock when provider_chain_checkpoint != null (
        store provider, amount
        STORE(consumer, peer_id)
        session_id = HASH(peer_id + provider + NOW())
        consumer_nonce = RANDOM_BYTES(32)
        provider_chain_checkpoint = READ(provider, "head_hash")
    ) else -> FAILED (
        store provider, amount
        STORE(consumer, peer_id)
        STORE(reject_reason, "no_prior_provider_checkpoint")
    )

    SENDING_LOCK_INTENT -> WAITING_FOR_WITNESS_COMMITMENT auto (
        SEND(provider, LOCK_INTENT)
        STORE(intent_sent_at, NOW())
    )

    WAITING_FOR_WITNESS_COMMITMENT -> VERIFYING_PROVIDER_CHAIN on WITNESS_SELECTION_COMMITMENT (
        store provider_nonce, provider_chain_segment, selection_inputs
        STORE(proposed_witnesses, message.witnesses)
        chain_segment_valid_and_contains_checkpoint = VERIFY_CHAIN_SEGMENT(provider_chain_segment) AND CHAIN_CONTAINS_HASH(provider_chain_segment, provider_chain_checkpoint)
    )

    WAITING_FOR_WITNESS_COMMITMENT -> FAILED on LOCK_REJECTED (
        STORE(reject_reason, message.reason)
    )

    WAITING_FOR_WITNESS_COMMITMENT -> FAILED on timeout(WITNESS_COMMITMENT_TIMEOUT) (
        STORE(reject_reason, "provider_timeout")
    )

    VERIFYING_PROVIDER_CHAIN -> VERIFYING_WITNESSES auto when chain_segment_valid_and_contains_checkpoint (
        verified_chain_state = CHAIN_STATE_AT(provider_chain_segment, provider_chain_checkpoint)
        witness_selection_valid = VERIFY_WITNESS_SELECTION(proposed_witnesses, selection_inputs, session_id, provider_nonce, consumer_nonce)
    )

    VERIFYING_WITNESSES -> SENDING_REQUESTS auto when witness_selection_valid (
        STORE(witnesses, proposed_witnesses)
    )

    SENDING_REQUESTS -> WAITING_FOR_RESULT auto (
        BROADCAST(witnesses, WITNESS_REQUEST)
        STORE(requests_sent_at, NOW())
    )

    WAITING_FOR_RESULT -> REVIEWING_RESULT on LOCK_RESULT_FOR_SIGNATURE (
        STORE(pending_result, message.result)
        STORE(result_sender, message.sender)
        result_valid_and_accepted = VALIDATE_LOCK_RESULT(pending_result, session_id, amount)
    )

    WAITING_FOR_RESULT -> FAILED on timeout(RECRUITMENT_TIMEOUT) (
        STORE(reject_reason, "witness_timeout")
    )

    REVIEWING_RESULT -> SIGNING_RESULT auto when result_valid_and_accepted

    REVIEWING_RESULT -> FAILED auto when NOT result_valid_and_accepted (
        STORE(reject_reason, "lock_rejected")
    )

    SIGNING_RESULT -> LOCKED auto (
        consumer_signature = SIGN(pending_result)
        STORE(lock_result, {...pending_result, consumer_signature consumer_signature})
        APPEND(chain, BALANCE_LOCK)
        BROADCAST(witnesses, CONSUMER_SIGNED_LOCK)
        STORE(total_escrowed, amount)
    )

    # Locked state transitions
    LOCKED -> LOCKED on LIVENESS_PING (
        STORE(from_witness, peer_id)
        SEND(message.sender, LIVENESS_PONG)
    )

    LOCKED -> SENDING_TOPUP on initiate_topup (
        store additional_amount
        current_lock_hash = HASH(lock_result)
    )

    # Top-up flow
    SENDING_TOPUP -> WAITING_FOR_TOPUP_RESULT auto (
        BROADCAST(witnesses, TOPUP_INTENT)
        STORE(topup_sent_at, NOW())
    )

    WAITING_FOR_TOPUP_RESULT -> REVIEWING_TOPUP_RESULT on TOPUP_RESULT_FOR_SIGNATURE (
        STORE(pending_topup_result, message.topup_result)
        topup_result_valid = VALIDATE_TOPUP_RESULT(pending_topup_result, session_id, additional_amount)
    )

    WAITING_FOR_TOPUP_RESULT -> LOCKED on timeout(CONSENSUS_TIMEOUT) (
        STORE(topup_failed_reason, "timeout")
    )

    REVIEWING_TOPUP_RESULT -> SIGNING_TOPUP auto when topup_result_valid

    SIGNING_TOPUP -> LOCKED auto (
        consumer_signature = SIGN(pending_topup_result)
        STORE(topup_result, {...pending_topup_result, consumer_signature consumer_signature})
        APPEND(chain, BALANCE_TOPUP)
        BROADCAST(witnesses, CONSUMER_SIGNED_TOPUP)
        STORE(total_escrowed, total_escrowed + additional_amount)
    )
)
```

### Actor: Provider

```omt
actor Provider "Party providing service, selects witnesses" (
    store (
        consumer                   peer_id
        amount                     uint
        session_id                 hash
        consumer_nonce             bytes
        provider_nonce             bytes
        requested_checkpoint       hash
        checkpoint_timestamp       timestamp
        chain_state_at_checkpoint  ChainState
        provider_chain_segment     bytes
        witnesses                  list<peer_id>
        selection_inputs           SelectionInputs
        commitment_sent_at         timestamp
        lock_result                LockResult
        reason                     string
    )

    state IDLE initial "Waiting for lock request"
    state VALIDATING_CHECKPOINT "Validating consumer's checkpoint reference"
    state SENDING_REJECTION "Sending rejection due to invalid checkpoint"
    state SELECTING_WITNESSES "Computing deterministic witness selection"
    state SENDING_COMMITMENT "Sending witness selection to consumer"
    state WAITING_FOR_LOCK "Waiting for lock to complete"
    state SERVICE_PHASE terminal "Lock complete, providing service"

    IDLE -> VALIDATING_CHECKPOINT on LOCK_INTENT (
        store consumer, amount, session_id, consumer_nonce
        STORE(requested_checkpoint, message.provider_chain_checkpoint)
        provider_nonce = RANDOM_BYTES(32)
    )

    VALIDATING_CHECKPOINT -> SELECTING_WITNESSES auto when CHAIN_CONTAINS_HASH(chain, requested_checkpoint) (
        chain_state_at_checkpoint = CHAIN_STATE_AT(chain, requested_checkpoint)
        provider_chain_segment = CHAIN_SEGMENT(chain, requested_checkpoint)
    ) else -> SENDING_REJECTION (
        STORE(reason, "unknown_checkpoint")
    )

    SENDING_REJECTION -> IDLE auto (
        SEND(consumer, LOCK_REJECTED)
    )

    SELECTING_WITNESSES -> SENDING_COMMITMENT auto (
        witnesses = SELECT_WITNESSES(HASH(session_id + provider_nonce + consumer_nonce), chain_state_at_checkpoint)
        STORE(selection_inputs, chain_state_at_checkpoint)
    )

    SENDING_COMMITMENT -> WAITING_FOR_LOCK auto (
        SEND(consumer, WITNESS_SELECTION_COMMITMENT)
        STORE(commitment_sent_at, NOW())
    )

    WAITING_FOR_LOCK -> SERVICE_PHASE on BALANCE_UPDATE_BROADCAST when message.lock_result.session_id == session_id and message.lock_result.status == ACCEPTED (
        STORE(lock_result, message.lock_result)
    )

    WAITING_FOR_LOCK -> IDLE on timeout(LOCK_TIMEOUT) (
        STORE(session_id, null)
    )
)
```

### Actor: Witness

```omt
actor Witness "Verifies consumer balance, participates in consensus" (
    store (
        request                  WitnessRequest
        consumer                 peer_id
        provider                 peer_id
        amount                   uint
        session_id               hash
        my_chain_head            hash
        witnesses                list<peer_id>
        other_witnesses          list<peer_id>
        last_seen_record         ChainRecord
        peer_balances            map<peer_id, uint>
        observed_balance         uint
        observed_chain_head      hash
        reject_reason            string
        verdict                  WitnessVerdict
        preliminaries            list<WitnessPreliminary>
        votes                    list<WitnessFinalVote>
        signatures               list<signature>
        recruitment_round        uint
        consensus_direction      string
        final_result             LockStatus
        result                   LockResult
        total_escrowed           uint
        topup_intent             TopUpIntent
        topup_observed_balance   uint
        topup_free_balance       uint
        topup_verdict            WitnessVerdict
        topup_votes              list<TopUpVote>
        topup_signatures         list<signature>
        topup_final_result       LockStatus
        topup_result             TopUpResult
    )

    state IDLE initial "Waiting for witness request"
    state CHECKING_CHAIN_KNOWLEDGE "Checking if we have recent consumer chain data"
    state CHECKING_BALANCE "Verifying consumer has sufficient balance"
    state CHECKING_EXISTING_LOCKS "Checking for existing locks on balance"
    state SHARING_PRELIMINARY "Sharing preliminary verdict with peers"
    state COLLECTING_PRELIMINARIES "Collecting preliminary verdicts"
    state VOTING "Casting final vote"
    state COLLECTING_VOTES "Collecting final votes"
    state BUILDING_RESULT "Building final lock result"
    state SIGNING_RESULT "Signing the lock result"
    state PROPAGATING_RESULT "Sending result to consumer"
    state ESCROW_ACTIVE "Escrow locked, monitoring liveness"
    state DONE terminal "Lock process complete"
    state CHECKING_TOPUP_BALANCE "Verifying consumer has additional free balance"
    state VOTING_TOPUP "Voting on top-up request"
    state COLLECTING_TOPUP_VOTES "Collecting top-up votes from other witnesses"
    state BUILDING_TOPUP_RESULT "Building the top-up result after consensus"
    state PROPAGATING_TOPUP "Sending top-up result to consumer for signature"

    IDLE -> CHECKING_CHAIN_KNOWLEDGE on WITNESS_REQUEST (
        store consumer, provider, amount, session_id, my_chain_head, witnesses
        STORE(consumer, message.sender)
        other_witnesses = REMOVE(witnesses, peer_id)
        STORE(preliminaries, [])
        STORE(votes, [])
        STORE(signatures, [])
        STORE(recruitment_round, 0)
    )

    CHECKING_CHAIN_KNOWLEDGE -> CHECKING_BALANCE auto (
        observed_balance = peer_balances[consumer]
    )

    CHECKING_BALANCE -> CHECKING_EXISTING_LOCKS auto when observed_balance >= amount

    CHECKING_BALANCE -> SHARING_PRELIMINARY auto when observed_balance < amount (
        STORE(verdict, REJECT)
        STORE(reject_reason, "insufficient_balance")
    )

    CHECKING_EXISTING_LOCKS -> SHARING_PRELIMINARY auto (
        STORE(verdict, ACCEPT)
    )

    SHARING_PRELIMINARY -> COLLECTING_PRELIMINARIES auto (
        BROADCAST(other_witnesses, WITNESS_PRELIMINARY)
        STORE(preliminary_sent_at, NOW())
    )

    COLLECTING_PRELIMINARIES -> COLLECTING_PRELIMINARIES on WITNESS_PRELIMINARY (
        APPEND(preliminaries, message.payload)
    )

    # Fast path: advance when enough preliminaries collected
    COLLECTING_PRELIMINARIES -> VOTING auto when LENGTH(preliminaries) >= WITNESS_THRESHOLD - 1 (
        consensus_direction = COMPUTE_ESCROW_CONSENSUS(preliminaries)
    )

    # Timeout fallback
    COLLECTING_PRELIMINARIES -> VOTING on timeout(PRELIMINARY_TIMEOUT) (
        consensus_direction = COMPUTE_ESCROW_CONSENSUS(preliminaries)
    )

    VOTING -> COLLECTING_VOTES auto (
        BROADCAST(other_witnesses, WITNESS_FINAL_VOTE)
    )

    COLLECTING_VOTES -> COLLECTING_VOTES on WITNESS_FINAL_VOTE (
        APPEND(votes, message.payload)
    )

    # Fast path: advance when enough votes collected
    COLLECTING_VOTES -> BUILDING_RESULT auto when LENGTH(votes) >= WITNESS_THRESHOLD

    # Timeout fallback
    COLLECTING_VOTES -> BUILDING_RESULT on timeout(CONSENSUS_TIMEOUT) when LENGTH(votes) >= WITNESS_THRESHOLD

    BUILDING_RESULT -> SIGNING_RESULT auto (
        result = BUILD_LOCK_RESULT()
    )

    SIGNING_RESULT -> PROPAGATING_RESULT auto (
        SEND(consumer, LOCK_RESULT_FOR_SIGNATURE)
        STORE(propagated_at, NOW())
    )

    PROPAGATING_RESULT -> ESCROW_ACTIVE on CONSUMER_SIGNED_LOCK (
        STORE(consumer_signature, message.signature)
        STORE(total_escrowed, amount)
        APPEND(chain, WITNESS_COMMITMENT)
        SEND(provider, BALANCE_UPDATE_BROADCAST)
    )

    PROPAGATING_RESULT -> DONE on timeout(CONSENSUS_TIMEOUT) (
        STORE(reject_reason, "consumer_signature_timeout")
    )

    ESCROW_ACTIVE -> CHECKING_TOPUP_BALANCE on TOPUP_INTENT (
        STORE(topup_intent, message)
        topup_observed_balance = peer_balances[consumer]
    )

    # Top-up balance check - accept if sufficient free balance
    CHECKING_TOPUP_BALANCE -> VOTING_TOPUP auto when topup_observed_balance - total_escrowed >= topup_intent.additional_amount (
        STORE(topup_verdict, accept)
    )

    # Top-up balance check - reject if insufficient
    CHECKING_TOPUP_BALANCE -> ESCROW_ACTIVE auto when topup_observed_balance - total_escrowed < topup_intent.additional_amount (
        STORE(topup_verdict, reject)
        STORE(topup_reject_reason, "insufficient_free_balance")
    )

    VOTING_TOPUP -> COLLECTING_TOPUP_VOTES auto (
        STORE(topup_votes, [])
        BROADCAST(other_witnesses, TOPUP_VOTE)
    )

    COLLECTING_TOPUP_VOTES -> COLLECTING_TOPUP_VOTES on TOPUP_VOTE (
        APPEND(topup_votes, message.payload)
    )

    # Fast path - need WITNESS_THRESHOLD total (including own vote added in VOTING_TOPUP)
    COLLECTING_TOPUP_VOTES -> BUILDING_TOPUP_RESULT auto when LENGTH(topup_votes) >= WITNESS_THRESHOLD

    # Timeout fallback
    COLLECTING_TOPUP_VOTES -> BUILDING_TOPUP_RESULT on timeout(PRELIMINARY_TIMEOUT) when LENGTH(topup_votes) >= WITNESS_THRESHOLD

    COLLECTING_TOPUP_VOTES -> ESCROW_ACTIVE on timeout(CONSENSUS_TIMEOUT) (
        STORE(topup_failed_reason, "vote_timeout")
    )

    BUILDING_TOPUP_RESULT -> PROPAGATING_TOPUP auto (
        topup_result = BUILD_TOPUP_RESULT()
        SEND(consumer, TOPUP_RESULT_FOR_SIGNATURE)
    )

    PROPAGATING_TOPUP -> ESCROW_ACTIVE on CONSUMER_SIGNED_TOPUP (
        STORE(total_escrowed, total_escrowed + topup_intent.additional_amount)
    )

    PROPAGATING_TOPUP -> ESCROW_ACTIVE on timeout(CONSENSUS_TIMEOUT) (
        STORE(topup_failed_reason, "consumer_signature_timeout")
    )

    ESCROW_ACTIVE -> ESCROW_ACTIVE on LIVENESS_PING (
        STORE(from_witness, peer_id)
        SEND(message.sender, LIVENESS_PONG)
    )
)
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
