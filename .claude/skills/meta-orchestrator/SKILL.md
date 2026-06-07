---
name: meta-orchestrator
description: DAG-based workflow orchestration engine. Decompose every non-trivial task into a directed acyclic graph of steps, execute with parallelism, route by complexity, handle failures. MUST be invoked at session start.
origin: OpenSquilla-inspired
always: true
---

# Meta-Orchestrator

DAG-based workflow engine that brings OpenSquilla's MetaSkill execution model to Claude Code. You are both the planner AND the runtime -- decompose, dispatch, track, and synthesize.

## CRITICAL: Session-Start Mandate

**This skill is ALWAYS active.** At the start of every conversation, before responding to the user, mentally classify the user's request:

- **Trivial** (single tool call, one-line answer, known file path) → execute directly
- **Non-trivial** (multi-step, multi-file, requires planning, unclear scope) → **DECOMPOSE FIRST**

### Before Creating an Ad-Hoc DAG: Check Existing Workflows

Read `.claude/workflows/` directory. If the user's intent matches any workflow's `triggers` or `description`, **execute the existing workflow** instead of creating an ad-hoc DAG. Existing workflows are already tested and optimized -- reuse them.

Match logic:
1. List all `.yaml` files in `.claude/workflows/`
2. Compare user's request against each workflow's `triggers` and `description`
3. Pick the best match by `meta_priority` (higher = more specific)
4. Execute the matched workflow's DAG steps

## Step 0: Complexity Classification (Tiers)

Before ANY non-trivial work, classify the task and log your reasoning:

| Tier | Complexity | Model | When |
|------|-----------|-------|------|
| **T0** | Lookup, read, explain | haiku | Grep, Read, single-file answers |
| **T1** | Simple edit, fix | haiku → escalate if needed | Single-file edits, well-scoped bugs |
| **T2** | Feature, multi-file, refactor | sonnet | Most development work |
| **T3** | Architecture, novel design, deep reasoning | opus | System design, complex debugging |

Start at the lowest tier that CAN handle it. Escalate only when the task demands it.

**CRITICAL — Crystallization eligibility:** Only T2 and T3 tasks qualify for workflow crystallization. T0 and T1 tasks are too simple and never get saved as reusable workflows. Moreover, a T2/T3 pattern must repeat 2-3 times before it's proven worthy of saving (see Step 5).

## Step 1: DAG Decomposition

For non-trivial tasks, emit a DAG plan BEFORE executing. The DAG is a set of steps connected by `depends_on` edges:

```yaml
# Internal mental model -- emit this as a plan to the user
dag:
  steps:
    - id: <unique_id>
      kind: classify | agent | generate | skill | input | tool
      description: <one-line purpose>
      depends_on: [<step_id>, ...]  # empty = runs immediately
      # kind-specific fields below
```

### Step Kinds

**`classify`** -- Route based on one classification decision.
```
prompt: <what to decide>
output_choices: [A, B, C]
```
RESULT: exactly one choice. Use this to BRANCH the DAG.

**`agent`** -- Dispatch a sub-agent for reasoning or implementation.
```
agent_type: explore | plan | code-review | tdd | security | ...
prompt: <self-contained task description>
model: haiku | sonnet | opus  # default: sonnet
```

**`generate`** -- Pure LLM generation, no tool loop. For summaries, drafts, audits.
```
prompt: <what to produce>
```

**`skill`** -- Invoke a named skill.
```
skill_name: <name from available skills>
args: <optional arguments>
```

**`input`** -- Pause and collect structured input from user.
```
prompt: <what to ask>
schema: {field: type, ...}
```
Supports `route` to branch on user response, same syntax as `classify`:
```yaml
- id: user_approve
  kind: input
  prompt: "Approve the plan?"
  schema:
    decision: {type: enum, choices: [approved, changes_needed]}
  route:
    - when: approved
      to: next_step
    - when: changes_needed
      to: revise_plan
```

**`tool`** -- Deterministic tool call with narrow parameters.
```
tool: Bash | Read | Write | ...
params: {arg: value, ...}
```

### DAG Rules (ENFORCED)

1. Steps with **no** `depends_on` or empty `depends_on` → run **immediately in parallel**
2. Steps with `depends_on` → wait for ALL named predecessors to complete
3. Independent steps at the same depth → **MUST run in parallel** (single Agent call with multiple agents)
4. The graph must be **acyclic** -- no circular dependencies
5. Each step ID must be unique within the DAG
6. **depends_on must ONLY reference steps GUARANTEED to execute.** Do NOT depend on:
   - Steps reachable only via `classify` route branches (conditional execution)
   - Steps declared as `on_failure` fallback targets (dormant until error)
   Before writing a dependency, ask: "does this predecessor ALWAYS run?"
7. **Merge points after conditional routes** depend on the last common ancestor BEFORE the branch, not the branch targets. Branch targets chain forward via their own routes.
8. **`on_failure` fallback steps** are dormant. They execute ONLY as error recovery. No other step may list them in `depends_on`. The fallback replaces its parent in the DAG flow on failure — dependents of the parent resolve against whichever executed (parent or fallback).

#### Common Deadlock Patterns (LEARN FROM THESE)

These are the actual mistakes that cause DAG deadlocks. **Before writing any `depends_on`, scan for these:**

**Pattern A: Depending on a route-only branch target**
```yaml
# WRONG — `diagnose` depends on `incident_response`, but incident_response only
# runs when classify_severity routes to "P0". P1/P2/P3 never reach it.
- id: classify_severity
  kind: classify
  output_choices: [P0, P1, P2, P3]
  route:
    - when: P0
      to: incident_response   # ← ONLY runs for P0
    - when: P1
      to: diagnose            # ← diagnose runs here for P1
    - when: P2
      to: diagnose
    - when: P3
      to: diagnose
- id: diagnose
  depends_on: [classify_severity, incident_response]  # ← DEADLOCK for P1/P2/P3
```
Fix: `diagnose` should only depend on `[classify_severity]`. Branch targets are NOT guaranteed.

**Pattern B: Merging all route branches into one step**
```yaml
# WRONG — `synthesize` depends on security_review, quality_review, infra_review.
# But classify_scope routes to only ONE of them. The other two never execute.
- id: classify_scope
  kind: classify
  output_choices: [security, quality, infra]
  route:
    - when: security → security_review
    - when: quality → quality_review
    - when: infra → infra_review
- id: security_review
  kind: agent
  ...
- id: quality_review
  kind: agent
  ...
- id: infra_review
  kind: agent
  ...
- id: synthesize
  depends_on: [security_review, quality_review, infra_review]  # ← DEADLOCK
```
Fix: remove the route and run all reviews in parallel, OR depend on `classify_scope` as the merge point.

**Pattern C: Depending on a fallback step**
```yaml
# WRONG — `deploy_ready` depends on `build`, but also lists `build_failed`.
# build_failed only runs when build FAILS. Normal path never executes it.
- id: build
  kind: tool
  on_failure: build_failed
- id: build_failed
  kind: generate
  ...
- id: deploy_ready
  depends_on: [build, build_failed]  # ← DEADLOCK: build_failed is dormant
```
Fix: `deploy_ready.depends_on: [build]`. Fallback replaces its parent — dependents resolve against whichever executed.

**Pattern D: Route missing coverage for output_choices**
```yaml
# WRONG — `user_approve` has "changes_needed" choice but no route for it.
# When user selects changes_needed, the DAG silently proceeds to implement_phase1.
- id: user_approve
  kind: input
  output_choices: [approved, changes_needed]
  route:
    - when: approved
      to: implement_phase1
  # ← Missing: when changes_needed → ???
```
Fix: every `output_choices` value MUST have a corresponding `route.when` entry.

### Routing

Steps can branch the DAG using route conditions:
```yaml
- id: classify_task
  kind: classify
  prompt: "Is this a bug fix, feature, or refactor?"
  output_choices: [bug, feature, refactor]
  route:
    - when: bug
      to: fix_bug
    - when: feature
      to: implement_feature
    - when: refactor
      to: refactor_code
```
Only the routed-to branch executes. Others are skipped.

### Failure Handling

Any step can declare a fallback:
```yaml
- id: risky_step
  kind: agent
  on_failure: fallback_step_id
```
If the step fails (agent returns error, tool fails), execute `fallback_step_id` instead.

CRITICAL: Fallback steps must NOT have `depends_on` in the normal DAG flow. They are ONLY executed as error recovery when their parent step fails. Do NOT schedule them in parallel with other steps. They are dormant until triggered by failure.

## Step 2: Parallel Dispatch

When multiple steps are ready (all `depends_on` satisfied), dispatch them in **one call** with multiple Agent invocations:

```
# Parallel dispatch -- single message, multiple Agent calls
Agent(description="Research auth patterns", subagent_type="Explore", prompt="...")
Agent(description="Review existing code", subagent_type="code-reviewer", prompt="...")
Agent(description="Check security", subagent_type="security-reviewer", prompt="...")
```

**Never** run independent steps sequentially. This is the biggest efficiency loss.

## Step 3: Track Execution

Use TaskCreate for each DAG step:
- Create task when step starts
- Mark `in_progress` when dispatching
- Mark `completed` when result arrives
- Mark with failure note if step fails

This gives the user visibility into what's running, what's done, and what failed.

## Step 4: Synthesize Output

After all steps complete, synthesize the final answer. Three modes:

| Mode | Behavior |
|------|----------|
| **auto** (default) | Synthesize a concise answer from all step outputs. Cross-reference, resolve conflicts, highlight key decisions. |
| **raw** | Return the last non-fallback step's output verbatim. |
| **step:<id>** | Return that specific step's output verbatim. |

Default to `auto`. The final synthesis should:
- Answer the user's original question/request
- Reference which steps contributed what
- Flag any unresolved issues or open decisions
- Be concise -- the user can inspect individual step outputs if needed

## Model Selection by Step

Each `agent` step should pick the cheapest capable model:

| Step Complexity | Model | Example |
|----------------|-------|---------|
| Read/search/locate | haiku | "Find where auth logic is defined" |
| Code generation, fix | sonnet | "Implement the OAuth flow" |
| Architecture, novel design | opus | "Design the multi-tenant isolation strategy" |

## Execution Checklist (BEFORE starting work)

For any non-trivial task:
- [ ] Checked `.claude/workflows/` for matching existing workflow
- [ ] Classified into T0-T3 tier
- [ ] If no matching workflow: decomposed into DAG steps with IDs and depends_on
- [ ] Identified parallelism (same-depth steps without dependencies)
- [ ] Assigned model per step
- [ ] Declared failure fallbacks for risky steps
- [ ] Chosen final synthesis mode

## Execution Checklist (AFTER completing work)

- [ ] All steps completed or failed gracefully
- [ ] Final synthesis delivered to user
- [ ] **Workflow executed with issues?** → Flag for self-healing (see Step 5, "Workflow Self-Healing")
- [ ] T2+ task with novel DAG? → Record pattern signature in `.claude/.pattern-memory.yaml`
- [ ] Pattern count >= 3 (3rd occurrence)? → Propose crystallization
- [ ] User said "每次/以后/记住"? → Crystallize immediately without asking

## Anti-Patterns

| Don't | Do |
|-------|-----|
| Execute multi-step work sequentially when steps are independent | Parallel dispatch |
| Use sonnet/opus for lookups and reads | Route to haiku for T0/T1 |
| Start coding without DAG plan for T2+ | Decompose first |
| Run agents one at a time when they don't depend on each other | Batch parallel Agent calls |
| Skip tracking for complex DAGs | TaskCreate per step |
| Let a failed step silently derail the DAG | on_failure fallback |
| Depend on steps that may never execute (conditional routes, fallbacks) | Only depend on guaranteed-execution steps |

## Step 5: Workflow Crystallization (Save Repeated Patterns Only)

Workflow crystallization saves PROVEN patterns — not every ad-hoc DAG. The rule: a pattern must be observed **3 times** before it earns a permanent `.yaml` file. One-off workflows are never saved.

### Complexity Gate

Only T2 and T3 tasks are eligible for crystallization. T0 (lookup/explain) and T1 (simple edit) tasks are never tracked.

### Pattern Memory File

Use `.claude/.pattern-memory.yaml` to track ad-hoc DAG patterns across sessions:

```yaml
# .claude/.pattern-memory.yaml
patterns:
  - signature: "agent|agent|generate→agent|generate→generate"
    task_family: "Multi-phase implementation with parallel audit and review"
    first_seen: 2026-06-06
    count: 2
    last_seen: 2026-06-12
```

### Pattern Signature

A signature is the step-kind sequence with `|` for parallel groups, `→` for sequential:
- `agent|agent → generate → agent|generate → generate` means: 2 parallel agents, then a generate, then agent+generate in parallel, then generate

### Crystallization Workflow

**1st occurrence (count = 1):**
- Compute the pattern signature
- If no matching signature exists in `.claude/.pattern-memory.yaml`, add it with count=1
- Do NOT propose crystallization — one occurrence is not enough
- Do NOT mention it to the user

**2nd occurrence (count = 2):**
- Increment count to 2
- Still do NOT propose yet — borderline, observe one more time

**3rd occurrence (count >= 3):**
- NOW propose crystallization:
  ```
  This workflow pattern has been used 3 times now. Save it for reuse?

  Name: <suggested-kebab-case-name>
  Triggers: <2-3 natural phrases users would say>
  Steps: <summary of the DAG structure>

  Save to .claude/workflows/<name>.yaml? [y/n/edit]
  ```
- If user approves, write the YAML and remove the pattern from `.claude/.pattern-memory.yaml`

### Automatic Crystallization (Bypasses Repetition Threshold)

If the user says "每次/以后/always/今后/记住" explicitly, crystallize **immediately** regardless of repetition count:
- "每次发版前都跑这个" → crystallize immediately, don't ask
- "以后遇到这种问题都用这个流程" → crystallize immediately
- "记住这个流程" → crystallize immediately

This is the only case where a single-occurrence pattern gets saved.

### Crystallization Validation Checklist (MUST PASS before writing .yaml)

Before crystallizing ANY workflow (either by 3-occurrence threshold or automatic bypass), validate the DAG against these rules. If any check fails, fix the DAG FIRST, then crystallize.

- [ ] **No deadlock**: every `depends_on` target is a step that ALWAYS executes (not conditional, not a fallback)
- [ ] **Route completeness**: every `output_choices` value in `classify`/`input` steps has a matching `route.when` entry
- [ ] **Fallback isolation**: `on_failure` targets appear ONLY as `on_failure` values, never in another step's `depends_on`
- [ ] **Merge correctness**: steps after conditional branches depend on the common ancestor, not on branch-specific targets
- [ ] **Acyclicity**: no circular dependency chain (step A → B → ... → A)
- [ ] **No hardcoded paths**: trigger phrases and prompts are generic, not tied to specific file paths or project names

### Workflow Self-Healing (Auto-Optimize Existing Workflows)

When executing an existing workflow, if it exhibits ANY of these symptoms, auto-fix it and update the `.yaml` file:

#### Detection Triggers

| Symptom | Auto-Fix |
|---------|----------|
| A step hangs indefinitely (deadlock detected) | Analyze `depends_on` vs route/fallback reachability, remove unreachable dependencies |
| A step's `on_failure` target is listed in another step's `depends_on` | Remove the fallback from `depends_on`, apply DAG Rule 8 |
| A `classify`/`input` route is missing coverage for some `output_choices` | Add missing route entries or a default route |
| A route branch merges into a step that depends on ALL branches (not the common ancestor) | Fix the merge point to depend on the common ancestor (DAG Rule 7) |
| A step has no `on_failure` but is a key risk point (agent execution, external tool call) | Add `on_failure` fallback with a generate step that reports the failure |
| A `tool` step uses an echo/placeholder command instead of actual work | Replace with a real tool invocation or document it as a stub with a comment |

#### Self-Healing Process

1. **Detect**: When a workflow step fails, hangs, or produces obviously wrong output, pause and analyze the root cause.
2. **Diagnose**: Identify which DAG Rule (1-8) was violated. Log the finding.
3. **Fix**: Apply the minimal fix to the workflow `.yaml` file. Follow the same validation checklist as crystallization.
4. **Report**: Tell the user what was fixed and why:
   ```
   Auto-fixed workflow `<name>`: <brief description of the issue and fix>.
   ```
5. **Do NOT ask for permission** — self-healing fixes correctness bugs, not design changes. If the fix is potentially controversial (e.g., adding a new step), ask first.

#### Periodic Health Check

When listing workflows or at session start, quickly scan all `.yaml` files in `.claude/workflows/` for:
- Deadlock patterns (any step depending on a fallback-only or conditional-only step)
- Missing `on_failure` on `agent`/`tool` steps
- Placeholder `tool` commands (`echo`, `true`, empty params)
- Route coverage gaps

Flag issues to the user as a brief summary. Fix critical (deadlock) issues immediately.

### When NOT to Track

Do NOT even record in pattern memory:
- T0/T1 tasks (too simple)
- One-off investigations ("what caused yesterday's outage?")
- Trivial 1-2 step sequences
- Workflows containing hardcoded file paths or timestamps
- Debugging sessions where the steps were exploratory

### Anti-Crystallization (When NOT to save even at count >= 3)

Even after 3+ repetitions, do NOT crystallize if:
- The pattern is essentially "read → think → answer" (every task does this)
- The steps contain project-specific paths or configuration that won't transfer
- An existing workflow in `.claude/workflows/` already covers the same pattern

## Integration with Existing Rules

This skill sits ABOVE the user's existing agent orchestration rules (common/agents.md, common/development-workflow.md). Those rules define WHAT agents exist and WHEN to use them. This skill defines HOW to structure and execute the work across those agents.

Think of it as: existing rules = catalog of capabilities, meta-orchestrator = the execution engine that composes them.
