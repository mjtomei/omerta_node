# Transaction 03: State Query

Request cabal-attested state values (balance, age, trust) without full verification.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

## Overview

When a peer needs state information they don't have (new user, offline resync, stale data), they can request a cabal attestation of the current value. This is the lightweight path - fast and low cost, but relies on cabal honesty.

The heavyweight alternative is [State Audit](04_state_audit.md) which verifies from first principles.

**Actors:**
- **Requester** - needs state information they don't have
- **Subject** - the peer whose state is being queried
- **Cabal (Witnesses)** - verify and attest to the state value

**Use Cases:**
- New user bootstrapping into the network
- Offline peer resyncing after returning
- Witness with stale data during escrow verification
- Periodic health checks / spot audits
- Any situation where you need trusted data without full verification

**Flow:**
1. Requester selects cabal (or uses existing cabal if in escrow context)
2. Requester sends STATE_QUERY to cabal members
3. Each witness checks their local view of subject's state
4. Witnesses sign their attestation of the value
5. Requester collects threshold signatures
6. Requester now has attested state value with accountability

---

## Query Types

| Query Type | Returns | Derived From |
|------------|---------|--------------|
| `BALANCE` | Current spendable balance | Chain transaction history |
| `AGE` | Chain age in days | Genesis block timestamp |
| `TRUST` | Current trust score | Attestation history + age |
| `CHAIN_HEAD` | Current head block hash | Latest block |
| `CHAIN_LENGTH` | Number of blocks | Chain length |

---

## Record Types

```
STATE_QUERY {
  query_id: hash                # Unique identifier for this query
  requester: peer_id
  subject: peer_id              # Whose state are we asking about?
  query_type: BALANCE | AGE | TRUST | CHAIN_HEAD | CHAIN_LENGTH
  context: string               # Optional: "escrow_verification", "bootstrap", etc.
  timestamp: timestamp
  requester_signature: signature
}

WITNESS_STATE_CHECK {
  query_id: hash
  witness: peer_id
  subject: peer_id
  query_type: string

  # Result
  value: any                    # The attested value
  confidence: HIGH | MEDIUM | LOW  # Based on data freshness
  last_seen: timestamp          # When witness last verified subject's chain
  evidence_hash: hash           # Hash of chain state this was derived from

  timestamp: timestamp
  signature: signature
}

STATE_ATTESTATION {
  query_id: hash
  subject: peer_id
  query_type: string

  # Consensus value
  attested_value: any

  # Evidence chain
  witness_checks: [hash]        # Hashes of WITNESS_STATE_CHECK records

  # Multi-sig
  witnesses: [peer_id]
  signatures: [signature]

  created_at: timestamp
}
```

---

## State Machines

### Requester States

```
ACTOR: Requester

STATES: [PREPARING, QUERYING, COLLECTING, COMPLETE, FAILED]

STATE PREPARING:
  actions:
    - Determine query type and subject
    - Select cabal for attestation (or use existing)
    - Create STATE_QUERY
    - SIGN(query)
  → next_state: QUERYING

STATE QUERYING:
  actions:
    - BROADCAST(cabal, STATE_QUERY)
  → next_state: COLLECTING

STATE COLLECTING:
  on WITNESS_STATE_CHECK from Witness:
    actions:
      - Verify signature
      - Store response
      - If threshold reached: create STATE_ATTESTATION

  on THRESHOLD_REACHED:
    → next_state: COMPLETE

  after(QUERY_TIMEOUT):
    → next_state: FAILED

STATE COMPLETE:
  # Have attested value with accountability

STATE FAILED:
  # Insufficient responses, try different cabal or escalate to audit
```

### Witness States

```
ACTOR: Witness

STATES: [IDLE, CHECKING, RESPONDING]

STATE IDLE:
  on STATE_QUERY from Requester:
    → next_state: CHECKING

STATE CHECKING:
  actions:
    - Look up subject in cached chain data
    - Determine confidence based on data freshness
    - Compute requested value (balance, age, trust, etc.)
    - If data too stale: respond with LOW confidence or reject
  → next_state: RESPONDING

STATE RESPONDING:
  actions:
    - Create WITNESS_STATE_CHECK with value and confidence
    - SIGN(check)
    - SEND(requester, check)
  → next_state: IDLE
```

---

## Confidence Levels

Witnesses report confidence based on data freshness:

| Confidence | Data Age | Meaning |
|------------|----------|---------|
| HIGH | < 24 hours | Recently verified, high trust |
| MEDIUM | 24h - 7 days | Somewhat stale, acceptable for most uses |
| LOW | > 7 days | Very stale, requester should seek fresher data |

Requester can set minimum confidence threshold for their use case:
- Escrow verification: require HIGH
- Bootstrap overview: MEDIUM acceptable
- Health check: any confidence, flag LOW for follow-up

---

## Cabal Selection for Queries

For state queries outside an escrow context, requester selects a query cabal:

1. Exclude the subject (can't attest to your own state)
2. Prefer witnesses with recent interaction with subject
3. Standard cabal selection criteria (high trust, low correlation)

If query is part of escrow flow, use the existing escrow cabal.

---

## Accountability

If attested value is later proven wrong (via State Audit):
1. Audit produces definitive value with full evidence chain
2. Compare against STATE_ATTESTATION
3. Witnesses who signed incorrect attestation:
   - If data was available: trust penalty (negligent or malicious)
   - If data was unavailable: no penalty (honest mistake, should have reported LOW confidence)

This creates incentive for witnesses to:
- Maintain fresh data on peers they might attest for
- Report LOW confidence when uncertain rather than guess
- Be honest, since lies are provable via audit

---

## Verification Requirements

For STATE_ATTESTATION to be valid:
1. Query must be properly signed by requester
2. At least THRESHOLD witnesses must respond
3. All witness signatures must be valid
4. Attested value must match majority of witness responses
5. Confidence levels must meet requester's threshold

---

## Edge Cases

### Subject is Unknown

If witnesses have never seen the subject:
- Respond with "UNKNOWN" value
- Confidence: NONE
- Requester must find witnesses who know the subject, or trigger audit

### Witnesses Disagree

If witness values differ significantly:
- Return majority value with note of disagreement
- Flag for potential audit
- Could indicate: stale data, fork, or fraud

### Query About Self

Peers cannot attest to their own state (conflict of interest).
Subject is excluded from cabal for queries about themselves.

---

## Attack Analysis

TODO: Add attack analysis following template in FORMAT.md

---

## Open Questions

1. How does a truly new user find an initial cabal to query? Bootstrap nodes?
2. Should there be a cost/stake for queries to prevent spam?
3. Can the subject provide their own chain data to help witnesses verify?
4. How to handle queries for peers that no longer exist / abandoned chains?
