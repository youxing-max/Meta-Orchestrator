# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `install.ps1` — Windows PowerShell installer mirroring `install.sh`
  (`-Target claude|codex|both`, `-Uninstall`, `-DryRun`). Writes
  `%USERPROFILE%\.claude\CLAUDE.md` for force-load, wires the Stop
  hook, runs the same self-check.
- README: Windows prerequisites section, `install.ps1` command table,
  FAQ entry for PowerShell execution policy + winget install hints.
- Roadmap entry: Windows file-lock research moved to "still open" line
  alongside the now-shipped installer.

### Changed
- **Both `install.sh` and `install.ps1` now APPEND a sentinel-delimited
  block to `~/.claude/CLAUDE.md` instead of overwriting it.** The block
  is wrapped in `<!-- >>> meta-orchestrator (managed block, do not edit) >>>`
  / `<!-- <<< meta-orchestrator <<<` sentinels. Re-running either
  installer is a no-op (strips + re-appends); `--uninstall` /
  `-Uninstall` strips only the managed block and preserves any user
  content. SENTINEL strings are shared between the bash and PowerShell
  installers so the two stay in lock-step.
- `install.sh` / `install.ps1` both use the same Claude Code settings
  path on their respective platforms (`~/.claude/settings.json` on POSIX,
  `%USERPROFILE%\.claude\settings.json` on Windows).
- **`jq` is now a soft dependency**, not a hard install gate. Previously
  both installers called `exit 1` if `jq` wasn't on PATH, which blocked
  installation on machines that didn't have it yet. jq is only needed
  by Claude Code itself when *firing* the Stop hook (to parse stdin),
  not by anything the installer does. Both installers now warn + skip
  the wire-stop-hook step if jq is missing, but still sync the skill
  files, write CLAUDE.md, and run the self-check. README prerequisites
  updated to mark jq optional.

## [0.x] — historical

See git log for the unified-script refactor, hook re-entrance fix,
cross-platform path docs, and earlier work.
