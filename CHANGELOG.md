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
- `install.sh` / `install.ps1` both use the same Claude Code settings
  path on their respective platforms (`~/.claude/settings.json` on POSIX,
  `%USERPROFILE%\.claude\settings.json` on Windows).

## [0.x] — historical

See git log for the unified-script refactor, hook re-entrance fix,
cross-platform path docs, and earlier work.
