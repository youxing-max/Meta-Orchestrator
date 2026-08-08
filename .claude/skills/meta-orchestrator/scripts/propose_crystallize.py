#!/usr/bin/env python3
"""
GATE 4: Generate a crystallization proposal for a pending pattern.
Moves the pattern from `patterns` to `pending_crystallization`,
then prints user-facing proposal text.

IMPORTANT: This script ONLY mutates pattern memory. It does NOT write
the workflow file. The AI agent (you) is responsible for writing
`workflows/<name>.yaml` after the user approves.

Requires: PyYAML (pip install pyyaml)

Usage:
  python scripts/propose_crystallize.py --pattern-id <id>
"""
import argparse
import os
import sys
import tempfile
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

SCRIPT_DIR = Path(__file__).resolve().parent
MEMORY_FILE = SCRIPT_DIR / "pattern-memory.yaml"


def save_memory(data):
    fd, tmp_path = tempfile.mkstemp(
        dir=MEMORY_FILE.parent, suffix=".tmp", prefix=".pattern-memory."
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, MEMORY_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pattern-id", required=True)
    args = parser.parse_args()

    if not MEMORY_FILE.exists():
        sys.exit("pattern-memory.yaml not found — run record_invocation.py first")

    with open(MEMORY_FILE, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    pattern = None
    target = str(args.pattern_id)
    for p in data.get("patterns", []):
        if str(p.get("id")) == target:
            pattern = p
            break
    if pattern is None:
        sys.exit(f"Pattern id={args.pattern_id} not found")

    data["patterns"] = [
        p for p in data["patterns"] if str(p.get("id")) != target
    ]
    data.setdefault("pending_crystallization", []).append(pattern)
    save_memory(data)

    sig = pattern["signature"]
    family = pattern["task_family"]
    # Safe-name suggestion: only [a-z0-9-], max 32 chars.
    suggested_name = "".join(
        c if c.isalnum() or c == "-" else "-"
        for c in family.lower()
    )[:32].strip("-") or "new-workflow"
    count = pattern.get("count", 0)

    proposal = f"""
这个 DAG 模式已经出现 {count} 次，建议沉淀为可复用工作流：

  签名:    `{sig}`
  任务族:  {family}
  首次:    {pattern.get('first_seen', '?')}
  最近:    {pattern.get('last_seen', '?')}

下一步（AI 负责执行）:
  如果你批准，AI 会把工作流写入：workflows/{suggested_name}.yaml
  （脚本只更新沉淀状态，不会写文件。）

是否保存？ [y/n/edit]
  y    — 写入 workflows/{suggested_name}.yaml
  n    — 拒绝本次提议
  edit — 我想修改名称或触发词
"""
    print(proposal)


if __name__ == "__main__":
    main()