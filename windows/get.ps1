<#
.SYNOPSIS
    claude-terminal Windows entrypoint: fetch New-UbuntuHyperVVM.ps1 and run it.

.DESCRIPTION
    From an elevated PowerShell on the Hyper-V host:

        irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/get.ps1 | iex

    This downloads the provisioning script and invokes it as a real .ps1 file
    rather than executing it inline. That distinction is the whole reason this
    launcher exists: PowerShell honours `#Requires` statements only for script
    files, and content run straight from a pipe has an `exit` that terminates
    the calling console instead of the script. Landing the file on disk first
    keeps the provisioning script's own guards, exit codes, and parameters
    working exactly as they do when you run it by hand.

    To pass switches through, bind them to this launcher instead of piping:

        & ([scriptblock]::Create((irm <same-url>))) -SkipIsoUpdate

.NOTES
    Requires: Administrator privileges, internet access.
    The provisioning script checks for Hyper-V itself.
#>

# No param() block on purpose: unbound arguments land in $args, and splatting
# $args is the one forwarding form that preserves named parameters. Declaring
# them via ValueFromRemainingArguments looks tidier but forwards positionally,
# so `-SkipIsoUpdate` would silently bind to -VMRoot instead.

$ErrorActionPreference = 'Stop'

$Source = 'https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/New-UbuntuHyperVVM.ps1'
$Dest   = Join-Path $env:TEMP 'New-UbuntuHyperVVM.ps1'

# Windows PowerShell 5.1 on older Server builds still negotiates TLS 1.0 first,
# which raw.githubusercontent.com refuses.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Process-scoped: reverts when this console closes, touches no machine policy.
try { Set-ExecutionPolicy Bypass -Scope Process -Force } catch { }

Write-Host "[get] downloading New-UbuntuHyperVVM.ps1..." -ForegroundColor Cyan
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $Source -OutFile $Dest -UseBasicParsing

Unblock-File -Path $Dest -ErrorAction SilentlyContinue

Write-Host "[get] running $Dest`n" -ForegroundColor Cyan
& $Dest @args
