<#
.SYNOPSIS
    Meta-Orchestrator installer (Windows PowerShell).

.DESCRIPTION
    Idempotent. Re-running is safe — it only writes files that are missing
    or whose contents drift from this skill's expected config.

    Mirrors the bash install.sh contract on Windows so users on either
    platform get the same end state:

      * Skill files synced into the target skills directory
      * Stop hook wired into the Claude Code settings.json
      * ~/.claude/CLAUDE.md written so SKILL.md is force-loaded every session
      * Self-check (validate_dag.py + _matcher.py) at the end

.PARAMETER Target
    Where to install. 'claude' (default) | 'codex' | 'both'.

.PARAMETER Uninstall
    Remove what this script installed (skill dir, hook entry, CLAUDE.md).

.PARAMETER DryRun
    Print the actions the script would take without writing anything.

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -Target both
.EXAMPLE
    .\install.ps1 -DryRun
.EXAMPLE
    .\install.ps1 -Uninstall

.NOTES
    Requires PowerShell 5.1+ (Windows default) or PowerShell 7+.
    Requires Python 3.8+ on PATH (the 'py' launcher is preferred).
    Requires 'jq' on PATH for the Stop hook (winget install jqlang.jq).
#>

[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'both')]
    [string]$Target = 'claude',

    [switch]$Uninstall,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- paths ---------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src       = $ScriptDir   # this repo IS the skill

# PowerShell $HOME on Windows points at the user profile (Documents etc.),
# which differs from $env:USERPROFILE on some shells. We use USERPROFILE
# because Claude Code / Codex expect paths under %USERPROFILE%\.claude\…
$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { $HomeDir = $HOME }

function Write-Log  { param([string]$Msg) Write-Host "[install] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[warn]    $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "[err]     $Msg" -ForegroundColor Red }
function Write-Ok   { param([string]$Msg) Write-Host "[ok]      $Msg" -ForegroundColor Green }

# --- helpers -------------------------------------------------------------
function Invoke-Action {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Host "  DRY-RUN: $Description"
    } else {
        & $Action
    }
}

function Test-Dependency {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Err "missing dependency: $Name"
        if ($InstallHint) { Write-Err "install with: $InstallHint" }
        exit 1
    }
}

# --- find python ---------------------------------------------------------
# 'py' launcher is the Windows-canonical way; fall back to 'python' / 'python3'.
function Get-PythonCmd {
    foreach ($c in @('py', 'python', 'python3')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return $c }
    }
    return $null
}

# --- embedded Python snippets -------------------------------------------
# We keep these as here-strings so they survive code review and so the
# Windows install path stays parallel to the bash one. Each block is
# passed to the discovered Python interpreter via stdin.

$PythonWireStopHook = @'
import json, os, sys
dry = os.environ.get("DRY") == "1"
hook_cmd = os.environ["HOOK_CMD_ABS"]
p = os.path.expanduser(os.path.join(os.environ["USERPROFILE"], ".claude", "settings.json"))
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.exists(p):
    try:
        data = json.load(open(p, encoding="utf-8"))
    except Exception:
        data = {}
hooks_root = data.setdefault("hooks", {})
st = hooks_root.setdefault("Stop", [])
if not any("stop-reminder" in str(h) for hs in st for h in hs.get("hooks", [])):
    st.append({"hooks": [{"type": "command", "command": hook_cmd}]})
if dry:
    print("  DRY-RUN: would write", p)
    print("  hook_cmd:", hook_cmd)
else:
    json.dump(data, open(p, "w", encoding="utf-8"), indent=2)
    print(f"  Stop hook configured at {p}")
'@

# Prune only the Stop hook entries we added; keep any other Stop hooks
# the user (or another tool) configured. Mirrors the bash install.sh
# uninstall semantics.
$PythonPruneStopHook = @'
import json, os, sys
dry = os.environ.get("DRY") == "1"
p = os.path.expanduser(os.path.join(os.environ["USERPROFILE"], ".claude", "settings.json"))
if not os.path.exists(p):
    sys.exit(0)
try:
    data = json.load(open(p, encoding="utf-8"))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
hooks_root = data.get("hooks", {})
st = hooks_root.get("Stop", [])
new = [hs for hs in st
       if not any("stop-reminder" in h.get("command", "") for h in hs.get("hooks", []))]
if new == st:
    print(f"  no meta-orchestrator Stop hook found in {p}")
    sys.exit(0)
data["hooks"]["Stop"] = new
if dry:
    print(f"  DRY-RUN: would prune Stop hook from {p}")
    sys.exit(0)
json.dump(data, open(p, "w", encoding="utf-8"), indent=2)
print(f"  pruned Stop hook from {p}")
'@

# Idempotent CLAUDE.md editor.
#
# We never *replace* the user's CLAUDE.md — only append a sentinel-delimited
# block (or strip it on uninstall). The block we own is wrapped between two
# unique sentinels so re-running the installer is a no-op, and uninstall
# can peel our block out without touching anything the user wrote.
$PythonUpsertClaudeMd = @'
import os, re, sys

dry = os.environ.get("DRY") == "1"
claude_md = os.environ["CLAUDE_MD_PATH"]
skill_md  = os.environ["SKILL_MD_REF"]
SENTINEL_OPEN  = "<!-- >>> meta-orchestrator (managed block, do not edit) >>>"
SENTINEL_CLOSE = "<!-- <<< meta-orchestrator <<<"

block = f"""{SENTINEL_OPEN}
# Auto-installed by meta-orchestrator/install.ps1
# This block is owned by the installer. Re-running install.ps1 re-applies
# it idempotently; -Uninstall strips it. Anything outside these sentinels
# is yours to edit.

## Always-loaded skills

The following skill must be available in EVERY Claude Code session,
regardless of prompt content. This is force-loaded via CLAUDE.md, not
relying on description matching.

@{skill_md}

## Behavior

- Treat `meta-orchestrator` as default-on. Do not ask the user
  "should I load it?" -- it is already loaded.
- Honor explicit opt-out keywords: `skip`, `--no`, `don't run orchestrator`.
- After every response, emit the
  `<!-- meta-orchestrator: sig=... family=... matched=... -->`
  marker (or call `orchestrator.py record` directly) so the Stop hook
  can update pattern memory.
- Run Step 0 (check workflows/*.yaml) before improvising any non-trivial
  multi-step plan.

## What this skill does (TL;DR)

1. `workflows/*.yaml` holds reusable DAGs. Match by `triggers` /
   `description` before improvising.
2. Tier every task T0-T3; T2/T3 -> decompose into DAG.
3. GATE 2 (record) -> GATE 3 (check, threshold >=3) -> GATE 4 (propose
   crystallization) -> workflow file written.

When a pattern's count reaches 3, the hook prompts the user: `y` to
write a workflow file, `n` to archive as declined.
{SENTINEL_CLOSE}
"""

# Strip any prior version of our block (idempotent re-apply + uninstall).
pattern = re.compile(
    re.escape(SENTINEL_OPEN) + r".*?" + re.escape(SENTINEL_CLOSE) + r"\n*",
    re.DOTALL,
)

existing = ""
if os.path.exists(claude_md):
    with open(claude_md, encoding="utf-8") as f:
        existing = f.read()

# Recover whether the user's ORIGINAL content ended with a newline.
# The post-install file is always:
#     user_content + "\n" + block       (user had no trailing \n)
#     user_content + "\n\n" + block     (user had trailing \n)
# so byte at sentinel_open - 2 is the LAST byte of user content.
m = re.search(re.escape(SENTINEL_OPEN), existing)
if m:
    if m.start() >= 2:
        user_ended_with_newline = existing[m.start() - 2] == "\n"
    else:
        user_ended_with_newline = False
else:
    user_ended_with_newline = existing.endswith("\n")

stripped = pattern.sub("", existing).rstrip()
# Install layout rules:
#   - empty user content            -> block at top, no leading ws
#   - user content + trailing \n    -> "\n\n" separator (one blank line)
#   - user content + NO trailing \n -> "\n"  separator (flush)
# Uninstall layout rules:
#   - user had trailing \n    -> file ends with \n
#   - user had NO trailing \n -> file ends without \n
if stripped:
    if skill_md:  # install path passes a non-empty SKILL_MD_REF
        prefix = stripped + ("\n\n" if user_ended_with_newline else "\n")
        new_content = prefix + block
    else:  # uninstall path -- SKILL_MD_REF is empty
        new_content = stripped + ("\n" if user_ended_with_newline else "")
else:
    new_content = block if skill_md else ""

if new_content == existing:
    print(f"  CLAUDE.md already has current meta-orchestrator block at {claude_md}")
    sys.exit(0)

if dry:
    print(f"  DRY-RUN: would append meta-orchestrator block to {claude_md}")
    sys.exit(0)

os.makedirs(os.path.dirname(claude_md), exist_ok=True)
with open(claude_md, "w", encoding="utf-8") as f:
    f.write(new_content)
print(f"  appended meta-orchestrator block to {claude_md}")
'@

# --- uninstall path ------------------------------------------------------
if ($Uninstall) {
    Write-Log "Uninstalling meta-orchestrator..."

    $targets = @()
    if ($Target -eq 'claude' -or $Target -eq 'both') { $targets += 'claude' }
    if ($Target -eq 'codex'  -or $Target -eq 'both') { $targets += 'codex'  }

    foreach ($t in $targets) {
        $skillDir = Join-Path $HomeDir ".$t\skills\meta-orchestrator"
        $claudeMd = Join-Path $HomeDir ".$t\CLAUDE.md"

        if ($t -eq 'claude') {
            Invoke-Action "rm -rf $skillDir" { Remove-Item -LiteralPath $skillDir -Recurse -Force -ErrorAction SilentlyContinue }

            # Strip ONLY the managed meta-orchestrator block from CLAUDE.md;
            # anything the user wrote above / below stays untouched.
            $py = Get-PythonCmd
            if ($py) {
                $env:USERPROFILE    = $HomeDir
                $env:CLAUDE_MD_PATH = $claudeMd
                $env:SKILL_MD_REF   = ''
                $env:DRY = if ($DryRun) { '1' } else { '0' }
                if ($DryRun) {
                    Write-Host "  DRY-RUN: would strip meta-orchestrator block from $claudeMd (preserving other content)"
                } else {
                    $PythonUpsertClaudeMd | & $py -
                }

                # Strip ONLY the Stop hook we added, preserve any others.
                $env:DRY = if ($DryRun) { '1' } else { '0' }
                if ($DryRun) {
                    Write-Host "  DRY-RUN: would prune Stop hook from $HomeDir\.claude\settings.json"
                } else {
                    $PythonPruneStopHook | & $py -
                }
            } else {
                Write-Warn "python not found -- manually remove the meta-orchestrator block from $claudeMd and the stop-reminder entry from $HomeDir\.claude\settings.json"
            }
        }
        elseif ($t -eq 'codex') {
            Invoke-Action "rm -rf $skillDir" { Remove-Item -LiteralPath $skillDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Ok "Uninstall complete."
    exit 0
}

# --- install path --------------------------------------------------------
Write-Log "Installing meta-orchestrator from: $Src"

# dependency checks
Test-Dependency -Name 'jq'   -InstallHint 'winget install jqlang.jq  /  choco install jq'
$py = Get-PythonCmd
if (-not $py) {
    Write-Err "missing dependency: python3"
    Write-Err "install with: winget install Python.Python.3.12  /  choco install python3"
    exit 1
}

# PyYAML check
$pyYamlOk = & $py -c "import yaml" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "PyYAML not installed — running: pip install pyyaml"
    if (-not $DryRun) { pip install pyyaml | Out-Null }
}

# --- sync helper ---------------------------------------------------------
# Mirrors `rsync -a --exclude='.git' …` from install.sh. PowerShell's
# Copy-Item -Recurse does the job; we exclude the same patterns.
function Sync-SkillDir {
    param([string]$Source, [string]$Destination)

    if (-not (Test-Path $Destination)) {
        Invoke-Action "mkdir -p $Destination" { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    } else {
        # Clean destination of files we own (keep the user's pattern-memory
        # untouched — they are runtime state). We mirror the bash version's
        # exclude list so the sync is byte-identical.
        Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('pattern-memory.yaml', 'pattern-memory.yaml.bak', 'pattern-memory.yaml.lock') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $exclude = @('.git', '__pycache__', 'install.sh', 'install.ps1')
    $excludeExt = @('.pyc')
    $excludeFilePrefixes = @('pattern-memory.yaml')

    Get-ChildItem -LiteralPath $Source -Force |
        Where-Object {
            $n = $_.Name
            if ($exclude -contains $n) { return $false }
            if ($excludeExt -contains [System.IO.Path]::GetExtension($n)) { return $false }
            foreach ($p in $excludeFilePrefixes) {
                if ($n.StartsWith($p)) { return $false }
            }
            return $true
        } |
        ForEach-Object {
            $target = Join-Path $Destination $_.Name
            if ($_.PSIsContainer) {
                Invoke-Action "copy dir $($_.FullName) -> $target" {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
                }
            } else {
                Invoke-Action "copy file $($_.FullName) -> $target" {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                }
            }
        }
}

# --- Claude Code ---------------------------------------------------------
if ($Target -eq 'claude' -or $Target -eq 'both') {
    $Dest = Join-Path $HomeDir '.claude\skills\meta-orchestrator'
    Write-Log "Syncing skill -> $Dest"
    Sync-SkillDir -Source $Src -Destination $Dest
    Write-Ok "Skill files synced to $Dest"

    # Wire Stop hook
    Write-Log "Wiring Stop hook in $HomeDir\.claude\settings.json"
    $hookCmd = "bash $Dest\hooks\claude-code-stop-reminder.sh"
    $env:HOOK_CMD_ABS = $hookCmd
    $env:USERPROFILE  = $HomeDir
    $env:DRY = if ($DryRun) { '1' } else { '0' }
    if ($DryRun) {
        Write-Host "  DRY-RUN: would wire Stop hook command: $hookCmd"
    } else {
        $PythonWireStopHook | & $py -
    }

    # Upsert ~/.claude/CLAUDE.md (force-load SKILL.md every session).
    # We APPEND a sentinel-delimited block instead of overwriting, so any
    # user content above / below stays intact across re-installs and
    # uninstalls. See $PythonUpsertClaudeMd for the strip-on-install
    # idempotency.
    $claudeMdPath = Join-Path $HomeDir '.claude\CLAUDE.md'
    $skillMdRef   = "$Dest\SKILL.md"
    Write-Log "Appending managed block to $claudeMdPath (force-load SKILL.md every session)"
    $env:CLAUDE_MD_PATH = $claudeMdPath
    $env:SKILL_MD_REF   = $skillMdRef
    $env:DRY = if ($DryRun) { '1' } else { '0' }
    $PythonUpsertClaudeMd | & $py -

# --- Codex ---------------------------------------------------------------
if ($Target -eq 'codex' -or $Target -eq 'both') {
    $Dest = Join-Path $HomeDir '.codex\skills\meta-orchestrator'
    Write-Log "Syncing skill -> $Dest"
    Sync-SkillDir -Source $Src -Destination $Dest
    Write-Ok "Skill files synced to $Dest"
    Write-Warn "Codex has no turn_end hook. Model must self-emit marker or run"
    Write-Warn "  python $Dest\scripts\orchestrator.py record ..."
    Write-Warn "after each response. SKILL.md describes this contract."
}

# --- self-check ----------------------------------------------------------
Write-Log "Running self-check..."
$validateDag = Join-Path $Src 'scripts\validate_dag.py'
if (Test-Path $validateDag) {
    if ($DryRun) {
        Write-Host "  DRY-RUN: would run $validateDag"
    } else {
        & $py $validateDag
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "validate_dag.py: PASS"
        } else {
            Write-Warn "validate_dag.py reported issues"
        }
    }
}
$matcher = Join-Path $Src 'scripts\_matcher.py'
if (Test-Path $matcher -and -not $DryRun) {
    $mt = & $py $matcher --text "fix bug" 2>$null
    if ($LASTEXITCODE -eq 0 -and $mt -match '"matched"') {
        try {
            $obj = $mt | ConvertFrom-Json
            Write-Ok "_matcher.py: PASS (matched $($obj.matched))"
        } catch {
            Write-Warn "_matcher.py returned non-JSON: $mt"
        }
    } else {
        Write-Warn "_matcher.py did not return expected JSON: $mt"
    }
}

Write-Ok "Install complete."
Write-Log "Next:"
Write-Host "  1. Open a new Claude Code session."
Write-Host "  2. Run any non-trivial task. The Stop hook will auto-record."
Write-Host "  3. After ~3 uses of the same pattern, hook prompts you to"
Write-Host "     crystallize (y/n/edit)."
