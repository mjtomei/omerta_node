# Transaction Protocol Format

This document defines the format and primitives used for specifying distributed transaction protocols.

**See also:** [Design Philosophy](DESIGN_PHILOSOPHY.md) for comparison to other systems and our consistency model.

## Actor Definition

Each actor in a transaction is defined as a state machine:

```
ACTOR: [Name]

STATES: [S0, S1, S2, ...]

STATE S0:
  actions:
    - action1
    - action2
    - ...

  on MESSAGE_TYPE from PEER:
    → next_state: S1

  on OTHER_MESSAGE from PEER:
    → next_state: S2

  after(duration):
    → next_state: S3
```

## Semantics

**Action execution:**
- All actions in a state execute to completion before checking messages
- Messages received during action execution are queued
- If you need interruptibility, break into separate states with one action each

**State transitions:**
- Actions never end with "stay in this state"
- To wait/loop, use a state with no actions (or minimal actions) and `after(duration) → same_state`
- Every state must have explicit transitions via messages or timeout

**Message handling:**
- Messages are checked only after all actions complete
- If multiple messages queued, process in order received
- Unhandled message types are ignored (or could define `on UNHANDLED:` behavior)

**Timeout (`after`):**
- `after(duration)` means: wait at least this long before transitioning
- This is the default transition if no matching message arrives
- Not necessarily an error - can be the happy path (e.g., "no objections received, proceed")
- Can transition to self for waiting/polling loops

---

## Primitive Operations

### Chain operations
- `APPEND(my_chain, record)` - add record to my chain
- `READ(chain, query) → value` - read from a chain (mine or cached copy of peer's)
- `CHAIN_STATE_AT(chain, hash) → state` - extract chain state at a specific block hash
- `CHAIN_CONTAINS_HASH(chain, hash) → bool` - check if hash exists in chain
- `CHAIN_SEGMENT(chain, from, to) → bytes` - extract portion of chain
- `VERIFY_CHAIN_SEGMENT(segment) → bool` - verify chain segment validity

### Local state operations
- `STORE(key, value)` - save to local peer state (not on chain)
- `LOAD(key) → value` - retrieve from local state

### Communication
- `SEND(peer, message)` - send message to peer
- `BROADCAST(peer_list, message)` - send message to multiple peers
- Messages received are handled by `on MESSAGE_TYPE` clauses

### Cryptographic
- `SIGN(data) → signature` - sign with my private key
- `VERIFY_SIG(public_key, data, signature) → bool`
- `HASH(data) → hash` - cryptographic hash (SHA-256). Also used for hashlocks: `hashlock = HASH(preimage)`, verify with `HASH(revealed) == hashlock`
- `MULTI_SIGN(data, existing_sigs) → combined_signature` - add my signature to multi-sig
- `RANDOM_BYTES(n) → bytes` - generate n random bytes
- `GENERATE_ID() → string` - generate unique identifier (typically hash of random data + timestamp)

### Compute
- `COMPARE(a, b) → bool`
- `SUM(a, b)`, `SUBTRACT(a, b)`, etc.
- `IF(condition) THEN ... ELSE ...`
- `FOR item in list: ...` - iteration
- `ABORT(reason)` - exit state machine with error
- `NOW() → timestamp` - current time
- `LENGTH(list) → int` - list length
- `REMOVE(list, item) → list` - remove item from list
- `SORT(list, by) → list` - sort list by key

### Selection
- `SELECT_WITNESSES(seed, chain_state, criteria) → peer_list` - deterministic witness selection
- `SEEDED_RNG(seed) → rng` - create seeded random number generator
- `SEEDED_SAMPLE(rng, list, n) → list` - deterministically sample n items

---

## Consistency Model

These protocols provide **eventual consistency** with **economic enforcement**, following a lockless programming philosophy. See [Design Philosophy](DESIGN_PHILOSOPHY.md) for full details.

**Key properties:**
- No global state or global invariants
- Each peer maintains a local view that may differ from others
- Conflicts are detected after the fact, not prevented
- Economic penalties (trust damage) enforce honest behavior

**Message validity is locally verifiable:**
- Recipients can check signatures, thresholds, and structure
- No coordination with other peers required to validate a message

**"If-then" consistency:**
- If you see a valid `LOCK_RESULT`, then the supporting `WITNESS_FINAL_VOTE` messages must exist
- If you see a `BALANCE_LOCK` on a consumer's chain, then a valid `LOCK_RESULT` with their signature exists

---

## Attack Analysis Template

### Attack: [Name]

**Description:** What the attacker does

**Attacker role:** Which actor is malicious (Consumer / Provider / Witness / Network Peer / External)

**Sequence:**
1. Attacker action (state, message, or chain operation)
2. ...

**Harm:** What damage results

**Detection:** How honest parties detect this

**On-chain proof:** What evidence exists

**Defense:** Protocol changes to prevent/mitigate

---

### Fault: [Name]

**Description:** What goes wrong (not malicious)

**Faulty actor:** Which actor experiences fault

**Fault type:** Network / Crash / Stale data / Byzantine

**Sequence:**
1. Normal operation
2. Fault occurs
3. ...

**Impact:** What breaks

**Recovery:** How protocol recovers

**Residual risk:** What can't be recovered

---

## Transaction Index

| ID | Name | Description | Status |
|----|------|-------------|--------|
| 00 | [Escrow Lock](transactions/00_escrow_lock.md) | Lock/top-up funds with distributed witness consensus | Spec complete |
| 01 | [Cabal Attestation](transactions/01_cabal_attestation.md) | Verify VM allocation and monitor session | Stub |
| 02 | [Escrow Settle](transactions/02_escrow_settle.md) | Distribute escrowed funds after session ends | Stub |
| 03 | [State Query](transactions/03_state_query.md) | Request cabal-attested state (balance, age, trust) | Stub |
| 04 | [State Audit](transactions/04_state_audit.md) | Full history reconstruction and verification | Stub |

---

## Settlement Economics

### Payment Formula

The provider's share of payment depends on their trust level:

```
provider_share = 1 - 1/(1 + K_PAYMENT × T)
burn = total_payment / (1 + K_PAYMENT × T)
```

Where:
- **T** = provider's trust level
- **K_PAYMENT** = curve scaling constant (network parameter)
- Higher trust → more payment to provider, less burned

**Examples (assuming K_PAYMENT = 0.01):**

| Provider Trust | Provider Share | Burn Rate |
|----------------|----------------|-----------|
| 0 (new) | 0% | 100% |
| 100 | 50% | 50% |
| 500 | 83% | 17% |
| 1000 | 91% | 9% |
| 2000 | 95% | 5% |

### Settlement Conditions

| Condition | Escrow Action | Trust Signal |
|-----------|---------------|--------------|
| **COMPLETED_NORMAL** | Full release per burn formula | Trust credit for provider |
| **CONSUMER_TERMINATED_EARLY** | Pro-rated partial release | Neutral (consumer's choice) |
| **PROVIDER_TERMINATED** | No release for remaining time | Reliability signal (tracked) |
| **SESSION_FAILED** | Investigate if pattern emerges | No automatic penalty |

### Burn Rate Calculation

Burn rate must be **deterministically verifiable** by any observer:

1. **Inputs** (all on-chain or in signed messages):
   - Provider's trust T (computed from their chain history)
   - K_PAYMENT constant (network parameter)
   - Session duration (from cabal attestation)
   - Hourly rate (from session terms)

2. **Formula**:
   ```
   total_payment = duration_hours × hourly_rate
   provider_payment = total_payment × provider_share
   burn = total_payment - provider_payment
   consumer_refund = escrowed_amount - total_payment
   ```

3. **Verification**: Any peer can recompute by:
   - Reading provider's chain to compute trust
   - Checking session terms and attestation
   - Applying the formula

This follows the same pattern as witness selection: deterministic computation from verifiable inputs.
