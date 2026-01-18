# Participation Verification System with Distributed Trust

## Overview

A distributed trust system for compute swarm participation verification. No central authority determines trust - instead, trust is subjective, computed locally from on-chain verifiable data. All consumers pay uniform market rates; trust scores determine how payments split between providers and cryptographic burn.

---

## 1. Core Design Principles

### What's Verifiable (On-Chain Facts)

| Element | Verifiable | How |
|---------|------------|-----|
| Identity age | Yes | Creation timestamp on chain |
| Transactions | Yes | Immutable ledger record |
| Burn occurred | Yes | Transfer to burn address |
| Trust scores claimed | Yes | Published on chain |
| Verification logs | Yes | Recorded with results |
| Trust score accuracy | Partially | Compare against your own checks |
| Scorer reliability | Derivable | Track accuracy over time |

### What's Subjective (Computed Locally)

- Your trust in any given provider
- Your trust in any given scorer's accuracy
- How you weight different signals
- Your payment/acceptance strategies

### Key Insight

**Identity age is the only unforgeable credential.** You can't buy time on chain - you can only earn it by existing.

---

## 2. Trust-Annotated Blockchain

### Block Contents

Each block contains:
- Block number and link to previous block
- Timestamp
- Transactions (compute session payments)
- Trust assertions (participants' claims about others' trustworthiness)
- Verification logs (results of resource checks)
- Merkle root for integrity verification

### Identity Record

An identity is defined by:
- **Identity ID**: Hash of the public key
- **Creation block**: When the identity first appeared on chain
- **Public key**: For signature verification

Derived data (computed from chain, not stored):
- Age (current block minus creation block)
- Transaction count
- Trust assertions received

### Transaction Record

A compute transaction records:
- Consumer and provider identity IDs
- Total amount paid by consumer
- Amount received by provider
- Amount burned
- Resource specification (CPU, memory, GPU, etc.)
- Duration
- Signatures from both parties

### Trust Assertion

A trust assertion is a signed claim by one identity about another:
- Asserter ID (who is making the claim)
- Subject ID (who the claim is about)
- Trust score (0.0 to 1.0)
- Context (e.g., "compute_provider" or "scorer")
- Evidence hashes (links to verification logs supporting the claim)
- Human-readable reasoning
- Timestamp and signature

### Verification Log

A verification log records the results of checking a provider:
- Verifier and subject identity IDs
- Verification type: resource check, liveness, benchmark, or uptime
- What the provider claimed vs. what was actually measured
- Pass/fail result
- Timestamp and signature

---

## 3. Uniform Pricing Model

### Consumer Experience

All consumers pay the same market rate for equivalent compute. No negotiation, no trust calculation required from the consumer's perspective. Simple, transparent pricing.

### Market Rate Discovery (On-Chain Order Book)

The "spot rate" consumers see is derived from an on-chain order book. The complexity is hidden, but real price discovery happens underneath.

```
What consumer sees:          What's actually happening:
┌─────────────────────┐      ┌─────────────────────────────────────┐
│ 8 cores = 0.09 OMC/hr│  ←── │ Order book with bids/asks           │
│ [Rent Now]          │      │ Matching engine                     │
└─────────────────────┘      │ Spot rate = last matched price      │
                             └─────────────────────────────────────┘
```

---

## 3.1 On-Chain Compute Market

### Order Book Structure

**Orders** contain:
- Order ID and identity of placer
- Side: BID (consumer wants to buy) or ASK (provider wants to sell)
- Resource specification (CPU cores, memory, storage, GPU type/count)
- Price per hour
- Minimum and maximum duration
- Quantity (number of instances)
- Creation and expiration timestamps
- Status: open, partially filled, filled, cancelled, or expired

**Order Books** are maintained per resource class, with:
- Bids sorted by price descending (highest first)
- Asks sorted by price ascending (lowest first)
- Last trade price and time

### Resource Classes

Orders are grouped into standardized resource classes for liquidity:

| Class | Specs |
|-------|-------|
| small_cpu | 2 vCPU, 4GB RAM |
| medium_cpu | 4 vCPU, 16GB RAM |
| large_cpu | 8 vCPU, 32GB RAM |
| xlarge_cpu | 16 vCPU, 64GB RAM |
| gpu_consumer | 8 vCPU, 32GB RAM, consumer GPU (RTX 3080/4080 class) |
| gpu_pro | 16 vCPU, 64GB RAM, professional GPU (A10/A40 class) |
| gpu_datacenter | 32 vCPU, 128GB RAM, datacenter GPU (A100/H100 class) |

### Order Actions

**Place Order**: Submit a bid or ask to the book. The order is published to chain and the matching engine attempts immediate matching against the opposite side.

**Cancel Order**: Remove an open or partially filled order from the book.

**Market Order**: Execute immediately at the best available price, matching against existing orders on the opposite side.

### Matching Engine

The matching engine uses price-time priority:
- New bids match against asks at or below the bid price (lowest asks first)
- New asks match against bids at or above the ask price (highest bids first)
- When a match occurs, a session is initiated and escrow is triggered

### Spot Rate Calculation

The spot rate shown to users is derived from market data:

1. **VWAP** (Volume-Weighted Average Price): Preferred for stability - averages recent trade prices weighted by volume
2. **Mid-market**: Average of best bid and best ask
3. **Last trade**: Most recent execution price
4. **Reference price**: Fallback if no market data exists

### Consumer-Facing Simplicity

Consumers see a simple interface:
- Browse available resource classes
- See a single price per hour for each class
- Click "Rent Now" to get compute

Behind the scenes, the system places a market order on their behalf. If no immediate match is available, a limit order is placed at the current spot rate.

### Provider-Facing Interface

Providers see market conditions:
- Current spot rate
- Best bid and ask prices
- Order book depth
- 24-hour volume
- Price history
- Pricing suggestions (e.g., "Buyers willing to pay up to X, list at or below to match immediately")

---

## 3.2 Purpose-Based Order Types

Not all compute requests are equal. Different purposes have different verification requirements, trust thresholds, and economic models.

### Order Purpose Categories

| Purpose | Verification Level | Trust Threshold | Payment Model |
|---------|-------------------|-----------------|---------------|
| **Commercial** | Standard | Market-determined | Full market rate |
| **Research donation** | Light | Lower (altruistic) | Subsidized or free |
| **Network infrastructure** | Heavy | High | Network-funded |
| **Verification/audit** | Maximum | Very high | Burn-funded |

### Research Donation Bids

Central authorities representing research projects can maintain standing bids for donated compute. These integrate existing distributed computing efforts into the Omerta network.

**Examples:**
- BOINC projects (SETI@home successor projects, Einstein@Home, Rosetta@home)
- Folding@home (protein folding simulations)
- Academic research institutions
- Open-source scientific computing initiatives

**How it works:**

1. Research organization registers as a verified identity (may require off-chain verification of legitimacy)
2. Organization places standing bids at below-market rates (or zero for pure donation)
3. Providers with spare capacity can accept these bids
4. Verification is lighter—research workloads are often fault-tolerant and can detect bad results internally
5. Providers earn trust credit for donation, even at reduced/zero payment

**Provider incentives for donation:**
- Trust score bonus for altruistic contribution
- Increased daily distribution share (reputation for community contribution)
- Portfolio diversification (not all eggs in commercial basket)
- Idle resource utilization (something beats nothing)

### Standing Bid Structure

Standing bids differ from regular orders:

- **Persistent**: Don't expire, remain open until cancelled
- **Partial fill**: Accept any available capacity, no minimum
- **Priority**: Lower than commercial orders (providers choose when to donate)
- **Verification**: Purpose-specific (research projects handle their own result validation)
- **Price**: Zero or negative—research orgs never need funds

```
Standing bids from Folding@home:

Bid A (pure donation):
  Price:        0 OMC/hr
  Trust gain:   1x baseline
  Provider:     Donates compute, receives baseline trust

Bid B (burn for accelerated trust):
  Price:        -20 OMC/hr
  Trust gain:   4x multiplier
  Provider:     Donates compute AND burns 20 OMC/hr, receives 4x trust
```

### Negative Price = Provider Burns

The negative price means the provider pays to do the work. This inverts the normal flow:

```
Normal commercial order:
  Consumer pays provider → Provider delivers compute

Zero-price donation:
  No payment either way → Provider delivers compute → Baseline trust

Negative-price donation:
  Provider burns coins → Provider delivers compute → Multiplied trust
```

**Why would a provider burn to donate?**
- Accelerated trust building (investment in future earnings)
- New providers bootstrapping reputation faster
- Providers with coins but no commercial customers yet
- Altruism + economic benefit combined

The research org posts the standing bid but never needs funds. Providers choose which tier to accept based on whether they want to invest coins for faster trust growth.

### Verification Levels by Purpose

**Commercial (Standard)**
- Full resource verification before session
- Continuous liveness checks
- Benchmark validation
- Full escrow and payment protection

**Research Donation (Light)**
- Basic liveness check
- No upfront benchmark (research project handles validation)
- Minimal escrow (or none for free donations)
- Trust bonus based on accepted work units

**Network Infrastructure (Heavy)**
- Extended verification period
- Multiple independent verifiers required
- Continuous monitoring throughout
- Higher trust threshold to even bid

**Verification/Audit (Maximum)**
- Used for verifying other providers
- Requires highest trust tier
- Multiple redundant checks
- Results published as verification logs

### Research Organization Verification

To prevent abuse of the donation system, research organizations undergo verification:

1. **Off-chain identity verification**: Prove affiliation with legitimate research institution
2. **Work unit transparency**: Publish what computations are being performed
3. **Result publication**: Commit to publishing research outcomes
4. **Community standing**: Existing reputation in scientific/open-source community

Verified research organizations receive a special designation visible to providers, helping providers choose causes they want to support.

### Economic Flow for Donations

```
Commercial session (100 GPU-hours at market rate):

Bid price:            +1.20 OMC/hr
Consumer pays:        120 OMC
Provider receives:    84 OMC (70% at 0.70 trust)
Burned:               36 OMC
Trust gain:           +0.02

Pure donation (100 GPU-hours at 0 price):

Bid price:            0 OMC/hr
Provider pays:        0 OMC
Provider receives:    0 OMC
Burned:               0 OMC
Trust gain:           +0.02 (baseline)

Accelerated donation (100 GPU-hours at negative price):

Bid price:            -0.20 OMC/hr
Provider pays:        20 OMC (burned)
Provider receives:    0 OMC
Burned:               20 OMC
Trust gain:           +0.08 (4x multiplier)
```

### Trust Multiplier by Burn Level

| Bid Price | Provider Action | Trust Multiplier |
|-----------|-----------------|------------------|
| Positive | Receives payment | 1x (commercial) |
| Zero | Donates compute only | 1x (baseline) |
| Negative | Donates compute + burns | Scales with burn amount |

The multiplier for negative-price bids scales with how much the provider burns relative to market rate. Burning the full market rate equivalent yields maximum multiplier (4x for research). Partial burns yield proportional multipliers.

### Why This Design?

Trust comes from **verifiable compute provision**. Burning is an optional accelerator:
- Provider decides whether to invest in faster trust growth
- Research orgs never need funds—just verification capability
- New providers can bootstrap by burning into donations
- Established providers can donate at zero cost for slower trust gain

### Anti-Gaming: You Can't Buy Infinite Trust

Two mechanisms prevent trust inflation through pure spending:

**1. Trust requires verified compute**

You can't just burn coins—you must provide real, verified compute alongside the burn. Trust gain is bounded by actual work done, not coins spent.

```
Can't do:   Burn 1,000,000 OMC → Get massive trust
Must do:    Provide 1000 GPU-hours (verified) + burn proportional amount → Get trust for 1000 GPU-hours
```

**2. Cap on negative bid price**

The network sets a maximum negative price (e.g., -2x market rate). Beyond this, burning more coins provides no additional trust multiplier.

```
Market rate:        1.00 OMC/hr
Max negative cap:  -2.00 OMC/hr
Max multiplier:     4x

Burning 2 OMC/hr:   4x trust (at cap)
Burning 10 OMC/hr:  Still 4x trust (excess burn wasted)
```

**Tunable knob**: The network can adjust the negative price cap to control how fast trust can be purchased. Tighter cap = slower trust buying = more emphasis on time and organic reputation.

### Buying Trust with Real Money

Trust can be purchased with fiat through cloud arbitrage:

```
Fiat → Cloud instances → Connect to Omerta → Donate compute → Burn OMC → Trust

Example:
  $100/hr on AWS GPUs
  → Connect to network, accept negative-price research bids
  → Provide verified compute + burn OMC
  → Gain trust proportional to work done
```

This is acceptable—even desirable. Spending real money IS proof:
- Proof of Work: spent electricity and hardware
- Proof of Stake: locked up capital (opportunity cost)
- Proof of Burn: destroyed money + real compute resources

Someone willing to burn real money (via cloud costs + OMC burn) has demonstrated:
- They have resources (not a trivial attacker)
- They're committed long-term (wouldn't burn for hit-and-run)
- They have skin in the game (real loss if trust is wasted)

### Tracking the Fiat-to-Trust Conversion Rate

The network should track this conversion rate explicitly:

```
Current rates (example):
  Cloud cost:         $1.20/GPU-hr (market average)
  OMC burn at cap:    2.00 OMC/GPU-hr
  Trust gain:         +0.001 per GPU-hr at 4x multiplier

Derived:
  Cost to gain +0.1 trust: ~$120 cloud + 200 OMC burned
  Cost to gain +1.0 trust: ~$1,200 cloud + 2,000 OMC burned
```

**Why track this?**
- Understand economic security (cost to attack the network)
- Set appropriate caps on negative bids
- Compare to PoW cost-to-attack metrics
- Transparency about what trust actually costs
- Detect anomalies (if rate shifts dramatically, something changed)

This makes the economics explicit rather than hidden. Everyone knows the price of trust.

### Donation Log Structure

All donations recorded on-chain:
- Provider identity
- Research org identity (verifier)
- Resource class and duration
- Verification signature from research org
- Timestamp
- Bid price (0 or negative)
- Burn amount (if negative price)

This creates a permanent, verifiable record of contribution.

---

### Trust-Based Payment Splits

The uniform price is split based on provider trust:

```
Consumer pays:     100 OMC (fixed market rate)
                      │
         ┌────────────┴────────────┐
         │    Trust Score Lookup   │
         │    (automated, local)   │
         └────────────┬────────────┘
                      │
    ┌─────────────────┴─────────────────┐
    ▼                                   ▼
Provider receives              Burned (public good)
(proportional to trust)        (remainder)
```

### Example Splits

| Provider Trust Score | Provider Receives | Burned |
|---------------------|-------------------|--------|
| 0.95 (very high) | 95 OMC | 5 OMC |
| 0.70 (established) | 70 OMC | 30 OMC |
| 0.40 (new) | 40 OMC | 60 OMC |
| 0.20 (untrusted) | 20 OMC | 80 OMC |

### Reference Pricing (Based on Cloud Spot Markets)

| Resource Class | Market Rate |
|----------------|-------------|
| 2 vCPU, 4GB RAM | ~0.015 OMC/hr |
| 4 vCPU, 16GB RAM | ~0.045 OMC/hr |
| 8 vCPU, 32GB RAM | ~0.09 OMC/hr |
| GPU (RTX 3080 equiv) | ~0.35 OMC/hr |
| GPU (A100 equiv) | ~1.20 OMC/hr |

---

## 4. Distributed Trust Computation

### Local Trust Calculation

Each participant computes trust scores locally using multiple factors:

**Factor 1: Identity age (20% weight)**
- Verifiable on-chain
- Score scales linearly up to a cap (e.g., 180 days for full credit)

**Factor 2: Direct experience (40% weight)**
- Your own transaction history with this provider
- Success rate of past sessions

**Factor 3: Trusted scorers' assessments (40% weight)**
- Assertions from identities you trust
- Weighted by your meta-trust in each scorer

Final score = weighted average of all factors

### Meta-Trust (Trust in Scorers)

Track how accurate others' assessments are by comparing their assertions against your own verification results. If a scorer's assertions consistently match your findings, increase your meta-trust in them. If they diverge, decrease it.

### Trust Propagation

Trust propagates through the network:
- Alice trusts Bob's scoring (0.9 meta-trust)
- Bob asserts Charlie has 0.8 trust
- Alice's derived trust in Charlie = 0.8 × 0.9 = 0.72

If Alice also has direct experience with Charlie, her final trust is a weighted average of direct and derived trust.

---

## 5. Self-Correcting Verification

### The Verification Loop

1. You rent compute from Provider P
2. You run your own checks (benchmarks, resource verification)
3. You get objective results
4. You publish a verification log on chain
5. You compare your results to others' trust assertions about P

If a scorer's assertions match your checks, increase meta-trust in them. If they diverge, decrease meta-trust and consider publishing your own assertion.

### Social Verification Requests

If you're suspicious of a provider:
1. Ask someone you trust to check them out
2. They rent from the provider, run checks
3. They publish a verification log
4. They may publish a trust assertion
5. You factor their findings into your trust calculation

### No Central Adjudication

- No authority decides who's right
- Everyone maintains their own trust graph
- Bad scorers naturally get discounted (their scores don't match reality)
- Good scorers gain influence (their scores are accurate)

---

## 6. Token Design: OmertaCoin (OMC)

### Token Properties

| Property | Value |
|----------|-------|
| Name | OmertaCoin (OMC) |
| Smallest unit | 1 microOMC = 0.000001 OMC |
| Supply | Controlled by daily distribution |
| Burn address | Provably unspendable |

### Burn Address Derivation

The burn address is derived as a hash of a known string plus the genesis block hash. Properties:
- No private key exists (hash preimage is unknown)
- Deterministic (anyone can verify)
- Chain-specific (prevents confusion across networks)

### Burn Proof

Every burn is recorded on chain with:
- Transaction ID
- Amount burned
- Provider trust score at time of burn
- Merkle proof of inclusion
- Cumulative burn total

### Phased Token Strategy

| Phase | Description |
|-------|-------------|
| **1. Launch** | Central ledger, fast and free transactions |
| **2. Bridge** | Deploy ERC-20/SPL representation, enable withdrawals |
| **3. Decentralize** | Multisig or threshold bridge, reduce central control |
| **4. Full P2P** | Optional: trustless bridge with ZK proofs |

---

## 6.1 Coin Generation: Trust-Weighted Daily Distribution

A simple model: fixed coins minted daily, distributed proportionally to trust scores. Honest behavior = keep getting your share. Dishonest behavior = trust drops = smaller share tomorrow.

### Core Concept

```
Every day:
  1. Fixed amount of coins minted (e.g., 10,000 OMC)
  2. Distributed to all participants proportional to trust score
  3. That's it. No voting, no proposals, no complexity.

Your incentive to behave honestly:
  - Misbehave → Trust drops → Smaller share tomorrow
  - Stay honest → Trust stable/grows → Keep getting your cut
```

### Daily Distribution

A fixed amount is minted each day (decreasing over time like Bitcoin's halving):
- Year 1: 10,000 OMC/day
- Year 2: 8,000 OMC/day
- Year 3: 6,000 OMC/day
- Year 4: 4,000 OMC/day
- Year 5: 2,000 OMC/day
- Year 6+: 1,000 OMC/day

Distribution is proportional to trust scores. All participants with positive trust receive their share of the daily mint.

### Trust Penalties

Actions that reduce trust (and tomorrow's share):

| Violation | Penalty |
|-----------|---------|
| Overspend (tried to spend more than balance) | -10% trust |
| Network disagreement (state differs from consensus) | -15% trust |
| Failed verification (didn't deliver claimed resources) | -20% trust |
| Bounced payment/escrow | -25% trust |
| Inactivity | -5% trust (gradual decay) |

### Example Distribution

```
Day 100, Daily mint: 10,000 OMC

Participants and trust scores:
  Alice:   0.95 trust → 32.2% → 3,220 OMC
  Bob:     0.80 trust → 27.1% → 2,710 OMC
  Charlie: 0.60 trust → 20.3% → 2,030 OMC
  Dave:    0.40 trust → 13.6% → 1,360 OMC
  Eve:     0.20 trust →  6.8% →   680 OMC

Next day, Eve tries to overspend:
  Eve's trust: 0.20 → 0.10 (-50% of her trust)

Day 101 distribution for Eve:
  Eve: 0.10/2.85 = 3.5% = 350 OMC (was 680)

Eve lost ~330 OMC/day by misbehaving.
```

### Why This Works

Traditional incentive: "Don't misbehave or you'll be punished" (requires enforcement, detection, adjudication)

Trust-weighted distribution: "Misbehave and you get less free money tomorrow" (self-enforcing, automatic, proportional)

**The motivation to be honest is simply: KEEP GETTING YOUR HANDOUT**

### Network Disagreement Detection

Participants' claimed state is checked against network consensus:
- Balance claims must match the ledger
- Transaction history must match
- Pending obligations must match

Disagreements automatically trigger trust penalties.

### Fiat Bridge: Inner Circle Consensus

Establishing a fiat bridge (connection to real-world currency) requires extraordinary consensus:
- Only high-trust participants (≥0.80) can vote
- Requires 95% approval weighted by trust
- This ensures the entire "inner circle" must agree before the token touches real money

---

## 7. Transparency for Users

### Simple User Experience

```
User wants compute:
  1. Browse available resources
  2. See market price: "8 cores = 100 OMC/hr"
  3. Select provider (or let system choose)
  4. Pay market rate
  5. Get compute

After session:
  "You paid: 100 OMC"
  "Provider received: 72 OMC"
  "Burned for ecosystem: 28 OMC"
```

### What Users Don't Need to Understand

- Trust algorithms
- Verification protocols
- Meta-trust computation
- Scorer reliability tracking

### What Users Can Inspect (If Curious)

- Provider's identity age
- Provider's transaction history
- Trust assertions about provider
- Verification logs
- Burn history

---

## 8. Bootstrap Process

### Genesis Block

Contains:
- Initial identities (founders, early participants)
- Their initial trust relationships
- Reference implementation parameters

These identities have verifiable maximum age.

### New Participant Joins

**Day 0:**
- Identity age: 0 (verifiable)
- Transaction history: none
- Trust assertions: none
- Expected trust score: low
- Daily distribution share: small

**Over time:**
- Age increases (verifiable)
- Transactions accumulate
- Verification logs published
- Trust assertions received
- Daily distribution share improves

### Sybil Resistance

Creating a new identity provides no advantage:
- Age resets to zero
- History resets to nothing
- Trust resets to baseline
- Most of payment gets burned, daily share is tiny

Cost of Sybil attack = time to rebuild trust × opportunity cost of low daily share

---

## 9. Protocol Stack

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Personal Strategy                             │
│  - Your trust computation                               │
│  - Your payment preferences                             │
│  - Your verification frequency                          │
│  (Subjective, not on-chain)                            │
└─────────────────────────────────────────────────────────┘
                           │
┌─────────────────────────────────────────────────────────┐
│  Layer 2: Standard Protocols (Optional)                 │
│  - Reference trust algorithms                           │
│  - Suggested verification methods                       │
│  - Default payment split formulas                       │
│  (Suggested, not enforced)                             │
└─────────────────────────────────────────────────────────┘
                           │
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Consensus (On-Chain Facts)                    │
│  - Identity timestamps                                  │
│  - Transactions                                         │
│  - Trust assertions                                     │
│  - Verification logs                                    │
│  - Burns                                                │
│  (Verifiable, immutable)                               │
└─────────────────────────────────────────────────────────┘
```

---

## 10. Summary

| Question | Answer |
|----------|--------|
| Who determines trust? | Each participant, locally |
| What's on chain? | Facts: identity age, transactions, assertions, logs |
| What's verifiable? | Age, transactions, your own checks, scorer accuracy over time |
| How are prices set? | On-chain order book with bid/ask matching |
| How are providers paid? | Trust score determines split (high trust = more) |
| Where does rest go? | Cryptographically burned |
| How are coins created? | Fixed daily mint, distributed proportional to trust |
| Why be honest? | Keep your share of daily distribution |
| How to bootstrap? | Genesis identities, then trust builds from age + behavior |
| Sybil resistance? | New identities start at zero, tiny daily share |
