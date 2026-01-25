# Transaction 05: Health Check

Decentralized, verifiable health monitoring with deterministic trigger computation.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

## Overview

Peers are responsible for triggering health checks on other peers. The trigger computation is deterministic and verifiable - you can't arbitrarily target someone, you must prove the check is warranted based on public chain state.

**Actors:**
- **Trigger Peer** - computes that a check is needed, initiates
- **Subject** - peer being checked
- **Cabal** - verifies trigger computation, performs heavyweight audit

**Flow:**
1. Trigger peer runs local computation on their view of the network
2. Computation outputs "subject X needs checking" based on:
   - Time since subject's last check
   - Subject's current suspicion score
   - Other deterministic factors
3. Trigger peer selects cabal and submits trigger proof
4. Cabal verifies trigger computation is honest
5. Cabal performs State Audit (Transaction 04) on subject
6. Results recorded on-chain, suspicion score updated

---

## On-Chain State (Per Peer)

```
HEALTH_STATUS {
  peer_id: peer_id
  last_checked_at: timestamp
  last_checked_by: peer_id
  check_result: PASS | FAIL | PARTIAL
  suspicion_score: float        # Deterministic, anyone can recompute
  check_history: [CheckRecord]  # Recent check results
}

CheckRecord {
  timestamp: timestamp
  checker: peer_id
  cabal: [peer_id]
  result: PASS | FAIL | PARTIAL
  discrepancies_found: uint
}
```

---

## Suspicion Score

Deterministic formula (TBD) based on:

**Increases with:**
- Time since last check
- Previous check failures
- Witness disagreement on state queries
- Anomalous transaction patterns
- Non-responsiveness to queries

**Decreases with:**
- Passing checks
- Consistent state across witnesses
- Regular activity / liveness
- Age (established peers get benefit of doubt)

Formula must be reproducible by any peer from public chain state.

---

## Trigger Computation

```
SHOULD_CHECK(subject, my_view) → bool:
  # Inputs from public chain state
  last_check = subject.last_checked_at
  suspicion = subject.suspicion_score
  time_since_check = NOW() - last_check

  # Deterministic threshold
  check_interval = BASE_INTERVAL / (1 + suspicion)

  return time_since_check > check_interval
```

Trigger peer must prove they computed this honestly - cabal verifies against their view of chain state.

---

## Record Types

```
CHECK_TRIGGER {
  trigger_id: hash
  trigger_peer: peer_id
  subject: peer_id

  # Proof of honest computation
  inputs_hash: hash             # Hash of inputs used
  computed_suspicion: float
  computed_interval: float

  selected_cabal: [peer_id]

  timestamp: timestamp
  signature: signature
}

CHECK_RESULT {
  trigger_id: hash
  subject: peer_id

  # Audit summary
  audit_result_hash: hash       # Reference to full State Audit
  passed: bool
  discrepancies: uint

  # Updated metrics
  new_suspicion_score: float

  # Cabal attestation
  cabal: [peer_id]
  signatures: [signature]

  timestamp: timestamp
}
```

---

## State Machines

TODO: Define state machines for Trigger Peer, Subject, and Cabal

---

## Open Questions

1. Exact formula for suspicion score
2. How to prevent trigger spam (cost/stake for triggering?)
3. What if trigger peer and subject collude to avoid real checks?
4. How often should peers scan for check triggers?
5. Should there be network-wide health aggregates in addition to per-peer?
