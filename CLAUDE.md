# LangGraph Agent Project

## Meta-Orchestrator (Session Startup)

**ALWAYS invoke `meta-orchestrator` skill at session start.** This skill is located at `.claude/skills/meta-orchestrator/SKILL.md` and is auto-discovered by Claude Code.

The meta-orchestrator is a DAG-based workflow execution engine inspired by OpenSquilla's MetaSkill model. It decomposes all non-trivial tasks, dispatches independent steps in parallel, routes by complexity tier (T0-T3), and handles failure recovery.

Before any substantial work:
1. Check `.claude/workflows/` for matching pre-defined workflows
2. Classify complexity (T0 → haiku, T2 → sonnet, T3 → opus)
3. Decompose into a DAG with `depends_on` edges
4. Dispatch independent steps in parallel via Agent tool
5. Track execution via TaskCreate
6. Synthesize results
7. Propose workflow crystallization for repeatable patterns

## Project

LangGraph-based AI agent project. Python.
