#!/usr/bin/env bash
# Meta-Orchestrator installer
# ---------------------------
# Idempotent. Re-running is safe — it only writes files that are missing
# or whose contents drift from this skill's expected config.
#
# Usage:
#   ./install.sh                    # install for Claude Code (default)
#   ./install.sh --target=claude    # same as above
#   ./install.sh --target=codex     # install for Codex only
#   ./install.sh --target=both      # install for both
#   ./install.sh --uninstall        # remove what this script installed
#   ./install.sh --dry-run          # print actions without writing
#
# What it does:
#   1. Locates this skill's directory (= the dir containing this script's
#      parent repo). If installed via git clone to ~/.claude/skills/, that
#      path. If running from a dev tree, the parent of this file.
#   2. Copies/syncs skill files into the target skills directory.
#   3. Wires ~/.claude/settings.json Stop hook (Claude Code only).
#   4. Writes ~/.claude/CLAUDE.md pointing at this skill's SKILL.md.
#   5. Runs a self-check at the end.

set -euo pipefail

# --- argument parsing ---
TARGET="claude"
UNINSTALL=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --target=claude) TARGET="claude" ;;
    --target=codex)  TARGET="codex" ;;
    --target=both)   TARGET="both" ;;
    --uninstall)     UNINSTALL=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# --- paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR"  # this repo IS the skill

log() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }
ok() { printf '\033[32m[ok]\033[0m %s\n' "$*"; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  DRY-RUN: %s\n' "$*"
  else
    eval "$@"
  fi
}

# --- uninstall path ---
if [ "$UNINSTALL" = "1" ]; then
  log "Uninstalling meta-orchestrator..."
  if [ "$TARGET" = "claude" ] || [ "$TARGET" = "both" ]; then
    run "rm -rf \"\$HOME/.claude/skills/meta-orchestrator\""
    run "rm -f \"\$HOME/.claude/CLAUDE.md\""
    # Remove only the hook we added; preserve other Stop hooks
    python3 - <<'PYEOF' "$DRY_RUN" 2>/dev/null
import json, os, sys
dry = sys.argv[1] == "1"
p = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(p):
    sys.exit(0)
try:
    data = json.load(open(p))
except Exception:
    sys.exit(0)
hooks_stop = data.get("hooks", {}).get("Stop", [])
new = []
for hs in hooks_stop:
    if any("stop-reminder" in h.get("command", "") for h in hs.get("hooks", [])):
        continue
    new.append(hs)
data.setdefault("hooks", {})["Stop"] = new
if dry:
    print("  DRY-RUN: would rewrite", p)
else:
    json.dump(data, open(p, "w"), indent=2)
    print(f"  pruned Stop hook from {p}")
PYEOF
  fi
  if [ "$TARGET" = "codex" ] || [ "$TARGET" = "both" ]; then
    run "rm -rf \"\$HOME/.codex/skills/meta-orchestrator\""
  fi
  ok "Uninstall complete."
  exit 0
fi

# --- install path ---
log "Installing meta-orchestrator from: $SRC"

# dependency check
for dep in python3 jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    err "missing dependency: $dep"
    case "$dep" in
      jq) err "install with: apt install jq  /  brew install jq" ;;
      python3) err "install Python 3.8+" ;;
    esac
    exit 1
  fi
done

# python pyyaml check
if ! python3 -c "import yaml" 2>/dev/null; then
  warn "PyYAML not installed — running: pip install pyyaml"
  run "pip install pyyaml"
fi

# --- Claude Code ---
if [ "$TARGET" = "claude" ] || [ "$TARGET" = "both" ]; then
  DEST="$HOME/.claude/skills/meta-orchestrator"
  log "Syncing skill → $DEST"
  run "mkdir -p \"$DEST\""
  if command -v rsync >/dev/null 2>&1; then
    run "rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='pattern-memory.yaml*' --exclude='install.sh' \"$SRC\"/ \"$DEST\"/"
  else
    run "find \"$SRC\" -maxdepth 1 -mindepth 1 ! -path '*/.git' ! -path '*/__pycache__' ! -name '*.pyc' ! -name 'pattern-memory.yaml*' ! -name 'install.sh' -exec cp -r {} \"$DEST\"/ \;"
  fi
  ok "Skill files synced to $DEST"

  # Wire Stop hook
  log "Wiring Stop hook in ~/.claude/settings.json"
  HOOK_CMD="bash $DEST/hooks/claude-code-stop-reminder.sh"
  DRY="$DRY_RUN" SKILL_DIR_ABS="$DEST" HOOK_CMD_ABS="$HOOK_CMD" python3 - <<'PYEOF'
import json, os, sys
dry = os.environ.get("DRY") == "1"
hook_cmd = os.environ["HOOK_CMD_ABS"]
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    try:
        data = json.load(open(p))
    except Exception:
        data = {}
hooks_root = data.setdefault("hooks", {})
st = hooks_root.setdefault("Stop", [])
if not any("stop-reminder" in str(h) for hs in st for h in hs.get("hooks", [])):
    st.append({"hooks": [{"type": "command", "command": hook_cmd}]})
if dry:
    print("  DRY-RUN: would write", p)
    print("  hook_cmd:", hook_cmd)
else:
    json.dump(data, open(p, "w"), indent=2)
    print(f"  ✓ Stop hook configured at {p}")
PYEOF

  # Write ~/.claude/CLAUDE.md pointing at the skill
  log "Writing ~/.claude/CLAUDE.md (force-load SKILL.md every session)"
  CLAUDE_PATH="$HOME/.claude/CLAUDE.md"
  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY-RUN: would write $CLAUDE_PATH"
  else
    cat > "$CLAUDE_PATH" <<MDEOF
# Auto-installed by meta-orchestrator/install.sh

## Always-loaded skills

The following skill must be available in EVERY Claude Code session,
regardless of prompt content. This is force-loaded via CLAUDE.md, not
relying on description matching.

@$DEST/SKILL.md

## Behavior

- Treat \`meta-orchestrator\` as default-on. Do not ask the user
  "should I load it?" — it is already loaded.
- Honor explicit opt-out keywords: \`skip\`, \`--no\`, \`don't run orchestrator\`.
- After every response, emit the
  \`<!-- meta-orchestrator: sig=... family=... matched=... -->\`
  marker (or call \`orchestrator.py record\` directly) so the Stop hook
  can update pattern memory.
- Run Step 0 (check workflows/*.yaml) before improvising any non-trivial
  multi-step plan.

## What this skill does (TL;DR)

1. \`workflows/*.yaml\` holds reusable DAGs. Match by \`triggers\` /
   \`description\` before improvising.
2. Tier every task T0–T3; T2/T3 → decompose into DAG.
3. GATE 2 (record) → GATE 3 (check, threshold ≥3) → GATE 4 (propose
   crystallization) → workflow file written.

When a pattern's count reaches 3, the hook prompts the user: \`y\` to
write a workflow file, \`n\` to archive as declined.
MDEOF
    ok "Wrote $CLAUDE_PATH"
  fi
fi

# --- Codex ---
if [ "$TARGET" = "codex" ] || [ "$TARGET" = "both" ]; then
  DEST="$HOME/.codex/skills/meta-orchestrator"
  log "Syncing skill → $DEST"
  run "mkdir -p \"$DEST\""
  if command -v rsync >/dev/null 2>&1; then
    run "rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='pattern-memory.yaml*' --exclude='install.sh' \"$SRC\"/ \"$DEST\"/"
  else
    run "find \"$SRC\" -maxdepth 1 -mindepth 1 ! -path '*/.git' ! -path '*/__pycache__' ! -name '*.pyc' ! -name 'pattern-memory.yaml*' ! -name 'install.sh' -exec cp -r {} \"$DEST\"/ \;"
  fi
  ok "Skill files synced to $DEST"
  warn "Codex has no turn_end hook. Model must self-emit marker or run"
  warn "  python3 $DEST/scripts/orchestrator.py record ..."
  warn "after each response. SKILL.md describes this contract."
fi

# --- self-check ---
log "Running self-check..."
SELF_CHECK="$DEST/scripts/validate_dag.py" 2>/dev/null || SELF_CHECK=""
if [ -n "$SELF_CHECK" ] && [ -f "$SELF_CHECK" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY-RUN: would run $SELF_CHECK"
  else
    python3 "$SELF_CHECK" && ok "validate_dag.py: PASS" || warn "validate_dag.py reported issues"
  fi
fi
if [ -f "$DEST/scripts/_matcher.py" ] && [ "$DRY_RUN" = "0" ]; then
  match_test="$(python3 "$DEST/scripts/_matcher.py" --text "fix bug" 2>&1 || true)"
  if echo "$match_test" | grep -q '"matched"'; then
    ok "_matcher.py: PASS (matched $(echo "$match_test" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("matched", "?"))' 2>/dev/null || echo '?'))"
  else
    warn "_matcher.py did not return expected JSON: $match_test"
  fi
fi

ok "Install complete."
log "Next:"
echo "  1. Open a new Claude Code session."
echo "  2. Run any non-trivial task. The Stop hook will auto-record."
echo "  3. After ~3 uses of the same pattern, hook prompts you to"
echo "     crystallize (y/n/edit)."
