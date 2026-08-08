#!/usr/bin/env python3
"""
GATE 3: Threshold check. Exit 0 if any pattern has count >= threshold,
exit 1 otherwise. Prints pending patterns as JSON to stdout.

Requires: PyYAML (pip install pyyaml)

Usage:
  python3 scripts/check_threshold.py [--threshold N]
"""
import argparse
import json
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

SCRIPT_DIR = Path(__file__).resolve().parent
MEMORY_FILE = SCRIPT_DIR / "pattern-memory.yaml"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold", type=int, default=2)
    args = parser.parse_args()

    if not MEMORY_FILE.exists():
        print(json.dumps({
            "triggered": False,
            "threshold": args.threshold,
            "patterns_total": 0,
            "highest_count": 0,
            "note": "pattern-memory.yaml not found — run record_invocation.py first",
        }, ensure_ascii=False))
        sys.exit(1)

    with open(MEMORY_FILE, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    pending = [
        p for p in data.get("patterns", [])
        if int(p.get("count", 0)) >= args.threshold
    ]
    if pending:
        print(json.dumps(pending, ensure_ascii=False, indent=2))
        sys.exit(0)
    # exit 1: still emit a one-line JSON so the LLM can parse it
    print(json.dumps({
        "triggered": False,
        "threshold": args.threshold,
        "patterns_total": len(data.get("patterns", [])),
        "highest_count": max(
            (int(p.get("count", 0)) for p in data.get("patterns", [])),
            default=0,
        ),
    }, ensure_ascii=False))
    sys.exit(1)


if __name__ == "__main__":
    main()