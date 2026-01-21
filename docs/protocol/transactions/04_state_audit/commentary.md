# Transaction 04: State Audit

Full history reconstruction and verification from first principles.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

## Overview

When lightweight attestation ([State Query](03_state_query.md)) isn't sufficient - disputes, fraud detection, proving a cabal lied - the auditor can reconstruct state from the complete transaction history. This is expensive but definitive.

**Actors:**
- **Auditor** - the peer performing the audit (can be anyone)
- **Subject** - the peer whose state is being audited
- **Counterparties** - all peers who have transacted with the subject
- **Witnesses** - peers who attested to subject's transactions

**Use Cases:**
- Dispute resolution: "The cabal said my balance was X but I think it's Y"
- Fraud detection: "I suspect this peer is double-spending"
- Proving cabal lied: "These witnesses attested to a false value"
- Deep health check: verify network state is consistent
- Legal/compliance: produce verifiable audit trail

**Flow:**
1. Auditor requests subject's full chain from genesis
2. For each transaction on the chain:
   - Contact counterparties to verify their side
   - Contact witnesses who attested
   - Verify all signatures
3. Recompute state (balance, trust) from raw history
4. Compare against any disputed attestations
5. Produce AUDIT_RESULT with full evidence chain

---

## Audit Scope

| Scope | What's Verified | Cost |
|-------|-----------------|------|
| `BALANCE` | All value-affecting transactions | Medium |
| `TRUST` | All attestations as provider | Medium |
| `FULL` | Complete chain, all transactions | High |
| `TARGETED` | Specific time range or transaction set | Low-Medium |

---

## Record Types

```
AUDIT_REQUEST {
  audit_id: hash
  auditor: peer_id
  subject: peer_id
  scope: BALANCE | TRUST | FULL | TARGETED

  # For targeted audits
  from_timestamp: timestamp     # Optional: start of range
  to_timestamp: timestamp       # Optional: end of range
  target_transactions: [hash]   # Optional: specific transactions

  # Context
  reason: string                # "dispute", "health_check", "fraud_investigation"
  disputed_attestation: hash    # Optional: attestation being challenged

  timestamp: timestamp
  auditor_signature: signature
}

CHAIN_REQUEST {
  audit_id: hash
  auditor: peer_id
  target: peer_id               # Whose chain do you want?
  from_block: uint              # 0 for genesis
  to_block: uint                # -1 for head
  timestamp: timestamp
  signature: signature
}

CHAIN_RESPONSE {
  audit_id: hash
  provider: peer_id             # Who is providing this chain?
  target: peer_id               # Whose chain is this?

  blocks: [Block]               # The actual chain data
  head_hash: hash

  timestamp: timestamp
  provider_signature: signature
}

COUNTERPARTY_VERIFICATION {
  audit_id: hash
  transaction_hash: hash        # Which transaction?
  counterparty: peer_id

  # Counterparty's view
  confirmed: bool               # Do they confirm this transaction?
  their_record_hash: hash       # Hash of their record of this transaction

  timestamp: timestamp
  signature: signature
}

AUDIT_RESULT {
  audit_id: hash
  auditor: peer_id
  subject: peer_id
  scope: string

  # Computed values
  computed_balance: uint
  computed_trust: float
  computed_age_days: float

  # Evidence chain
  chain_hash: hash              # Hash of subject's chain as audited
  chain_length: uint
  transactions_verified: uint
  counterparties_contacted: uint

  # Discrepancies found
  discrepancies: [AuditDiscrepancy]

  # If disputing an attestation
  disputed_attestation: hash
  attestation_correct: bool

  # Full audit trail available on request
  evidence_available: bool

  timestamp: timestamp
  auditor_signature: signature
}

AuditDiscrepancy {
  type: MISSING_COUNTERPARTY | SIGNATURE_INVALID | VALUE_MISMATCH |
        DOUBLE_SPEND | ATTESTATION_FALSE | CHAIN_FORK
  transaction_hash: hash
  description: string
  evidence_hash: hash
}
```

---

## State Machines

### Auditor States

```
ACTOR: Auditor

STATES: [INITIATING, COLLECTING_CHAIN, VERIFYING_TRANSACTIONS,
         CONTACTING_COUNTERPARTIES, COMPUTING, COMPLETE]

STATE INITIATING:
  actions:
    - Create AUDIT_REQUEST
    - Determine scope and targets
    - SIGN(request)
  → next_state: COLLECTING_CHAIN

STATE COLLECTING_CHAIN:
  actions:
    - Send CHAIN_REQUEST to subject
    - Optionally request from other peers who may have copies
    - Verify chain integrity (hash chain, signatures)

  on CHAIN_RESPONSE:
    → next_state: VERIFYING_TRANSACTIONS

  after(CHAIN_TIMEOUT):
    # Subject unresponsive - try alternative sources or flag
    → next_state: COMPLETE (with SUBJECT_UNRESPONSIVE flag)

STATE VERIFYING_TRANSACTIONS:
  actions:
    - FOR each transaction in scope:
      - Verify block signature
      - Extract counterparty
      - Add to verification queue
  → next_state: CONTACTING_COUNTERPARTIES

STATE CONTACTING_COUNTERPARTIES:
  actions:
    - FOR each counterparty:
      - Request their view of the transaction
      - Compare with subject's record
      - Note any discrepancies

  # Can proceed with partial responses
  after(COUNTERPARTY_TIMEOUT):
    → next_state: COMPUTING

STATE COMPUTING:
  actions:
    - Replay all transactions from genesis
    - Compute balance at each step
    - Compute trust from attestations
    - Compare with disputed attestation if any
    - Create AUDIT_RESULT
  → next_state: COMPLETE

STATE COMPLETE:
  actions:
    - BROADCAST(network, AUDIT_RESULT) if discrepancies found
    - Or return result to requester only
```

### Subject States

```
ACTOR: Subject (being audited)

STATES: [NORMAL, RESPONDING_TO_AUDIT]

STATE NORMAL:
  on CHAIN_REQUEST from Auditor:
    → next_state: RESPONDING_TO_AUDIT

STATE RESPONDING_TO_AUDIT:
  actions:
    - Prepare requested chain segment
    - SEND(auditor, CHAIN_RESPONSE)
  → next_state: NORMAL

  # Note: Subject has incentive to respond honestly
  # Non-response or false data will be noted in audit result
```

---

## Verification Process

### Balance Audit

1. Start with balance = 0 at genesis
2. For each ESCROW_LOCK where subject is consumer: balance -= locked_amount
3. For each ESCROW_SETTLE where subject is consumer: balance += refund_amount
4. For each ESCROW_SETTLE where subject is provider: balance += payment_amount
5. Final balance = computed_balance

### Trust Audit

1. Start with trust = 0 at genesis
2. Compute age component from chain age
3. For each ATTESTATION where subject is provider:
   - Verify attestation signatures
   - Apply trust credit/penalty based on outcome
4. Final trust = computed_trust

### Chain Integrity

1. Verify genesis block is properly formed
2. For each subsequent block:
   - Verify prev_hash matches previous block
   - Verify signature is valid for subject's public key
   - Verify timestamp is monotonically increasing
3. Verify head_hash matches claimed head

---

## Handling Non-Responsive Peers

If subject or counterparties don't respond:

| Peer | Non-Response Handling |
|------|----------------------|
| Subject | Flag as unresponsive; try to get chain from peers who have cached copies |
| Counterparty | Note as "unverified"; doesn't invalidate transaction but reduces confidence |
| Witness | Their attestation stands but marked "witness unavailable for verification" |

Non-response is itself evidence that can affect trust:
- Pattern of non-response to audits → reliability concern
- Non-response when accused of fraud → strong negative signal

---

## Dispute Resolution

When audit contradicts a STATE_ATTESTATION:

1. AUDIT_RESULT includes `disputed_attestation` hash and `attestation_correct: false`
2. Evidence chain shows the correct computation
3. Witnesses who signed false attestation are identified
4. Trust penalties applied:
   - If witness had stale data and reported HIGH confidence: negligent, moderate penalty
   - If witness had correct data and lied: malicious, severe penalty
   - If witness reported LOW confidence: no penalty (they warned)

---

## Cost Considerations

Audits are expensive:
- Network bandwidth for chain transfer
- Computation to verify all signatures
- Latency to contact counterparties

To prevent audit spam:
- Auditor may need to stake tokens
- Rate limiting per auditor
- Higher bar for full audits vs targeted audits

But audits must always be possible - they're the ultimate source of truth.

---

## Attack Analysis

TODO: Add attack analysis following template in FORMAT.md

---

## Open Questions

1. Who pays for audit costs? Auditor, subject, or loser of dispute?
2. Should audit results be public or private?
3. How long must peers retain full chain history to support audits?
4. Can audits be parallelized across multiple auditors for large chains?
5. What if the subject's chain has been legitimately pruned?
