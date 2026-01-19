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

    # Regenerate each transaction
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
            print(f"Warning: Failed to regenerate {tx_dir.name}")
            print(result.stderr)
        else:
            print(f"Regenerated: {tx_dir.name}")
