#!/usr/bin/env python3
"""
DAG schema validator for /root/Meta-Orchestrator/workflows/*.yaml.

Enforces the 5 DAG RULES (workflow structure) from SKILL.md §Step 1:
  1. No deadlock -- every depends_on target exists as a step id.
  2. Route completeness -- every output_choice has matching route.when.
  3. Fallback isolation -- on_failure targets never appear in another depends_on.
  4. Acyclicity -- no circular dependencies.
  5. Top-level structure -- name, description, triggers, composition.steps non-empty.

Also enforces 3 EXTRA checks that the DAG schema implies but §Step 1
lists separately under "Required fields per kind":
  E1. kind=agent requires agent_type
  E2. kind=tool requires tool + params
  E3. kind=classify/input requires both output_choices (or schema.enum
      for input) AND a non-empty route

Additional safety checks (not in SKILL.md but easy to detect):
  S3.4. classify step with depends_on is a misuse warning
  S3.5. duplicate route.when is rejected

SKILL.md §Step 1 also has a separate "DAG Rules" line:
  5. One-level references -- don't nest SKILL.md → a.md → b.md
That rule is about **documentation hygiene** (don't chain markdown
includes), not about workflow YAML structure. It is NOT checked by
this validator -- and the validator's own "Rule 5" (top-level
structure) is named to match SKILL.md's first rule 5 for grep-ability.
The two "Rule 5" instances are unrelated; see SKILL.md for context.

Usage:
  python3 scripts/validate_dag.py [--workflows-dir <path>] [--quiet]

Exit 0 = all workflows valid; exit 1 = one or more violations.
"""
import argparse
import json
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_WF_DIR = SCRIPT_DIR.parent / "workflows"

REQUIRED_TOP_LEVEL = {"name", "description", "triggers", "composition"}
ALLOWED_KINDS = {"agent", "generate", "classify", "input", "tool"}


def validate_workflow(path: Path) -> list[str]:
    """Return a list of violation strings; empty list = valid."""
    violations: list[str] = []

    with open(path, encoding="utf-8") as f:
        try:
            wf = yaml.safe_load(f)
        except yaml.YAMLError as e:
            return [f"YAML parse error: {e}"]

    if not isinstance(wf, dict):
        return [f"top-level must be a mapping, got {type(wf).__name__}"]

    # Rule 5: top-level structure
    missing = REQUIRED_TOP_LEVEL - set(wf.keys())
    if missing:
        violations.append(f"missing top-level keys: {sorted(missing)}")

    if "triggers" in wf and not isinstance(wf["triggers"], list):
        violations.append(f"'triggers' must be a list, got {type(wf['triggers']).__name__}")
    elif "triggers" in wf and len(wf["triggers"]) == 0:
        violations.append("'triggers' is empty")

    # S3.4: classify step with depends_on is invalid -- a classify node
    # routes between siblings, it does not precede them. Detect and warn
    # (don't fail -- current 5 workflows don't do this, but future ones
    # might by accident).
    comp = wf.get("composition")
    if not isinstance(comp, dict):
        violations.append("'composition' must be a mapping")
        return violations

    steps = comp.get("steps")
    if not isinstance(steps, list) or len(steps) == 0:
        violations.append("'composition.steps' must be a non-empty list")
        return violations

    # Index steps by id
    by_id: dict[str, dict] = {}
    for i, s in enumerate(steps):
        if not isinstance(s, dict):
            violations.append(f"step #{i} is not a mapping")
            continue
        sid = s.get("id")
        if not isinstance(sid, str) or not sid:
            violations.append(f"step #{i} has missing/invalid id")
            continue
        if sid in by_id:
            violations.append(f"duplicate step id: {sid!r}")
        by_id[sid] = s

    # Validate each step's well-formedness and accumulate deps
    REQUIRED_BY_KIND = {
        "agent":   ["agent_type", "prompt"],
        "generate": ["prompt"],
        "classify": ["output_choices", "route", "prompt"],
        "input":   ["prompt"],  # resolved below (output_choices OR schema.enum)
        "tool":    ["tool", "params"],
    }
    for s in steps:
        if not isinstance(s, dict):
            continue
        sid = s.get("id", "<no-id>")
        kind = s.get("kind")
        if kind not in ALLOWED_KINDS:
            violations.append(f"step {sid!r}: invalid kind {kind!r}")
            continue
        for field in REQUIRED_BY_KIND.get(kind, []):
            if field not in s:
                violations.append(
                    f"step {sid!r}: kind={kind} requires {field!r}"
                )
        # kind=input special-case: must have either output_choices OR a schema with enum
        if kind == "input":
            has_output_choices = isinstance(s.get("output_choices"), list)
            schema = s.get("schema")
            has_schema_enum = isinstance(schema, dict) and any(
                isinstance(fdef, dict) and fdef.get("type") == "enum"
                and isinstance(fdef.get("choices"), list)
                for fdef in schema.values()
            )
            if not (has_output_choices or has_schema_enum):
                violations.append(
                    f"step {sid!r}: kind=input requires output_choices "
                    f"or schema with enum choices"
                )
        deps = s.get("depends_on", [])
        if deps is None:
            deps = []
        if not isinstance(deps, list):
            violations.append(f"step {sid!r}: depends_on must be a list")
            deps = []
        if "on_failure" in s and not isinstance(s["on_failure"], str):
            violations.append(f"step {sid!r}: on_failure must be a string id")

    # Rule 1: no deadlock -- every depends_on target exists
    for s in steps:
        if not isinstance(s, dict):
            continue
        sid = s.get("id", "<no-id>")
        for dep in (s.get("depends_on") or []):
            if dep not in by_id:
                violations.append(f"step {sid!r}: depends_on unknown step {dep!r}")

    # Rule 2: route completeness -- every output_choice has matching route.when
    # SKILL.md §Step 1 says classify/input both use output_choices + route.
    # Some real workflows (api-migration.user_approve) use a JSON `schema`
    # with an enum to express choices -- treat that as equivalent when
    # output_choices is absent.
    for s in steps:
        if not isinstance(s, dict):
            continue
        sid = s.get("id", "<no-id>")
        if s.get("kind") not in ("classify", "input"):
            continue
        route = s.get("route")
        if not isinstance(route, list):
            violations.append(f"step {sid!r}: classify/input requires route list")
            continue

        choices = s.get("output_choices")
        if choices is None:
            # Fall back to schema-driven input: extract enum choices from schema.
            schema = s.get("schema")
            if isinstance(schema, dict):
                enum_choices = []
                for field_def in schema.values():
                    if isinstance(field_def, dict) and field_def.get("type") == "enum":
                        cs = field_def.get("choices")
                        if isinstance(cs, list):
                            enum_choices.extend(cs)
                choices = enum_choices if enum_choices else None
        if choices is None or len(choices) == 0:
            violations.append(
                f"step {sid!r}: classify/input requires non-empty "
                f"output_choices list or schema with enum choices"
            )
            continue

        when_set = set()
        for r in route:
            if not isinstance(r, dict):
                violations.append(f"step {sid!r}: route entry must be a mapping")
                continue
            when = r.get("when")
            target = r.get("to")
            if when is None:
                violations.append(f"step {sid!r}: route entry missing 'when'")
            if target is None:
                violations.append(f"step {sid!r}: route entry missing 'to'")
            if when is not None and target is None:
                # Already reported above; no further action.
                pass
            elif when is not None:
                if when in when_set:
                    violations.append(
                        f"step {sid!r}: duplicate route.when={when!r}"
                    )
                when_set.add(when)
            if target is not None and target not in by_id:
                violations.append(
                    f"step {sid!r}: route target {target!r} is not a step id"
                )
        # S3.4 part 2: a classify step with depends_on set is almost
        # certainly a mistake -- the classifier routes between branches
        # that should already have run. Allow it (some workflows use
        # this for "fallback reroute") but warn.
        if s.get("kind") == "classify" and s.get("depends_on"):
            violations.append(
                f"step {sid!r}: classify step has depends_on -- usually "
                f"a mistake (classify routes between siblings, not "
                f"predecessors)"
            )
        for choice in choices:
            if choice not in when_set:
                violations.append(
                    f"step {sid!r}: output_choice {choice!r} has no matching route.when"
                )

    # Rule 3: fallback isolation -- on_failure targets never in another depends_on
    fallback_ids = {s["on_failure"] for s in steps
                    if isinstance(s, dict) and "on_failure" in s}
    for s in steps:
        if not isinstance(s, dict):
            continue
        sid = s.get("id", "<no-id>")
        for dep in (s.get("depends_on") or []):
            if dep in fallback_ids:
                violations.append(
                    f"step {sid!r}: depends_on {dep!r}, but {dep!r} is a fallback "
                    f"(referenced in some on_failure). Fallbacks must not be in "
                    f"depends_on of any step."
                )

    # Rule 4: acyclicity (consider depends_on AND on_failure fallback chains)
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {sid: WHITE for sid in by_id}

    def visit(n, path):
        if color[n] == GRAY:
            cycle = " -> ".join(path + [n])
            violations.append(f"cycle detected: {cycle}")
            return
        if color[n] == BLACK:
            return
        color[n] = GRAY
        for dep in (by_id[n].get("depends_on") or []):
            if dep in by_id:
                visit(dep, path + [n])
        # Also follow on_failure fallback edges -- a step whose on_failure
        # target depends_on the original step creates a cycle through the
        # fallback path that depends_on alone would miss.
        fb = by_id[n].get("on_failure")
        if isinstance(fb, str) and fb in by_id:
            visit(fb, path + [n])
        color[n] = BLACK

    for sid in by_id:
        if color[sid] == WHITE:
            visit(sid, [])

    return violations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflows-dir", type=Path, default=DEFAULT_WF_DIR)
    parser.add_argument("--quiet", action="store_true",
                        help="Only print summary (no per-file details on success)")
    args = parser.parse_args()

    if not args.workflows_dir.exists():
        sys.exit(f"workflows dir not found: {args.workflows_dir}")

    yaml_files = sorted(args.workflows_dir.glob("*.yaml"))
    if not yaml_files:
        sys.exit(f"no .yaml files in {args.workflows_dir}")

    all_violations: dict[str, list[str]] = {}
    for path in yaml_files:
        v = validate_workflow(path)
        if v:
            all_violations[path.name] = v

    if not args.quiet:
        for path in yaml_files:
            name = path.name
            if name in all_violations:
                print(f"  [FAIL] {name}")
                for line in all_violations[name]:
                    print(f"         - {line}")
            else:
                print(f"  [PASS] {name}")

    total = len(yaml_files)
    failed = len(all_violations)
    passed = total - failed
    print(f"\nResult: {passed}/{total} workflows valid",
          end="")
    if failed:
        vsum = sum(len(v) for v in all_violations.values())
        print(f" ({vsum} total violations)")
        sys.exit(1)
    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
