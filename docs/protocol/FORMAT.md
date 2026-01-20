# Transaction Protocol Format

This document defines the format and primitives used for specifying distributed transaction protocols.

**See also:**
- [Design Philosophy](DESIGN_PHILOSOPHY.md) for comparison to other systems and our consistency model
- [Gossip Protocol](GOSSIP.md) for how information propagates through the network
- [Code Generation](GENERATION.md) for how schemas are translated to documentation and executable code

## Transaction Structure

Each `.omt` file defines a complete transaction protocol. Sections appear in this order:

```
transaction ID "Name" "Description"

imports shared/common

parameters (...)

enum EnumName "description" (...)

block BlockType by [Actors] (...)

message MessageName from Actor to [Recipients] signed (...)

function name(params) -> ReturnType (...)

native function name(params) -> ReturnType "library.path"

actor ActorName "description" (...)
```

### Transaction Header

```
transaction 00 "Escrow Lock" "Lock funds with distributed witness consensus"
```

Components:
- **ID**: Two-digit identifier (00-99)
- **Name**: Short name for the transaction
- **Description**: One-line summary

### Imports

```
imports shared/common
```

Import shared type definitions from another file. Path is relative to the `docs/protocol/` directory.

### Parameters

```
parameters (
    WITNESS_COUNT = 5 count "Initial witnesses to recruit"
    LOCK_TIMEOUT = 300 seconds "Seconds for consumer to complete lock"
    CONSENSUS_THRESHOLD = 0.67 fraction "Fraction needed to decide"
)
```

Parameter units:
- `count` - integer count
- `seconds` - time duration
- `fraction` - decimal 0.0-1.0

Parameters become constants in generated code (uppercase names).

### Enums

```
enum WitnessVerdict "Witness verdict on lock request" (
    ACCEPT
    REJECT
    NEED_MORE_INFO   # optional comment
)
```

Enum values are uppercase. Optional description after name.

### Block Types

Blocks are records written to an actor's chain:

```
block BALANCE_LOCK by [Consumer, Witness] (
    session_id       hash
    amount           uint
    lock_result_hash hash
    timestamp        timestamp
)
```

- **by [Actors]**: Which actor types can write this block
- Fields with types (see Data Types below)

### Messages

```
message LOCK_INTENT from Consumer to [Provider] signed (
    consumer    peer_id
    amount      uint
    session_id  hash
    timestamp   timestamp
)
```

Components:
- **from Actor**: Sender type
- **to [Recipients]**: One or more recipient types
- **signed**: (optional) Message requires cryptographic signature
- Fields with types

Special recipient `[Network]` indicates broadcast to all peers.

### Functions

Transaction-specific helper functions:

```
function count_positive_votes(votes list<dict>) -> uint (
    RETURN LENGTH(FILTER(votes, v => v.can_reach_vm == true))
)

function build_lock_result() -> LockResult (
    consensus = LOAD(consensus_direction)
    status = IF consensus == "ACCEPT" THEN LockStatus.ACCEPTED ELSE LockStatus.REJECTED
    RETURN {
        session_id LOAD(session_id),
        status status,
        timestamp NOW()
    }
)
```

#### Function Body Statements

Function bodies support these statement types:

- **Assignment**: `name = expression`
- **Return**: `RETURN expression`
- **For loop**: `FOR var IN iterable statements`

Statements are delimited by their starting patterns (no semicolons needed):
- `RETURN` keyword starts a return statement
- `FOR` keyword starts a for loop
- `identifier =` starts an assignment

#### IF Expressions

The `IF` syntax is used as a **ternary expression** (not a statement):

```
IF condition THEN value ELSE value
```

This can be used anywhere an expression is expected:
- In assignments: `status = IF approved THEN "OK" ELSE "REJECTED"`
- In return statements: `RETURN IF count >= threshold THEN "ACCEPT" ELSE "REJECT"`
- Nested in expressions: `total = base + IF bonus THEN extra ELSE 0`

#### Function Purity Restriction

**Functions must be pure** - they cannot contain side effects. The following operations are only allowed in transition actions, not in function bodies:

- `SEND(target, MESSAGE)` - send message to a peer
- `BROADCAST(list, MESSAGE)` - broadcast message to peers
- `APPEND(list, value)` - append to a list
- `APPEND(chain, BLOCK_TYPE)` - append block to chain

This restriction ensures functions are deterministic and have no observable effects other than their return value.

#### No IF Statements

The DSL explicitly does **not** support IF as a control flow statement. Only IF ternary expressions are allowed:

```
# ALLOWED: IF as ternary expression
status = IF count > 0 THEN "active" ELSE "inactive"
RETURN IF approved THEN result ELSE default

# NOT ALLOWED: IF as control flow
IF condition THEN
    do_something()
ELSE
    do_other()
```

This restriction encourages expressing control flow through state machine transitions rather than imperative conditionals within actions.

#### Block Statements

FOR loops support multi-statement bodies using parentheses:

```
FOR item IN items (
    total = total + item.value
    count = count + 1
)
```

Single statements don't require parentheses:
```
FOR item IN items total = total + item.value
```

### Native Functions

Native functions have implementations provided by external libraries rather than being defined purely in the DSL. They are used for operations that require system access (SSH, network checks, hardware interaction, etc.).

**Syntax:**
```
native function NAME(PARAMS) -> TYPE "library.path"
```

**Example:**
```
native function check_vm_connectivity(vm_endpoint string) -> bool "omerta.native.vm_connectivity"
```

### Actors

```
actor Consumer "Party paying for service" (
    store (...)

    trigger initiate_lock(provider peer_id, amount uint) in [IDLE] "Start a new lock"

    state IDLE initial "Waiting to initiate"
    state LOCKED terminal "Funds locked"
    state FAILED terminal "Lock failed"

    # Transitions...
)
```

#### Store Section

Local variables for the actor:

```
store (
    provider         peer_id
    amount           uint
    session_id       hash
    witnesses        list<peer_id>
    peer_balances    map<peer_id, uint>
)
```

#### Triggers

External entry points to start protocol flows:

```
trigger initiate_lock(provider peer_id, amount uint) in [IDLE] "Start a new lock"
trigger initiate_topup(amount uint) in [LOCKED] "Add funds to existing escrow"
```

- **Parameters**: typed parameters
- **in [STATES]**: Valid states to call from
- **Description**: What the trigger does

#### States

```
state IDLE initial "Waiting to initiate"
state SENDING_REQUEST "Sending request to provider"
state LOCKED "Funds successfully locked"
state FAILED terminal "Lock failed"
```

Modifiers:
- `initial` - Starting state (exactly one required)
- `terminal` - End state (no outgoing transitions)

#### Transitions

**On trigger with guard:**
```
IDLE -> SENDING_LOCK on initiate_lock when has_provider_checkpoint (
    store provider, amount
    session_id = HASH(peer_id + provider + NOW())
) else -> FAILED (
    STORE(reject_reason, "no_checkpoint")
)
```

**On message:**
```
WAITING -> PROCESSING on RESPONSE_MESSAGE (
    STORE(result, message.payload)
)

WAITING -> PROCESSING on RESPONSE when message.status == "OK" (
    STORE(result, message.payload)
)
```

**Auto transition (immediate):**
```
COMPUTING -> SENDING auto (
    result = BUILD_RESULT()
    SEND(consumer, RESULT_MESSAGE)
)

VERIFYING -> ACCEPTED auto when verification_passed
```

**Timeout:**
```
WAITING -> FAILED on timeout(LOCK_TIMEOUT) (
    STORE(reject_reason, "timeout")
)
```

**Self-loop:**
```
COLLECTING -> COLLECTING on VOTE_MESSAGE (
    APPEND(votes, message.payload)
)
```

**Fast path with guard:**
```
# Advance early when condition met
COLLECTING -> EVALUATING auto when LENGTH(votes) >= THRESHOLD

# Timeout fallback
COLLECTING -> EVALUATING on timeout(VOTE_TIMEOUT)
```

#### Transition Actions

**Store from message fields:**
```
store field1, field2, field3
```
Extracts named fields from the triggering message/trigger and stores them.

**Store explicit value:**
```
STORE(key, value)
STORE(reject_reason, "insufficient_balance")
```

**Assign computed value:**
```
session_id = HASH(peer_id + provider + NOW())
signature = SIGN(result)
rng = SEEDED_RNG(seed)
```

**Send message:**
```
SEND(provider, LOCK_INTENT)
SEND(message.sender, RESPONSE)
```

**Broadcast to list:**
```
BROADCAST(witnesses, WITNESS_REQUEST)
```

**Append to list:**
```
APPEND(votes, message.payload)
```

**Append block to chain:**
```
APPEND(chain, BALANCE_LOCK)
```

---

## Protected Keywords

The following words are part of the DSL syntax and cannot be used as identifiers (variable names, message names, state names, etc.). Keywords are case-insensitive (`trigger`, `TRIGGER`, and `Trigger` are all reserved).

### Declaration Keywords

| Keyword | Usage |
|---------|-------|
| `transaction` | Transaction header declaration |
| `imports` | Import shared definitions |
| `parameters` | Protocol parameters block |
| `enum` | Enum type declaration |
| `message` | Message type declaration |
| `block` | Block type declaration |
| `actor` | Actor declaration |
| `function` | Function declaration |
| `native` | Native function modifier |

### Actor Keywords

| Keyword | Usage |
|---------|-------|
| `store` | Actor local storage block |
| `trigger` | External trigger declaration |
| `state` | State declaration |
| `initial` | Initial state modifier |
| `terminal` | Terminal state modifier |

### Transition Keywords

| Keyword | Usage |
|---------|-------|
| `on` | Message/trigger transition |
| `auto` | Automatic transition |
| `when` | Guard condition |
| `else` | Guard failure handler |

### Action Keywords

| Keyword | Usage |
|---------|-------|
| `lookup` | Lookup value from chain |
| `send` | Send message to peer |
| `broadcast` | Broadcast message to list |
| `append` | Append to list/chain |
| `append_block` | Append block (legacy) |
| `return` | Return from function |

Note: Assignment (`x = expr`) uses bare identifier syntax, not a keyword.

### Modifier Keywords

| Keyword | Usage |
|---------|-------|
| `from` | Message sender |
| `to` | Message recipients |
| `by` | Block appenders |
| `in` | Trigger valid states / loop iteration |
| `with` | Additional context |
| `signed` | Message requires signature |

### Logical Operators

| Keyword | Usage |
|---------|-------|
| `and` | Boolean AND |
| `or` | Boolean OR |
| `not` | Boolean NOT |

---

## Reserved Identifiers

The following identifiers have special meaning at runtime and cannot be used as variable names:

| Identifier | Context | Meaning |
|------------|---------|---------|
| `chain` | Any expression | The actor's own blockchain (`self.chain`) |
| `peer_id` | Any expression | The actor's own peer identifier |
| `message` | Message transitions | The incoming message being processed |
| `null` | Any expression | Null/None value |

Note: Use `NOW()` function to get the current time instead of a reserved keyword.

### Accessing Message Fields

In message-triggered transitions, use `message.field` to access fields from the incoming message:

```
WAITING -> PROCESSING on RESPONSE_MESSAGE (
    STORE(result, message.payload)
    STORE(sender, message.sender)
)

WAITING -> DONE on RESULT when message.status == "OK" (
    STORE(data, message.data)
)
```

Available message properties:
- `message.sender` - peer ID of the message sender
- `message.<field>` - access payload field by name

---

## Primitive Operations

### Chain Operations
- `APPEND(chain, BLOCK_TYPE)` - add block to actor's chain
- `READ(peer_id, query) → value` - read from a peer's cached chain data
- `CHAIN_STATE_AT(chain, hash) → state` - extract chain state at a specific block hash
- `CHAIN_CONTAINS_HASH(chain, hash) → bool` - check if hash exists in chain
- `CHAIN_SEGMENT(chain, hash) → list` - extract portion of chain up to hash
- `VERIFY_CHAIN_SEGMENT(segment) → bool` - verify chain segment validity

Note: `chain` refers to the actor's own chain. For peer chain data, use `READ(peer_id, query)` which accesses cached chain information received via gossip.

### Local State Operations
- `STORE(key, value)` - save to local peer state (not on chain)
- `LOAD(key) → value` - retrieve from local state

### Communication
- `SEND(peer, MESSAGE)` - send message to peer
- `BROADCAST(peer_list, MESSAGE)` - send message to multiple peers
- Messages received are handled by `on MESSAGE_TYPE` transitions

### Cryptographic
- `SIGN(data) → signature` - sign with my private key
- `VERIFY_SIG(public_key, data, signature) → bool` - verify signature
- `HASH(data) → hash` - cryptographic hash (SHA-256)
- `MULTI_SIGN(data, existing_sigs) → combined_signature` - add my signature to multi-sig
- `RANDOM_BYTES(n) → bytes` - generate n random bytes
- `GENERATE_ID() → string` - generate unique identifier

### Seeded Random
- `SEEDED_RNG(seed) → rng` - create seeded random number generator
- `SEEDED_SAMPLE(rng, list, n) → list` - deterministically sample n items

### Compute
- `IF condition THEN value ELSE value` - conditional expression (ternary)
- `NOT condition`, `AND`, `OR` - boolean operators
- `FOR item IN list ...` - iteration
- `NOW() → timestamp` - current time
- `ABORT(reason)` - exit state machine with error

### Collection Operations
- `APPEND(list, value)` - append value to list (action only, not in functions)
- `FILTER(list, predicate) → list` - filter list by lambda predicate
- `MAP(list, transform) → list` - transform list elements by lambda
- `LENGTH(list) → int` - list length
- `CONCAT(list_a, list_b) → list` - concatenate two lists
- `SORT(list) → list` - sort list (returns new list)
- `HAS_KEY(dict, key) → bool` - check if dict contains key (null-safe)

### Common Library

Additional helper functions are defined in `shared/common.omt` and can be imported via `imports shared/common`. These include: `CONTAINS`, `REMOVE`, `SET_EQUALS`, `GET`, `MIN`, `MAX`, `EXTRACT_FIELD`, `COUNT_MATCHING`. See the file for full signatures.

### Metaprogramming

**Dynamic field access:**
```
value = record.[field_name]   # Access field by variable name
```
The `.[expr]` syntax allows accessing a field whose name is computed from an expression.

**Lambda expressions:**
```
FILTER(items, x => x.status == "active")
MAP(items, item => item.value * 2)
```
Lambda expressions use the `=>` arrow syntax. The left side is the parameter name, the right side is the expression to evaluate.

---

## Data Types

| Type | Description |
|------|-------------|
| `hash` | Cryptographic hash (hex string) |
| `peer_id` | Peer identifier (public key hash) |
| `uint` | Unsigned integer |
| `int` | Signed integer |
| `bytes` | Raw byte sequence |
| `timestamp` | Unix timestamp (float) |
| `string` | UTF-8 text |
| `bool` | Boolean (true/false) |
| `signature` | Cryptographic signature |
| `dict` | Key-value object |
| `list<T>` | List of type T |
| `map<K, V>` | Map from key type K to value type V |

Custom types (defined by enums or in shared imports):
- `WitnessVerdict`, `LockStatus`, `TerminationReason` (enums)
- `LockResult`, `TopUpResult`, `SelectionInputs` (structs from shared)

---

## Guards

Boolean expressions for conditional transitions:

```
when has_provider_checkpoint
when observed_balance >= amount
when LENGTH(votes) >= THRESHOLD
when message.status == "OK" AND LENGTH(message.data) > 0
when message.sender == LOAD(consumer)
```

Access message fields with `message.field` or `message.payload.field`.

---

## Struct Literals

Create inline objects using curly braces with field-value pairs (no colons):

```
{session_id LOAD(session_id), status ACCEPTED, timestamp NOW()}
```

Empty struct:
```
{}
```

**Spread syntax** copies all fields from an existing struct into a new one, optionally adding or overriding fields:

```
{...pending_result, consumer_signature signature}
```

---

## Semantics

**Action execution:**
- All actions in a state execute to completion before checking messages
- Messages received during action execution are queued

**State transitions:**
- Actions never end with "stay in this state"
- To wait/loop, use a state with no actions and `after(duration) → same_state`
- Every state must have explicit transitions via messages or timeout

**Message handling:**
- Messages are checked only after all actions complete
- If multiple messages queued, process in order received

**Timeout (`after`):**
- `after(duration)` means: wait at least this long before transitioning
- This is the default transition if no matching message arrives
- Can transition to self for waiting/polling loops

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
| 05 | [Health Check](transactions/05_health_check.md) | Decentralized monitoring with verifiable triggers | Stub |

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
