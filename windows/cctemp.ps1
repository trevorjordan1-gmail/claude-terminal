<#
.SYNOPSIS
    cctemp: TEMPORARY Claude Code install on Windows, for troubleshooting.
    This is NOT the claude-terminal build. It leaves when you tell it to —
    or after 30 days of nobody using it.

.DESCRIPTION
    Puts Claude Code on a Windows machine for the duration of a troubleshooting
    engagement, and removes it — binary, config, session transcripts,
    credentials — when you're done. Everything is user-profile-scoped: no admin
    rights, no machine-wide changes, no services, nothing in Program Files.

    Install (from any PowerShell, including a ScreenConnect Backstage session):

        irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1 | iex

    Remove everything when the engagement is over:

        & ([scriptblock]::Create((irm <same-url>))) -Cleanup

    (Switches must be bound via the scriptblock form — content piped to iex
    can't take parameters. Same launcher rationale as windows/get.ps1.)

    AUTO-CLEANUP (on by default): a daily scheduled task checks when Claude
    Code was last USED — newest write time under ~\.claude, where every session
    updates transcripts — and only when the install has sat idle for
    -AutoCleanupDays days (default 30) does it purge. Any use resets the clock,
    so an engagement that revives with a ticket keeps its install; a forgotten
    one removes itself. `-AutoCleanupDays 0` disables the dead-man switch.
    The check runs from a local copy saved at install time, so it works
    offline and nothing is re-fetched from the internet on a schedule.

.NOTES
    - Backstage sessions run as SYSTEM: the install lands in the SYSTEM
      profile, which is fine for troubleshooting — just run -Cleanup from the
      same context you installed from.
    - Sign-in is interactive (claude.ai account or API key) and is never
      stored by this script. -Cleanup deletes the local credential material
      and all session transcripts with the rest of ~\.claude. (Local purge —
      the OAuth grant itself expires server-side; revoke in claude.ai account
      settings if a box was hostile.)
    - Intent marker: %LOCALAPPDATA%\cctemp\installed.json records when and by
      whom the temporary install was made, so a later tech (or an auditor)
      can tell this apart from a deliberate permanent install.
#>

[CmdletBinding()]
param(
    [switch]$Cleanup,
    [int]$AutoCleanupDays = 30,
    [switch]$AutoCleanupCheck
)

$ErrorActionPreference = 'Stop'

$MarkerDir = Join-Path $env:LOCALAPPDATA 'cctemp'
$Marker    = Join-Path $MarkerDir 'installed.json'
$LocalCopy = Join-Path $MarkerDir 'cctemp.ps1'
$SelfUrl   = 'https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1'
$TaskName  = 'cctemp-autocleanup'

function Get-CCLastUsed {
    # Every Claude Code session writes transcripts/state under ~\.claude, so
    # the newest write time there is a faithful "last used" signal. Fall back
    # to the install timestamp, then to "now" (never wipe on missing data).
    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    if (Test-Path $claudeDir) {
        $newest = Get-ChildItem $claudeDir -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { return $newest.LastWriteTime }
    }
    if (Test-Path $Marker) {
        try { return [datetime](Get-Content $Marker -Raw | ConvertFrom-Json).installed_at } catch { }
    }
    return Get-Date
}

function Remove-CCTemp {
    Write-Host "`n[cctemp] removing temporary Claude Code install..." -ForegroundColor Yellow

    Get-Process -Name 'claude*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $targets = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\claude'),
        (Join-Path $env:USERPROFILE '.local\share\claude'),
        (Join-Path $env:USERPROFILE '.claude'),          # sessions, transcripts, credentials, settings
        (Join-Path $env:USERPROFILE '.claude.json'),
        (Join-Path $env:USERPROFILE '.claude.json.backup')
    )
    foreach ($t in $targets) {
        if (Test-Path $t) {
            Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $t"
        }
    }

    # Drop the user-PATH entry only if the directory is now empty/gone —
    # the official installer adds %USERPROFILE%\.local\bin, but the user may
    # keep other tools there.
    $binDir = Join-Path $env:USERPROFILE '.local\bin'
    if (-not (Test-Path $binDir) -or -not (Get-ChildItem $binDir -ErrorAction SilentlyContinue)) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -and $userPath -like "*$binDir*") {
            $newPath = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $binDir }) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "  removed $binDir from user PATH"
        }
    }

    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null

    # Marker + local copy go last so a failed run above leaves the evidence.
    if (Test-Path $MarkerDir) { Remove-Item $MarkerDir -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "[cctemp] done - no Claude Code remains for this user profile." -ForegroundColor Green
}

if ($Cleanup) { Remove-CCTemp; return }

if ($AutoCleanupCheck) {
    # Ran daily by the scheduled task, from the local copy. Quiet unless acting.
    $days = $AutoCleanupDays
    if (Test-Path $Marker) {
        try { $days = [int](Get-Content $Marker -Raw | ConvertFrom-Json).auto_cleanup_days } catch { }
    }
    if ($days -le 0) { return }
    $idle = (New-TimeSpan -Start (Get-CCLastUsed) -End (Get-Date)).TotalDays
    if ($idle -ge $days) {
        Write-Host "[cctemp] idle $([math]::Floor($idle))d >= $days d threshold - auto-cleaning."
        Remove-CCTemp
    }
    return
}

Write-Host ''
Write-Host '=====================================================================' -ForegroundColor Yellow
Write-Host '  cctemp: TEMPORARY Claude Code install - troubleshooting use only'   -ForegroundColor Yellow
Write-Host "  Auto-removes after $AutoCleanupDays days of no use. Remove now with:" -ForegroundColor Yellow
Write-Host "    & ([scriptblock]::Create((irm $SelfUrl))) -Cleanup"
Write-Host '=====================================================================' -ForegroundColor Yellow
Write-Host ''

# Windows PowerShell 5.1 on older builds negotiates TLS 1.0 first; the
# download hosts refuse it.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Official native installer, landed on disk first (same reasoning as get.ps1:
# #Requires and exit semantics only behave for real script files).
$Installer = Join-Path $env:TEMP 'claude-install.ps1'
$ProgressPreference = 'SilentlyContinue'
Write-Host '[cctemp] downloading official Claude Code installer...' -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://claude.ai/install.ps1' -OutFile $Installer -UseBasicParsing
Unblock-File -Path $Installer -ErrorAction SilentlyContinue
& $Installer

# Intent marker: makes "why is Claude Code on this box?" answerable later.
New-Item -ItemType Directory -Path $MarkerDir -Force | Out-Null
@{
    installed_at      = (Get-Date).ToString('o')
    installed_by      = "$env:USERDOMAIN\$env:USERNAME"
    host              = $env:COMPUTERNAME
    purpose           = 'TEMPORARY troubleshooting install (cctemp, claude-terminal repo)'
    auto_cleanup_days = $AutoCleanupDays
    cleanup           = "& ([scriptblock]::Create((irm $SelfUrl))) -Cleanup"
} | ConvertTo-Json | Set-Content -Path $Marker -Encoding UTF8

if ($AutoCleanupDays -gt 0) {
    # Keep a local copy for the daily idle check: offline-safe, and the task
    # never re-fetches code from the internet on a schedule.
    try { Invoke-WebRequest -Uri $SelfUrl -OutFile $LocalCopy -UseBasicParsing }
    catch { if ($PSCommandPath) { Copy-Item $PSCommandPath $LocalCopy -Force } }

    if (Test-Path $LocalCopy) {
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$LocalCopy`" -AutoCleanupCheck"
        schtasks /Create /TN $TaskName /TR $cmd /SC DAILY /ST 13:00 /F | Out-Null
        Write-Host "[cctemp] dead-man switch armed: daily check, purge after $AutoCleanupDays days of no use." -ForegroundColor Cyan
    } else {
        Write-Host '[cctemp] WARNING: could not save local copy - auto-cleanup NOT armed; remove manually.' -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '[cctemp] installed. Start a session with:  claude' -ForegroundColor Green
Write-Host '[cctemp] (new PATH entry - open a fresh shell, or run: $env:Path = [Environment]::GetEnvironmentVariable(''Path'',''User'') + '';'' + $env:Path)'
Write-Host '[cctemp] REMEMBER: this install is temporary. Clean up when done.' -ForegroundColor Yellow
