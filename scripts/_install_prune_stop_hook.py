"""Prune only the meta-orchestrator Stop hook entries from
~/.claude/settings.json. Used by uninstall.

Leaves any other Stop hooks the user (or another tool) configured
untouched. Idempotent: re-running is a no-op if our hook isn't present.
"""
import json
import os
import sys


def main() -> int:
    dry = os.environ.get("DRY") == "1"
    p = os.path.expanduser(
        os.path.join(os.environ["USERPROFILE"], ".claude", "settings.json")
    )
    if not os.path.exists(p):
        return 0
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0

    hooks_root = data.get("hooks", {})
    stop = hooks_root.get("Stop", [])
    new = [
        hs for hs in stop
        if not any(
            "stop-reminder" in h.get("command", "")
            for h in hs.get("hooks", [])
        )
    ]
    if new == stop:
        print(f"  no meta-orchestrator Stop hook found in {p}")
        return 0
    data["hooks"]["Stop"] = new

    if dry:
        print(f"  DRY-RUN: would prune Stop hook from {p}")
        return 0

    with open(p, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print(f"  pruned Stop hook from {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
