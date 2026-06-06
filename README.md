# Meta-Orchestrator

> DAG-based skill orchestration for Claude Code — inspired by [OpenSquilla](https://github.com/opensquilla/opensquilla)'s MetaSkill execution engine.

**Meta-Orchestrator** transforms Claude Code from a linear agent into a DAG-based workflow engine. It decomposes complex tasks, dispatches independent steps in parallel, routes work by complexity tier, handles failures gracefully, and automatically crystallizes repeated patterns into reusable workflows.

Same budget, more capability, better results.

## Why?

Claude Code with default behavior executes work sequentially. It relies on the model's memory to follow a plan. This works for simple tasks but breaks down when:

- Multiple independent sub-tasks could run in parallel but run one-by-one
- The model forgets a step or skips error handling
- A workflow that worked well yesterday is forgotten and rebuilt from scratch
- The same pattern (code review, deploy check, bug fix) is re-planned every time

**Meta-Orchestrator solves this with a structured execution engine:**

| Without | With Meta-Orchestrator |
|---|---|
| Sequential execution by default | DAG decomposition with parallel dispatch |
| Model decides what to do next | Dependency graph enforces correct order |
| Repeated patterns re-planned every time | Crystallized into reusable `.yaml` workflows |
| One model for everything | T0-T3 complexity tier routing (haiku → opus) |
| Failures silently derail progress | Explicit `on_failure` fallback steps |
| No execution visibility | TaskCreate tracking per DAG step |

## Architecture

```
User Request
     │
     ▼
┌─────────────────────────────────────┐
│ Step 0: Complexity Classification   │
│ T0 (haiku) → T1 → T2 (sonnet) → T3 │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 1: Check Existing Workflows    │
│ .claude/workflows/*.yaml            │
└──────┬──────────────────┬───────────┘
       │ Match?           │ No Match
       ▼                  ▼
┌──────────────┐  ┌───────────────────┐
│ Execute      │  │ Step 2: DAG       │
│ workflow     │  │ Decomposition     │
│ YAML         │  │                   │
└──────────────┘  │ classify → agent  │
                  │ generate → skill  │
                  │ input   → tool    │
                  └────────┬──────────┘
                           ▼
┌─────────────────────────────────────┐
│ Step 3: Parallel Dispatch           │
│ Independent steps → single batch    │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 4: Track + Synthesize          │
│ TaskCreate per step → auto merge    │
└──────────────┬──────────────────────┘
               ▼
┌─────────────────────────────────────┐
│ Step 5: Workflow Crystallization    │
│ Repeated pattern? → Save as .yaml   │
└─────────────────────────────────────┘
```

### Step Types

| Kind | Purpose | Example |
|------|---------|---------|
| `classify` | Route based on one decision | "Is this a bug, feature, or refactor?" |
| `agent` | Dispatch a sub-agent | Code review, security scan, implementation |
| `generate` | Pure LLM generation, no tools | Summaries, reports, documentation |
| `skill` | Invoke a named Claude Code skill | `code-review`, `tdd`, `security-review` |
| `input` | Pause for structured user input | Approval gates, design reviews |
| `tool` | Deterministic tool call | `Bash`, `Read`, `Write` |

### Complexity Tiers

| Tier | Use Case | Model | Cost |
|------|----------|-------|------|
| **T0** | Lookup, read, explain | haiku | $ |
| **T1** | Simple edit, single-file fix | haiku → escalate | $ |
| **T2** | Feature, multi-file, refactor | sonnet | $$ |
| **T3** | Architecture, novel design | opus | $$$ |

## Quick Start

```bash
cp -r .claude /your-project/
cp CLAUDE.md /your-project/
```

Claude Code auto-discovers skills in `.claude/skills/` and reads `CLAUDE.md` at session start. The meta-orchestrator activates on the next session.

Verify:

```
> 帮我全面审查一下代码
```

You should see the meta-orchestrator classify the task (T2), match `code-review-pipeline`, and dispatch parallel review agents.

## Usage

### Automatic (default)

Just use Claude Code normally. Meta-Orchestrator activates for non-trivial tasks:

```
User: 帮我把 session 认证改成 JWT
      ↓
Meta-Orchestrator:
  1. Classify: T2 (multi-file feature)
  2. No matching workflow → ad-hoc DAG
  3. DAG: audit || research → design → implement → test || security → synthesize
  4. Parallel dispatch: [audit, research] → [design] → [implement] → [test, security] → [synthesize]
  5. Propose crystallization: "Save this as a reusable workflow?"
```

### Explicit workflow invocation

Use natural language that matches a workflow trigger:

```
> 上线前检查一下
→ matches deploy-checklist.yaml trigger "上线前检查"
→ executes: test || security → build → summary → notify
```

### Creating reusable workflows

After a complex task succeeds, meta-orchestrator proposes saving it. Say "每次/以后/记住" to auto-crystallize:

```
> 每次改完代码后自动跑测试和lint检查，记住了
→ detects "每次" + "记住" → crystallizes immediately
→ .claude/workflows/auto-test-lint.yaml created
```

## Workflow Examples

### 1. Code Review Pipeline

Trigger: "全面审查", "安全审计", "code review"

```
classify_scope → security_review || quality_review || infra_review → synthesize_report
```

### 2. Deploy Checklist

Trigger: "上线前检查", "pre-deploy", "发版检查"

```
run_tests || security_scan → build → deploy_ready → notify
```

### 3. Bug Fix Workflow

Trigger: "修bug", "fix bug", "debug", "修复"

```
classify_severity (P0→incident, P1-P3→diagnose)
  → diagnose → repro_steps
  → implement_fix || write_tests
  → review_fix || verify_edge_cases
  → synthesize
```

### 4. API Migration

Trigger: "API 迁移", "接口迁移", "migrate API"

```
audit_endpoints || research_target || analyze_breaking
  → design_migration → user_approve
  → implement_phase1 → test_migration
  → review_migration → migration_docs → synthesize
```

## Workflow Authoring Guide

```yaml
name: my-workflow              # kebab-case identifier
kind: meta                     # always "meta"
description: One-line purpose
triggers:                      # 2-5 natural phrases
  - do the thing
  - 做这件事
meta_priority: 10              # higher = preferred when multiple match
always: false
final_text_mode: auto          # auto | raw | step:<id>

composition:
  steps:
    - id: step_1
      kind: agent              # classify | agent | generate | skill | input | tool
      description: What it does
      depends_on: []           # empty = runs immediately (root)
      agent_type: Explore
      model: haiku             # haiku | sonnet | opus
      prompt: "..."

    - id: step_2
      kind: generate
      depends_on: [step_1]
      on_failure: fallback_id  # dormant — only runs if this step fails
      prompt: "..."

    - id: router
      kind: classify
      output_choices: [A, B]
      route:
        - when: A
          to: path_a           # only this branch executes
        - when: B
          to: path_b
```

### DAG Rules

1. Empty `depends_on` → run immediately in parallel
2. Non-empty `depends_on` → wait for ALL named predecessors
3. Independent steps at same depth → **always dispatched in one parallel batch**
4. Graph must be **acyclic** — no circular dependencies
5. Fallback steps are **dormant** — only run when parent fails

## Design Philosophy

Directly inspired by [OpenSquilla](https://github.com/opensquilla/opensquilla)'s MetaSkill system:

| OpenSquilla | Meta-Orchestrator |
|---|---|
| External Python runtime enforces DAG | Claude follows DAG via skill instructions |
| LightGBM + ONNX router classifies tasks | Claude classifies with keyword + context heuristics |
| `meta_invoke()` tool triggers workflows | Intent matching against trigger phrases |
| Proposal gate for human review | Crystallization proposal after successful DAG |
| Risk-level sandbox | Claude Code permission system |
| 20+ LLM backend routing | haiku/sonnet/opus tier routing |

The core insight: **execution guarantee through structure, not through hoping the model does the right thing.**

## Directory Structure

```
.claude/
├── skills/
│   └── meta-orchestrator/
│       └── SKILL.md              # The orchestration engine
└── workflows/
    ├── code-review-pipeline.yaml # Parallel security + quality review
    ├── deploy-checklist.yaml     # Pre-deploy verification
    ├── bug-fix-workflow.yaml     # Structured bug fix pipeline
    └── api-migration.yaml        # API migration/replatforming
CLAUDE.md                         # Session startup instructions
README.md                         # This file
```

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- No external dependencies — runs entirely within Claude's skill system

## Reference

- [OpenSquilla](https://github.com/opensquilla/opensquilla) — Token-efficient AI agent with MetaSkill system
- [Claude Code Skills](https://docs.anthropic.com/en/docs/claude-code/skills)

## License

MIT
