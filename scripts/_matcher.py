#!/usr/bin/env python3
"""Step 0 workflow-matching gate + Step 0.5 tier classification.

Implements the algorithm from SKILL.md §Step 0 / §Step 0.5:

  Step 0:
    1. List workflows/*.yaml
    2. Read each workflow's triggers, description, neg-keywords, meta_priority, --loose
    3. Neg-keyword check: if any neg-keyword appears in the user request,
       that workflow is excluded from matching.
    4. Score:
       - exact trigger phrase match  → weight 10
       - description keyword overlap (>=2) → weight 5
       - single keyword overlap → weight 1
       - no overlap → 0
    5. Match threshold: score >= 5. Workflows with `loose: true` opt back into >=1.
    6. Tiebreakers: higher score → higher meta_priority → fall through to Step 0.5.
    7. No match → Step 0.5.

  Step 0.5: classify task tier T0-T3.

CLI:
  python3 _matcher.py --text "<user request>" [--workflows-dir <path>]
Exit:
  0 = match found; JSON printed with workflow name + tier + score
  1 = no match; tier printed
  2 = no workflows dir
"""
import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


DEFAULT_WORKFLOWS_DIR = Path(__file__).resolve().parent.parent / "workflows"

# Tier classification keywords (matched in user request). Order matters:
# first match wins.
TIER_KEYWORDS = [
    # T3: architecture, design, system-level
    (3, [
        "architecture", "design", "redesign", "restructure",
        "架构", "设计", "重构", "重新设计",
    ]),
    # T2: multi-file, refactor, migrate
    (2, [
        "refactor", "migrate", "split", "modularize",
        "multi-file", "across files", "many files",
        "重构", "迁移", "拆分", "多文件",
    ]),
    # T1: single-file edit, fix, change
    (1, [
        "edit", "fix", "change", "update", "modify", "rename", "tweak",
        "修改", "修复", "改", "更新", "调整",
    ]),
    # T0: lookup, single-file, read-only
    (0, [
        "lookup", "find", "where", "which", "what is", "show me",
        "查", "哪里", "哪个", "什么", "看看",
    ]),
]


def _normalize(text: str) -> str:
    return (text or "").lower().strip()


def _score_workflow(workflow: dict, text: str) -> int:
    """Compute match score for one workflow against user text."""
    score = 0
    triggers = workflow.get("triggers") or []
    description = _normalize(workflow.get("description", ""))

    # Exact trigger phrase match: weight 10
    for trig in triggers:
        if not isinstance(trig, str):
            continue
        if _normalize(trig) in text:
            score = max(score, 10)
            break

    if score >= 10:
        # Description scoring is moot; short-circuit.
        return score

    # Description keyword overlap.
    # Tokenize description on word boundaries; require each token >= 3 chars.
    # Dedupe via set so repeated words don't inflate the hit count.
    desc_words = set(re.findall(r"[a-z一-鿿]{3,}", description))
    if desc_words:
        hits = sum(1 for w in desc_words if w in text)
        if hits >= 2:
            score = max(score, 5)
        elif hits == 1:
            score = max(score, 1)

    return score


def _neg_keyword_excluded(workflow: dict, text: str) -> bool:
    """True if any neg-keyword appears in the user request → exclude this wf."""
    neg = workflow.get("neg-keywords") or []
    for kw in neg:
        if isinstance(kw, str) and _normalize(kw) in text:
            return True
    return False


def _tier_for(text: str) -> int:
    """Classify task tier T0-T3 by keyword scan. First match wins."""
    text_norm = _normalize(text)
    for tier, kws in TIER_KEYWORDS:
        for kw in kws:
            if kw in text_norm:
                return tier
    # No keyword hit → fall back to defaults: long/multi-line text → T2,
    # single short request → T1. Pure safety net.
    if len(text_norm) > 200:
        return 2
    return 1


def match(text: str, workflows_dir: Path = DEFAULT_WORKFLOWS_DIR) -> dict:
    """Run Step 0 + Step 0.5. Returns a dict suitable for JSON output."""
    text_norm = _normalize(text)
    if not workflows_dir.exists():
        return {"matched": None, "tier": _tier_for(text_norm), "error": "no workflows dir"}

    candidates = []
    for yaml_file in sorted(workflows_dir.glob("*.yaml")):
        try:
            with open(yaml_file, encoding="utf-8") as f:
                wf = yaml.safe_load(f) or {}
        except (yaml.YAMLError, OSError):
            continue
        if not isinstance(wf, dict):
            continue
        if _neg_keyword_excluded(wf, text_norm):
            continue
        score = _score_workflow(wf, text_norm)
        threshold = 1 if wf.get("loose") else 5
        if score >= threshold:
            candidates.append({
                "name": wf.get("name") or yaml_file.stem,
                "score": score,
                "meta_priority": int(wf.get("meta_priority", 0) or 0),
                "path": str(yaml_file),
            })

    if not candidates:
        return {"matched": None, "tier": _tier_for(text_norm), "candidates": []}

    # Tiebreakers: score desc, meta_priority desc, name asc (stable).
    candidates.sort(key=lambda c: (-c["score"], -c["meta_priority"], c["name"]))
    winner = candidates[0]
    return {
        "matched": winner["name"],
        "matched_path": winner["path"],
        "score": winner["score"],
        "meta_priority": winner["meta_priority"],
        "tier": _tier_for(text_norm),
        "candidates": candidates,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Step 0 + Step 0.5 matcher")
    ap.add_argument("--text", required=True, help="User request to match")
    ap.add_argument("--workflows-dir", type=Path, default=DEFAULT_WORKFLOWS_DIR)
    args = ap.parse_args()
    result = match(args.text, args.workflows_dir)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("matched") else 1


if __name__ == "__main__":
    sys.exit(main())
