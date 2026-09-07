#!/bin/bash
# Claude Code Stop hook -- classifier + derive + lazy orchestrator.
#
# Goal: minimize writes to pattern-memory.yaml. Skip trivial turns entirely;
# auto-derive signature/family/matched for task turns where the LLM forgot
# the marker. Only run orchestrator.py check when the file actually has content.
#
# Flow:
#   1. Loop guard (stop_hook_active) -- exit silently on re-entry.
#   2. Lazy orchestrator -- only if pattern-memory.yaml exists and has
#      non-empty invocations[] section. Skip if empty (no point computing).
#   3. Extract last assistant text from transcript.
#   4. Classify into 4 tiers:
#        TRIVIAL_SKIP  -- short text, no tools, no markdown: skip entirely
#        ACK_SKIP      -- pure ack (ok/yes/no/好的): skip entirely
#        META_RECORD   -- mentions orchestrator keywords: write as --trivial
#        TASK_RECORD   -- real task: try marker first, else derive
#   5. For TASK_RECORD:
#        - If marker present and parseable: use it
#        - Else: derive signature from tool_use sequence, family from
#          first sentence, matched from workflows/*.yaml triggers
#   6. Assemble additionalContext with pending hint + record status.

INPUT=$(cat)
if echo "$INPUT" | jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
  exit 0
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Step 2: lazy orchestrator ---
# Only run if pattern-memory.yaml exists and has actual content. Empty /
# missing file means no work to do. Skip cleanly without emitting phantom
# hints if `check` ever fails or returns malformed JSON.
threshold_json=""
mem_file="$SKILL_DIR/scripts/pattern-memory.yaml"
if [ -s "$mem_file" ]; then
  threshold_json="$(python3 - "$mem_file" "$SKILL_DIR" <<'PYEOF' 2>/dev/null || echo ""
import json, subprocess, sys, yaml
mem_file, skill_dir = sys.argv[1], sys.argv[2]
# Pre-check: skip check entirely if there are no invocations yet.
try:
    with open(mem_file) as f:
        d = yaml.safe_load(f) or {}
    if not d.get("invocations"):
        sys.exit(0)
except Exception:
    sys.exit(0)
try:
    r = subprocess.run(
        ["python3", f"{skill_dir}/scripts/orchestrator.py", "check"],
        capture_output=True, text=True, timeout=10,
    )
    # Only trust a clean exit-0 with parseable JSON list.
    if r.returncode != 0:
        sys.exit(0)
    parsed = json.loads(r.stdout)
    if not isinstance(parsed, list):
        sys.exit(0)
    # Filter: every returned id must exist in current patterns[].
    actual_ids = {p.get("id") for p in d.get("patterns", []) if isinstance(p, dict)}
    valid = [row for row in parsed
             if (row.get("pattern_id") or row.get("id")) in actual_ids]
    if valid:
        print(json.dumps(valid, ensure_ascii=False))
except Exception:
    sys.exit(0)
PYEOF
  )"
fi

pending_hint=""
if [ -n "$threshold_json" ] && [ "$threshold_json" != "[]" ]; then
  # Build a human-readable hint: for each pending pattern show signature,
  # task_family, count, and a one-line description. The user needs to know
  # WHAT the pattern is before deciding to crystallize — id alone is opaque.
  # Use a tmp file for stdin to dodge bash 5.x heredoc-in-substitution syntax
  # errors that fire when `|| echo ""` follows a `<<'PYEOF'` heredoc.
  _hint_in="$(mktemp 2>/dev/null || echo "/tmp/meta-orch-hint-in-$$")"
  _hint_out="$(mktemp 2>/dev/null || echo "/tmp/meta-orch-hint-out-$$")"
  printf '%s' "$threshold_json" > "$_hint_in"
  SKILL_DIR_OVERRIDE="$SKILL_DIR" python3 - "$mem_file" "$_hint_in" > "$_hint_out" 2>/dev/null <<'PYEOF' || true
import json, os, sys, yaml
mem_file, hint_in = sys.argv[1], sys.argv[2]
try:
    threshold = json.loads(open(hint_in).read())
except Exception:
    sys.exit(0)
try:
    with open(mem_file) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
invocations = data.get("invocations", [])
lines = []
for p in threshold:
    pid = p.get("pattern_id") or p.get("id")
    sig = p.get("signature", "?")
    fam = p.get("task_family", "?")
    count = p.get("count", 0)
    first_seen = p.get("first_seen", "?")
    last_seen = p.get("last_seen", "?")
    samples = [i for i in invocations
               if i.get("signature") == sig and not i.get("trivial")]
    last_sample = samples[-1] if samples else {}
    last_family = last_sample.get("task_family", fam)
    lines.append(
        f"  · id={pid}  count={count}  range={first_seen}..{last_seen}\n"
        f"      signature: {sig}\n"
        f"      family:    {fam}\n"
        f"      example:   last invocation family = {last_family!r}"
    )
print("\n".join(lines))
PYEOF
  pending_hint="$(cat "$_hint_out")"
  rm -f "$_hint_in" "$_hint_out"
  if [ -n "$pending_hint" ]; then
    pending_hint="⚠ Crystallization threshold met — these patterns are ready to review:\n${pending_hint}\n\nFor each, run: scripts/orchestrator.py propose --pattern-id <id>\n  (y → write workflow file   n → archive as declined)"
  fi
fi

# --- Step 3: extract last assistant text ---
last_text=""
transcript_path="$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)"
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  last_text="$(python3 - "$transcript_path" <<'PYEOF'
import json, sys
path = sys.argv[1]
last = ""
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("type") != "assistant":
                continue
            content = r.get("message", {}).get("content", [])
            if not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    last = c.get("text", "")
except Exception:
    pass
print(last)
PYEOF
  )"
fi

# --- Step 4: classify ---
# Use Python (not bash regex) for robust unicode + JSON handling.
# Outputs one of: COMPLEX_TASK | SIMPLE_TASK | TRIVIAL_SKIP | ACK_SKIP | META_RECORD
#
# COMPLEX_TASK  -- worth recording as a real pattern candidate:
#                  ≥3 distinct tool calls, OR a long response (≥500 chars),
#                  OR an explicit <!-- meta-orchestrator: --> marker.
# SIMPLE_TASK   -- has tools but is short / single-step. Skip — too noisy
#                  to crystallize into a workflow on its own.
# TRIVIAL_SKIP  -- short text, no tools, no markdown. Skip.
# ACK_SKIP      -- pure ack. Skip.
# META_RECORD   -- mentions orchestrator keywords. Write as --trivial.
classifier="$(python3 - "$last_text" <<'PYEOF' 2>/dev/null || echo "TRIVIAL_SKIP"
import re, sys
text = sys.argv[1] if len(sys.argv) > 1 else ""
text_no_marker = re.sub(r'<!--\s*meta-orchestrator:.*?-->', '', text, flags=re.DOTALL).strip()
n = len(text_no_marker)
# Distinct tools mentioned by name in the rendered response. The transcript
# we see is post-render, so tool calls surface as "Read foo.ts", "Edit x",
# "I'll Write …", etc. Only count capitalized tool names at sentence start
# to avoid counting prose like "edit your config" as a tool call.
tools = re.findall(r'\b(Read|Edit|Write|Bash|Grep|Glob|WebFetch|WebSearch|Agent|Task)\b', text)
distinct_tools = set(tools)
has_md_structure = '\n##' in text_no_marker or '\n```' in text_no_marker
ack_only = text_no_marker.lower() in (
    '', 'ok', 'yes', 'no', 'sure', 'done', '好的', '是的', '收到', '👌', '👍', '✓', 'x', 'k'
)
has_explicit_marker = bool(re.search(r'<!--\s*meta-orchestrator:', text))
if ack_only:
    print("ACK_SKIP")
elif n < 50 and not distinct_tools and not has_md_structure and not has_explicit_marker:
    # Truly trivial: short text, no tools referenced, no markdown, no
    # marker. NOTE: an action verb (Fix/Edit/Refactor/查/修) implies
    # intent to do work even without an explicit tool name in the rendered
    # response — those are at least SIMPLE_TASK. Pure greetings ("Hi",
    # "Done.") with nothing else fall through to TRIVIAL_SKIP. META_RECORD
    # (orchestrator-related) wins over SIMPLE_TASK.
    has_orch_keyword = any(kw in text_no_marker for kw in (
        "meta-orchestrator", "orchestrator", "crystalliz", "crystallize",
        "workflow 库", "workflow 库状态", "skill 本身", "skill 设置",
    ))
    if has_orch_keyword:
        print("META_RECORD")
    else:
        # Action-intent regex. The leading-byte group is for CJK verbs which
        # have no word boundaries — `\b` only matches ASCII. We try the ASCII
        # regex first (handles "Fix", "Look up", etc.), then the CJK list.
        has_action_intent = bool(re.search(
            r'\b(fix|edits?|changes?|updates?|modif(y|ies)|refactors?|migrates?|renames?|tweaks?|reads?|checks?|looks?|finds?|searches?|debugs?|tests?|builds?|deploys?|commits?|pushes?|pulls?|creates?|deletes?|adds?|removes?|installs?|configures?|setups?|runs?|executes?|analyzes?|reviews?|investigates?|traces?|reproduces?|writes?)\b',
            text_no_marker, re.IGNORECASE,
        ))
        if not has_action_intent:
            for cjk in ("查", "找", "修", "改", "更新", "调整", "看", "读",
                        "搜", "打开", "运行", "执行", "测试", "写", "删",
                        "建", "装", "配", "设", "分析", "审", "检查",
                        "部署", "调试", "复制", "移动"):
                if cjk in text_no_marker:
                    has_action_intent = True
                    break
        if has_action_intent:
            print("SIMPLE_TASK")
        else:
            print("TRIVIAL_SKIP")
elif any(kw in text_no_marker for kw in (
    "meta-orchestrator", "crystalliz", "crystallize",
    "workflow 库", "workflow 库状态", "skill 本身", "skill 设置",
    "orchestrator 当前", "orchestrator 状态", "orchestrator 配置",
)):
    print("META_RECORD")
elif len(distinct_tools) >= 3 or n >= 500 or has_md_structure or has_explicit_marker:
    # A real task worth recording: multi-step tools, or substantial output,
    # or has markdown structure indicating a non-trivial response.
    print("COMPLEX_TASK")
else:
    # Has tools but only one kind, short response, no markdown — too thin
    # to crystallize into anything useful. Skip without writing.
    print("SIMPLE_TASK")
PYEOF
)"

# --- Step 5: route per classification ---
record_status=""
case "$classifier" in
  TRIVIAL_SKIP|ACK_SKIP|SIMPLE_TASK)
    # Skip writes entirely. SIMPLE_TASK is short single-tool responses that
    # are not worth crystallizing into a workflow on their own -- they
    # would just pollute pattern-memory.yaml with low-quality patterns.
    record_status="✓ trivial/simple turn skipped (no write, classifier=$classifier)"
    ;;
  META_RECORD|COMPLEX_TASK)
    # Try the marker first; if absent/malformed, derive.
    marker="$(printf '%s' "$last_text" | grep -oE '<!--\s*meta-orchestrator:.*-->' | tail -1 || true)"
    sig=""
    fam=""
    mtc=""
    pattern_id_flag=""
    intent_flag=""
    intent_value=""
    trivial_flag=""
    if [ -n "$marker" ]; then
      # Marker field extraction -- single robust Python pass.
      # Robust to BUG 1: a sig value containing "-->" (legal in templates)
      # previously broke sed re-anchoring on the LAST "-->". The Python
      # parser scans for the unquoted "-->" terminator, so quoted values
      # are preserved verbatim. Outputs TSV:
      #   sig \t fam \t mtc \t pattern_id_num \t intent_value \t trivial_flag
      marker_tsv=""
      marker_tsv="$(MARKER="$marker" SKILL_DIR_OVERRIDE="$SKILL_DIR" python3 <<'PYEOF' 2>/dev/null
import re, sys, os
marker = os.environ["MARKER"]
QUOTES = ('"', "“", "”", "‘", "’")
# Scan forward to find the FIRST unquoted "-->" (the marker terminator).
i, in_quote, quote_char, end = 0, False, "", -1
while i < len(marker):
    if not in_quote and marker[i:i+3] == "-->":
        end = i
        break
    ch = marker[i]
    if in_quote:
        if ch == quote_char:
            in_quote = False
    elif ch in QUOTES:
        in_quote = True
        quote_char = ch
    i += 1
body = marker[:end] if end >= 0 else marker
m = re.match(r"<!--\s*meta-orchestrator:", body)
if m:
    body = body[m.end():]
# Tokenize: split on whitespace OUTSIDE quotes; keep quoted values intact.
def tokenize(s):
    tokens, buf, in_quote, quote_char = [], [], False, ""
    for ch in s:
        if in_quote:
            buf.append(ch)
            if ch == quote_char:
                in_quote = False
            continue
        if ch in QUOTES:
            in_quote = True
            quote_char = ch
            if buf:
                tokens.append("".join(buf))
                buf = []
            buf.append(ch)
            continue
        if ch.isspace():
            if buf:
                tokens.append("".join(buf))
                buf = []
            continue
        buf.append(ch)
    if buf:
        tokens.append("".join(buf))
    return [t for t in tokens if t]
def strip_quotes(v):
    if len(v) >= 2 and v[0] in QUOTES and v[-1] in QUOTES:
        return v[1:-1]
    return v
fields, trivial_flag = {}, ""
# Pre-process body: glue chain separators (`->` / `→` / `|`) onto
# adjacent tokens so the tokenizer's whitespace split doesn't
# fragment the value. We do this by replacing runs of
# ` <sep> ` with `<sep>` before tokenizing, then re-padding so the
# tokenizer still finds word boundaries correctly.
def glue_chain_separators(s):
    # Collapse ` -> ` ` → ` ` | ` (with surrounding spaces) onto the
    # surrounding tokens. We do it by replacing each chain separator
    # preceded or followed by whitespace with one that has no surrounding
    # spaces; this makes the tokenizer treat `Read→Edit` as one token.
    return re.sub(r"\s*(?:->|→|\|)\s*", lambda m: m.group(0).strip(), s)
tokens = tokenize(glue_chain_separators(body))
# Re-join `key=` with following tokens until the next token that itself
# contains `=` (the start of the next field). Bare values may contain
# chain separators and/or be split by whitespace, so we cannot rely on
# quote state to delimit them. Quoted values are already a single token
# because the tokenizer keeps quoted runs together.
joined = []
i = 0
while i < len(tokens):
    tok = tokens[i]
    if "=" in tok and not tok.startswith("-"):
        k, _, v = tok.partition("=")
        if v:
            joined.append(tok)
            i += 1
            continue
        parts = [tok]
        j = i + 1
        while j < len(tokens) and "=" not in tokens[j] and not tokens[j].startswith("-"):
            parts.append(tokens[j])
            j += 1
        joined.append(" ".join(parts))
        i = j
        continue
    joined.append(tok)
    i += 1
for tok in joined:
    if tok == "--trivial":
        trivial_flag = "--trivial"
        continue
    if "=" in tok and not tok.startswith("-"):
        k, _, v = tok.partition("=")
        fields[k.strip()] = strip_quotes(v.strip())
sig = fields.get("sig", "")
fam = fields.get("family", "")
mtc = fields.get("matched", "")
pattern_id_num = fields.get("pattern", "")
intent_value = fields.get("intent", "")
print("\x1f".join([sig, fam, mtc, pattern_id_num, intent_value, trivial_flag]))
PYEOF
)"
      # Use US (\x1f, ASCII unit-separator) instead of tab because bash
      # `read` collapses trailing tab-delimited empty fields, which would
      # shift pattern_id_num / intent_value left by one slot.
      IFS=$'\x1f' read -r sig fam mtc pattern_id_num intent_value trivial_flag <<< "$marker_tsv"
      # Sanitize: if a TSV field accidentally collapsed an empty value into
      # something python emitted, treat empty the same as absent.
      [ -z "$pattern_id_num" ] && pattern_id_num=""
      [ -z "$intent_value" ] && intent_value=""
      if [ -n "$pattern_id_num" ]; then pattern_id_flag="--pattern-id"; fi
      if [ -n "$intent_value" ];   then intent_flag="--intent"; fi
    fi
    if [ -z "$sig" ] || [ -z "$fam" ]; then
      # Derive from response content. Each python helper prints ONE
      # line to stdout; we capture it.
      derived="$(SKILL_DIR_OVERRIDE="$SKILL_DIR" python3 - "$last_text" <<'PYEOF'
import os, re, sys, pathlib
text = sys.argv[1]
skill_dir = os.environ.get("SKILL_DIR_OVERRIDE", "")

# --- Derive signature from tool_use sequence ---
# If response mentions tools, build a DAG-shape signature. Otherwise
# use a generic "agent" placeholder (better than "unknown" because
# at least it's a real DAG category).
tools = re.findall(r'\b(Read|Edit|Write|Bash|Grep|Glob|WebFetch|WebSearch|Agent|Task)\b', text)
# Dedupe consecutive duplicates
seen = set()
deduped = []
for t in tools:
    if t not in seen:
        seen.add(t)
        deduped.append(t)
# Re-join: parallel siblings separated by '|', sequential by '→'
sig = "agent" if not deduped else " → ".join(deduped[:4])
wf_dir = pathlib.Path(skill_dir) / "workflows"

# --- Derive family from first non-empty sentence ---
# Strip markdown headers / code blocks / list markers; take first line.
clean = re.sub(r'```[\s\S]*?```', '', text)
clean = re.sub(r'^#+\s*', '', clean, flags=re.M)
clean = re.sub(r'^\s*[-*]\s*', '', clean, flags=re.M)
first_line = next((l.strip() for l in clean.splitlines() if l.strip()), "")
# Take first 4 words as family slug
words = re.findall(r"[A-Za-z一-鿿]+", first_line)[:4]
family = "-".join(w.lower() for w in words) if words else "task"

# --- Derive matched via Step 0 algorithm (scripts/_matcher.py) ---
# Replaces the old simple `triggers in text_lower` substring check with
# weighted scoring + neg-keyword exclusion. See SKILL.md §Step 0.
matched = "null"
try:
    import subprocess
    _m = subprocess.run(
        ["python3", f"{skill_dir}/scripts/_matcher.py",
         "--text", text, "--workflows-dir", str(wf_dir)],
        capture_output=True, text=True, timeout=3,
    )
    if _m.returncode == 0:
        import json as _json
        _result = _json.loads(_m.stdout)
        matched = _result.get("matched") or "null"
except Exception:
    pass

print(f"{sig}\n{family}\n{matched}")
PYEOF
      )"
      sig="$(printf '%s' "$derived" | sed -n '1p')"
      fam="$(printf '%s' "$derived" | sed -n '2p')"
      mtc="$(printf '%s' "$derived" | sed -n '3p')"
      # Fallback if derive failed
      [ -z "$sig" ] && sig="agent"
      [ -z "$fam" ] && fam="task"
      [ -z "$mtc" ] && mtc="null"
    fi
    if [ "$classifier" = "META_RECORD" ]; then
      trivial_flag="--trivial"
    fi

    # A+C scheme: if marker declared a pattern id, forward it (C). Otherwise
    # let orchestrator call the LLM judge (A). The judge is a single bounded
    # call (~5s timeout) that returns None on any failure; orchestrator falls
    # back to signature-string match if the judge says nothing.
    judge_flag=""
    if [ -z "$pattern_id_flag" ] && [ "$classifier" = "COMPLEX_TASK" ]; then
      judge_flag="--judge"
    fi

    # Use bash array to avoid word-splitting on fields that may contain
    # spaces (e.g., intent="multi word description").
    record_cmd=(
      python3 "$SKILL_DIR/scripts/orchestrator.py" record
      --signature "$sig"
      --family "$fam"
      --matched "$mtc"
    )
    [ -n "$trivial_flag" ] && record_cmd+=("$trivial_flag")
    if [ -n "$pattern_id_flag" ]; then
      record_cmd+=("$pattern_id_flag" "$pattern_id_num")
    fi
    [ -n "$judge_flag" ] && record_cmd+=("$judge_flag")
    if [ -n "$intent_flag" ] && [ -n "$intent_value" ]; then
      record_cmd+=("$intent_flag" "$intent_value")
    fi
    record_output="$("${record_cmd[@]}" 2>&1 || true)"
    if [ -n "$record_output" ]; then
      record_status="✓ orchestrator.py record auto-ran (classifier=$classifier): $record_output"
    fi
    ;;
esac

# --- Step 6: assemble reminder text ---
record_hint=""
if [ -n "$record_status" ]; then
  record_hint="\n\n$record_status"
fi

exec jq -n --arg hint "$pending_hint" --arg rhint "$record_hint" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: ("[meta-orchestrator] 本轮响应结束。\n\n" + $hint + $rhint)
  }
}'
exit 0
