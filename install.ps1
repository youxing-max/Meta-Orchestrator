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

# --- install helpers (standalone Python) ---------------------------------
# The three install-time helpers used to be inlined here as @'...'@
# PowerShell here-strings. They were relocated to scripts/ because
# PowerShell here-string parsing has subtle edge cases with multi-line
# Python (apostrophes inside the body, f-string braces, etc.) that
# silently broke on pwsh 7. The standalone scripts take their inputs
# from environment variables (CLAUDE_MD_PATH, SKILL_MD_REF, HOOK_CMD_ABS,
# USERPROFILE, DRY) and are listed in the install.sh / install.ps1
# exclude list when syncing into ~/.claude/skills/.

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
            # IMPORTANT: run the helper scripts FIRST. When the user ran
            # `git clone ... ~/.claude/skills/meta-orchestrator` and is now
            # invoking install.ps1 in place, $Src == $skillDir -- deleting
            # the dir before invoking the helpers would lose them.

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
                    & $py "$Src/scripts/_install_upsert_claude_md.py"
                }

                # Strip ONLY the Stop hook we added, preserve any others.
                $env:DRY = if ($DryRun) { '1' } else { '0' }
                if ($DryRun) {
                    Write-Host "  DRY-RUN: would prune Stop hook from $HomeDir\.claude\settings.json"
                } else {
                    & $py "$Src/scripts/_install_prune_stop_hook.py"
                }
            } else {
                Write-Warn "python not found -- manually remove the meta-orchestrator block from $claudeMd and the stop-reminder entry from $HomeDir\.claude\settings.json"
            }

            Invoke-Action "rm -rf $skillDir" { Remove-Item -LiteralPath $skillDir -Recurse -Force -ErrorAction SilentlyContinue }
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

# Dependency checks.
# python3 is hard-required (the install helpers are Python scripts).
# jq is soft-required: it's only used by Claude Code itself to parse
# Stop hook stdin, not by anything we run here. If jq is missing we
# warn and continue -- skill files still sync, CLAUDE.md still gets
# written, self-check still runs. The Stop hook wiring step still
# runs (the JSON edit is pure Python) but won't fire correctly until
# jq is installed.
$py = Get-PythonCmd
if (-not $py) {
    Write-Err "missing dependency: python3"
    Write-Err "install with: winget install Python.Python.3.12  /  choco install python3"
    exit 1
}
$jqAvailable = $null -ne (Get-Command 'jq' -ErrorAction SilentlyContinue)
if (-not $jqAvailable) {
    Write-Warn "jq not found on PATH -- attempting auto-install so the Stop hook actually fires."

    $jqInstalled = $false
    # Try package managers in order. winget is the most common on Win10/11
    # but requires user confirmation by default; choco is non-interactive.
    # scoop is also non-interactive if installed. We never fail the install
    # if all of these fail -- we just warn again at the end.
    if ($null -ne (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
        # winget requires --accept-package-agreements and possibly --scope user.
        # Try non-interactive install. May prompt for UAC.
        $p = Start-Process -FilePath 'winget' -ArgumentList @(
            'install', '--id', 'jqlang.jq', '-e',
            '--accept-source-agreements', '--accept-package-agreements'
        ) -PassThru -Wait -NoNewWindow -RedirectStandardOutput 'NUL' -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -and ($null -ne (Get-Command 'jq' -ErrorAction SilentlyContinue))) {
            $jqInstalled = $true
        }
    }
    if (-not $jqInstalled -and ($null -ne (Get-Command 'choco' -ErrorAction SilentlyContinue))) {
        $p = Start-Process -FilePath 'choco' -ArgumentList @('install', '-y', 'jq') `
            -PassThru -Wait -NoNewWindow -RedirectStandardOutput 'NUL' -ErrorAction SilentlyContinue
        if ($p.ExitCode -eq 0 -and ($null -ne (Get-Command 'jq' -ErrorAction SilentlyContinue))) {
            $jqInstalled = $true
        }
    }
    if (-not $jqInstalled -and ($null -ne (Get-Command 'scoop' -ErrorAction SilentlyContinue))) {
        & scoop install jq 2>$null | Out-Null
        if ($null -ne (Get-Command 'jq' -ErrorAction SilentlyContinue)) {
            $jqInstalled = $true
        }
    }

    # PowerShell's process PATH cache can lag behind child-process installs.
    # Re-resolve via $env:PATH so the rest of this script sees the new binary.
    if ($jqInstalled) {
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + `
                    [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + `
                    $env:PATH
        $jqAvailable = $true
        Write-Ok "jq auto-installed successfully."
    } else {
        Write-Warn "Could not auto-install jq (no package manager available, or install failed)."
        Write-Warn "Install it manually: winget install jqlang.jq  /  choco install jq"
        Write-Warn "Everything else below will still run; the Stop hook just won't fire until jq is present."
    }
}

# PyYAML check (soft-dep; used only by pattern-memory auto-bootstrap).
# Try pip first, then `py -m pip` and `python -m pip` for PEP 668 envs.
$pyYamlOk = & $py -c "import yaml" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "PyYAML not installed — attempting install so pattern-memory auto-bootstrap works."
    if (-not $DryRun) {
        $installed = $false
        if ($null -ne (Get-Command 'pip' -ErrorAction SilentlyContinue)) {
            pip install pyyaml | Out-Null; $installed = ($LASTEXITCODE -eq 0)
        }
        if (-not $installed) {
            & $py -m pip install pyyaml | Out-Null 2>$null
            $installed = ($LASTEXITCODE -eq 0)
        }
        if (-not $installed) {
            Write-Warn "PyYAML install failed — continuing without it (pattern-memory auto-bootstrap will warn)."
        }
    }
}

# --- sync helper ---------------------------------------------------------
# Mirrors `rsync -a --exclude='.git' …` from install.sh. PowerShell's
# Copy-Item -Recurse does the job; we exclude the same patterns.
function Sync-SkillDir {
    param([string]$Source, [string]$Destination)

    # Idempotency: when the user has already copied the skill into the
    # destination (e.g. they ran `git clone ... ~/.claude/skills/meta-orchestrator`
    # and then run install.ps1 in place), Source == Destination. Skip the
    # cleanup-then-recopy dance -- the files are already there.
    # Resolve-Path on a missing path throws, so guard with Test-Path.
    $samePath = $false
    if ((Test-Path -LiteralPath $Source) -and (Test-Path -LiteralPath $Destination)) {
        $samePath = ((Resolve-Path -LiteralPath $Source).Path -eq
                     (Resolve-Path -LiteralPath $Destination).Path)
    }
    if ($samePath) {
        Write-Log "Source and destination identical, skipping sync."
        return
    }

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
        & $py "$Src/scripts/_install_wire_stop_hook.py"
    }

    # Upsert ~/.claude/CLAUDE.md (force-load SKILL.md every session).
    # We APPEND a sentinel-delimited block instead of overwriting, so any
    # user content above / below stays intact across re-installs and
    # uninstalls. See scripts/_install_upsert_claude_md.py for the strip-on-install
    # idempotency.
    $claudeMdPath = Join-Path $HomeDir '.claude\CLAUDE.md'
    $skillMdRef   = "$Dest\SKILL.md"
    Write-Log "Appending managed block to $claudeMdPath (force-load SKILL.md every session)"
    $env:CLAUDE_MD_PATH = $claudeMdPath
    $env:SKILL_MD_REF   = $skillMdRef
    $env:DRY = if ($DryRun) { '1' } else { '0' }
    & $py "$Src/scripts/_install_upsert_claude_md.py"
}

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
if ((Test-Path $matcher) -and -not $DryRun) {
    $mt = & $py $matcher --text "fix bug" 2>$null
    if (($LASTEXITCODE -eq 0) -and ($mt -match '"matched"')) {
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
