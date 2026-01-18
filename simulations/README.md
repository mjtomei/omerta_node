# Omerta Simulations

This directory contains simulation code for the Omerta distributed compute marketplace.

## Directory Structure

```
simulations/
├── chain/              # Core blockchain primitives
│   ├── primitives.py   # Block, Chain, crypto functions
│   ├── types.py        # Session, attestation, escrow types
│   └── network.py      # Network simulation
├── transactions/       # Transaction state machines
│   └── escrow_lock.py  # Step 0: Escrow locking protocol
├── tests/              # Unit tests
│   └── test_escrow_lock.py
└── legacy/             # Early exploratory simulations (preserved for reference)
```

## Current Implementation

### Chain Package (`chain/`)

Core blockchain primitives extracted from the original `omerta_chain.py`:

- **primitives.py**: `Block`, `Chain`, cryptographic functions (`hash_data`, `sign`, `verify_sig`)
- **types.py**: `SessionTerms`, `SessionStart`, `SessionEnd`, `CabalAttestation`, escrow types
- **network.py**: `Network` class for simulating peer interactions, keepalives, sessions

### Transactions (`transactions/`)

State machine implementations following the formal protocol specifications in `docs/protocol/transactions/`:

- **escrow_lock.py**: Consumer, Provider, and Witness actors for escrow locking (Step 0)
  - 900+ lines of state machine code
  - Implements provider-driven witness selection with consumer verification
  - Full message passing and consensus protocol

### Tests (`tests/`)

Unit tests using pytest:

```bash
# Run from project root
source simulations/.venv/bin/activate
PYTHONPATH=${OMERTA_DIR} python -m pytest simulations/tests/ -v
```

## Legacy Simulations (`legacy/`)

Early exploratory simulations preserved for reference. See `legacy/README.md` for details on:

- Trust system simulations
- Identity rotation attack analysis
- Reliability market experiments
- Double-spend resolution
- Economic value analysis

## Usage

```python
# Using the chain package
from simulations.chain import Network, Chain, BlockType

net = Network()
alice = net.create_identity("alice")
bob = net.create_identity("bob")

# Simulate keepalives
net.simulate_keepalives(rounds=10)

# Run a session
terms, attestation = net.run_full_session(
    alice.public_key,
    bob.public_key,
    duration_hours=1.0,
)

# Using the escrow lock transaction
from simulations.transactions.escrow_lock import (
    Consumer, Provider, Witness,
    EscrowLockSimulation
)

sim = EscrowLockSimulation(net)
consumer = sim.create_consumer("pk_alice")
provider = sim.create_provider("pk_bob")
# ... add witnesses, run simulation
```

## Related Documentation

- Protocol specifications: `docs/protocol/`
- Format specification: `docs/protocol/FORMAT.md`
- Escrow lock spec: `docs/protocol/transactions/00_escrow_lock.md`
