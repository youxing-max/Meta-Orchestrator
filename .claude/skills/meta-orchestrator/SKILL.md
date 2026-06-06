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
- [ ] T2+ task with novel DAG? → Record pattern signature in `.claude/workflows/.pattern-memory.yaml`
- [ ] Pattern count >= 2 (3rd occurrence)? → Propose crystallization
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

## Step 5: Workflow Crystallization (Save Repeated Patterns Only)

Workflow crystallization saves PROVEN patterns — not every ad-hoc DAG. The rule: a pattern must be observed **2-3 times** before it earns a permanent `.yaml` file. One-off workflows are never saved.

### Complexity Gate

Only T2 and T3 tasks are eligible for crystallization. T0 (lookup/explain) and T1 (simple edit) tasks are never tracked.

### Pattern Memory File

Use `.claude/workflows/.pattern-memory.yaml` to track ad-hoc DAG patterns across sessions:

```yaml
# .claude/workflows/.pattern-memory.yaml
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
- If no matching signature exists in `.pattern-memory.yaml`, add it with count=1
- Do NOT propose crystallization — one occurrence is not enough
- Do NOT mention it to the user

**2nd occurrence (count = 2):**
- Increment count to 2
- Still do NOT propose yet — borderline, observe one more time

**3rd occurrence (count >= 2, i.e., 3+ times):**
- NOW propose crystallization:
  ```
  This workflow pattern has been used 3 times now. Save it for reuse?

  Name: <suggested-kebab-case-name>
  Triggers: <2-3 natural phrases users would say>
  Steps: <summary of the DAG structure>

  Save to .claude/workflows/<name>.yaml? [y/n/edit]
  ```
- If user approves, write the YAML and remove the pattern from `.pattern-memory.yaml`

### Automatic Crystallization (Bypasses Repetition Threshold)

If the user says "每次/以后/always/今后/记住" explicitly, crystallize **immediately** regardless of repetition count:
- "每次发版前都跑这个" → crystallize immediately, don't ask
- "以后遇到这种问题都用这个流程" → crystallize immediately
- "记住这个流程" → crystallize immediately

This is the only case where a single-occurrence pattern gets saved.

### When NOT to Track

Do NOT even record in pattern memory:
- T0/T1 tasks (too simple)
- One-off investigations ("what caused yesterday's outage?")
- Trivial 1-2 step sequences
- Workflows containing hardcoded file paths or timestamps
- Debugging sessions where the steps were exploratory

### Anti-Crystallization (When NOT to save even at count >= 2)

Even after 3+ repetitions, do NOT crystallize if:
- The pattern is essentially "read → think → answer" (every task does this)
- The steps contain project-specific paths or configuration that won't transfer
- An existing workflow in `.claude/workflows/` already covers the same pattern

## Integration with Existing Rules

This skill sits ABOVE the user's existing agent orchestration rules (common/agents.md, common/development-workflow.md). Those rules define WHAT agents exist and WHEN to use them. This skill defines HOW to structure and execute the work across those agents.

Think of it as: existing rules = catalog of capabilities, meta-orchestrator = the execution engine that composes them.
