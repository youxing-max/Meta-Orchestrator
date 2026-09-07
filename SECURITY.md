# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| latest  | ✅        |
| older   | ❌        |

This skill runs shell scripts on your machine via Claude Code / Codex
Stop hooks. It does not fetch code from the network and does not phone
home. The runtime state (`scripts/pattern-memory.yaml`) is plain YAML
under your `~/.claude/skills/meta-orchestrator/` directory.

## What this skill does to your system

| Action | Scope | Reversible |
|--------|-------|------------|
| Writes `~/.claude/settings.json` | adds a Stop hook entry | yes — `install.sh --uninstall` |
| Writes `~/.claude/CLAUDE.md` | prepends always-loaded skill section | yes — manual edit / uninstall |
| Reads transcripts | `/dev/null` or your project transcripts | n/a |
| Writes `scripts/pattern-memory.yaml` | appends invocations | yes — git checkout |
| Reads `workflows/*.yaml` | Step 0 matching | n/a |

It does **not**:

- Make outbound network calls
- Modify code in your projects
- Read files outside its own directory and the active Claude Code transcript
- Run arbitrary code from your project (the only bash execution is its own scripts)

## Reporting a vulnerability

Please open a **private** issue / contact maintainers directly rather
than filing a public bug. Include:

- Reproduction steps
- Affected version (commit SHA)
- Whether you can demonstrate arbitrary code execution or only DoS / info disclosure

We aim to acknowledge within 72h and patch critical issues within 7d.
