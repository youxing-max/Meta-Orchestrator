# meta-orchestrator

DAG-based workflow orchestration engine. Reuses existing workflows, decomposes ad-hoc tasks, and crystallizes repeated patterns into permanent assets.

## What it does

- **Step 0**: Before responding to any non-trivial task, the AI checks `workflows/*.yaml` for matching triggers and executes the best match.
- **Step 0.5**: Classifies the task into T0 (lookup) / T1 (single edit) / T2 (multi-file) / T3 (architecture).
- **Step 1**: For T2/T3 tasks, decomposes into a DAG with kinds (`agent`, `generate`, `classify`, `input`, `tool`), routing, and failure fallbacks.
- **Step 5 (Crystallization)**: After each response, the AI records the invocation. When a pattern appears 2+ times, it proposes to save it as a reusable workflow.

## Install

Copy this directory to `~/.claude/skills/`:

```bash
cp -r Meta-Orchestrator ~/.claude/skills/meta-orchestrator
```

The skill is now loaded automatically — the `description` in `SKILL.md` frontmatter is injected into the system prompt at every session start.

## Configure hooks (one-time)

The skill ships with three hooks. Configure them in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/meta-orchestrator/hooks/session-start-reminder.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/meta-orchestrator/hooks/claude-code-stop-reminder.sh"
          }
        ]
      }
    ]
  }
}
```

For Codex, append to `~/.codex/config.toml`:

```toml
[hooks]
turn_end = [
  { command = ["bash", "~/.claude/skills/meta-orchestrator/hooks/codex-turn-end-reminder.sh"], timeout = 5000 }
]
```

## Verify the install

Run the self-check from anywhere:

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/self_check.py
```

Should print `Result: 13/13 checks passed`.

## Usage

When the AI is asked a non-trivial task, it will:

1. List `workflows/*.yaml` in the skill
2. Read each file's `triggers` and `description`
3. Match the user's request
4. If a workflow matches → execute it verbatim
5. If no match → decompose into a DAG (T2/T3) or run directly (T0/T1)

After the response, the AI is reminded to record the invocation:

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/record_invocation.py \
  --signature "agent → generate" \
  --family "code review" \
  --matched "code-review-pipeline"
```

If the pattern count reaches 2, the AI proposes crystallization:

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/propose_crystallize.py --pattern-id 2
```

Three responses are accepted via flags:

- `--yes` → write a stub workflow file directly (autonomous mode)
- `--no` → archive the pattern (declined_count++)
- (no flag) → print a Chinese-language proposal for the user

## Directory layout

```
meta-orchestrator/
├── SKILL.md                       # Main protocol (~600 lines)
├── README.md                      # This file
├── hooks/
│   ├── session-start-reminder.sh  # Reminds at session start
│   ├── claude-code-stop-reminder.sh  # Reminds after each response
│   └── codex-turn-end-reminder.sh # Codex equivalent
├── scripts/
│   ├── self_check.py              # Diagnose the install
│   ├── record_invocation.py       # GATE 2
│   ├── check_threshold.py         # GATE 3
│   └── propose_crystallize.py     # GATE 4
└── workflows/                     # 5 reference DAGs
    ├── api-migration.yaml
    ├── bug-fix-workflow.yaml
    ├── code-review-pipeline.yaml
    ├── deploy-checklist.yaml
    └── parallel-analysis.yaml
```

## Files NOT in the repo (auto-generated)

- `scripts/pattern-memory.yaml` — created on first `record_invocation.py` run
- `.codex-turn-end-trigger` — Codex sentinel file (only on Codex)

## Troubleshooting

### "Hook fires every response, AI keeps re-running scripts"

The Stop hook reminder is being treated as a real task. Make sure the hook script reads `stop_hook_active` from stdin and exits silently when true. The shipped `claude-code-stop-reminder.sh` already does this.

### "Pattern not found" when running `propose_crystallize.py`

The pattern ID must come from `propose_crystallize.py` itself or from `record_invocation.py` JSON output. IDs don't match `invocations[].id` directly — they're drawn from a shared `next_id` counter.

### "PyYAML not found"

```bash
pip install pyyaml
```

The skill won't work without PyYAML. All four scripts hard-fail without it (no fallback).

### "Workflow not found when Step 0 looks for it"

Workflows are at `~/.claude/skills/meta-orchestrator/workflows/*.yaml`. If you installed the skill elsewhere, the AI will look in the wrong place. Make sure the skill is installed at the standard path.

### "I copied the skill but the AI doesn't see it"

Reproduce the install:

```bash
# Quick check
python3 ~/.claude/skills/meta-orchestrator/scripts/self_check.py

# Full reinstall
rm -rf ~/.claude/skills/meta-orchestrator
cp -r Meta-Orchestrator ~/.claude/skills/meta-orchestrator
python3 ~/.claude/skills/meta-orchestrator/scripts/self_check.py
```

Restart Claude Code after copying.

## Cross-platform

| OS | Python | Script invocation |
|----|--------|-------------------|
| Linux / macOS | `python3` | `python3 ~/.claude/skills/meta-orchestrator/scripts/<name>.py` |
| Windows | `python3` | `python3 %USERPROFILE%\.claude\skills\meta-orchestrator\scripts\<name>.py` |

Scripts use `pathlib.Path(__file__).parent` internally, so they work from any cwd on any OS.

## Undoing a crystallization

The user said "no" to a proposal, but the pattern is still in `pending_crystallization[]`. Run with `--no` instead:

```bash
python3 ~/.claude/skills/meta-orchestrator/scripts/propose_crystallize.py --pattern-id 2 --no
```

This moves the pattern to `archived_patterns[]` with `declined_count: 1`. After 2 declines, the pattern is permanently archived.

## License

MIT (or whatever the project uses).