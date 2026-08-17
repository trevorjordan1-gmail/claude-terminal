<#
.SYNOPSIS
    cctemp: TEMPORARY Claude Code install on Windows, for troubleshooting.
    This is NOT the claude-terminal build. It leaves when you tell it to.

.DESCRIPTION
    Puts Claude Code on a Windows machine for the duration of a troubleshooting
    engagement, and removes it — binary, config, credentials — when you're done.
    Everything is user-profile-scoped: no admin rights, no machine-wide changes,
    no services, nothing in Program Files.

    Install (from any PowerShell, including a ScreenConnect Backstage session):

        irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1 | iex

    Remove everything when the engagement is over:

        & ([scriptblock]::Create((irm <same-url>))) -Cleanup

    (Switches must be bound via the scriptblock form — content piped to iex
    can't take parameters. Same launcher rationale as windows/get.ps1.)

    Optional dead-man switch — schedule automatic cleanup N days out, so a
    forgotten install removes itself:

        & ([scriptblock]::Create((irm <same-url>))) -AutoCleanupDays 7

.NOTES
    - Backstage sessions run as SYSTEM: the install lands in the SYSTEM
      profile, which is fine for troubleshooting — just run -Cleanup from the
      same context you installed from.
    - Sign-in is interactive (claude.ai account or API key) and is never
      stored by this script; -Cleanup deletes the credential material with
      the rest of ~/.claude.
    - Intent marker: %LOCALAPPDATA%\cctemp\installed.json records when and by
      whom the temporary install was made, so a later tech (or an auditor)
      can tell this apart from a deliberate permanent install.
#>

[CmdletBinding()]
param(
    [switch]$Cleanup,
    [int]$AutoCleanupDays = 0
)

$ErrorActionPreference = 'Stop'

$Marker    = Join-Path $env:LOCALAPPDATA 'cctemp\installed.json'
$MarkerDir = Split-Path $Marker
$SelfUrl   = 'https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1'
$TaskName  = 'cctemp-autocleanup'

function Remove-CCTemp {
    Write-Host "`n[cctemp] removing temporary Claude Code install..." -ForegroundColor Yellow

    Get-Process -Name 'claude*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $targets = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\claude'),
        (Join-Path $env:USERPROFILE '.local\share\claude'),
        (Join-Path $env:USERPROFILE '.claude'),
        (Join-Path $env:USERPROFILE '.claude.json'),
        (Join-Path $env:USERPROFILE '.claude.json.backup'),
        $MarkerDir
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

    Write-Host "[cctemp] done - no Claude Code remains for this user profile." -ForegroundColor Green
}

if ($Cleanup) { Remove-CCTemp; return }

Write-Host ''
Write-Host '=====================================================================' -ForegroundColor Yellow
Write-Host '  cctemp: TEMPORARY Claude Code install - troubleshooting use only'   -ForegroundColor Yellow
Write-Host '  Remove when finished:'                                              -ForegroundColor Yellow
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
    installed_at = (Get-Date).ToString('o')
    installed_by = "$env:USERDOMAIN\$env:USERNAME"
    host         = $env:COMPUTERNAME
    purpose      = 'TEMPORARY troubleshooting install (cctemp, claude-terminal repo)'
    cleanup      = "& ([scriptblock]::Create((irm $SelfUrl))) -Cleanup"
} | ConvertTo-Json | Set-Content -Path $Marker -Encoding UTF8

if ($AutoCleanupDays -gt 0) {
    $when = (Get-Date).AddDays($AutoCleanupDays)
    $cmd  = "powershell -NoProfile -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((irm $SelfUrl))) -Cleanup`""
    schtasks /Create /TN $TaskName /TR $cmd /SC ONCE /ST $when.ToString('HH:mm') /SD $when.ToString('MM/dd/yyyy') /F | Out-Null
    Write-Host "[cctemp] dead-man switch set: auto-cleanup on $($when.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan
}

Write-Host ''
Write-Host '[cctemp] installed. Start a session with:  claude' -ForegroundColor Green
Write-Host '[cctemp] (new PATH entry - open a fresh shell, or run: $env:Path = [Environment]::GetEnvironmentVariable(''Path'',''User'') + '';'' + $env:Path)'
Write-Host '[cctemp] REMEMBER: this install is temporary. Clean up when done.' -ForegroundColor Yellow
