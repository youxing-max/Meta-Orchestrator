---
name: Bug report
about: Something broken? Tell me what happened and how to reproduce.
title: "[bug] "
labels: ["bug"]
assignees: []
---

## What happened

<!-- One sentence: what went wrong -->

## How to reproduce

<!-- Minimal steps to trigger. Include the prompt you typed, the hook
     output you saw, and any error messages. -->

1.
2.
3.

## Expected behavior

<!-- What did you expect to happen? -->

## Environment

- OS: [e.g. macOS 14.4, Ubuntu 22.04]
- Python version: `python3 --version`
- PyYAML version: `python3 -c "import yaml; print(yaml.__version__)"`
- jq version: `jq --version`
- Claude Code version (if applicable):
- Codex version (if applicable):
- Install method: `./install.sh` / manual / dev tree

## Relevant config

<!-- Paste your `~/.claude/settings.json` Stop hook entry, your
     `~/.claude/CLAUDE.md` (force-load section), and any non-default
     workflow YAML fields. -->

## Logs

<!-- If a hook failed, paste the output of running it manually:

     echo '{"stop_hook_active": false, "transcript_path": "/dev/null"}' | \
       bash ~/.claude/skills/meta-orchestrator/hooks/claude-code-stop-reminder.sh

     Or attach a transcript excerpt. -->
