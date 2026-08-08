#!/bin/bash
# Codex turn_end hook. Writes sentinel file because Codex hooks cannot
# directly message the LLM. SKILL.md's Codex runtime section reads this
# file and triggers the crystallization gate when fresh.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SKILL_DIR/.codex-turn-end-trigger"
exit 0
