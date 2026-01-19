#!/usr/bin/env python3
"""
Regenerate all transaction artifacts from DSL files.

This script regenerates:
1. Markdown documentation
2. Python simulation code
3. State machine graph imagery (Mermaid diagrams rendered to SVG/PNG)

Usage:
    ./scripts/regenerate_all.py [--graphs-only] [--verbose]
"""

import argparse
import subprocess
import sys
from pathlib import Path


# Directories
REPO_ROOT = Path(__file__).parent.parent
SCHEMA_BASE = REPO_ROOT / "docs" / "protocol" / "transactions"
PYTHON_OUTPUT = REPO_ROOT / "simulations" / "transactions"
GRAPHS_OUTPUT = REPO_ROOT / "docs" / "protocol" / "transactions" / "graphs"


def find_transaction_dirs() -> list[Path]:
    """Find all transaction directories containing DSL files (.omt or .yaml)."""
    tx_dirs = []
    for item in sorted(SCHEMA_BASE.iterdir()):
        if item.is_dir():
            # Prefer .omt files, fall back to .yaml
            dsl_file = item / "transaction.omt"
            yaml_file = item / "schema.yaml"
            if dsl_file.exists() or yaml_file.exists():
                tx_dirs.append(item)
    return tx_dirs


def generate_mermaid_statechart(tx_def: dict, actor_name: str) -> str:
    """Generate a Mermaid stateDiagram-v2 for an actor."""
    actor_info = tx_def.get("actors", {}).get(actor_name, {})
    if not actor_info:
        return ""

    lines = ["stateDiagram-v2"]

    states = actor_info.get("states", {})
    initial_state = actor_info.get("initial_state", "IDLE")
    transitions = actor_info.get("transitions", [])

    # Initial state arrow
    lines.append(f"    [*] --> {initial_state}")

    # Add state notes for terminal states
    for state_name, state_info in states.items():
        if state_info.get("terminal", False):
            lines.append(f"    {state_name} --> [*]")

    # Add transitions
    for trans in transitions:
        from_state = trans.get("from", "?")
        to_state = trans.get("to", "?")
        trigger = trans.get("trigger", "auto")
        guard = trans.get("guard", "")

        # Format the label
        if trigger == "auto":
            label = "[auto]"
        elif trigger.startswith("timeout("):
            label = trigger
        else:
            label = trigger

        if guard:
            # Truncate long guards
            guard_short = guard[:30] + "..." if len(guard) > 30 else guard
            label = f"{label}\\n[{guard_short}]"

        # Mermaid syntax for transition with label
        lines.append(f"    {from_state} --> {to_state} : {label}")

    return "\n".join(lines)


def generate_dot_statechart(tx_def: dict, actor_name: str) -> str:
    """Generate a DOT (Graphviz) statechart for an actor."""
    actor_info = tx_def.get("actors", {}).get(actor_name, {})
    if not actor_info:
        return ""

    lines = [
        "digraph {",
        '    rankdir=TB;',
        '    node [shape=box, style=rounded];',
        '    edge [fontsize=10];',
        '',
    ]

    states = actor_info.get("states", {})
    initial_state = actor_info.get("initial_state", "IDLE")
    transitions = actor_info.get("transitions", [])

    # Initial state (invisible point)
    lines.append('    __start__ [shape=point, width=0.2];')
    lines.append(f'    __start__ -> {initial_state};')
    lines.append('')

    # Terminal states get double border
    for state_name, state_info in states.items():
        if state_info.get("terminal", False):
            lines.append(f'    {state_name} [shape=box, style="rounded,bold"];')

    lines.append('')

    # Transitions
    for trans in transitions:
        from_state = trans.get("from", "?")
        to_state = trans.get("to", "?")
        trigger = trans.get("trigger", "auto")
        guard = trans.get("guard", "")

        # Format the label
        if trigger == "auto":
            label = "auto"
        elif trigger.startswith("timeout("):
            label = trigger
        else:
            label = trigger

        if guard:
            guard_short = guard[:25] + "..." if len(guard) > 25 else guard
            label = f"{label}\\n[{guard_short}]"

        lines.append(f'    {from_state} -> {to_state} [label="{label}"];')

    lines.append("}")
    return "\n".join(lines)


def write_graph_files(tx_dir: Path, tx_def: dict, output_dir: Path, verbose: bool = False):
    """Write graph files (Mermaid and DOT) for all actors in a transaction."""
    tx_name = tx_dir.name
    actors = tx_def.get("actors", {})

    output_dir.mkdir(parents=True, exist_ok=True)

    for actor_name in actors:
        # Mermaid file
        mermaid_content = generate_mermaid_statechart(tx_def, actor_name)
        mermaid_path = output_dir / f"{tx_name}_{actor_name.lower()}.mmd"
        mermaid_path.write_text(mermaid_content)
        if verbose:
            print(f"  Generated: {mermaid_path}")

        # DOT file
        dot_content = generate_dot_statechart(tx_def, actor_name)
        dot_path = output_dir / f"{tx_name}_{actor_name.lower()}.dot"
        dot_path.write_text(dot_content)
        if verbose:
            print(f"  Generated: {dot_path}")

        # Try to render SVG using Graphviz if available
        svg_path = output_dir / f"{tx_name}_{actor_name.lower()}.svg"
        try:
            result = subprocess.run(
                ["dot", "-Tsvg", "-o", str(svg_path), str(dot_path)],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                if verbose:
                    print(f"  Rendered: {svg_path}")
            else:
                if verbose:
                    print(f"  Warning: Could not render SVG (graphviz error)")
        except FileNotFoundError:
            if verbose:
                print(f"  Note: Install graphviz to render SVG (dot command not found)")


def regenerate_markdown(tx_dir: Path, verbose: bool = False) -> bool:
    """Regenerate markdown documentation for a transaction."""
    tx_name = tx_dir.name
    output_path = tx_dir.parent / f"{tx_name}.md"

    result = subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts" / "generate_transaction.py"),
            "--markdown",
            "--output-dir", str(tx_dir.parent),
            str(tx_dir),
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        if verbose:
            print(f"  Generated: {output_path}")
        return True
    else:
        print(f"  Error generating markdown: {result.stderr}", file=sys.stderr)
        return False


def regenerate_python(tx_dir: Path, verbose: bool = False) -> bool:
    """Regenerate Python simulation code for a transaction."""
    tx_name = tx_dir.name.split("_", 1)[1] if "_" in tx_dir.name else tx_dir.name
    output_path = PYTHON_OUTPUT / f"{tx_name}_generated.py"

    result = subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts" / "generate_transaction.py"),
            "--python",
            "--output-dir", str(PYTHON_OUTPUT),
            str(tx_dir),
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        if verbose:
            print(f"  Generated: {output_path}")
        return True
    else:
        print(f"  Error generating Python: {result.stderr}", file=sys.stderr)
        return False


def regenerate_graphs(tx_dir: Path, verbose: bool = False) -> bool:
    """Regenerate state machine graphs for a transaction."""
    # Import the DSL loader
    sys.path.insert(0, str(REPO_ROOT / "scripts"))
    try:
        from dsl_converter import load_transaction
    except ImportError:
        print(f"  Error: Could not import DSL loader", file=sys.stderr)
        return False

    # Try DSL first, then YAML
    dsl_path = tx_dir / "transaction.omt"
    yaml_path = tx_dir / "schema.yaml"

    try:
        if dsl_path.exists():
            tx_def = load_transaction(dsl_path)
        elif yaml_path.exists():
            import yaml
            with open(yaml_path) as f:
                tx_def = yaml.safe_load(f)
        else:
            print(f"  Error: No transaction file found in {tx_dir}", file=sys.stderr)
            return False
    except Exception as e:
        print(f"  Error loading transaction: {e}", file=sys.stderr)
        return False

    write_graph_files(tx_dir, tx_def, GRAPHS_OUTPUT, verbose)
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Regenerate all transaction artifacts from DSL files"
    )
    parser.add_argument(
        "--graphs-only",
        action="store_true",
        help="Only regenerate graph files",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Show detailed output",
    )
    parser.add_argument(
        "--transaction", "-t",
        help="Only process specific transaction (e.g., '00_escrow_lock')",
    )

    args = parser.parse_args()

    # Find all transaction directories
    tx_dirs = find_transaction_dirs()

    if not tx_dirs:
        print("No transaction directories found.", file=sys.stderr)
        sys.exit(1)

    # Filter to specific transaction if requested
    if args.transaction:
        tx_dirs = [d for d in tx_dirs if d.name == args.transaction]
        if not tx_dirs:
            print(f"Transaction not found: {args.transaction}", file=sys.stderr)
            sys.exit(1)

    print(f"Found {len(tx_dirs)} transaction(s)")
    print()

    success_count = 0
    error_count = 0

    for tx_dir in tx_dirs:
        print(f"Processing: {tx_dir.name}")

        if args.graphs_only:
            if regenerate_graphs(tx_dir, args.verbose):
                success_count += 1
            else:
                error_count += 1
        else:
            # Regenerate all artifacts
            md_ok = regenerate_markdown(tx_dir, args.verbose)
            py_ok = regenerate_python(tx_dir, args.verbose)
            graph_ok = regenerate_graphs(tx_dir, args.verbose)

            if md_ok and py_ok and graph_ok:
                success_count += 1
            else:
                error_count += 1

        print()

    print(f"Done: {success_count} succeeded, {error_count} failed")

    if error_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
