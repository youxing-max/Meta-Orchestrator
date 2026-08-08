#!/usr/bin/env python3
"""
GATE 2: Record invocation. Read-then-write pattern-memory.yaml atomically.

Counts only increment for ad-hoc invocations (matched=null).
Reusing an existing workflow does NOT count toward crystallization —
only newly-composed DAGs do.

Requires: PyYAML (pip install pyyaml)

Usage:
  python scripts/record_invocation.py \
    --signature "<sig>" \
    --family "<short name>" \
    --matched "<workflow_name_or_null>"
"""
import argparse
import json
import os
import sys
import tempfile
from datetime import date
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

SCRIPT_DIR = Path(__file__).resolve().parent
MEMORY_FILE = SCRIPT_DIR / "pattern-memory.yaml"


def load_memory():
    if not MEMORY_FILE.exists():
        return {
            "next_id": 1,
            "patterns": [],
            "pending_crystallization": [],
            "archived_patterns": [],
            "invocations": [],
        }
    with open(MEMORY_FILE, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    for key in (
        "patterns", "pending_crystallization",
        "archived_patterns", "invocations",
    ):
        data.setdefault(key, [])
    data.setdefault("next_id", 1)
    return data


def save_memory(data):
    """Atomic write: tempfile + os.replace in same directory."""
    fd, tmp_path = tempfile.mkstemp(
        dir=MEMORY_FILE.parent, suffix=".tmp", prefix=".pattern-memory."
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, MEMORY_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--signature", required=True)
    parser.add_argument("--family", required=True)
    parser.add_argument("--matched", default="null")
    args = parser.parse_args()

    matched = None if args.matched in ("null", "") else args.matched
    data = load_memory()
    today = date.today().isoformat()
    next_id = int(data.get("next_id", 1))

    invocation = {
        "id": next_id,
        "timestamp": today,
        "signature": args.signature,
        "task_family": args.family,
        "matched_workflow": matched,
    }
    data["invocations"].append(invocation)
    next_id += 1

    if matched is None:
        # Only ad-hoc DAGs count toward crystallization.
        existing = next(
            (p for p in data["patterns"] if p["signature"] == args.signature),
            None,
        )
        if existing:
            existing["count"] = int(existing.get("count", 1)) + 1
            existing["last_seen"] = today
            triggered_id = existing.get("id")
        else:
            triggered_id = next_id
            data["patterns"].append({
                "id": next_id,
                "signature": args.signature,
                "task_family": args.family,
                "count": 1,
                "first_seen": today,
                "last_seen": today,
            })
            next_id += 1
        triggered_count = next(
            (p["count"] for p in data["patterns"]
             if p["signature"] == args.signature),
            1,
        )
    else:
        triggered_id = None
        triggered_count = None

    data["next_id"] = next_id
    save_memory(data)

    print(json.dumps({
        "recorded": True,
        "signature": args.signature,
        "matched_workflow": matched,
        "pattern_id": triggered_id,
        "count": triggered_count,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()