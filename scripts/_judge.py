#!/usr/bin/env python3
"""LLM judge for pattern-aggregation decisions.

Used by cmd_record when `--judge` is passed. Single chat completion call
asks the LLM whether a new invocation belongs to one of the existing
patterns (semantic match — not just signature string match).

API config is read from environment:
  ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN   (Claude Code)
  OPENAI_BASE_URL + OPENAI_API_KEY              (Codex)
The judge is intentionally minimal: ONE call per record, strict response
shape, hard 5-second timeout. On any error it returns None — caller falls
back to existing signature-string matching.

Requires: PyYAML (already required by the other scripts).
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from typing import Optional

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


JUDGE_TIMEOUT = 5.0  # seconds — keep this tight so Stop hook stays snappy
MAX_PATTERNS_IN_PROMPT = 20
MAX_PATTERN_DESC = 80  # truncate each pattern family/example to keep prompt small


def _detect_api() -> tuple[str, str, str]:
    """Return (base_url, token, model) from environment, supporting both
    Claude Code (ANTHROPIC_*) and Codex (OPENAI_*) conventions."""
    if os.environ.get("ANTHROPIC_BASE_URL") and os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        return (
            os.environ["ANTHROPIC_BASE_URL"].rstrip("/"),
            os.environ["ANTHROPIC_AUTH_TOKEN"],
            # Claude Code's actual small-model env var is
            # ANTHROPIC_SMALL_FAST_MODEL. ANTHROPIC_DEFAULT_HAIKU_MODEL is a
            # proxy-side convention. Prefer the real one when set.
            os.environ.get(
                "ANTHROPIC_SMALL_FAST_MODEL",
                os.environ.get("ANTHROPIC_DEFAULT_HAIKU_MODEL", "claude-3-5-haiku-latest"),
            ),
        )
    if os.environ.get("OPENAI_BASE_URL") and os.environ.get("OPENAI_API_KEY"):
        return (
            os.environ["OPENAI_BASE_URL"].rstrip("/"),
            os.environ["OPENAI_API_KEY"],
            os.environ.get("OPENAI_DEFAULT_MODEL", "gpt-4o-mini"),
        )
    raise RuntimeError(
        "no API config in env: need ANTHROPIC_{BASE_URL,AUTH_TOKEN} or "
        "OPENAI_{BASE_URL,API_KEY}"
    )


def _truncate(s: str, n: int) -> str:
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[: n - 1] + "…"


def _build_prompt(new_family: str, new_signature: str, patterns: list[dict]) -> str:
    """Build a strict prompt. Response must be one of:
        - `id=<int>`   → match pattern by id
        - `none`       → no match
    """
    lines = [
        "You are a strict pattern-classifier for an AI workflow skill.",
        "Below are existing patterns and a NEW invocation. Decide whether the",
        "new invocation belongs to one of the existing patterns (semantic match:",
        "same kind of recurring task) or is a NEW distinct task.",
        "",
        "Response format (REQUIRED — exactly one line, no commentary):",
        "  id=<N>     if NEW belongs to pattern id N",
        "  none       if NEW is a distinct new task",
        "",
        f"NEW: signature={new_signature!r}  family={new_family!r}",
        "",
        "EXISTING PATTERNS:",
    ]
    for i, p in enumerate(patterns[:MAX_PATTERNS_IN_PROMPT]):
        pid = p.get("id", "?")
        sig = _truncate(str(p.get("signature", "?")), MAX_PATTERN_DESC)
        fam = _truncate(str(p.get("task_family", "?")), MAX_PATTERN_DESC)
        count = p.get("count", 0)
        lines.append(f"  id={pid}  count={count}  signature={sig!r}  family={fam!r}")
    if len(patterns) > MAX_PATTERNS_IN_PROMPT:
        lines.append(f"  ... ({len(patterns) - MAX_PATTERNS_IN_PROMPT} more truncated)")
    lines.append("")
    lines.append("Answer with exactly one line: id=<N> or none.")
    return "\n".join(lines)


def _parse_verdict(text: str) -> Optional[int]:
    """Parse LLM response. Strict — any non-conforming response returns None."""
    text = (text or "").strip()
    if not text:
        return None
    # Take first non-empty line only (defensive against commentary)
    first = next((l.strip() for l in text.splitlines() if l.strip()), "")
    if first.lower() == "none":
        return None  # explicit "no match"
    m = re.match(r"^id\s*[=:]\s*(\d+)\s*$", first)
    if m:
        return int(m.group(1))
    return None


def judge(new_family: str, new_signature: str, patterns: list[dict]) -> Optional[int]:
    """Ask the LLM which existing pattern (by id) the new invocation belongs to.
    Returns the matched pattern id, or None if no match / error.
    NEVER raises — returns None on any failure so caller can fall back.
    """
    try:
        base_url, token, model = _detect_api()
    except RuntimeError:
        return None

    # SECURITY: refuse plaintext HTTP. base URLs starting with http:// (not
    # https://) would otherwise send the Bearer token in cleartext to
    # whatever process listens on that port.
    if base_url.startswith("http://"):
        # Caller can override with JUDGE_ALLOW_INSECURE=1 for local proxies.
        if not os.environ.get("JUDGE_ALLOW_INSECURE"):
            return None

    prompt = _build_prompt(new_family, new_signature, patterns)
    body = json.dumps({
        "model": model,
        "max_tokens": 20,
        "temperature": 0,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )

    # Use a default SSL context — verifies the server's TLS cert against the
    # system CA bundle. urllib's default does this, but being explicit makes
    # the security posture reviewable.
    ctx = ssl.create_default_context()

    try:
        with urllib.request.urlopen(req, timeout=JUDGE_TIMEOUT, context=ctx) as r:
            resp = json.loads(r.read())
        msg = resp.get("choices", [{}])[0].get("message", {}).get("content", "")
        return _parse_verdict(msg)
    except urllib.error.HTTPError as e:
        # Distinguish auth errors (token invalid) from transient errors so
        # we can debug. We do NOT print the full request line — that leaks
        # the Authorization header to logs. Just HTTP code + URL host.
        try:
            host = req.host
        except Exception:
            host = "?"
        sys.stderr.write(f"_judge: HTTP {e.code} from {host}\n")
        return None
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError, KeyError):
        return None


if __name__ == "__main__":
    # CLI smoke-test: read patterns from a YAML file on stdin, judge a fresh
    # invocation given as --signature and --family argv.
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--signature", required=True)
    ap.add_argument("--family", required=True)
    ap.add_argument("--patterns-yaml", required=True,
                    help="YAML file with a top-level 'patterns' list")
    args = ap.parse_args()
    with open(args.patterns_yaml) as f:
        data = yaml.safe_load(f) or {}
    pats = data.get("patterns") if isinstance(data, dict) else None
    if not isinstance(pats, list):
        sys.exit(f"no 'patterns' list in {args.patterns_yaml}")
    result = judge(args.family, args.signature, pats)
    if result is None:
        print("none")
    else:
        print(f"id={result}")
    sys.exit(0)
