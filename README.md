# Meta-Orchestrator

A Claude Code / Codex skill that turns repeated ad-hoc work into a personal
workflow DAG library. Every turn is auto-recorded; once a pattern hits 3
non-trivial invocations, the skill proposes a workflow YAML you can either
crystallize (write the file) or decline (archive).

See [`SKILL.md`](./SKILL.md) for the full reference (bootstrap, Step 0
matching, GATE 2 / GATE 3 / GATE 4 pipeline, signature grammar, marker
syntax).

## Layout

```
SKILL.md                         full skill reference
hooks/claude-code-stop-reminder.sh   Stop hook (auto-records + crystallization hint)
scripts/orchestrator.py          record / check / propose subcommands
scripts/_matcher.py              Step 0 (workflow match) + Step 0.5 (tier)
scripts/_judge.py                LLM judge for semantic pattern match (5s timeout)
scripts/_memory.py               atomic YAML load/save with .bak
scripts/_file_lock.py            fcntl-based concurrent-write guard
scripts/validate_dag.py          workflow schema validator
workflows/_TEMPLATE.yaml         sample workflow DAG
```

## Install

```bash
# Claude Code
git clone <this repo> ~/.claude/skills/meta-orchestrator
# then follow SKILL.md §"Bootstrap Hooks" to wire the Stop hook
```

## Quick sanity check

```bash
python3 scripts/validate_dag.py                # 1/1 workflows valid
python3 scripts/_matcher.py --text "fix bug"   # → bug-fix-workflow (tier T1)
```
