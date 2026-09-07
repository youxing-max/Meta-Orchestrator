# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `install.sh` — one-shot installer with `--target=claude|codex|both`,
  `--uninstall`, `--dry-run` flags
- `CLAUDE.md.template` — force-load mechanism for default-on behavior
- GitHub Actions CI (`.github/workflows/ci.yml`) — validates workflows,
  smoke-tests matcher, lints shell scripts
- GitHub Actions release (`.github/workflows/release.yml`) — tags
  trigger a tarball + GitHub Release
- Issue templates: bug, feature request, crystallization proposal
- `SECURITY.md` — disclosure policy and threat model
- `workflows/config-update.yaml` — real crystallized artifact (demo)
- README rewrite: beginner-friendly intro + architecture deep-dive

### Changed
- `SKILL.md` description: "Recommended for non-trivial sessions" →
  "MANDATORY default-on"

## [0.x] — historical

See git log for the unified-script refactor, hook re-entrance fix,
cross-platform path docs, and earlier work.
