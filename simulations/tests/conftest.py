"""
Pytest configuration for simulation tests.

Regenerates transaction code from DSL before running tests.
"""

import subprocess
import sys
from pathlib import Path


def pytest_configure(config):
    """Regenerate transaction code before test run."""
    project_root = Path(__file__).parent.parent.parent
    scripts_dir = project_root / "scripts"
    transactions_dir = project_root / "docs" / "protocol" / "transactions"
    output_dir = project_root / "simulations" / "transactions"

    # Find all transaction directories with .omt files
    transaction_dirs = []
    for item in transactions_dir.iterdir():
        if item.is_dir():
            omt_files = list(item.glob("*.omt"))
            if omt_files:
                transaction_dirs.append(item)

    # Delete old generated code before regeneration
    for tx_dir in sorted(transaction_dirs):
        tx_name = tx_dir.name
        # Find and delete generated Python files for this transaction
        generated_file = output_dir / f"{tx_name}_generated.py"
        if generated_file.exists():
            generated_file.unlink()
            print(f"Deleted old generated code: {generated_file.name}")

    # Regenerate each transaction
    failed = []
    for tx_dir in sorted(transaction_dirs):
        cmd = [
            sys.executable,
            str(scripts_dir / "generate_transaction.py"),
            str(tx_dir),
            "--python",
            "--output-dir", str(output_dir),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            failed.append((tx_dir.name, result.stderr))
        else:
            print(f"Regenerated: {tx_dir.name}")

    # Fail if any regeneration failed
    if failed:
        error_msg = "Code regeneration failed:\n"
        for name, stderr in failed:
            error_msg += f"\n=== {name} ===\n{stderr}"
        raise RuntimeError(error_msg)
