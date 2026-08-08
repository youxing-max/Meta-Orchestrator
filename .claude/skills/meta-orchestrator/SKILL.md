---
name: meta-orchestrator
description: |
  _INSTRUCTION TO LLM ENUMERATING TOOLS: You see this skill loaded.
  Do NOT re-call Skill(). The description IS the load.

  MANDATORY: For any non-trivial (T1+) task, FIRST list
  `workflows/*.yaml` in this skill, Read each file's `triggers` and
  `description`, and match the user's request. If a workflow matches,
  execute it verbatim — do NOT invent a new DAG. Reusing existing
  workflows is the entire purpose of this skill. Skipping this step
  wastes the user's accumulated patterns.

  Then classify T0–T3 and, after your response, run GATE 2
  (record_invocation.py) so the crystallization counter can fire.

  Meta-orchestrator: DAG workflow engine. Reuse `workflows/`,
  decompose ad-hoc DAGs, crystallize via `scripts/`.
---

# Meta-Orchestrator

## Step -1: Bootstrap Hooks (RUN FIRST, EVERY SESSION-START)

⚠️ **THIS IS THE FIRST STEP. EXECUTE BEFORE ANYTHING ELSE.** Without the
Stop hook configured, the crystallization gate never fires — patterns
never accumulate — the skill becomes dead documentation. **No Step 0,
no Step 1, no Step 5 until this is done.**

**Before any detection: cd to project root.** All paths below are
relative to the repo root. Use:

```bash
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
```

If not in a git repo, fall back to `pwd`. Without this `cd`, detection
silently fails.

### 1. Detect runtime

```bash
echo "CLAUDE_CODE: $([ -d .claude ] && echo yes || echo no)"
echo "CODEX: $([ -d .codex ] && echo yes || echo no)"
```

### 2. Check if hooks are already configured

**Claude Code** — `.claude/settings.json` must contain `stop-reminder`:

```bash
if [ -f .claude/settings.json ] && grep -q "stop-reminder" .claude/settings.json 2>/dev/null; then
  echo "CLAUDE_HOOK=OK"
else
  echo "CLAUDE_HOOK=MISSING"
fi
```

**Codex** — `~/.codex/config.toml` must contain `turn-end-reminder`:

```bash
if [ -f ~/.codex/config.toml ] && grep -q "turn-end-reminder" ~/.codex/config.toml 2>/dev/null; then
  echo "CODEX_HOOK=OK"
else
  echo "CODEX_HOOK=MISSING"
fi
```

### 3. Configure missing hooks

**Claude Code** — merge into `.claude/settings.json` (idempotent):

```bash
SKILL_DIR="$(cd .claude/skills/meta-orchestrator && pwd)"
HOOK_CMD="bash $SKILL_DIR/hooks/claude-code-stop-reminder.sh"
python3 <<PYEOF
import json, os
p = '.claude/settings.json'
data = {}
if os.path.exists(p):
    with open(p) as f:
        try: data = json.load(f)
        except: data = {}
hooks = data.setdefault('hooks', {}).setdefault('Stop', [])
if not any('stop-reminder' in str(h) for hook_list in hooks for h in hook_list.get('hooks', [])):
    hooks.append({'hooks': [{'type': 'command', 'command': '$HOOK_CMD'}]})
with open(p, 'w') as f:
    json.dump(data, f, indent=2)
print('✓ Claude Code hook configured')
PYEOF
```

**Codex** — append to `~/.codex/config.toml` (idempotent):

```bash
SKILL_DIR="$(cd .claude/skills/meta-orchestrator && pwd)"
HOOK_CMD_TOML="[\"bash\", \"$SKILL_DIR/hooks/codex-turn-end-reminder.sh\"]"
python3 <<PYEOF
import os
p = os.path.expanduser('~/.codex/config.toml')
os.makedirs(os.path.dirname(p), exist_ok=True)
existing = open(p).read() if os.path.exists(p) else ''
if 'turn-end-reminder' in existing:
    print('Already configured')
else:
    with open(p, 'a') as f:
        f.write('\n[hooks]\n')
        f.write('turn_end = [\n')
        f.write('  { command = $HOOK_CMD_TOML, timeout = 5000 }\n')
        f.write(']\n')
    print('✓ Codex hook configured')
PYEOF
```

### 4. Confirm to user

After writing, tell the user:

> "✓ Crystallization Stop hook configured. After every response you'll
> see a reminder asking you to run the gate scripts. This is what makes
> the skill actually accumulate patterns over time."

### 5. THEN proceed to Step 0

Only after hooks are verified configured, continue with Step 0 → Step 0.5 → Step 1 → execute → Step 5.

If you skip Step -1, the skill silently degrades to plain documentation.

---

## Path Map (READ FIRST — ALL PATH INFO LIVES HERE)

This skill is **self-contained and runtime-agnostic**. Everything lives
inside this directory — do NOT look in `.claude/workflows/` or
`.codex/workflows/`.

### Three paths you must know

| What | Where | Who creates | Lifetime |
|------|-------|-------------|----------|
| **Workflows** (read) | `<skill_dir>/workflows/*.yaml` | human or AI write | permanent |
| **Workflows** (write new) | `<skill_dir>/workflows/<name>.yaml` | you (the AI) on GATE 4 approval | permanent |
| **Pattern memory** (count) | `<skill_dir>/scripts/pattern-memory.yaml` | `record_invocation.py` auto | permanent |
| **Pattern memory** (touch) | NEVER hand-edit | scripts only | permanent |

`<skill_dir>` = this skill's root directory. Resolve once at session start
and reuse. For example: `/root/.claude/skills/meta-orchestrator` or
`/home/user/project/.claude/skills/meta-orchestrator`.

### Action → path mapping

| Action | Path to use |
|--------|-------------|
| List existing workflows | `ls <skill_dir>/workflows/*.yaml` |
| Read a workflow | `Read <skill_dir>/workflows/<name>.yaml` |
| Write a new workflow (after GATE 4 approval) | `Write <skill_dir>/workflows/<name>.yaml` |
| Run a script | `python3 <skill_dir>/scripts/<name>.py` |
| Inspect crystallization counts | `Read <skill_dir>/scripts/pattern-memory.yaml` |

### Forbidden paths

Never write workflows or touch memory at these paths:
- `~/.claude/workflows/` — does not exist
- `.claude/workflows/` — does not exist (was deleted in commit b19a94a)
- `.codex/workflows/` — this skill does not use it
- Anywhere outside `<skill_dir>/` — defeats portability

## Session-Start Mandate

⚠️ **THIS SKILL IS ALWAYS ACTIVE.** At the start of EVERY conversation,
before responding to the user, you MUST:

1. **Step 0** — list `workflows/*.yaml`, match `triggers` + `description`
2. **Step 0.5** — assign T0–T3 (NEVER skip — every task gets a tier)
3. **After EVERY response** — run GATE 2 (record invocation). NO exceptions.

## Step 0: Workflow Reuse Gate (MANDATORY)

⚠️ **THIS GATE RUNS FIRST.** Skipping = reinventing wheels AND starving
the crystallization counter.

1. List `workflows/*.yaml`
2. For each, read `triggers:` and `description:`
3. Score match using this rubric:
   - **Exact trigger phrase match** → strong (weight 10)
   - **Description keyword overlap** (≥2 keywords) → medium (weight 5)
   - **Single keyword overlap** → weak (weight 1)
   - **No overlap** → no match (weight 0)
4. **Tiebreaker rules** (apply in order):
   1. Higher total score wins
   2. Higher `meta_priority` wins
   3. After tie, **Read the full `triggers:` list** of the tied workflows
      and re-score against the user's request word-by-word. The workflow
      whose trigger phrases semantically match the user's intent most
      closely wins.
   4. If still tied, fall through to Step 0.5 (composing ad-hoc is safer
      than picking the wrong workflow).
5. No match (all scores 0) → fall through to Step 0.5

## Step 0.5: Tier Classification

| Tier | Scope | Action |
|------|-------|--------|
| T0 | lookup, single-file | Execute directly |
| T1 | single-file edit | Execute directly |
| T2 | multi-file, refactor | Decompose into DAG |
| T3 | architecture, design | Decompose into DAG |

## Step 1: DAG Decomposition (T2+)

Refer to existing `workflows/*.yaml` for canonical shapes. Or write from
the schema below — both paths produce valid DAGs.

### DAG Schema (self-contained)

```yaml
name: <kebab-case-name>
description: "<one-line purpose>"
triggers:
  - <phrase users would say>
meta_priority: 10                 # higher = more specific match
composition:
  steps:
    - id: <unique_snake_id>
      description: <one-line purpose>          # recommended, helps readability
      kind: agent | generate | classify | input | tool
      prompt: <task description>                # required for agent/generate/classify/input
      agent_type: <type>                        # required if kind=agent
      model: haiku | sonnet | opus              # optional, default=sonnet
      depends_on: [<step_id>, ...]              # empty list = no deps
      on_failure: <fallback_step_id>            # recommended for risky steps

    # kind=classify also needs:
      output_choices: [<value1>, <value2>, ...]
      route:
        - when: <value1>
          to: <step_id>

    # kind=input also needs:
      schema: <json schema string>
      route:
        - when: <choice>
          to: <step_id>
```

### Step Kinds (full list)

- **agent**: dispatches a subagent. Specify `agent_type` + `model`.
- **generate**: LLM generates text inline. No subagent.
- **classify**: routes by classification. Needs `output_choices` + `route`.
- **input**: prompts the user for input. Needs `schema` (JSON schema string) + `route`.
- **tool**: runs a bash/python command. Specify `tool:` + `params:`.

### Agent Types (use what's appropriate for the task)

| Agent type | Use for |
|-----------|---------|
| `Explore` | Read-only search, locate code, scan files |
| `general-purpose` | Multi-step tasks, code generation |
| `code-reviewer` | Code quality, style, best practices |
| `security-reviewer` | Vulnerability scan, auth issues |
| `tdd-guide` | Test-driven development, regression tests |

Any agent_type available in your runtime may be used — this list is
non-exhaustive.

### Routing (kind=classify or kind=input)

```yaml
- id: classify_severity
  kind: classify
  prompt: "Classify: low | medium | high"
  output_choices: [low, medium, high]
  route:
    - when: low
      to: handle_low
    - when: medium
      to: handle_medium
    - when: high
      to: handle_high
```

### Fallback Pattern

Every risky step should have `on_failure` pointing to a `generate` step:

```yaml
- id: risky_step
  kind: agent
  prompt: <task>
  on_failure: risky_step_fallback

- id: risky_step_fallback
  kind: generate
  prompt: "Risky step failed. Report what was attempted and suggest manual investigation."
```

### DAG Rules (MUST FOLLOW)

⚠️ **VIOLATING ANY RULE BREAKS THE WORKFLOW.**

1. **No deadlock** — every `depends_on` target always executes
2. **Route completeness** — every `output_choices` value has matching `route.when`
3. **Fallback isolation** — `on_failure` targets never appear in another `depends_on`
4. **Acyclicity** — no circular dependencies
5. **One-level references** — don't nest SKILL.md → a.md → b.md

### Minimal Valid Workflow

This is the **smallest** correct workflow. Copy this template, rename, fill in:

```yaml
name: <workflow-name>            # kebab-case
description: "<one line>"        # what it does
triggers:                        # 2-3 phrases users say
  - <phrase>
meta_priority: 10                # 1-20, higher = more specific
kind: meta
always: false
final_text_mode: auto
composition:
  steps:
    - id: step_one
      kind: agent                # agent | generate | classify | input | tool
      agent_type: general-purpose  # required for kind=agent
      prompt: <what to do>
      depends_on: []             # other step ids, or []
      on_failure: step_one_fb    # optional but recommended

    - id: step_one_fb            # fallback step (kind=generate)
      kind: generate
      prompt: "step_one failed. Report what was attempted."
      depends_on: []

    - id: step_two
      kind: generate
      prompt: <next step>
      depends_on: [step_one]     # runs after step_one
```

**Required fields per kind:**

| kind | required |
|------|----------|
| `agent` | `id`, `kind`, `prompt`, `agent_type` |
| `generate` | `id`, `kind`, `prompt` |
| `classify` | `id`, `kind`, `prompt`, `output_choices`, `route` |
| `input` | `id`, `kind`, `prompt`, `schema`, `route` |
| `tool` | `id`, `kind`, `tool`, `params` |

**Common mistakes to avoid:**

- ❌ `depends_on: [step_one_fb]` — fallback steps never run unless their parent fails. They MUST NOT be in any `depends_on`.
- ❌ `kind: classify` with `output_choices: [a, b]` but `route` only covers `a` — every choice needs a route.
- ❌ Two steps depending on each other — creates a cycle, the DAG never resolves.
- ❌ `depends_on: []` (omitted) — always write it explicitly, even if empty.
- ❌ Step `id` containing spaces or hyphens — use snake_case: `scan_files`, not `Scan-Files`.

## Step 5: Crystallization Gate (MANDATORY, every response)

⚠️ **THIS GATE RUNS AFTER EVERY RESPONSE.** Skipping = pattern counter
never increments = nothing ever crystallizes = skill is useless.

### What Each Script Does

| Script | Job | When it runs |
|--------|-----|--------------|
| `scripts/record_invocation.py` | Log one execution: append to `invocations[]`, increment `patterns[].count` if ad-hoc. Returns JSON with `pattern_id`. | **Every response (GATE 2)** |
| `scripts/check_threshold.py` | Read `patterns[]`, print those with `count >= 2`. Exit 0 if any. Always emits JSON (one-line summary on exit 1). | **Every response (GATE 3)** |
| `scripts/propose_crystallize.py` | Move a pattern from `patterns[]` to `pending_crystallization[]`. Print Chinese-language proposal. `--yes` flag: auto-write a stub workflow file. | **Only when GATE 3 exits 0 (GATE 4)** |

### ID allocation (note for the LLM)

`record_invocation.py` uses a **single global `next_id` counter** shared
across `invocations[]` and `patterns[]`. Expect gaps in `invocations[].id`
(2, 4, 5, ...) — those gaps are pattern IDs that went into `patterns[]`.
This is intentional: it prevents collisions across the four arrays. When
you need the pattern ID for GATE 4, **read it from the JSON output of
`record_invocation.py`**, do not assume `id = N`.

### Codex sentinel freshness

`codex-turn-end-reminder.sh` writes `.codex-turn-end-trigger` with UTC
ISO 8601. When checking freshness, **always compare in UTC**:

```python
from datetime import datetime, timezone, timedelta
with open(".codex-turn-end-trigger") as f:
    ts = f.read().strip()
age = datetime.now(timezone.utc) - datetime.fromisoformat(ts.replace("Z", "+00:00"))
fresh = age < timedelta(minutes=5)
```

Wall-clock comparisons will show spuriously large ages (the test
environment was 8h off local vs UTC).

Pattern memory lives at `scripts/pattern-memory.yaml` (auto-created on first run, never edit by hand).

### GATE 2: Record invocation (ALWAYS RUN)

```bash
python <skill_dir>/scripts/record_invocation.py \
  --signature "<dag-shape>" \
  --family "<short-name>" \
  --matched "<workflow-name-or-null>"
```

| Argument | Meaning |
|----------|---------|
| `--signature` | DAG shape string (see Signature Computation below). |
| `--family` | Short slug for this DAG pattern, e.g. `code-review`. |
| `--matched` | The workflow name if Step 0 hit; literal `null` if you composed ad-hoc. **Only ad-hoc counts toward crystallization.** |

The script prints JSON to stdout. Capture `pattern_id` from it for GATE 4.

### GATE 3: Threshold check

```bash
python <skill_dir>/scripts/check_threshold.py
```

- **Exit 0** → GATE 4 fires. Use the `pattern_id` from the JSON output.
- **Exit 1** → nothing to crystallize, but the script still emits a
  one-line JSON summary (`{"triggered": false, ...}`) so you can see
  the current highest count.

### GATE 4: Propose crystallization

```bash
python <skill_dir>/scripts/propose_crystallize.py --pattern-id <id>
```

The script moves the pattern to `pending_crystallization[]` and prints
a Chinese-language proposal. **It does not write the workflow file.**

When the user approves (or `--yes` is passed), the new workflow lands at:

```
<skill_dir>/workflows/<name>.yaml
```

That's the **only** correct path. Read "Path Map" above — `.claude/workflows/`
and `.codex/workflows/` do not exist for this skill.

For autonomous execution (no human present), pass `--yes` to auto-write
a stub workflow file:

```bash
python <skill_dir>/scripts/propose_crystallize.py --pattern-id <id> --yes
```

The stub is a starting template with a TODO prompt — edit it before
the next Step 0 match wants to use it. The script refuses to overwrite
an existing file (exit code 2) — pick a different name or delete the
stub first.

**User-explicit bypass:** "每次/以后/always/今后/记住/一直" → crystallize NOW (skip threshold). Write the workflow immediately.

## Pattern Memory Schema

`scripts/pattern-memory.yaml` (managed by scripts):

```yaml
next_id: 1                       # global monotonic counter
patterns:                        # count < 2
  - id: 1
    signature: "agent → generate"
    task_family: "code review"
    count: 2
    first_seen: 2026-08-01
    last_seen: 2026-08-05
pending_crystallization:         # count >= 2, awaiting approval
  []
archived_patterns:               # declined 2+ times
  []
invocations:                     # append-only log
  - id: 1
    timestamp: 2026-08-05
    signature: "agent → generate"
    matched_workflow: code-review-pipeline
```

## Signature Computation

Format: `kind|kind → kind → kind|kind`
- `|` separates parallel siblings
- `→` separates sequential phases
- `agent` and `generate` are normalized as equivalent (only `classify`/`input`/`tool` change signature)

Examples:
- `classify → agent|agent → generate` (route, parallel, merge)
- `agent → generate → agent → generate` (linear)

## Anti-Patterns

| Don't | Do |
|-------|-----|
| Skip Step 0 | Always check `workflows/` first |
| "Remember to track" without script | Run GATE 2 script |
| Threshold 3+ | Threshold = 2 |
| Look in `.claude/workflows/` | Use `workflows/` (this skill) |
| Edit pattern-memory.yaml by hand | Always use scripts |
| Skip on_failure fallbacks | Every risky step gets one |
| Run scripts from arbitrary CWD | Run from skill directory or with absolute path |
| Run record_invocation.py concurrently | One script at a time (no file locking) |

## Script Invocation Notes

- `--matched ""` is equivalent to `--matched null` (treated as ad-hoc, counts toward crystallization).
- **Concurrency:** This skill is designed for single-script sequential
  use. Concurrent invocations of `record_invocation.py` are NOT
  supported — would require `fcntl.flock`. Run gates one at a time.
- **Path:** Always run from this skill's directory, or pass an absolute
  path to `<skill_dir>/scripts/record_invocation.py`.
- **Dependencies:** All scripts require **PyYAML** (`pip install pyyaml`).

## Undocumented Workflow Fields (top-level)

These fields appear in existing workflows but are not part of the core schema:

- `kind: meta` — workflow kind marker; all workflows in this skill use this
- `always: false` — workflow is not always loaded; only triggered by Step 0 match
- `final_text_mode: auto` — synthesis mode after DAG completes (auto/raw/step:<id>)

## Script Internals

All scripts require **PyYAML** (`pip install pyyaml`). They use atomic
write (`tempfile` + `os.replace` + `fsync`) and a global monotonic `next_id`
counter to prevent collisions across the four arrays (`patterns`,
`pending_crystallization`, `archived_patterns`, `invocations`).`pending_crystallization`, `archived_patterns`).