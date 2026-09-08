"""Wire the meta-orchestrator Stop hook into ~/.claude/settings.json.

Used by install.ps1 / install.sh as a one-shot helper. Reads the desired
hook command from $HOOK_CMD_ABS and writes (or dry-runs) settings.json.

Idempotent: re-running is a no-op if the hook is already wired.
"""
import json
import os
import sys


def main() -> int:
    dry = os.environ.get("DRY") == "1"
    hook_cmd = os.environ["HOOK_CMD_ABS"]
    p = os.path.expanduser(
        os.path.join(os.environ["USERPROFILE"], ".claude", "settings.json")
    )
    os.makedirs(os.path.dirname(p), exist_ok=True)
    data = {}
    if os.path.exists(p):
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}

    hooks_root = data.setdefault("hooks", {})
    stop = hooks_root.setdefault("Stop", [])
    if not any(
        "stop-reminder" in str(h)
        for hs in stop
        for h in hs.get("hooks", [])
    ):
        stop.append({"hooks": [{"type": "command", "command": hook_cmd}]})

    if dry:
        print("  DRY-RUN: would write", p)
        print("  hook_cmd:", hook_cmd)
    else:
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"  Stop hook configured at {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
