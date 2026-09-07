#!/usr/bin/env python3
"""Meta-orchestrator gate runner. Single entry point for all pattern
accumulation + crystallization logic.

Subcommands:
  record   - GATE 2: append an invocation to pattern-memory.yaml,
             increment patterns[].count if ad-hoc + non-trivial.
  check    - GATE 3: recompute non-trivial ad-hoc counts; exit 0 if
             any signature's count >= threshold (default 3).
  propose  - GATE 4: read-only proposal by default; --yes writes a
             stub workflow and archives the pattern as crystallized;
             --no archives it as declined.

Pattern schema (scripts/pattern-memory.yaml):
  next_id: int
  patterns: [{id, signature, task_family, count, first_seen, last_seen}, ...]
  archived_patterns: [{... pattern with outcome in {crystallized, declined}}, ...]
  invocations: [{id, timestamp, signature, task_family, matched_workflow, trivial}, ...]

Requires: PyYAML (pip install pyyaml)
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

try:
    from _file_lock import file_lock
    from _memory import (
        load_with_recovery,
        save_with_backup,
        get_patterns,
        get_archived,
        add_to_archived,
    )
    from _judge import judge as _llm_judge
except ModuleNotFoundError as e:
    sys.exit(
        f"REFUSED: missing helper module '{e.name}'. "
        f"scripts/_file_lock.py and scripts/_memory.py must ship together."
    )


SCRIPT_DIR = Path(__file__).resolve().parent
MEMORY_FILE = SCRIPT_DIR / "pattern-memory.yaml"


def utc_today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


# ----------------------------- helpers -----------------------------

def suggest_name(family: str) -> str:
    """ASCII-only ([a-z0-9-]) kebab-case, max 32 chars, fallback 'new-workflow'.

    Pure-CJK family strings (e.g. "代码审查") would otherwise collapse to
    'new-workflow' and collide with every other CJK-only pattern. Append
    a short hex hash of the original family so each gets a unique name.
    """
    import hashlib
    ascii_family = family.encode("ascii", "ignore").decode("ascii").lower()
    cleaned = "".join(
        c if c.isalnum() or c == "-" else "-"
        for c in ascii_family
    ).strip("-")
    if cleaned:
        return cleaned[:32].strip("-") or "new-workflow"
    # No ASCII content -- hash the original family to guarantee uniqueness.
    suffix = hashlib.md5(family.encode("utf-8")).hexdigest()[:6]
    return f"new-workflow-{suffix}"


def non_trivial_count(data: dict, sig: str) -> int:
    """Recompute effective count from invocations[]. Same rule used by all gates."""
    return sum(
        1 for inv in data.get("invocations", [])
        if inv.get("signature") == sig
        and inv.get("matched_workflow") is None
        and not bool(inv.get("trivial", False))
    )


def drain_invocations(data: dict, sig: str) -> int:
    """Remove invocations[] rows matching `sig`. Returns count removed.
    Called on --yes / --no so the same signature cannot re-trigger
    crystallization until a fresh 3 non-trivial hits accumulate."""
    before = len(data.get("invocations", []))
    data["invocations"] = [
        inv for inv in data.get("invocations", [])
        if inv.get("signature") != sig
    ]
    return before - len(data["invocations"])


def reset_pattern_count(pattern: dict) -> None:
    pattern["count"] = 0


# ----------------------------- subcommands -----------------------------

def cmd_record(args) -> int:
    """GATE 2: append invocation; increment patterns[].count if ad-hoc + non-trivial."""
    if not args.signature or not args.signature.strip():
        sys.exit("REFUSED: --signature must be a non-empty DAG shape string")

    matched_raw = (args.matched or "").strip()
    matched = None if matched_raw.lower() in ("null", "none", "") else matched_raw

    with file_lock(MEMORY_FILE):
        data = load_with_recovery(MEMORY_FILE)
        today = utc_today()
        # Self-heal next_id: if a prior crashed writer left gaps, the
        # highest id actually used wins. Otherwise stale-ghost IDs leak
        # out of `check` and mislead users.
        existing_ids = [inv.get("id") for inv in data.get("invocations", [])
                        if isinstance(inv.get("id"), int)]
        existing_ids += [p.get("id") for p in data.get("patterns", [])
                         if isinstance(p.get("id"), int)]
        existing_ids += [p.get("id") for p in data.get("archived_patterns", [])
                         if isinstance(p.get("id"), int)]
        next_id = max(int(data.get("next_id", 1)), (max(existing_ids) + 1) if existing_ids else 1)

        invocation = {
            "id": next_id,
            "timestamp": today,
            "signature": args.signature,
            "task_family": args.family,
            "matched_workflow": matched,
            "trivial": args.trivial,
        }
        data["invocations"].append(invocation)
        next_id += 1

        # Resolve which pattern (if any) this invocation belongs to.
        # Decision order:
        #   1. Explicit --pattern-id from caller (LLM self-judged via marker)
        #   2. --judge: ask LLM which existing pattern matches (semantic)
        #   3. Fallback: signature-string match (legacy behavior)
        #   4. Else: create a new pattern entry (or skip if fallback signature)
        is_fallback_sig = args.signature.strip() == "agent"
        matched_pattern = None
        if args.pattern_id is not None:
            matched_pattern = next(
                (p for p in data["patterns"] if p.get("id") == args.pattern_id),
                None,
            )
            if matched_pattern is None:
                # Caller said "I belong to pattern X" but X doesn't exist —
                # log but don't fail; fall through to legacy matching.
                sys.stderr.write(
                    f"warn: --pattern-id={args.pattern_id} not in patterns[]; "
                    f"falling back to signature match\n"
                )
        if matched_pattern is None and args.judge and not is_fallback_sig and data["patterns"]:
            # Single LLM call; bounded timeout in _judge.py. Returns None on any error.
            judged_id = _llm_judge(
                new_family=args.family,
                new_signature=args.signature,
                patterns=data["patterns"],
            )
            if judged_id is not None:
                matched_pattern = next(
                    (p for p in data["patterns"] if p.get("id") == judged_id),
                    None,
                )
        if matched_pattern is None and not is_fallback_sig:
            matched_pattern = next(
                (p for p in data["patterns"] if p["signature"] == args.signature),
                None,
            )

        triggered_id = None
        triggered_count = None
        if matched is None and not args.trivial and matched_pattern is not None:
            # Self-heal: truth-of-disk wins over stored count.
            truth = non_trivial_count(data, matched_pattern["signature"])
            matched_pattern["count"] = max(
                int(matched_pattern.get("count", 1)) + 1, truth
            )
            matched_pattern["last_seen"] = today
            triggered_id = matched_pattern.get("id")
            triggered_count = matched_pattern["count"]
        elif matched is None and not args.trivial and matched_pattern is None and not is_fallback_sig:
            # New pattern: also include intent if caller provided one (C scheme).
            truth = non_trivial_count(data, args.signature)
            created_count = max(1, truth)
            triggered_id = next_id
            new_entry = {
                "id": next_id,
                "signature": args.signature,
                "task_family": args.family,
                "count": created_count,
                "first_seen": today,
                "last_seen": today,
            }
            if getattr(args, "intent", None):
                new_entry["intent"] = args.intent
            data["patterns"].append(new_entry)
            next_id += 1
            triggered_count = created_count

        data["next_id"] = next_id
        save_with_backup(MEMORY_FILE, data)

    print(json.dumps({
        "recorded": True,
        "signature": args.signature,
        "matched_workflow": matched,
        "trivial": args.trivial,
        "pattern_id": triggered_id,
        "count": triggered_count,
    }, ensure_ascii=False))
    return 0


def cmd_check(args) -> int:
    """GATE 3: exit 0 if any pattern has effective count >= threshold."""
    if args.threshold < 1:
        sys.exit(f"REFUSED: --threshold must be >= 1 (got {args.threshold})")

    # Take the file lock for read-only safety. Concurrent cmd_record may
    # be mid-write; without this lock, check can read a half-written
    # tempfile or stale .bak, returning wrong threshold state to the user.
    # The lock is released immediately after we read -- check is read-only.
    with file_lock(MEMORY_FILE):
        data = load_with_recovery(MEMORY_FILE)
        invocations = data.get("invocations", [])
        candidates = get_patterns(data)

        pending = [
            p for p in candidates
            if non_trivial_count(data, p["signature"]) >= args.threshold
        ]
    if pending:
        # Renamed to pattern_id for consistency with the `record` subcommand
        # and SKILL.md Step 5 (GATE 4 expects `pattern_id` from JSON output).
        out = [{**p, "pattern_id": p["id"]} for p in pending]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0
    highest = max(
        (non_trivial_count(data, p["signature"]) for p in candidates),
        default=0,
    )
    print(json.dumps({
        "triggered": False,
        "threshold": args.threshold,
        "patterns_total": len(candidates),
        "highest_count": highest,
    }, ensure_ascii=False))
    return 1


def cmd_propose(args) -> int:
    """GATE 4: print proposal (default), or --yes/--no to crystallize/decline."""
    with file_lock(MEMORY_FILE):
        data = load_with_recovery(MEMORY_FILE)
        target = str(args.pattern_id)

        patterns = get_patterns(data)
        pattern = next((p for p in patterns if str(p.get("id")) == target), None)
        if pattern is None:
            sys.exit(f"Pattern id={args.pattern_id} not found in patterns[]")

        sig = pattern["signature"]
        family = pattern["task_family"]
        suggested_name = suggest_name(family)
        count = non_trivial_count(data, sig)

        # Default mode: read-only proposal
        if not args.yes and not args.no:
            proposal = f"""
这个 DAG 模式已经出现 {count} 次，建议沉淀为可复用工作流：

  签名:    `{sig}`
  任务族:  {family}
  首次:    {pattern.get('first_seen', '?')}
  最近:    {pattern.get('last_seen', '?')}
  建议名:  workflows/{suggested_name}.yaml

下一步（AI 负责执行）:
  如果你批准，AI 会写 workflows/{suggested_name}.yaml 并把这条 pattern
  移到 archived_patterns[] (outcome=crystallized)。拒绝则移到
  archived_patterns[] (outcome=declined)。脚本在等你拍 y/n/edit。

  ⚠ 重要：这是 pattern，不是 workflow 文件。workflows/{suggested_name}.yaml
    现在还不存在 ---- 只有在你批准后才会写。

是否保存？ [y/n/edit]
  y    -- 写入 workflows/{suggested_name}.yaml
  n    -- 拒绝本次提议
  edit -- 我想修改名称或触发词
"""
            print(proposal)
            return 0

        # Pre-flight for --yes: target file must not exist
        workflow_path = SCRIPT_DIR.parent / "workflows" / f"{suggested_name}.yaml"
        if args.yes and workflow_path.exists():
            sys.exit(
                f"REFUSED: {workflow_path} already exists. "
                f"Pick a different --pattern-id, edit the existing file, "
                f"or delete it first."
            )

        # --no: archive declined, no file written.
        # For the "archive after 2 declines" rule to work, declined_count
        # must persist across declines of the SAME task. We key on
        # (signature, task_family) — if a prior archive entry matches,
        # we increment its declined_count instead of creating a fresh row.
        if args.no:
            family = pattern.get("task_family", "?")
            stable_key = (sig, family)
            prior = next(
                (a for a in data.get("archived_patterns", [])
                 if a.get("signature") == sig and a.get("task_family") == family),
                None,
            )
            data["patterns"] = [
                p for p in patterns if str(p.get("id")) != target
            ]
            drained = drain_invocations(data, sig)
            if prior is not None:
                # Carry over to the existing archive entry so declined_count
                # accumulates correctly across multiple declines.
                prior["declined_count"] = int(prior.get("declined_count", 0)) + 1
                prior["declined_at"] = utc_today()
                prior["drained_invocations"] = (
                    int(prior.get("drained_invocations", 0)) + drained
                )
                archive_target = prior
                already_archived = prior["declined_count"] >= 2
            else:
                pattern["declined_count"] = int(pattern.get("declined_count", 0)) + 1
                pattern["declined_at"] = utc_today()
                pattern["outcome"] = "declined"
                pattern["drained_invocations"] = drained
                reset_pattern_count(pattern)
                add_to_archived(data, pattern)
                archive_target = pattern
                already_archived = archive_target["declined_count"] >= 2
            save_with_backup(MEMORY_FILE, data)
            print(json.dumps({
                "declined": True,
                "pattern_id": args.pattern_id,
                "signature": sig,
                "declined_count": archive_target["declined_count"],
                "archived": already_archived,
                "drained_invocations": drained,
            }, ensure_ascii=False))
            return 0

        # --yes: write stub + archive crystallized
        workflow_path.parent.mkdir(parents=True, exist_ok=True)
        stub = (
            f"# AUTO-GENERATED by orchestrator.py propose --yes\n"
            f"# TODO: review signature `{sig}` and fill in prompts/agent_types\n"
            f"name: {suggested_name}\n"
            f"description: \"Stub for: {family}\"\n"
            f"triggers:\n  - {family}\n"
            f"meta_priority: 10\n"
            f"kind: meta\n"
            f"always: false\n"
            f"final_text_mode: auto\n"
            f"composition:\n"
            f"  steps:\n"
            f"    - id: implement\n"
            f"      kind: agent\n"
            f"      agent_type: general-purpose\n"
            f"      prompt: \"TODO: fill in based on signature `{sig}`\"\n"
        )
        workflow_path.write_text(stub, encoding="utf-8")

        data["patterns"] = [
            p for p in patterns if str(p.get("id")) != target
        ]
        pattern["outcome"] = "crystallized"
        pattern["crystallized_at"] = utc_today()
        pattern["workflow_path"] = str(workflow_path)
        drained = drain_invocations(data, sig)
        pattern["drained_invocations"] = drained
        add_to_archived(data, pattern)
        save_with_backup(MEMORY_FILE, data)

        print(json.dumps({
            "autonomous": True,
            "workflow_path": str(workflow_path),
            "pattern_id": args.pattern_id,
            "warning": "Stub YAML written. Edit the prompt/agent_type before reuse.",
            "drained_invocations": drained,
        }, ensure_ascii=False))
        return 0


# ----------------------------- entry point -----------------------------

def main():
    parser = argparse.ArgumentParser(prog="orchestrator")
    sub = parser.add_subparsers(dest="command", required=True)

    p_rec = sub.add_parser("record", help="GATE 2: log one invocation")
    p_rec.add_argument("--signature", required=True)
    p_rec.add_argument("--family", required=True)
    p_rec.add_argument("--matched", default="null")
    p_rec.add_argument("--trivial", action="store_true")
    # A+C scheme: caller (LLM via marker, or hook fallback) may declare which
    # pattern this invocation belongs to. Takes precedence over both --judge
    # and signature-string matching.
    p_rec.add_argument("--pattern-id", type=int, default=None,
                       help="Force-match to a specific existing pattern id "
                            "(LLM self-judged via marker).")
    # A scheme (fallback): ask the LLM which existing pattern matches.
    p_rec.add_argument("--judge", action="store_true",
                       help="Call LLM to semantically decide which existing "
                            "pattern this invocation belongs to.")
    # C scheme: caller (LLM) writes a precise intent description; stored
    # alongside the pattern for future reference and human review.
    p_rec.add_argument("--intent", default=None,
                       help="Optional human/LLM-written intent description "
                            "stored with new pattern entries.")
    p_rec.set_defaults(func=cmd_record)

    p_chk = sub.add_parser("check", help="GATE 3: threshold check")
    p_chk.add_argument("--threshold", type=int, default=3)
    p_chk.set_defaults(func=cmd_check)

    p_prp = sub.add_parser("propose", help="GATE 4: propose / crystallize / decline")
    p_prp.add_argument("--pattern-id", required=True)
    yes_grp = p_prp.add_mutually_exclusive_group()
    yes_grp.add_argument("--yes", action="store_true",
                         help="Write stub workflow and archive as crystallized.")
    yes_grp.add_argument("--no", action="store_true",
                         help="Archive as declined; no file written.")
    p_prp.set_defaults(func=cmd_propose)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
