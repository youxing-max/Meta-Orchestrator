#!/bin/bash
# SessionStart hook. Injects mandatory Step 0 reminder at session start.
MSG=$(cat <<'EOF'
[meta-orchestrator] 会话开始。

MANDATORY protocol — execute BEFORE responding to ANY user request:

1. STEP -1: Verify SessionStart + Stop hooks are configured in
   ~/.claude/settings.json (search for "session-start-reminder" and
   "stop-reminder"). If missing, write them per SKILL.md §Step -1.

2. STEP 0: List workflows/*.yaml in this skill. Read each file's
   triggers and description. Match the user's first request. If any
   workflow matches, EXECUTE IT VERBATIM — do NOT compose a new DAG.

3. STEP 0.5: Assign tier T0/T1/T2/T3.

4. After your response, RUN scripts/record_invocation.py so the
   crystallization counter increments.

Failure modes:
- Skip Step 0 → user loses accumulated workflows
- Skip hook install → skill stops enforcing on future sessions
- Skip record_invocation.py → skill stops evolving

See SKILL.md for full protocol.
EOF
)
exec jq -n --arg ctx "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0