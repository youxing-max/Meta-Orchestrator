#!/usr/bin/env python3
"""
Shared memory helpers for record_invocation.py / check_threshold.py /
propose_crystallize.py.

Atomic write with pre-write .bak backup. Schema-ensuring load. No
recovery from a corrupt main file -- if the user breaks the YAML by
hand they can delete the file or restore from .bak manually.
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


def load_with_recovery(path: Path) -> dict:
    """Load YAML from `path`. Returns empty schema on missing file.
    Exits with REFUSED if file exists but is not parseable."""
    if not path.exists():
        return _ensure_shape({})
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except (yaml.YAMLError, OSError) as e:
        sys.exit(
            f"REFUSED: {path.name} unreadable ({e}). "
            f"Restore from {path.name}.bak or delete the file to start fresh."
        )
    if not isinstance(data, dict):
        sys.exit(
            f"REFUSED: {path.name} parsed to {type(data).__name__}, "
            f"not a mapping. Delete or fix manually."
        )
    return _ensure_shape(data)


def save_with_backup(path: Path, data: dict) -> None:
    """Atomic write (tempfile + os.replace) with pre-write .bak backup.
    Backup is best-effort -- if shutil.copy2 fails the write still proceeds."""
    fd, tmp_path = tempfile.mkstemp(
        dir=path.parent, suffix=".tmp", prefix=".pattern-memory."
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
            f.flush()
            os.fsync(f.fileno())
        if path.exists():
            try:
                shutil.copy2(path, path.with_suffix(path.suffix + ".bak"))
            except OSError:
                pass
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _ensure_shape(data: dict) -> dict:
    data.setdefault("next_id", 1)
    data.setdefault("patterns", [])
    data.setdefault("archived_patterns", [])
    data.setdefault("invocations", [])
    return data


def get_patterns(data: dict) -> list:
    """Return the list of in-flight patterns (count < threshold)."""
    return data.get("patterns", [])


def get_archived(data: dict) -> list:
    """Return the list of archived (crystallized / declined) patterns."""
    return data.get("archived_patterns", [])


def add_to_archived(data: dict, entry: dict) -> None:
    """Append a pattern entry to the archive."""
    data.setdefault("archived_patterns", []).append(entry)
