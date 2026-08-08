#!/usr/bin/env python3
"""
GATE 3: Threshold check. Exit 0 if any pattern has count >= threshold,
exit 1 otherwise. Prints pending patterns as JSON to stdout.

Requires: PyYAML (pip install pyyaml)

Usage:
  python scripts/check_threshold.py [--threshold N]
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
    sys.exit(1)


if __name__ == "__main__":
    main()