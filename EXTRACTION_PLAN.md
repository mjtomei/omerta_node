# Plan: Extracting Economy & Blockchain Content to Separate Repositories

## Overview

This plan outlines the extraction of economy, blockchain, protocol specifications, transaction code, simulation infrastructure, and academic writing from the `omerta` repository into **two new repositories**:

| Repository | Contents |
|------------|----------|
| **`omerta_protocol`** | Protocol specifications, simulations, academic papers |
| **`omerta_lang`** | Language toolchain (parser, validator, code generator) |

Both repos will be usable as git submodules of the main `omerta` repo. The `omerta_protocol` repo will depend on `omerta_lang` for code generation.

---

## 1. Content Inventory

### Content for `omerta_lang` (Language Toolchain)

| Category | Current Location | Lines/Size |
|----------|------------------|------------|
| Grammar definition | `scripts/dsl_grammar.lark` | 252 lines |
| AST definitions | `scripts/dsl_ast.py` | 594 lines |
| PEG parser | `scripts/dsl_peg_parser.py` | 763 lines |
| Semantic validator | `scripts/dsl_validate.py` | 1,105 lines |
| Linter | `scripts/dsl_lint.py` | 302 lines |
| Code generator | `scripts/generate_transaction.py` | ~1,500 lines |
| Batch regeneration | `scripts/regenerate_all.py` | 337 lines |
| Parser fuzzer | `scripts/fuzz_parser.py` | ~100 lines |
| Tests | `scripts/tests/test_*.py` | ~500 lines |

### Content for `omerta_protocol` (Specifications & Simulations)

| Category | Current Location | Lines/Size |
|----------|------------------|------------|
| Protocol specifications | `docs/protocol/` | ~5,000 lines |
| Transaction .omt files | `docs/protocol/transactions/`, `docs/protocol/shared/` | 3 files |
| Economic Simulations | `simulations/legacy/` | 20,756 lines Python |
| Transaction Simulations | `simulations/transactions/` | ~4 files, 200KB+ |
| Chain Primitives | `simulations/chain/` | ~4 files |
| Simulator Framework | `simulations/simulator/` | Full framework |
| Academic Paper | `docs/ACADEMIC_PAPER_PARTICIPATION_VERIFICATION.*` | 1,981 lines + PDF |
| Economy Documentation | `docs/economy/` | 10+ files, ~30KB |
| Research Analysis | `docs/research/` | TrustChain analysis |
| Ready-to-share Paper | `docs-ready-to-share/paper/` | 48KB whitepaper |
| Ready-to-share Protocol | `docs-ready-to-share/protocol/` | 5 files |

### Language Toolchain Overview

The transaction protocol uses a custom language (`.omt` files) with a complete toolchain that will live in `omerta_lang`:

- **Grammar** (`grammar.lark`) - Formal PEG grammar for the language
- **Parser** (`parser.py`) - Lark-based parser producing AST nodes
- **AST** (`ast.py`) - Dataclass definitions for all AST node types
- **Validator** (`validate.py`) - Semantic validation, type checking, reference checking
- **Linter** (`lint.py`) - Linting with auto-fix for typos
- **Generator** (`generators/`) - Produces Python code and Markdown docs from .omt
- **Tests** - Parser, validator, and linter tests

### Content to Keep in Main Repo

- All Swift source code (`Sources/`)
- Infrastructure documentation (`CLAUDE.md`, `DEPLOYMENT.md`, `README.md`)
- CLI and mesh networking docs (`docs/cli-architecture.md`, `docs/mesh-*.md`)
- VM networking docs (`docs/vm-network-*.md`)
- Test files (`Tests/`)
- Build configuration (`Package.swift`, etc.)

---

## 2. Proposed Repository Structure

```
omerta_protocol/
├── README.md                           # Repository overview
├── LICENSE
│
├── docs/                               # Project documentation (non-academic)
│   ├── README.md                       # Documentation index
│   ├── getting-started.md              # How to use this repo
│   └── protocol/                       # Protocol documentation
│       ├── DESIGN_PHILOSOPHY.md        # From docs/protocol/
│       ├── FORMAT.md                   # Language specification
│       ├── GENERATION.md               # Code generation docs
│       ├── GOSSIP.md                   # Gossip protocol
│       └── transactions/               # Transaction specifications
│           ├── 00_escrow_lock.md
│           ├── 01_cabal_attestation.md
│           ├── 02_escrow_settle.md
│           ├── 03_state_query.md
│           ├── 04_state_audit.md
│           └── 05_health_check.md
│
├── papers/                             # Academic & whitepaper content
│   ├── README.md                       # Papers index
│   ├── whitepaper/
│   │   ├── WHITEPAPER.md               # Main whitepaper
│   │   └── WHITEPAPER.pdf              # Rendered version
│   ├── technical-paper/
│   │   ├── PARTICIPATION_VERIFICATION.md   # Full technical paper
│   │   └── PARTICIPATION_VERIFICATION.pdf
│   ├── economic-analysis/
│   │   ├── ECONOMIC_ANALYSIS.md        # Market dynamics analysis
│   │   ├── ECONOMIC_ANALYSIS.pdf
│   │   └── unreliable-compute-thesis.md
│   ├── mechanism-design/
│   │   ├── participation-verification.md
│   │   ├── participation-verification-math.md
│   │   ├── participation-verification-defenses.md
│   │   ├── participation-verification-vulnerabilities.md
│   │   ├── participation-verification-social-attacks.md
│   │   └── participation-verification-vs-blockchain.md
│   ├── research/
│   │   ├── TRUSTCHAIN_ANALYSIS.md      # External research analysis
│   │   └── literature-review.md        # Extracted from technical paper
│   └── simulation-reports/
│       ├── ACADEMIC_REPORT.md          # Simulation results
│       ├── CONSOLIDATED_SIMULATION_REPORT.md
│       └── double_spend_simulation_plan.md
│
├── protocol/                           # Protocol source (.omt files)
│   ├── README.md                       # Protocol overview
│   ├── shared/
│   │   └── common.omt                  # Shared types
│   └── transactions/
│       ├── 00_escrow_lock/
│       │   └── transaction.omt
│       ├── 01_cabal_attestation/
│       │   └── transaction.omt
│       └── ... (other transactions)
│
├── simulations/                        # Simulation infrastructure
│   ├── README.md                       # Simulation overview
│   ├── requirements.txt                # Python dependencies
│   │
│   ├── economic/                       # Economic simulations (from legacy/)
│   │   ├── monetary_policy_simulation.py
│   │   ├── economic_value_simulation.py
│   │   ├── double_spend_simulation.py
│   │   ├── trust_simulation.py
│   │   ├── identity_rotation_attack.py
│   │   ├── reliability_market_simulation.py
│   │   └── failure_modes.py
│   │
│   ├── chain/                          # Chain primitives
│   │   ├── primitives.py
│   │   ├── types.py
│   │   ├── gossip.py
│   │   ├── network.py
│   │   ├── omerta_chain.py             # From legacy/
│   │   └── local_chain.py              # From legacy/
│   │
│   ├── transactions/                   # Transaction state machines
│   │   ├── escrow_lock.py
│   │   ├── escrow_lock_generated.py
│   │   ├── cabal_attestation.py
│   │   ├── cabal_attestation_generated.py
│   │   ├── verification_protocol.py    # From legacy/
│   │   └── simulation_harness.py
│   │
│   └── framework/                      # Simulation framework (from simulator/)
│       ├── engine.py
│       ├── runner.py
│       ├── agents/
│       ├── assertions/
│       ├── network/
│       └── traces/
│
├── scripts/                            # Utility scripts
│   ├── render_papers.py                # PDF generation
│   └── run_simulations.py              # Simulation runner
│
└── .github/                            # CI/CD
    └── workflows/
        ├── test.yml                    # Python tests
        └── generate.yml                # Regenerate artifacts
```

### `omerta_lang` Repository Structure

```
omerta_lang/
├── README.md                           # Language overview and usage
├── LICENSE
├── pyproject.toml                      # Python package configuration
├── requirements.txt                    # Dependencies (lark, etc.)
│
├── omerta_lang/                        # Python package
│   ├── __init__.py
│   ├── grammar.lark                    # Formal grammar definition
│   ├── ast.py                          # AST node definitions
│   ├── parser.py                       # PEG parser (Lark-based)
│   ├── validate.py                     # Semantic validation
│   ├── lint.py                         # Linting with auto-fix
│   └── fuzz.py                         # Parser fuzzing
│
├── omerta_lang/generators/             # Code generation
│   ├── __init__.py
│   ├── python.py                       # Generate Python state machines
│   ├── markdown.py                     # Generate Markdown documentation
│   └── graphs.py                       # Generate state machine diagrams
│
├── omerta_lang/cli/                    # Command-line tools
│   ├── __init__.py
│   ├── lint.py                         # omerta-lint command
│   ├── generate.py                     # omerta-generate command
│   └── regenerate.py                   # omerta-regenerate command
│
├── tests/                              # Test suite
│   ├── test_parser.py
│   ├── test_validate.py
│   ├── test_lint.py
│   └── test_generators.py
│
└── .github/
    └── workflows/
        ├── test.yml                    # Run tests
        └── publish.yml                 # Publish to PyPI (optional)
```

---

## 3. Documentation Organization Philosophy

### Project Documentation (`docs/`)
- **Purpose**: How to use and understand this repository
- **Audience**: Developers implementing or extending the protocol
- **Content**:
  - Protocol language specification and usage
  - Transaction type reference
  - Code generation documentation
  - Getting started guides

### Academic & Whitepaper Content (`papers/`)
- **Purpose**: Formal presentation of the system's theoretical foundations
- **Audience**: Researchers, investors, technical evaluators
- **Content**:
  - Whitepapers (executive-level, shareable)
  - Technical papers (academic rigor, citations)
  - Economic analysis (market dynamics, equilibrium)
  - Mechanism design (trust formulas, Sybil resistance)
  - Research notes (analysis of related work)
  - Simulation reports (empirical validation)

### Key Distinctions

| Aspect | Project Docs | Academic Papers |
|--------|--------------|-----------------|
| Tone | Technical reference | Formal academic |
| Citations | Minimal | Full bibliography |
| Math | Inline formulas | Full derivations |
| Format | Markdown reference | Paper structure |
| Updates | Frequent | Versioned releases |

---

## 4. Migration Steps

### Phase 1a: Create `omerta_lang` Repository
1. Create new repository `omerta_lang`
2. Initialize as Python package with `pyproject.toml`
3. Copy `.gitignore` (Python entries only)
4. Add LICENSE
5. Migrate language toolchain:
   - `scripts/dsl_grammar.lark` → `omerta_lang/grammar.lark`
   - `scripts/dsl_ast.py` → `omerta_lang/ast.py`
   - `scripts/dsl_peg_parser.py` → `omerta_lang/parser.py`
   - `scripts/dsl_validate.py` → `omerta_lang/validate.py`
   - `scripts/dsl_lint.py` → `omerta_lang/lint.py`
   - `scripts/fuzz_parser.py` → `omerta_lang/fuzz.py`
   - `scripts/generate_transaction.py` → `omerta_lang/generators/`
   - `scripts/regenerate_all.py` → `omerta_lang/cli/regenerate.py`
   - `scripts/tests/test_*.py` → `tests/`
6. **Rename all "dsl" references**:
   - File names: remove "dsl_" prefix (already shown above)
   - Internal references: replace "DSL" with "language" or "lang"
   - Class/function names: e.g., `DSLTransformer` → `LangTransformer`
   - Documentation: "DSL" → "Omerta language" or "transaction language"
   - Comments: update any "dsl" mentions
7. Update all import paths
8. Create CLI entry points in `pyproject.toml`
9. Configure CI for tests

### Phase 1b: Create `omerta_protocol` Repository
1. Create new repository `omerta_protocol`
2. Copy `docs-ready-to-share/PROJECT_OVERVIEW.md` → `README.md` (update internal links)
3. Copy `.gitignore` from main repo, remove Swift/Xcode-specific entries, keep:
   - Python: `.venv/`, `__pycache__/`, `*.pyc`
   - Generated files: `*_generated.py`, generated markdown
   - Editor: `*.swp`, `*~`
   - General: `.DS_Store`, `*.log`, `.cache/`
4. Add LICENSE
5. Add `omerta_lang` as dependency (git submodule or pip install)
6. Set up directory structure as outlined above
7. Configure CI for simulation tests

### Phase 2: Content Migration to `omerta_protocol`

1. **Protocol source files**
   - Copy `docs/protocol/shared/` -> `protocol/shared/`
   - Copy `docs/protocol/transactions/*/transaction.omt` -> `protocol/transactions/*/`

3. **Protocol documentation**
   - Copy `docs/protocol/*.md` -> `docs/protocol/`
   - Copy `docs/protocol/transactions/*.md` -> `docs/protocol/transactions/`

4. **Academic papers**
   - Copy `docs/ACADEMIC_PAPER_*` -> `papers/technical-paper/`
   - Copy `docs-ready-to-share/paper/WHITEPAPER.md` -> `papers/whitepaper/`
   - Copy `docs/economy/ECONOMIC_ANALYSIS.*` -> `papers/economic-analysis/`
   - Copy `docs/economy/participation-verification*.md` -> `papers/mechanism-design/`
   - Copy `docs/economy/double_spend_simulation_plan.md` -> `papers/simulation-reports/`
   - Copy `docs/research/TRUSTCHAIN_ANALYSIS.md` -> `papers/research/`

5. **Simulations**
   - Copy `simulations/legacy/*.py` -> `simulations/economic/` and `simulations/chain/`
   - Copy `simulations/transactions/` -> `simulations/transactions/`
   - Copy `simulations/chain/` -> `simulations/chain/`
   - Copy `simulations/simulator/` -> `simulations/framework/`
   - Copy `simulations/legacy/ACADEMIC_REPORT.md` -> `papers/simulation-reports/`

### Phase 3: Cleanup & Cross-References
1. Update all internal links in migrated documents
2. **Verify no imports from main `omerta` repo** - simulations must be fully self-contained
3. Configure `omerta_protocol` to use `omerta_lang` for code generation
4. Create index README files for each major directory
5. Remove migrated content from main `omerta` repo
6. Add both repos as git submodules in main `omerta` repo

### Phase 4: Documentation Polish
1. Create `papers/README.md` with paper index and abstracts
2. Create `simulations/README.md` with simulation descriptions
3. Add citation information and versioning for papers
4. Write `omerta_lang` README with usage examples

---

## 5. Files to Create in New Repository

### `README.md` (root)

Use the existing `docs-ready-to-share/PROJECT_OVERVIEW.md` as the base for the root README. It already contains:
- Project summary and motivation
- Links to networking, protocol, and transaction documentation
- Simulation infrastructure overview
- Transaction status table

Update the relative links to match the new directory structure.

### `papers/README.md`
```markdown
# Papers & Research

## Whitepapers
- [Omerta Whitepaper](whitepaper/WHITEPAPER.md) - Executive overview

## Technical Papers
- [Participation Verification](technical-paper/PARTICIPATION_VERIFICATION.md) -
  Full technical paper on trust-based consensus alternative

## Economic Analysis
- [Economic Analysis](economic-analysis/ECONOMIC_ANALYSIS.md) -
  Market dynamics of unreliable compute

## Mechanism Design
- [Trust Mathematics](mechanism-design/participation-verification-math.md) -
  Formal specification of trust computation
- [Defense Mechanisms](mechanism-design/participation-verification-defenses.md) -
  Sybil resistance and attack mitigation

## Simulation Reports
- [Academic Report](simulation-reports/ACADEMIC_REPORT.md) -
  Empirical validation through simulation
```

---

## 6. Post-Migration Tasks

1. **Main repo updates**
   - Remove migrated files
   - Update any imports/references
   - Add deprecation notices if needed
   - Update README to reference new repo

2. **New repo setup**
   - GitHub Actions for CI
   - PDF generation workflow
   - Python test runner for simulations
   - Documentation site (optional: GitHub Pages)

3. **Ongoing maintenance**
   - Define versioning strategy for papers
   - Establish contribution guidelines
   - Set up issue templates for paper feedback vs simulation bugs

---

## 7. Language Toolchain Usage (`omerta_lang`)

After migration, the toolchain will be a standalone Python package.

### Installation
```bash
# From omerta_lang repo
pip install -e .

# Or install as dependency in omerta_protocol
pip install omerta_lang  # if published to PyPI
```

### Linting Transactions
```bash
omerta-lint protocol/transactions/00_escrow_lock/transaction.omt
omerta-lint --all  # Lint all transactions
omerta-lint --fix FILE  # Auto-fix typos
```

### Regenerating Artifacts
```bash
# Regenerate a single transaction
omerta-generate protocol/transactions/00_escrow_lock --markdown --python

# Regenerate all transactions
omerta-regenerate
```

### Running `omerta_lang` Tests
```bash
cd omerta_lang
pytest tests/
```

### Dependencies
- Python 3.10+
- `lark` (PEG parser library)
- `graphviz` (optional, for state machine diagrams)

---

## 8. Post-Migration Test Verification

All of the following tests must pass after extraction is complete.

### `omerta_lang` Tests

| Test File | What It Verifies |
|-----------|------------------|
| `test_parser.py` | Grammar parsing, AST node construction, type expressions, triggers |
| `test_validate.py` | Semantic validation (state references, message refs, type checking) |
| `test_lint.py` | Linting rules, auto-fix functionality, typo detection |
| `test_generators.py` | Python and Markdown code generation |

### `omerta_protocol` Simulation Tests

| Test File | What It Verifies |
|-----------|------------------|
| `test_chain.py` | Chain primitives, block structure, hash computation |
| `test_gossip.py` | Gossip protocol, information propagation |
| `test_escrow_lock.py` | Escrow lock transaction state machine |
| `test_cabal_attestation.py` | Cabal attestation transaction state machine |
| `test_simulator_phase1.py` | Basic simulator setup and initialization |
| `test_simulator_phase2.py` | Network simulation, message passing |
| `test_simulator_phase3.py` | Agent behavior, state transitions |
| `test_simulator_phase4.py` | Multi-agent scenarios |
| `test_simulator_phase5.py` | Full protocol simulations |

### Integration Test: Code Regeneration

The `conftest.py` fixture automatically regenerates Python code from `.omt` files before running simulation tests. This verifies the full pipeline:

```
.omt files → omerta_lang parser → AST → omerta_lang generator → Python state machines → Simulation tests
```

### Running All Tests

```bash
# omerta_lang tests
cd omerta_lang
pytest tests/ -v

# omerta_protocol simulation tests (auto-regenerates code first)
cd omerta_protocol
pytest simulations/tests/ -v

# Lint all transaction files
omerta-lint --all
```

### Expected Results

After successful migration:
- All `omerta_lang` tests pass
- All `omerta_protocol` simulation tests pass
- `omerta-lint --all` reports no errors (warnings acceptable)
- `omerta-regenerate` completes without errors

---

## 9. Decisions

| Question | Decision |
|----------|----------|
| Repository names | `omerta_protocol` (specs/sims) + `omerta_lang` (language toolchain) |
| PDF hosting | Keep in repo |
| Simulation data | Keep in repo |
| .gitignore | Copy from main `omerta` repo (Python entries) |
| Cross-repo dependencies | **None from main repo** - simulations self-contained; `omerta_protocol` depends on `omerta_lang` |
| Repo relationship | Both repos usable as git submodules of main `omerta` repo |
| Language toolchain | Separate `omerta_lang` repo as standalone Python package |

---

## 10. Migration Complexity

| Task | Notes |
|------|-------|
| `omerta_lang` setup | Convert scripts to proper Python package with entry points |
| `omerta_protocol` setup | Straightforward file migration |
| Language toolchain migration | Import path updates, package structure refactoring, rename "dsl" → "lang" |
| File migration | Many files, internal links need updating |
| Documentation cleanup | Cross-references between docs |
| Simulation reorganization | Some files need categorization |
| README/index creation | New files to write |
| CI/CD setup | Standard GitHub Actions for both repos |
| Integration | Configure `omerta_protocol` to use `omerta_lang` |

The `omerta_lang` extraction is the most complex piece due to:
- Converting standalone scripts to a proper Python package
- Creating CLI entry points (`omerta-lint`, `omerta-generate`, etc.)
- Updating imports across all modules
- Path references to grammar file need to use package resources
- Tests need to find .omt fixtures correctly
