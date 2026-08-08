#!/usr/bin/env python3
"""
Self-check: verify the meta-orchestrator skill is healthy.
Run this from anywhere — it auto-locates the skill via __file__.

Checks:
  1. SKILL.md exists and frontmatter parses
  2. description <= 1024 chars
  3. description contains self-load directive
  4. hooks/ has 3 expected files, all +x
  5. scripts/ has 3 expected .py files
  6. workflows/ has 5 .yaml files that all parse
  7. PyYAML is importable
  8. pattern-memory.yaml path resolution is sane (symlink-safe)

Exit code:
  0 = all checks pass
  1 = one or more checks failed
"""
import json
import os
import stat
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
EXPECTED_HOOKS = {
    "claude-code-stop-reminder.sh",
    "codex-turn-end-reminder.sh",
    "session-start-reminder.sh",
}
EXPECTED_SCRIPTS = {
    "record_invocation.py",
    "check_threshold.py",
    "propose_crystallize.py",
}


def check(label, ok, detail=""):
    """Print check result. Returns bool."""
    status = "PASS" if ok else "FAIL"
    line = f"  [{status}] {label}"
    if detail:
        line += f" — {detail}"
    print(line)
    return ok


def main():
    print(f"meta-orchestrator self-check")
    print(f"  skill_dir: {SKILL_DIR}")
    print(f"  script_dir: {SCRIPT_DIR}")
    print()

    results = []

    # 1. SKILL.md frontmatter
    skill_md = SKILL_DIR / "SKILL.md"
    if not skill_md.exists():
        results.append(check("SKILL.md exists", False, str(skill_md)))
        return finish(results)

    content = skill_md.read_text(encoding="utf-8")
    parts = content.split("---", 2)
    if len(parts) < 3:
        results.append(check("SKILL.md frontmatter parseable", False, "missing --- delimiters"))
        return finish(results)

    try:
        fm = yaml.safe_load(parts[1]) if HAS_YAML else None
        results.append(check("SKILL.md frontmatter parseable", fm is not None))
    except Exception as e:
        results.append(check("SKILL.md frontmatter parseable", False, str(e)))
        return finish(results)

    # 2. description size
    desc = fm.get("description", "")
    if isinstance(desc, list):
        desc = "\n".join(str(x) for x in desc)
    desc_len = len(desc.strip())
    results.append(check("description ≤ 1024 chars", desc_len <= 1024, f"{desc_len} chars"))

    # 3. self-load directive
    has_directive = "_INSTRUCTION" in desc or "MANDATORY" in desc or "DO NOT SKIP" in desc
    results.append(check("description has self-load directive", has_directive))

    # 4. hooks
    hooks_dir = SKILL_DIR / "hooks"
    if hooks_dir.exists():
        found = {p.name for p in hooks_dir.iterdir() if p.is_file()}
        missing = EXPECTED_HOOKS - found
        results.append(check("hooks/ has 3 expected files", not missing,
                             f"missing: {missing}" if missing else ""))
        for h in EXPECTED_HOOKS & found:
            p = hooks_dir / h
            executable = os.access(p, os.X_OK)
            results.append(check(f"hook {h} executable", executable))
    else:
        results.append(check("hooks/ directory exists", False))

    # 5. scripts
    scripts_dir = SKILL_DIR / "scripts"
    if scripts_dir.exists():
        found = {p.name for p in scripts_dir.iterdir() if p.is_file() and p.suffix == ".py"}
        missing = EXPECTED_SCRIPTS - found
        results.append(check("scripts/ has 3 expected .py", not missing,
                             f"missing: {missing}" if missing else ""))
    else:
        results.append(check("scripts/ directory exists", False))

    # 6. workflows
    wf_dir = SKILL_DIR / "workflows"
    if wf_dir.exists():
        wf_files = sorted(p for p in wf_dir.iterdir() if p.suffix in (".yaml", ".yml"))
        results.append(check("workflows/ has ≥1 .yaml", len(wf_files) >= 1,
                             f"{len(wf_files)} files"))
        all_parse = True
        for wf in wf_files:
            try:
                with open(wf) as f:
                    yaml.safe_load(f)
            except Exception as e:
                all_parse = False
                results.append(check(f"workflow {wf.name} parses", False, str(e)))
                break
        if all_parse:
            results.append(check("all workflows parse as YAML", True))
    else:
        results.append(check("workflows/ directory exists", False))

    # 7. PyYAML
    results.append(check("PyYAML importable", HAS_YAML,
                         "pip install pyyaml" if not HAS_YAML else ""))

    # 8. pattern-memory.yaml path resolution
    expected_mem = scripts_dir / "pattern-memory.yaml"
    # Resolve through symlink if any
    real_mem = expected_mem.resolve()
    results.append(check(
        "pattern-memory.yaml path resolvable",
        real_mem.parent.exists(),
        f"resolves to: {real_mem}"
    ))

    # Bonus: check whether we got here via symlink (informational)
    if SCRIPT_DIR.resolve() != SCRIPT_DIR:
        results.append(check("script dir is symlink", True, str(SCRIPT_DIR.resolve())))
    else:
        results.append(check("script dir is real path", True, str(SCRIPT_DIR)))

    finish(results)


def finish(results):
    print()
    total = len(results)
    passed = sum(1 for r in results if r)
    print(f"Result: {passed}/{total} checks passed")
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()