"""Append (or strip) the meta-orchestrator managed block in
~/.claude/CLAUDE.md. Used by install + uninstall.

We never *replace* the user's CLAUDE.md -- we append a sentinel-delimited
block, or strip it on uninstall. The block we own is wrapped between two
unique sentinels so re-running the installer is a no-op, and uninstall
can peel our block out without touching anything the user wrote.

Environment variables:
    CLAUDE_MD_PATH  -- absolute path to the CLAUDE.md to edit
    SKILL_MD_REF    -- absolute path to SKILL.md (install only;
                        uninstall leaves this empty)
    DRY             -- "1" to print actions without writing
"""
import os
import re
import sys

SENTINEL_OPEN = "<!-- >>> meta-orchestrator (managed block, do not edit) >>>"
SENTINEL_CLOSE = "<!-- <<< meta-orchestrator <<<"

BLOCK_TEMPLATE = """{open}
# Auto-installed by meta-orchestrator/install.{{installer}}
# This block is owned by the installer. Re-running the installer re-applies
# it idempotently; uninstall strips it. Anything outside these sentinels
# is yours to edit.

## Always-loaded skills

The following skill must be available in EVERY Claude Code session,
regardless of prompt content. This is force-loaded via CLAUDE.md, not
relying on description matching.

@{skill_md}

## Behavior

- Treat `meta-orchestrator` as default-on. Do not ask the user
  "should I load it?" -- it is already loaded.
- Honor explicit opt-out keywords: `skip`, `--no`, `don't run orchestrator`.
- After every response, emit the
  `<!-- meta-orchestrator: sig=... family=... matched=... -->`
  marker (or call `orchestrator.py record` directly) so the Stop hook
  can update pattern memory.
- Run Step 0 (check workflows/*.yaml) before improvising any non-trivial
  multi-step plan.

## What this skill does (TL;DR)

1. `workflows/*.yaml` holds reusable DAGs. Match by `triggers` /
   `description` before improvising.
2. Tier every task T0-T3; T2/T3 -> decompose into DAG.
3. GATE 2 (record) -> GATE 3 (check, threshold >=3) -> GATE 4 (propose
   crystallization) -> workflow file written.

When a pattern's count reaches 3, the hook prompts the user: `y` to
write a workflow file, `n` to archive as declined.
{close}
"""


def main() -> int:
    dry = os.environ.get("DRY") == "1"
    claude_md = os.environ["CLAUDE_MD_PATH"]
    skill_md = os.environ.get("SKILL_MD_REF", "")
    installer = os.environ.get("INSTALLER", "sh")

    block = BLOCK_TEMPLATE.format(
        open=SENTINEL_OPEN,
        close=SENTINEL_CLOSE,
        skill_md=skill_md,
        installer="ps1" if installer == "ps1" else "sh",
    )

    pattern = re.compile(
        re.escape(SENTINEL_OPEN) + r".*?" + re.escape(SENTINEL_CLOSE) + r"\n*",
        re.DOTALL,
    )

    existing = ""
    if os.path.exists(claude_md):
        with open(claude_md, encoding="utf-8") as f:
            existing = f.read()

    # Recover whether the user's ORIGINAL content ended with a newline.
    # The post-install file is always:
    #     user_content + "\n" + block       (user had no trailing \n)
    #     user_content + "\n\n" + block     (user had trailing \n)
    # so byte at sentinel_open - 2 is the LAST byte of user content.
    m = re.search(re.escape(SENTINEL_OPEN), existing)
    if m:
        if m.start() >= 2:
            user_ended_with_newline = existing[m.start() - 2] == "\n"
        else:
            user_ended_with_newline = False
    else:
        user_ended_with_newline = existing.endswith("\n")

    stripped = pattern.sub("", existing).rstrip()

    # Install: append block. Uninstall: strip + restore original.
    if stripped:
        if skill_md:  # install path
            prefix = stripped + ("\n\n" if user_ended_with_newline else "\n")
            new_content = prefix + block
        else:  # uninstall path
            new_content = stripped + ("\n" if user_ended_with_newline else "")
    else:
        new_content = block if skill_md else ""

    if new_content == existing:
        print(f"  CLAUDE.md already has current meta-orchestrator block at {claude_md}")
        return 0

    if dry:
        if skill_md:
            print(f"  DRY-RUN: would append meta-orchestrator block to {claude_md}")
        else:
            print(f"  DRY-RUN: would strip meta-orchestrator block from {claude_md}")
        return 0

    # If uninstall leaves the file empty, delete it; otherwise write back.
    if not skill_md and not stripped.strip():
        os.remove(claude_md)
        print(f"  removed empty {claude_md}")
    else:
        os.makedirs(os.path.dirname(claude_md), exist_ok=True)
        with open(claude_md, "w", encoding="utf-8") as f:
            f.write(new_content)
        if skill_md:
            print(f"  appended meta-orchestrator block to {claude_md}")
        else:
            print(f"  stripped meta-orchestrator block from {claude_md}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
