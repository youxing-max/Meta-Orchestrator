---
name: meta-orchestrator
description: |
  Recommended for non-trivial sessions. Use 'skip' or '--no' to bypass.
  Manages a workflow DAG library; records invocations for pattern
  accumulation. On Claude Code a Stop hook auto-runs `orchestrator.py record`
  after every response. On Codex there is no hook — the model itself must
  emit the meta-orchestrator marker or invoke `orchestrator.py record`.
  Opt-out keywords: "skip", "don't run orchestrator", "--no".

  Infrastructure exception: this skill is exempt from Step 0 (it IS
  the engine). User-facing workflows live in `workflows/<name>.yaml`.
---

# Meta-Orchestrator

## Bootstrap Hooks (RECOMMENDED, every session-start)

The skill auto-records invocations through a Claude Code **Stop hook**.
Install once; the skill stays silent without it. Skip this section if
the user said "skip" / "--no".

### 1. Configure `~/.claude/settings.json`

```bash
SKILL_DIR="$HOME/.claude/skills/meta-orchestrator"   # adjust if installed elsewhere
mkdir -p .claude
python3 <<PYEOF
import json, os
p = '.claude/settings.json'
data = {}
if os.path.exists(p):
    try:
        data = json.load(open(p))
    except Exception:
        data = {}

hooks_root = data.setdefault('hooks', {})
st = hooks_root.setdefault('Stop', [])
cmd = f'bash {os.environ.get("SKILL_DIR", "$SKILL_DIR")}/hooks/claude-code-stop-reminder.sh'
if not any('stop-reminder' in str(h) for hs in st for h in hs.get('hooks', [])):
    st.append({'hooks': [{'type': 'command', 'command': cmd}]})

with open(p, 'w') as f:
    json.dump(data, f, indent=2)
print('✓ Stop hook configured')
PYEOF
```

Requires `jq` (standard on Linux/macOS; `brew install jq` / `apt install jq` otherwise).

### 2. Confirm

> "✓ Stop hook configured. After every response the hook will run orchestrator.py record subcommand."

Without the hook, run the gate scripts manually after every response.

### 3. Codex setup (optional but recommended)

Codex auto-discovers skills placed under `~/.codex/skills/<name>/`.
Copy this skill there. The `turn_end` hook config block below is
documented for forward-compatibility — Codex 0.144.4 does **not** emit
a `turn_end` event today (its hook surface is limited to
`SessionStart` / `PreToolUse` / `PostToolUse` / `PreCompact` /
`PostCompact` / `SubagentStart` / `SubagentStop`). On Codex the
model itself emits the marker or invokes `orchestrator.py record`
after each response — there is no hook-side auto-record.

```bash
# 3a. Copy skill files (exclude .git, bytecode, runtime state)
CODEX_SKILLS="$HOME/.codex/skills"
mkdir -p "$CODEX_SKILLS/meta-orchestrator"
# rsync is preferred; fall back to cp -r if rsync is missing.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude='.git' --exclude='__pycache__' \
            --exclude='*.pyc' --exclude='pattern-memory.yaml*' \
            "$SKILL_DIR"/ "$CODEX_SKILLS/meta-orchestrator/"
else
  find "$SKILL_DIR" -maxdepth 1 -mindepth 1 \
       ! -path '*/.git' ! -path '*/__pycache__' \
       ! -name '*.pyc' ! -name 'pattern-memory.yaml*' \
       -exec cp -r {{}} "$CODEX_SKILLS/meta-orchestrator/" \;
fi
echo "✓ Copied to $CODEX_SKILLS/meta-orchestrator/"

# 3b. Wire turn_end hook in ~/.codex/config.toml (forward-compat placeholder).
#     Idempotent: replaces any existing [hooks] block, then appends ours.
#     Safe today (no-op because Codex 0.144.4 has no turn_end event) and
#     automatically active if Codex adds the event in a future release.
CODEX_CONFIG="$HOME/.codex/config.toml"
python3 <<PYEOF
import os, re
p = os.environ.get("CODEX_CONFIG")
src = open(p).read() if os.path.exists(p) else ""
hook_path = f"{os.environ['SKILL_DIR']}/hooks/claude-code-stop-reminder.sh"
hook_block = (
    '[hooks]\n'
    f'turn_end = [ {{ command = ["bash", "{hook_path}"], timeout = 5000 }} ]\n'
)
# Drop any existing [hooks] block(s) to avoid duplicate-key TOML parse errors,
# then append ours. Any other top-level tables ([projects.*], [tui.*], ...)
# are preserved untouched.
src = re.sub(r"\[hooks\]\s*\n.*?(?=\n\[|\Z)", "", src, flags=re.S).rstrip()
src = src + "\n\n" + hook_block
open(p, "w").write(src)
print(f"✓ turn_end hook placeholder written to {p}")
PYEOF
```

If you skip 3b, Codex still discovers the skill — auto-record on the
Codex side is purely model-driven (the model reads this SKILL.md and
emits the marker or runs `orchestrator.py record` itself).

### 4. Keep both copies in sync

Claude Code and Codex have separate skill directories. After any edit
to this skill, re-run 3a to refresh the Codex copy. Otherwise the
Codex model will see stale instructions.

---

## Path Map

`<SKILL_DIR>` = the absolute path where this skill is installed
(`~/.claude/skills/meta-orchestrator` on Claude Code).

| What | Where | Created by |
|------|-------|------------|
| Workflows | `<SKILL_DIR>/workflows/*.yaml` | human or AI |
| Pattern memory | `<SKILL_DIR>/scripts/pattern-memory.yaml` | scripts only — never hand-edit |
| Scripts | `<SKILL_DIR>/scripts/*.py` | this skill |
| Lock | `<SKILL_DIR>/scripts/pattern-memory.yaml.lock` | scripts (auto, POSIX only) |

| Script | Job |
|--------|-----|
| `orchestrator.py` | record / check / propose subcommands |
| `_memory.py` | YAML load + atomic backup helpers |
| `_file_lock.py` | POSIX fcntl lock |
| `_judge.py` | LLM judge for semantic pattern matching (5 s timeout) |
| `_matcher.py` | Step 0 weighted match + Step 0.5 tier classification |
| `validate_dag.py` | workflow schema validator |

Scripts auto-resolve `pattern-memory.yaml` via `Path(__file__).parent`,
so they work from any cwd on any OS. Do not `cd` first; pass the absolute path.

---

## Step 0: Workflow Reuse Gate (algorithm)

Implementation: `scripts/_matcher.py`. The hook invokes it on every
response; the LLM can also call it directly via:

```bash
python3 <SKILL_DIR>/scripts/_matcher.py --text "<user request>"
```

Returns JSON with `{matched, score, meta_priority, tier, candidates}`.

1. List `workflows/*.yaml`
2. For each, read `triggers:`, `description:`, `neg-keywords:`, `meta_priority:`, `loose:`
3. **Neg-keyword check**: if any neg-keyword appears in the user request,
   that workflow is excluded from matching
4. **Score**:
   - Exact trigger phrase match → weight **10**
   - Description keyword overlap (≥2 distinct words ≥3 chars) → weight **5**
   - Single description keyword overlap → weight **1**
   - No overlap → 0
5. **Match threshold**: score ≥ 5 to be a candidate. Set `loose: true` in
   the workflow YAML to opt back into ≥1.
6. **Tiebreakers**: higher score → higher `meta_priority` → name asc
7. No match → Step 0.5

**Workflow YAML fields** (optional unless noted):

```yaml
name: <kebab-case-name>           # required
description: "<one-line purpose>" # required, used for keyword scoring
triggers:                         # required, list of phrases
  - fix bug
neg-keywords:                     # optional, list of exclusion words
  - production
meta_priority: 10                 # optional, default 0; tiebreaker
loose: true                       # optional, opt into score >= 1 match
```

---

## Step 0.5: Tier Classification

Implementation: `_matcher.py:_tier_for`. Pure keyword scan, first match wins:

| Tier | Scope | Trigger keywords |
|------|-------|------------------|
| T3 | architecture, design | `architecture`, `design`, `redesign`, `架构`, `设计` |
| T2 | multi-file, refactor | `refactor`, `migrate`, `multi-file`, `重构`, `迁移` |
| T1 | single-file edit | `edit`, `fix`, `change`, `update`, `修改`, `修复` |
| T0 | lookup, read-only | `lookup`, `find`, `where`, `查`, `哪里` |

Fallback: text > 200 chars → T2, else T1.

---

## Session-Start Mandate

⚠️ Recommended, not mandatory. Honor any "skip" / "don't run orchestrator" / "--no".

1. **Step 0** — list `workflows/*.yaml`, match `triggers:` + `description:`
2. **Step 0.5** — assign T0–T3 (every task gets a tier)
3. **After EVERY response** — run GATE 2 (record invocation) or emit
   the marker so the Stop hook auto-runs it

Trivial turns (greetings, yes/no, single-line lookups) emit the marker
with `--trivial` so the audit trail is complete but `count` is not bumped.

---

## Step 0: Workflow Reuse Gate

1. List `workflows/*.yaml`
2. For each, read `triggers:`, `description:`, `neg-keywords:`
3. Neg-keyword check: if any neg-keyword appears in the user request,
   that workflow is excluded from matching
4. Score match:
   - Exact trigger phrase → weight 10
   - Description keyword overlap (≥2) → weight 5
   - Single keyword overlap → weight 1
   - No overlap → 0
5. Match threshold: score ≥ 5 to be a candidate. Set `--loose` in YAML
   to opt back into ≥1.
6. Tiebreakers: higher score → higher `meta_priority` → fall through to Step 0.5
7. No match → Step 0.5

---

## Step 0.5: Tier Classification

| Tier | Scope | Action |
|------|-------|--------|
| T0 | lookup, single-file | Execute directly |
| T1 | single-file edit | Execute directly |
| T2 | multi-file, refactor | Decompose into DAG |
| T3 | architecture, design | Decompose into DAG |

---

## Step 1: DAG Decomposition (T2+)

> Steps 2-4 are the agent's own reasoning (research / plan / execute).
> Not gated here — they fall under T3 default behavior.

Refer to existing `workflows/*.yaml` for canonical shapes. Or write from
the schema below.

```yaml
name: <kebab-case-name>
description: "<one-line purpose>"
triggers:
  - <phrase users would say>
meta_priority: 10                 # higher = more specific match
composition:
  steps:
    - id: <unique_snake_id>
      description: <one-line purpose>
      kind: agent | generate | classify | input | tool
      prompt: <task description>
      agent_type: <type>            # required if kind=agent
      model: haiku | sonnet | opus  # optional, default=sonnet
      depends_on: [<step_id>, ...]
      on_failure: <fallback_step_id>

    # kind=classify also needs:
      output_choices: [<value1>, <value2>, ...]
      route:
        - when: <value1>
          to: <step_id>

    # kind=input — schema-driven:
      schema:
        decision: {type: enum, choices: [approved, changes_needed]}
        feedback: {type: string}
      route:
        - when: approved
          to: <step_id>
        - when: changes_needed
          to: <step_id>
```

### Step Kinds

- **agent** — dispatches a subagent. Requires `agent_type`.
- **generate** — LLM generates text inline. No subagent.
- **classify** — routes by classification. Needs `output_choices` + `route`.
- **input** — prompts user. Needs `schema` + `route`.
- **tool** — runs bash/python. Requires `tool:` + `params:`.

### Agent Types

| Agent type | Use for |
|-----------|---------|
| `Explore` | Read-only search |
| `general-purpose` | Multi-step tasks, code generation |
| `code-reviewer` | Code quality, style |
| `security-reviewer` | Vulnerability scan |
| `tdd-guide` | TDD, regression tests |

### DAG Rules (MUST FOLLOW)

1. **No deadlock** — every `depends_on` target must always execute
2. **Route completeness** — every `output_choices` value has matching `route.when`
3. **Fallback isolation** — `on_failure` targets never appear in another `depends_on`
4. **Acyclicity** — no circular dependencies
5. **One-level references** — don't nest SKILL.md → a.md → b.md

For a working example, see `workflows/_TEMPLATE.yaml`.

---

## Step 5: Crystallization Gate (every response)

⚠️ Skip = pattern counter never increments = skill is useless.

### Pattern vs Workflow File

| Term | What | Where |
|------|------|-------|
| **pattern** | bookkeeping row: counter, signature, family | `scripts/pattern-memory.yaml → patterns[]` |
| **workflow file** | reusable DAG | `workflows/<name>.yaml` |

A pattern can fire the gate many times before any workflow file exists.
The workflow file is written **only after GATE 4 user approval** (or
`--yes` in unattended mode). Say explicitly: *"this is a pattern ready
to crystallize — the workflow file does not exist yet."*

### Scripts

| Script | Job | When |
|--------|-----|------|
| orchestrator.py record subcommand | Append `invocations[]`; increment `patterns[].count` if ad-hoc + non-trivial. Returns JSON with `pattern_id`. | Every response (GATE 2) |
| orchestrator.py check subcommand | Recompute non-trivial ad-hoc count per signature; exit 0 if any ≥ 3. | Every response (GATE 3) |
| orchestrator.py propose subcommand | Default: read-only print proposal. `--yes`: write stub + archive `crystallized`. `--no`: archive `declined`. | Only when GATE 3 exits 0 (GATE 4) |

### ID allocation

orchestrator.py record subcommand uses a single global `next_id` shared across
`invocations[]` and `patterns[]`. Expect gaps in `invocations[].id` —
those gaps are pattern IDs. Read `pattern_id` from JSON output, do not
assume `id = N`.

### GATE 2: Record invocation

**Auto-mode (recommended):** end your response with the marker:

```html
<!-- meta-orchestrator: sig=<dag-shape> family=<short-name> matched=<workflow-or-null> [pattern=<id>] [intent="..."] [--trivial] -->
```

The Stop hook extracts the fields and calls `orchestrator.py record`. The
optional `pattern=<id>` field lets the LLM self-judge which existing pattern
this invocation belongs to (best precision, zero LLM call cost). The
optional `intent="..."` field is stored on new patterns as a human-readable
hint about what task this represents.

**Pattern match decision (in order of precedence):**

1. **Marker `pattern=<id>`** — LLM-declared match. Forced; takes precedence.
2. **`--judge` (hook auto-mode)** — single LLM call (`scripts/_judge.py`,
   5 s timeout). Semantically decides which existing pattern (by id) the new
   invocation belongs to, or `none` for a new distinct task. Falls back to
   step 3 on any error / timeout.
3. **Signature-string fallback** — `p["signature"] == args.signature`. The
   legacy exact-match path. Misses cases where the same task has different
   tool sequences.
4. **Skip pattern aggregation** if signature is the fallback `"agent"` (no
   tools named) — prevents low-quality patterns from accumulating.

**Manual fallback:**

```bash
python3 <SKILL_DIR>/scripts/orchestrator.py record \
  --signature "<dag-shape>" \
  --family "<short-name>" \
  --matched "<workflow-name-or-null>" \
  [--pattern-id <id>] [--judge] [--intent "..."] [--trivial]
```

| Argument | Meaning |
|----------|---------|
| `--signature` | DAG shape string (see Signature Computation) |
| `--family` | Short slug for this pattern, e.g. `code-review` |
| `--matched` | Workflow name if Step 0 hit; literal `null` if ad-hoc. **Only ad-hoc counts toward crystallization.** |
| `--trivial` | Bookkeeping-only. Logged but `patterns[].count` NOT incremented. |
| `--pattern-id` | Force this invocation to bump count of an existing pattern (LLM self-judged). |
| `--judge` | Call the LLM once to decide which existing pattern matches semantically. ~3 s latency, 1 small API call. |
| `--intent` | Optional human-readable description stored on new patterns for future review. |

**Classifier (v1.2).** The hook runs a 5-tier classifier before writing:

| Tier | Rule | Action |
|------|------|--------|
| `TRIVIAL_SKIP` | < 50 chars, no tools, no markdown | skip |
| `ACK_SKIP` | pure acknowledgment ("ok" / "yes" / "好的") | skip |
| `SIMPLE_TASK` | has 1 tool but short / no markdown | skip |
| `META_RECORD` | mentions "meta-orchestrator" / "crystalliz" / "pattern" / "workflow" | write as `--trivial` |
| `COMPLEX_TASK` | ≥3 distinct tools OR ≥500 chars OR has markdown OR explicit marker | write non-trivial, hook auto-uses `--judge` |

If the marker is missing on `TASK_RECORD`, the hook derives
signature/family/matched from the response (tool sequence / first 4
words / grep `workflows/*.yaml` triggers).

### GATE 3: Threshold check

```bash
python3 <SKILL_DIR>/scripts/orchestrator.py check
```

- **Exit 0** → GATE 4 fires. Use `pattern_id` from the JSON output.
- **Exit 1** → nothing to crystallize; the script still prints a summary.

### GATE 4: Propose crystallization

```bash
python3 <SKILL_DIR>/scripts/orchestrator.py propose --pattern-id <id>
```

Default mode is read-only. Run again with `--yes` or `--no` after the
user decides:

```
patterns[] ──(this script invoked)──> [print proposal, wait]
          │
          ├── --yes: write workflows/<name>.yaml + patterns[] → archived_patterns[outcome=crystallized]
          └── --no:  patterns[] → archived_patterns[outcome=declined]
```

**Drain semantics (S4).** `--yes` and `--no` remove all `invocations[]`
rows matching the signature. The same signature cannot re-trigger until
**3 fresh non-trivial invocations** accumulate again.

**Autonomous mode:**

```bash
python3 <SKILL_DIR>/scripts/orchestrator.py propose --pattern-id <id> --yes
```

Writes a stub workflow with a TODO prompt — edit before reuse. Refuses
to overwrite an existing file.

**User-explicit bypass:** keywords "always" / "every time" / "from now
on" / "记住" / "每次" → propose crystallization immediately, still
running orchestrator.py propose subcommand first; only `--yes` after the user
confirms.

---

## Pattern Memory Schema

`scripts/pattern-memory.yaml` (managed by scripts):

```yaml
next_id: 1
patterns:                        # effective count < 3 (computed from invocations[])
  - id: 1
    signature: "agent → generate"
    task_family: "code review"
    count: 2                      # stored value; orchestrator.py recomputes
    first_seen: 2026-08-01
    last_seen: 2026-08-05
archived_patterns:               # declined or crystallized
  []
invocations:                     # append-only log
  - id: 1
    timestamp: 2026-08-05
    signature: "agent → generate"
    task_family: "code review"
    matched_workflow: code-review-pipeline
    trivial: false
```

---

## Signature Computation

Format: `kind|kind → kind → kind|kind`
- `|` separates parallel siblings
- `→` separates sequential phases
- `agent` and `generate` are normalized as equivalent

Examples: `classify → agent|agent → generate`, `agent → generate → agent`.

---

## Script Invocation Notes

- `--matched ""` is equivalent to `--matched null` (treated as ad-hoc).
- **Concurrency:** `scripts/_file_lock.py` serializes via `fcntl.flock`
  on POSIX. Windows degrades to no-op — `.bak` self-heal covers
  single-process case. Run gates sequentially.
- **Cross-platform paths:** scripts resolve `pattern-memory.yaml` via
  `Path(__file__).parent`; pass the absolute `<SKILL_DIR>/scripts/<name>.py`.
- **Dependencies:** All scripts require **PyYAML** (`pip install pyyaml`).