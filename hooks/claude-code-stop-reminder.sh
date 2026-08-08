#!/bin/bash
# Claude Code Stop hook. Outputs JSON reminder to LLM.
# This is a NUDGE, not a script runner. The AI runs the actual scripts.
exec jq -n '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: "[meta-orchestrator] 本轮响应结束。请执行结晶门 (Step 5 in SKILL.md):\n\n1. 判断本次任务 tier (T0-T3)\n2. 如果 T1+ 且用了 workflow:\n   - 调 scripts/record_invocation.py --signature \"<dag-shape>\" --family \"<short-name>\" --matched \"<workflow-name-or-null>\"\n3. 调 scripts/check_threshold.py\n4. exit 0 时调 scripts/propose_crystallize.py --pattern-id <id>\n5. 把提议文本贴给用户\n\n跳过此门 = pattern 永远不沉淀。详见 SKILL.md Step 5。"
  }
}'
exit 0
