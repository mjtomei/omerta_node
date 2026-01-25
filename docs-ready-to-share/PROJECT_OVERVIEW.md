# Omerta: Infrastructure for Machine-Managed Compute

---

## Summary

Omerta is a platform for ephemeral compute swarms which allows providers to share their compute without worrying about what is being run. It does this by deleting VMs after use and requiring all networking traffic go through a VPN served by the compute consumer. This decreases risks of providing compute in a swarm without requiring heavyweight mechanisms for encrypted computation or identity attestation. This functionality is built on top of a new mesh networking library which supports encrypted communication and seamless reconnection on session interruptions from either side.

Omerta also includes a protocol and associated programming language for specifying transactions on a novel blockchain which supports a type of eventual consistency for which there is never a single global consensus. This greatly reduces the overhead of currency and identity management without losing the benefits of blockchains. The ability to tolerate a lack of a single global consensus is accomplished by moving trust into explicit mechanisms for granting trust and verifying that trust is not abused which are recorded on-chain. Transactions on this blockchain are described using a new language describing Mealy machines and adopting a lockless programming style for synchronization. 

In order to gain confidence in the technology, we simulate economic actors participating in transactions and attempting to exploit the system. We study various types of economic participants and compute market conditions, and we borrow from an existing blockchain network simulation methodology to try to maintain accuracy in the performance characteristics of networking between participants. We also study the potential economic impact for existing cloud providers and potential market participants as well as various attack scenarios with higher level simulation methodologies.

---

## Why This Might Work Now

Prior attempts at decentralized compute (Golem, iExec, BOINC) faced real limitations:
- Humans don't want to manage unreliable infrastructure
- Blockchain consensus overhead erased the cost advantage
- Complex setup limited participation to experts
- Token economics created extractive incentives

Machine intelligence solves each of these problems:
- Machines can orchestrate parallel workloads across unreliable infrastructure—retrying, rerouting, recovering—in ways humans never would. What's friction for humans is normal operation for machines. 
- Trust measurement at scale was impractical when humans had to rate each other. Automated verification of every transaction enables trust computation that prior systems could only theorize about.
- We remove friction during onboarding through app store compatibility and user space execution. And we choose a simpler software architecture over unclear benefits from more complex mechanisms for managing cloud compute. Machine intelligences have shown a capability to handle the more diverse and unpredictable compute environments that will be exposed as a result.
- An infrastructure project can have benefits beyond what are attainable with things that work at smaller scales. The introduction of a new market comes with insider benefits that likely increase with good early choices that increase user trust like open sourcing the code and not retaining coins for yourself.

---

## What We've Built

### Networking Layer

A peer-to-peer mesh network handling NAT traversal, peer discovery, and encrypted communication.

| Document | Description |
|----------|-------------|
| [API.md](mesh/API.md) | Channel-based messaging API with request/response patterns |
| [CRYPTOGRAPHY.md](mesh/CRYPTOGRAPHY.md) | Wire format, ChaCha20-Poly1305 encryption, X25519 key exchange |
| [STRUCTURE.md](mesh/STRUCTURE.md) | Module organization and file structure |

**Implementation**: 17,000 lines of Swift, 16,000 lines of tests. Deployed and tested across LAN and WAN with NAT traversal.

### Protocol Layer 

A domain-specific language for specifying distributed transaction protocols, with code generation and simulation infrastructure.

| Document | Description |
|----------|-------------|
| [DESIGN_PHILOSOPHY.md](protocol/DESIGN_PHILOSOPHY.md) | Why lockless consensus, comparison to Lightning/blockchain/2PC |
| [FORMAT.md](protocol/FORMAT.md) | DSL specification for transaction state machines |
| [FORMAL_SPECIFICATION.md](protocol/FORMAL_SPECIFICATION.md) | Academic formalization, relationship to session types, future verification work |
| [GENERATION.md](protocol/GENERATION.md) | How schemas produce documentation and executable code |
| [GOSSIP.md](protocol/GOSSIP.md) | Information propagation protocol |

### Transaction Specifications

Specifications for the initial transaction types, with state machines, parameters, and attack analysis.

| Transaction | Status | Description |
|-------------|--------|-------------|
| [00_escrow_lock.md](transactions/00_escrow_lock.md) | Tested | Lock funds with distributed witness consensus |
| [01_cabal_attestation.md](transactions/01_cabal_attestation.md) | Tested | Witness attestation to compute session outcomes |
| [02_escrow_settle.md](transactions/02_escrow_settle.md) | Draft | Release locked funds after service completion |
| [03_state_query.md](transactions/03_state_query.md) | Draft | Query chain state from peers |
| [04_state_audit.md](transactions/04_state_audit.md) | Draft | Third-party verification of chain consistency |
| [05_health_check.md](transactions/05_health_check.md) | Draft | Liveness verification for witnesses |

### Simulation Infrastructure 

Discrete event simulation with agent-based testing to validate protocol correctness and attack resistance.

| Document | Description |
|----------|-------------|
| [SIMULATION.md](simulator/SIMULATION.md) | Architecture, results, and identified limitations |
| [SIMULATOR_DESIGN.md](simulator/SIMULATOR_DESIGN.md) | Full implementation details |

**Network model**: SimBlock-style simulation with region-based latency (6 geographic regions), Pareto-distributed delays matching real Bitcoin network measurements, connection types (Fiber/Cable/DSL/Mobile), and network partition simulation.

**AI agents**: Claude API integration for LLM-backed agents that can reason about protocol state and select actions. Agents receive role/goal descriptions, protocol rules, current state, and available actions.

**Tests**: Transaction tests for escrow_lock and cabal_attestation, simulator phase tests, gossip and chain tests.

**Economic simulations**: 7 attack scenarios, 5-year extended runs, automated monetary policy response validation.

### Theoretical Foundation

| Document | Description |
|----------|-------------|
| [WHITEPAPER.md](paper/WHITEPAPER.md) | Technical whitepaper with literature review |

---

