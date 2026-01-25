# Transaction 02: Escrow Settle

Distribute escrowed funds after session ends based on cabal attestation.

**See also:** [Protocol Format](../FORMAT.md) for primitive operations and state machine semantics.

## Overview

After a session ends and the cabal has attested to the actual service delivery (Transaction 01), the escrowed funds are distributed:
- Provider receives payment based on duration and burn rate formula
- Network burns a portion based on provider's trust level
- Consumer receives refund for unused portion

**Actors:**
- **Consumer** - receives refund for unused funds
- **Provider** - receives payment for service delivered
- **Cabal (Witnesses)** - compute and verify settlement amounts, multi-sign settlement

**Flow:**
1. Cabal attestation received (from Transaction 01)
2. Witnesses compute settlement amounts using burn rate formula
3. Witnesses multi-sign settlement result
4. Provider and consumer record settlement on their chains
5. Balance updates broadcast to network

---

## Settlement Economics

From [Protocol Format](../FORMAT.md#settlement-economics):

### Payment Formula

```
provider_share = 1 - 1/(1 + K_PAYMENT × T)
burn = total_payment / (1 + K_PAYMENT × T)
```

Where **T** = provider's trust level, **K_PAYMENT** = network constant.

### Burn Rate Calculation

All inputs must be deterministically verifiable:

```
# Inputs
T = provider_trust_at_settlement      # Computed from provider's chain
duration_hours = actual_duration_seconds / 3600
hourly_rate = session_terms.price_per_hour
escrowed_amount = lock_result.amount

# Computation
total_payment = duration_hours × hourly_rate
provider_share = 1 - 1/(1 + K_PAYMENT × T)
provider_payment = total_payment × provider_share
burn = total_payment - provider_payment
consumer_refund = escrowed_amount - total_payment

# Validation
ASSERT(consumer_refund >= 0)  # Cannot owe more than escrowed
ASSERT(provider_payment + burn + consumer_refund == escrowed_amount)
```

### Settlement Conditions

| Condition | Escrow Action | Trust Signal |
|-----------|---------------|--------------|
| **COMPLETED_NORMAL** | Full release per burn formula | Trust credit for provider |
| **CONSUMER_TERMINATED_EARLY** | Pro-rated partial release | Neutral (consumer's choice) |
| **PROVIDER_TERMINATED** | No release for remaining time | Reliability signal (tracked) |
| **SESSION_FAILED** | Investigate if pattern emerges | No automatic penalty |

---

## Record Types

```
SETTLEMENT_COMPUTATION {
  session_id: hash
  attestation_hash: hash          # Hash of CABAL_ATTESTATION

  # Inputs (for verification)
  provider_trust: uint            # T at time of settlement
  duration_seconds: uint
  hourly_rate: uint
  escrowed_amount: uint
  k_payment: uint                 # Network constant (fixed point)

  # Outputs
  provider_payment: uint
  burn_amount: uint
  consumer_refund: uint

  # Verification
  computed_at: timestamp
  witness: peer_id
  signature: signature
}

SETTLEMENT_RESULT {
  session_id: hash
  consumer: peer_id
  provider: peer_id

  # Final amounts
  provider_payment: uint
  burn_amount: uint
  consumer_refund: uint

  # Evidence chain
  lock_result_hash: hash
  attestation_hash: hash
  computation_hash: hash

  # Multi-sig from cabal
  witnesses: [peer_id]
  witness_signatures: [signature]

  timestamp: timestamp
}

BALANCE_UNLOCK {
  session_id: hash
  settlement_result_hash: hash
  refund_amount: uint
  timestamp: timestamp
}

PAYMENT_RECEIVED {
  session_id: hash
  settlement_result_hash: hash
  payment_amount: uint
  timestamp: timestamp
}
```

---

## State Machines

### Witness (Cabal) States

```
ACTOR: Witness

STATES: [AWAITING_ATTESTATION, COMPUTING_SETTLEMENT, COLLECTING_SIGNATURES, BROADCASTING]

STATE AWAITING_ATTESTATION:
  on CABAL_ATTESTATION from Witnesses:
    → next_state: COMPUTING_SETTLEMENT

STATE COMPUTING_SETTLEMENT:
  actions:
    - provider_trust = COMPUTE_TRUST(provider_chain)
    - computation = COMPUTE_SETTLEMENT(attestation, provider_trust)
    - SIGN(computation)
    - BROADCAST(witnesses, SETTLEMENT_COMPUTATION)
  → next_state: COLLECTING_SIGNATURES

STATE COLLECTING_SIGNATURES:
  actions:
    - Collect SETTLEMENT_COMPUTATION from other witnesses
    - Verify all computations match (deterministic)
    - If mismatch: flag dispute

  on THRESHOLD_SIGNATURES_COLLECTED:
    → next_state: BROADCASTING

STATE BROADCASTING:
  actions:
    - result = CREATE_SETTLEMENT_RESULT(computation, signatures)
    - SEND(consumer, result)
    - SEND(provider, result)
    - BROADCAST(network, BALANCE_UPDATE)
```

### Consumer States

```
ACTOR: Consumer

STATES: [AWAITING_SETTLEMENT, VERIFYING, RECORDING]

STATE AWAITING_SETTLEMENT:
  on SETTLEMENT_RESULT from Witness:
    → next_state: VERIFYING

STATE VERIFYING:
  actions:
    - Verify witness signatures (threshold met)
    - Verify computation matches formula
    - Verify refund amount is correct
    - If invalid: TODO dispute flow
  → next_state: RECORDING

STATE RECORDING:
  actions:
    - APPEND(my_chain, BALANCE_UNLOCK)
```

### Provider States

```
ACTOR: Provider

STATES: [AWAITING_SETTLEMENT, VERIFYING, RECORDING]

STATE AWAITING_SETTLEMENT:
  on SETTLEMENT_RESULT from Witness:
    → next_state: VERIFYING

STATE VERIFYING:
  actions:
    - Verify witness signatures (threshold met)
    - Verify computation matches formula
    - Verify payment amount is correct
    - If invalid: TODO dispute flow
  → next_state: RECORDING

STATE RECORDING:
  actions:
    - APPEND(my_chain, PAYMENT_RECEIVED)
```

---

## Trust Computation

Provider trust T is computed from their chain history at settlement time:

```
T = COMPUTE_TRUST(provider_chain) where:
  - T_transactions = sum of completed session credits
  - T_assertions = sum of peer vouches/accusations
  - age_derate = min(1.0, chain_age_days / AGE_MATURITY_DAYS)
  - T = (T_transactions + T_assertions) × age_derate
```

This must be deterministically computable by any peer with access to the provider's chain.

---

## Verification Requirements

For settlement to be valid:
1. `CABAL_ATTESTATION` must be valid (per Transaction 01)
2. All witnesses must compute identical settlement amounts (deterministic)
3. At least THRESHOLD witnesses must sign `SETTLEMENT_RESULT`
4. `provider_payment + burn_amount + consumer_refund == escrowed_amount`
5. Amounts must match the burn rate formula applied to inputs

---

## Edge Cases

### Session exceeds escrow

If `total_payment > escrowed_amount`:
- This should not happen if top-ups are required
- If it does: `consumer_refund = 0`, provider gets `escrowed_amount × provider_share`
- Consumer flagged for underpayment (trust impact)

### Zero duration

If session terminated immediately (duration ≈ 0):
- `total_payment = 0`
- `consumer_refund = escrowed_amount`
- No burn, no provider payment

### Provider trust = 0

If provider has zero trust:
- `provider_share = 0`
- `burn = total_payment` (100%)
- Provider receives nothing

---

## Attack Analysis

TODO: Add attack analysis following template in FORMAT.md

---

## Open Questions

1. How is provider trust computed exactly? Reference math doc section.
2. What happens if witnesses disagree on provider trust computation?
3. Should settlement be atomic (all-or-nothing) or can partial settlement occur?
4. How long after attestation must settlement occur?
