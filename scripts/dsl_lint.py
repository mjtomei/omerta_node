#!/usr/bin/env python3
"""
Lint DSL transaction files for errors and warnings.

Usage:
    python dsl_lint.py <file.omt> [file2.omt ...]
    python dsl_lint.py --all       # Lint all transaction files
    python dsl_lint.py --fix FILE  # Auto-fix obvious typos in FILE
"""

import argparse
import hashlib
import re
import sys
from pathlib import Path

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from dsl_peg_parser import parse
from dsl_validate import validate_schema, Fix

# Base directory for resolving imports
PROTOCOL_BASE = Path(__file__).parent.parent / "docs" / "protocol"


def content_hash(content: str) -> str:
    """Get a short hash of file content."""
    return hashlib.sha256(content.encode()).hexdigest()[:16]


SESSION_TIMEOUT_SECONDS = 600  # 10 minutes


def get_backup_paths(path: Path) -> tuple[Path, Path, Path]:
    """Get paths for backup and tracking files.

    Returns (orig_backup, pre_fix_backup, hash_file):
    - orig_backup: .filename.omt.orig - original before fixes (refreshed after session timeout)
    - pre_fix_backup: .filename.omt.bak - state before most recent fix (always overwritten)
    - hash_file: .filename.omt.fixed-hash - hash of content after last fix (to detect manual edits)
    """
    parent = path.parent
    name = path.name
    orig_backup = parent / f".{name}.orig"
    pre_fix_backup = parent / f".{name}.bak"
    hash_file = parent / f".{name}.fixed-hash"
    return orig_backup, pre_fix_backup, hash_file


def was_manually_edited(path: Path, content: str) -> bool:
    """Check if file was manually edited since last fix.

    Compares current content hash against stored hash from last fix.
    """
    _, _, hash_file = get_backup_paths(path)
    if not hash_file.exists():
        return True  # No record of fixes, assume edited

    last_fixed_hash = hash_file.read_text().strip()
    return content_hash(content) != last_fixed_hash


def record_fixed_hash(path: Path, content: str):
    """Record hash of content after fix, to detect future manual edits."""
    _, _, hash_file = get_backup_paths(path)
    hash_file.write_text(content_hash(content))


def save_backup(path: Path, content: str) -> tuple[Path | None, Path]:
    """Save content to backup files before applying fixes.

    Strategy:
    - .orig = original before fixes in this session
    - .bak = state just before this fix run (always overwritten)
    - .fixed-hash = hash of content after last fix (to detect manual edits)

    Session logic (for .orig):
    - If .orig doesn't exist → create it
    - If .orig exists and is < 10 minutes old → keep it (same session)
    - If .orig exists and is >= 10 minutes old:
      - If file was manually edited → replace .orig (new session)
      - If file was not edited → keep .orig

    Returns (orig_path, bak_path) - orig_path is None if .orig was kept from previous session.
    """
    import time

    orig_backup, pre_fix_backup, _ = get_backup_paths(path)

    orig_created = None

    if not orig_backup.exists():
        # First fix ever - create original backup
        orig_backup.write_text(content)
        orig_created = orig_backup
    else:
        # Check if we should refresh .orig (new session)
        orig_age = time.time() - orig_backup.stat().st_mtime

        if orig_age >= SESSION_TIMEOUT_SECONDS and was_manually_edited(path, content):
            # Session expired and file was manually edited - new session
            orig_backup.write_text(content)
            orig_created = orig_backup

    # Always save current state to .bak (overwrites previous)
    pre_fix_backup.write_text(content)

    return orig_created, pre_fix_backup


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


def apply_fixes(source: str, fixes: list[Fix]) -> str:
    """Apply fixes to source code.

    Fixes are applied by finding and replacing the old_text with new_text
    on the specified line. Fixes are applied in reverse line order to
    preserve line numbers.
    """
    lines = source.split('\n')

    # Group fixes by line and sort by line descending
    fixes_by_line: dict[int, list[Fix]] = {}
    for fix in fixes:
        if fix.line > 0 and fix.line <= len(lines):
            fixes_by_line.setdefault(fix.line, []).append(fix)

    # Apply fixes in reverse line order
    for line_num in sorted(fixes_by_line.keys(), reverse=True):
        line_fixes = fixes_by_line[line_num]
        line_idx = line_num - 1  # Convert to 0-indexed
        line = lines[line_idx]

        for fix in line_fixes:
            # Use word boundary matching to avoid partial replacements
            # e.g., don't replace "IDLE" in "IDLE_STATE"
            pattern = r'\b' + re.escape(fix.old_text) + r'\b'
            new_line = re.sub(pattern, fix.new_text, line, count=1)
            if new_line != line:
                line = new_line

        lines[line_idx] = line

    return '\n'.join(lines)


def lint_file(path: Path, apply_fix: bool = False) -> tuple[int, int, int]:
    """Lint a single file. Returns (error_count, warning_count, fix_count)."""
    try:
        with open(path) as f:
            source = f.read()
    except FileNotFoundError:
        print(f"{path}: file not found")
        return 1, 0, 0

    try:
        schema = parse(source)
    except Exception as e:
        print(f"{path}: parse error: {e}")
        return 1, 0, 0

    # Resolve imports
    imported_schemas = resolve_imports(schema, path.parent)

    result = validate_schema(schema, imported_schemas)

    # Collect fixes
    fixes = result.fixes

    # Apply fixes if requested
    if apply_fix and fixes:
        fixed_source = apply_fixes(source, fixes)
        if fixed_source != source:
            # Save backups before modifying
            orig_created, bak_path = save_backup(path, source)

            with open(path, 'w') as f:
                f.write(fixed_source)

            # Record hash of fixed content to detect future manual edits
            record_fixed_hash(path, fixed_source)

            # Report what was saved
            if orig_created:
                print(f"{path}: applied {len(fixes)} fix(es)")
                print(f"  Original saved to: {orig_created}")
                print(f"  Pre-fix backup: {bak_path}")
            else:
                orig_path, _, _ = get_backup_paths(path)
                print(f"{path}: applied {len(fixes)} fix(es)")
                print(f"  Pre-fix backup: {bak_path}")
                print(f"  (Original preserved at: {orig_path})")

            # Re-lint to show remaining issues
            return lint_file(path, apply_fix=False)

    # Print errors and warnings
    for error in result.errors:
        loc = f":{error.line}" if error.line else ""
        fix_marker = " [fixable]" if error.fix else ""
        print(f"{path}{loc}: error: {error.message}{fix_marker}")

    for warning in result.warnings:
        loc = f":{warning.line}" if warning.line else ""
        fix_marker = " [fixable]" if warning.fix else ""
        print(f"{path}{loc}: warning: {warning.message}{fix_marker}")

    return len(result.errors), len(result.warnings), result.fixable_count


def find_all_transactions() -> list[Path]:
    """Find all transaction.omt files."""
    base = Path(__file__).parent.parent / "docs" / "protocol" / "transactions"
    return sorted(base.glob("*/transaction.omt"))


def main():
    parser = argparse.ArgumentParser(
        description="Lint DSL transaction files for errors and warnings."
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Files to lint"
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Lint all transaction files"
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Auto-fix obvious typos (single-character edits with one suggestion)"
    )

    args = parser.parse_args()

    if args.all:
        files = find_all_transactions()
        if not files:
            print("No transaction files found")
            sys.exit(1)
    elif args.files:
        files = [Path(f) for f in args.files]
    else:
        parser.print_help()
        sys.exit(1)

    total_errors = 0
    total_warnings = 0
    total_fixable = 0

    for path in files:
        errors, warnings, fixable = lint_file(path, apply_fix=args.fix)
        total_errors += errors
        total_warnings += warnings
        total_fixable += fixable

    if total_errors or total_warnings:
        print(f"\n{total_errors} error(s), {total_warnings} warning(s)")

        # Suggest --fix if there are fixable issues and we didn't already fix
        if total_fixable > 0 and not args.fix:
            if len(files) == 1:
                print(f"\n{total_fixable} issue(s) can be auto-fixed. Run:")
                print(f"  python {sys.argv[0]} --fix {files[0]}")
            else:
                print(f"\n{total_fixable} issue(s) can be auto-fixed. Run with --fix to apply.")

    sys.exit(1 if total_errors else 0)


if __name__ == "__main__":
    main()
