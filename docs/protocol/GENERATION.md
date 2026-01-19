# Code Generation Infrastructure

This document describes the code generation pipeline that produces documentation and simulation code from transaction schemas.

**See also:**
- [Protocol Format](FORMAT.md) - DSL primitives and state machine semantics
- [Simulator Design](SIMULATOR_DESIGN.md) - How generated code is used in simulation
- [Design Philosophy](DESIGN_PHILOSOPHY.md) - Why we use this approach

---

## Overview

Each transaction in the protocol is defined by a **single source of truth**: a DSL schema file (`.omt`) that uses the primitives defined in [FORMAT.md](FORMAT.md). From this schema, we generate:

1. **Markdown documentation** - Human-readable protocol specification
2. **Python simulation code** - Executable state machines for the simulator described in [SIMULATOR_DESIGN.md](SIMULATOR_DESIGN.md)
3. **State machine diagrams** - Visual representations (Mermaid + Graphviz)

```
docs/protocol/transactions/<id>_<name>/
├── transaction.omt       ← SINGLE SOURCE OF TRUTH (DSL format)
└── commentary.md    ← Human-written narrative template

        │
        │  scripts/generate_from_schema.py
        ▼

docs/protocol/transactions/<id>_<name>.md           ← Generated documentation
simulations/transactions/<name>_generated.py        ← Generated Python code
docs/protocol/transactions/graphs/<id>_<name>_*.mmd ← State diagrams (Mermaid)
docs/protocol/transactions/graphs/<id>_<name>_*.svg ← Rendered diagrams
```

---

## File Structure

### Schema Directory

Each transaction has a directory under `docs/protocol/transactions/`:

```
docs/protocol/transactions/00_escrow_lock/
├── transaction.omt       # Complete transaction definition (DSL)
└── commentary.md    # Narrative template with placeholders
```

### Shared Definitions

Common types and functions are defined in:

```
docs/protocol/shared/
└── common.omt       # Shared types and functions
```

Import them in transaction schemas with:
```
imports shared/common
```

### Schema File (transaction.omt)

The schema uses a custom DSL syntax. Top-level sections:

```
# Transaction declaration
transaction 00 "Escrow Lock / Top-up" "Brief description"

# Import shared definitions
imports shared/common

# Protocol constants
parameters (
    TIMEOUT = 30 seconds "Description"
    THRESHOLD = 0.67 fraction "Description"
)

# Enumeration types
enum LockStatus "Status of lock attempt" (
    ACCEPTED
    REJECTED
)

# Chain records
block BALANCE_LOCK by [Consumer, Witness] (
    session_id  hash
    amount      uint
)

# Protocol messages
message LOCK_INTENT from Consumer to [Provider] signed (
    session_id  hash
    amount      uint
)

# State machines
actor Consumer "Party paying for service" (
    store (...)
    trigger initiate_lock(...) in [IDLE]
    state IDLE initial
    state LOCKED terminal
    IDLE -> LOCKED on trigger (...)
)

# Helper functions
function count_votes(votes list<dict>) -> uint (
    RETURN LENGTH(FILTER(votes, v => v.accepted))
)
```

---

## DSL Syntax Reference

### Parameters

```
parameters (
    PARAM_NAME = 5 count "Description"
    TIMEOUT = 30 seconds "Description"
    THRESHOLD = 0.67 fraction "Description"
)
```

### Enums

```
enum EnumName "Description" (
    VALUE_A
    VALUE_B
)
```

### Blocks (Chain Records)

```
block BLOCK_NAME by [Actor1, Actor2] (
    field_name  hash
    list_field  list<peer_id>
)
```

### Messages

```
message MESSAGE_NAME from Sender to [Recipient1, Recipient2] signed (
    field_name  hash
    payload     dict
)
```

Use `signed` modifier for signed messages.

### Actors

```
actor ActorName "Description" (
    store (
        var_name  type
        list_var  list<dict>
    )

    trigger trigger_name(param1 type1, param2 type2) in [STATE1, STATE2] "Description"

    state STATE_A initial "Description"
    state STATE_B
    state STATE_C terminal "Description"

    STATE_A -> STATE_B on trigger_name (
        store var1, var2
        store result = expression
        compute hash = HASH(data)
        lookup balance = peer_balances[consumer]
        send MESSAGE to recipient
        append list_var <- item
        append_block BLOCK_TYPE
    )

    STATE_B -> STATE_C auto when guard_expression (
        ...actions
    )

    STATE_B -> STATE_A on MESSAGE_TYPE when payload.field == value (
        ...actions
    )

    STATE_A -> STATE_C on timeout(TIMEOUT_PARAM) (
        ...actions
    )

    # Guard with fallback (else clause)
    STATE_A -> STATE_B auto when some_guard (
        ...success actions
    ) else -> STATE_ERROR (
        ...failure actions
    )
)
```

### Functions

```
function func_name(param1 type1, param2 type2) -> return_type (
    RETURN expression
)
```

### Expression Syntax

| Syntax | Meaning |
|--------|---------|
| `HASH(data)` | Cryptographic hash |
| `SIGN(data)` | Sign with actor's private key |
| `LOAD(key)` | Load from local store |
| `NOW()` | Current simulation time |
| `LENGTH(list)` | List length |
| `FILTER(list, pred)` | Filter list by predicate |
| `MAP(list, func)` | Map function over list |
| `peer_balances[peer]` | Lookup in map |
| `object.field` | Field access |
| `a + b`, `a - b` | Arithmetic |
| `a == b`, `a != b` | Comparison |
| `a and b`, `a or b` | Boolean logic |
| `{ ...base, field: value }` | Struct literal with spread |

### Action Syntax

| Action | Meaning |
|--------|---------|
| `store x, y, z` | Store message fields (in message-triggered transitions) or trigger params |
| `store x = expr` | Store computed value |
| `compute x = expr` | Compute and store value |
| `lookup x = expr` | Lookup value from chain state |
| `send MSG to target` | Send message to recipient |
| `append list <- item` | Append to list in store |
| `append_block TYPE` | Append block to chain |

### Guard Fallback Syntax

Transitions with guards can specify alternate behavior when the guard fails:

```
STATE_A -> STATE_B on trigger when guard_condition (
    ...success actions
) else -> STATE_C (
    ...failure actions
)
```

The `else` clause is optional. When omitted, the transition simply doesn't occur if the guard fails.

---

## Running the Generator

### Regenerate All Transactions

```bash
./scripts/regenerate_all.py --verbose
```

### Regenerate Specific Transaction

```bash
./scripts/regenerate_all.py --transaction 00_escrow_lock --verbose
```

### Generate Only Documentation

```bash
python scripts/generate_from_schema.py \
    docs/protocol/transactions/00_escrow_lock \
    --markdown \
    --output-dir docs/protocol/transactions
```

### Generate Only Python Code

```bash
python scripts/generate_from_schema.py \
    docs/protocol/transactions/00_escrow_lock \
    --python \
    --output-dir simulations/transactions
```

### Generate Only State Diagrams

```bash
./scripts/regenerate_all.py --graphs-only --verbose
```

---

## Adding a New Transaction

### 1. Create Schema Directory

```bash
mkdir docs/protocol/transactions/02_escrow_settle
```

### 2. Create transaction.omt

Define all structured elements using the DSL syntax.

### 3. Create commentary.md

Write the narrative sections (overview, attack analysis, open questions) and include placeholders for generated content:

```markdown
{{PARAMETERS}}
{{BLOCKS}}
{{MESSAGES}}
{{STATE_MACHINES}}
```

### 4. Generate Outputs

```bash
./scripts/regenerate_all.py --transaction 02_escrow_settle --verbose
```

### 5. Verify Generated Files

Check that these files were created:
- `docs/protocol/transactions/02_escrow_settle.md`
- `simulations/transactions/escrow_settle_generated.py`
- `docs/protocol/transactions/graphs/02_escrow_settle_*.mmd`

---

## DSL Feature Summary

The DSL parser supports:
- **Transaction metadata**: `transaction ID "name" "description"`
- **Imports**: `imports shared/common`
- **Parameters**: Named constants with units and descriptions
- **Enums**: Enumeration types with descriptions
- **Blocks**: Chain record types with fields
- **Messages**: Protocol messages with fields, sender, and recipients
- **Actors**: State machines with store, triggers, states, and transitions
- **Functions**: Helper functions with typed parameters and return types
- **Guards with fallback**: `when condition (...) else -> STATE (...)`
- **Lookup actions**: `lookup x = expr`
- **All expression types**: Arithmetic, comparison, boolean, function calls, field access
