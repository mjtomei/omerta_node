"""Tests for DSL linter auto-fix functionality."""

import pytest
import tempfile
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent))

from dsl_lint import (
    apply_fixes, save_backup, get_backup_paths, content_hash,
    record_fixed_hash, was_manually_edited, SESSION_TIMEOUT_SECONDS,
)
from dsl_validate import Fix


class TestApplyFixes:
    """Test fix application logic."""

    def test_apply_single_fix(self):
        source = "IDEL -> DONE auto"
        fixes = [Fix(old_text="IDEL", new_text="IDLE", line=1)]
        result = apply_fixes(source, fixes)
        assert result == "IDLE -> DONE auto"

    def test_apply_multiple_fixes_same_line(self):
        source = "IDEL -> DON auto"
        fixes = [
            Fix(old_text="IDEL", new_text="IDLE", line=1),
            Fix(old_text="DON", new_text="DONE", line=1),
        ]
        result = apply_fixes(source, fixes)
        assert result == "IDLE -> DONE auto"

    def test_apply_fixes_different_lines(self):
        source = "IDEL -> DONE auto\nSEND(sender, REQUET)"
        fixes = [
            Fix(old_text="IDEL", new_text="IDLE", line=1),
            Fix(old_text="REQUET", new_text="REQUEST", line=2),
        ]
        result = apply_fixes(source, fixes)
        assert result == "IDLE -> DONE auto\nSEND(sender, REQUEST)"

    def test_fix_with_word_boundary(self):
        """Fixes should use word boundaries to avoid partial replacements."""
        source = "IDLE_STATE -> IDLE auto"
        fixes = [Fix(old_text="IDLE", new_text="READY", line=1)]
        result = apply_fixes(source, fixes)
        # Should only replace the standalone IDLE, not IDLE in IDLE_STATE
        assert result == "IDLE_STATE -> READY auto"

    def test_fix_skips_invalid_line(self):
        """Fixes with invalid line numbers should be skipped."""
        source = "IDLE -> DONE"
        fixes = [Fix(old_text="IDLE", new_text="READY", line=0)]  # Invalid line
        result = apply_fixes(source, fixes)
        assert result == "IDLE -> DONE"  # Unchanged

    def test_fix_preserves_other_lines(self):
        source = "line1\nIDEL -> DONE\nline3"
        fixes = [Fix(old_text="IDEL", new_text="IDLE", line=2)]
        result = apply_fixes(source, fixes)
        assert result == "line1\nIDLE -> DONE\nline3"


class TestBackupFunctionality:
    """Test backup save/restore functionality."""

    def test_content_hash_consistency(self):
        """Same content should produce same hash."""
        content = "test content"
        assert content_hash(content) == content_hash(content)

    def test_content_hash_differs(self):
        """Different content should produce different hash."""
        assert content_hash("content1") != content_hash("content2")

    def test_get_backup_paths(self):
        """Backup paths should follow naming convention."""
        path = Path("/tmp/test.omt")
        orig, bak, hash_file = get_backup_paths(path)
        assert orig == Path("/tmp/.test.omt.orig")
        assert bak == Path("/tmp/.test.omt.bak")
        assert hash_file == Path("/tmp/.test.omt.fixed-hash")

    def test_save_backup_creates_orig_on_first_fix(self):
        """First fix should create .orig file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"
            path.write_text("original content")

            orig_created, bak_path = save_backup(path, "original content")

            orig, bak, _ = get_backup_paths(path)
            assert orig_created == orig
            assert bak_path == bak
            assert orig.exists()
            assert bak.exists()
            assert orig.read_text() == "original content"
            assert bak.read_text() == "original content"

    def test_save_backup_preserves_orig_within_session(self):
        """Within 10 minutes, .orig should not be overwritten."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"
            orig, bak, _ = get_backup_paths(path)

            # First fix - create original backup
            orig.write_text("true original")
            record_fixed_hash(path, "fixed content")

            # Second fix with different content (simulating manual edit)
            # But within session timeout, so .orig preserved
            orig_created, bak_path = save_backup(path, "edited content")

            assert orig_created is None  # .orig kept
            assert orig.read_text() == "true original"
            assert bak.read_text() == "edited content"

    def test_save_backup_always_overwrites_bak(self):
        """.bak should be overwritten on each fix."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"
            orig, bak, _ = get_backup_paths(path)

            # Create original backup
            orig.write_text("true original")

            # First fix
            save_backup(path, "state v1")
            assert bak.read_text() == "state v1"

            # Second fix
            save_backup(path, "state v2")
            assert bak.read_text() == "state v2"

            # Original always preserved within session
            assert orig.read_text() == "true original"

    def test_was_manually_edited_detects_changes(self):
        """was_manually_edited should detect when file differs from last fix."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"

            # No hash file yet - assume edited
            assert was_manually_edited(path, "content") is True

            # Record fixed hash
            record_fixed_hash(path, "fixed content")

            # Same content - not edited
            assert was_manually_edited(path, "fixed content") is False

            # Different content - was edited
            assert was_manually_edited(path, "different content") is True

    def test_session_timeout_refreshes_orig_on_manual_edit(self):
        """After 10 min timeout + manual edit, .orig should be refreshed."""
        import os
        import time

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"
            orig, bak, _ = get_backup_paths(path)

            # First fix
            save_backup(path, "original")
            record_fixed_hash(path, "after first fix")
            assert orig.read_text() == "original"

            # Simulate session timeout by backdating .orig
            old_time = time.time() - SESSION_TIMEOUT_SECONDS - 1
            os.utime(orig, (old_time, old_time))

            # Fix again with manually edited content
            orig_created, _ = save_backup(path, "manually edited")

            # .orig should be refreshed because:
            # 1. Session timed out (> 10 min)
            # 2. Content was manually edited (differs from hash)
            assert orig_created == orig
            assert orig.read_text() == "manually edited"

    def test_session_timeout_keeps_orig_if_not_edited(self):
        """After 10 min timeout but no manual edit, .orig should be kept."""
        import os
        import time

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.omt"
            orig, bak, _ = get_backup_paths(path)

            # First fix
            save_backup(path, "original")
            record_fixed_hash(path, "same content")
            assert orig.read_text() == "original"

            # Simulate session timeout
            old_time = time.time() - SESSION_TIMEOUT_SECONDS - 1
            os.utime(orig, (old_time, old_time))

            # Fix again with SAME content as last fix (no manual edit)
            orig_created, _ = save_backup(path, "same content")

            # .orig should NOT be refreshed (no manual edit)
            assert orig_created is None
            assert orig.read_text() == "original"


class TestGetObviousFix:
    """Test obvious fix detection."""

    def test_obvious_fix_single_char(self):
        from dsl_validate import get_obvious_fix

        fix = get_obvious_fix("REQUET", {"REQUEST", "RESPONSE"}, line=10)
        assert fix is not None
        assert fix.old_text == "REQUET"
        assert fix.new_text == "REQUEST"
        assert fix.line == 10

    def test_obvious_fix_transposition(self):
        from dsl_validate import get_obvious_fix

        # IDEL -> IDLE is distance 2, COMPLETED is much further
        fix = get_obvious_fix("IDEL", {"IDLE", "COMPLETED"}, line=5)
        assert fix is not None
        assert fix.new_text == "IDLE"

    def test_no_fix_when_ambiguous(self):
        from dsl_validate import get_obvious_fix

        # Both STATE1 and STATE2 are distance 1 from STAT1
        fix = get_obvious_fix("STAT", {"STATE", "START"}, line=1)
        # Could match both, so no fix
        assert fix is None

    def test_no_fix_when_too_different(self):
        from dsl_validate import get_obvious_fix

        fix = get_obvious_fix("COMPLETELY_DIFFERENT", {"A", "B"}, line=1)
        assert fix is None

    def test_fix_case_insensitive(self):
        from dsl_validate import get_obvious_fix

        fix = get_obvious_fix("requet", {"REQUEST"}, line=1)
        assert fix is not None
        assert fix.new_text == "REQUEST"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
