#!/usr/bin/env python3
"""
Lint DSL transaction files for errors and warnings.

Usage:
    python dsl_lint.py <file.omt> [file2.omt ...]
    python dsl_lint.py --all  # Lint all transaction files
"""

import sys
from pathlib import Path

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from dsl_peg_parser import parse
from dsl_validate import validate_schema

# Base directory for resolving imports
PROTOCOL_BASE = Path(__file__).parent.parent / "docs" / "protocol"


def resolve_imports(schema, base_path: Path) -> list:
    """Resolve and parse all imports from a schema."""
    imported_schemas = []

    for imp in schema.imports:
        # Import path like "shared/common" -> docs/protocol/shared/common.omt
        import_path = PROTOCOL_BASE / f"{imp.path}.omt"

        if not import_path.exists():
            print(f"warning: import not found: {imp.path} (looked at {import_path})")
            continue

        try:
            with open(import_path) as f:
                imported_source = f.read()
            imported_schema = parse(imported_source)
            imported_schemas.append(imported_schema)

            # Recursively resolve nested imports
            nested = resolve_imports(imported_schema, import_path.parent)
            imported_schemas.extend(nested)
        except Exception as e:
            print(f"warning: failed to parse import {imp.path}: {e}")

    return imported_schemas


def lint_file(path: Path) -> tuple[int, int]:
    """Lint a single file. Returns (error_count, warning_count)."""
    try:
        with open(path) as f:
            source = f.read()
    except FileNotFoundError:
        print(f"{path}: file not found")
        return 1, 0

    try:
        schema = parse(source)
    except Exception as e:
        print(f"{path}: parse error: {e}")
        return 1, 0

    # Resolve imports
    imported_schemas = resolve_imports(schema, path.parent)

    result = validate_schema(schema, imported_schemas)

    for error in result.errors:
        loc = f":{error.line}" if error.line else ""
        print(f"{path}{loc}: error: {error.message}")

    for warning in result.warnings:
        loc = f":{warning.line}" if warning.line else ""
        print(f"{path}{loc}: warning: {warning.message}")

    return len(result.errors), len(result.warnings)


def find_all_transactions() -> list[Path]:
    """Find all transaction.omt files."""
    base = Path(__file__).parent.parent / "docs" / "protocol" / "transactions"
    return sorted(base.glob("*/transaction.omt"))


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    if sys.argv[1] == "--all":
        files = find_all_transactions()
        if not files:
            print("No transaction files found")
            sys.exit(1)
    else:
        files = [Path(arg) for arg in sys.argv[1:]]

    total_errors = 0
    total_warnings = 0

    for path in files:
        errors, warnings = lint_file(path)
        total_errors += errors
        total_warnings += warnings

    if total_errors or total_warnings:
        print(f"\n{total_errors} error(s), {total_warnings} warning(s)")

    sys.exit(1 if total_errors else 0)


if __name__ == "__main__":
    main()
