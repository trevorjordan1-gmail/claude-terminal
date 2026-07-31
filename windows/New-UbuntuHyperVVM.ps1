#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Creates a new Hyper-V Generation 2 VM, staging the latest Ubuntu Desktop
    24.04 LTS ISO locally first.

.DESCRIPTION
    - Ensures C:\VMs and C:\VMs\ISOs exist
    - Queries releases.ubuntu.com for the newest 24.04.x desktop ISO
    - Downloads it if missing, or if a newer point release has shipped
    - Verifies the download against Canonical's published SHA256SUMS
    - Prompts for VM specs, ISO, and virtual switch, then builds the VM

.PARAMETER VMRoot
    Root folder for VMs. Defaults to C:\VMs. ISOs land in <VMRoot>\ISOs.

.PARAMETER SkipIsoUpdate
    Skip the online check entirely and just use whatever is already local.

.PARAMETER SkipHashCheck
    Skip SHA256 verification of a freshly downloaded ISO.

.NOTES
    Requires: Hyper-V module, Administrator privileges, internet access
#>

param(
    [string]$VMRoot = "C:\VMs",
    [switch]$SkipIsoUpdate,
    [switch]$SkipHashCheck
)

# =============================================================================
# CONFIGURATION
# =============================================================================

$ISOPath        = Join-Path $VMRoot "ISOs"
$UbuntuRelease  = "24.04"
$UbuntuBaseUrl  = "https://releases.ubuntu.com/$UbuntuRelease"
$IsoNameRegex   = 'ubuntu-\d+\.\d+(?:\.\d+)?-desktop-amd64\.iso'

# TLS 1.2 for Windows PowerShell 5.1 on older servers
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Get-IsoVersion {
    <# Turns 'ubuntu-24.04.4-desktop-amd64.iso' into [version]24.4.4.
       A bare 'ubuntu-24.04-desktop-amd64.iso' becomes 24.4.0. #>
    param([string]$Name)

    if ($Name -match 'ubuntu-(\d+)\.(\d+)(?:\.(\d+))?-desktop-amd64\.iso') {
        $point = if ($Matches[3]) { $Matches[3] } else { 0 }
        return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$point)
    }
    return $null
}

function Get-LatestRemoteIso {
    <# Scrapes the release directory listing and returns the newest desktop ISO name. #>
    $ProgressPreference = 'SilentlyContinue'
    try {
        $page = Invoke-WebRequest -Uri "$UbuntuBaseUrl/" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        Write-Host "  Could not reach $UbuntuBaseUrl ($($_.Exception.Message))" -ForegroundColor Yellow
        return $null
    }

    $names = [regex]::Matches($page.Content, $IsoNameRegex) |
             ForEach-Object { $_.Value } |
             Select-Object -Unique

    if (-not $names) { return $null }

    return ($names | Sort-Object { Get-IsoVersion $_ } -Descending | Select-Object -First 1)
}

function Get-PublishedHash {
    param([string]$FileName)
    try {
        $sums = (Invoke-WebRequest -Uri "$UbuntuBaseUrl/SHA256SUMS" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
    }
    catch { return $null }

    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($FileName))$") {
            return $Matches[1]
        }
    }
    return $null
}

function Invoke-IsoDownload {
    param([string]$Url, [string]$Destination)

    $partial = "$Destination.partial"
    if (Test-Path $partial) { Remove-Item $partial -Force }

    # BITS is faster and resumable; fall back to Invoke-WebRequest if it's unavailable.
    $bitsOk = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $partial `
                           -Description "Ubuntu Desktop ISO" -ErrorAction Stop
        $bitsOk = $true
    }
    catch {
        Write-Host "  BITS unavailable or failed, falling back to Invoke-WebRequest..." -ForegroundColor Yellow
    }

    if (-not $bitsOk) {
        $ProgressPreference = 'SilentlyContinue'   # progress bar cripples IWR throughput
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -ErrorAction Stop
    }

    Move-Item -Path $partial -Destination $Destination -Force
}

# =============================================================================
# FOLDER STRUCTURE
# =============================================================================

foreach ($folder in @($VMRoot, $ISOPath)) {
    if (-not (Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Write-Host "Created $folder" -ForegroundColor Green
    }
}

# =============================================================================
# ISO STAGING - download latest, or verify what we have is current
# =============================================================================

Write-Host "`nChecking Ubuntu $UbuntuRelease Desktop ISO..." -ForegroundColor Cyan

$LocalIsos  = @(Get-ChildItem -Path (Join-Path $ISOPath "*.iso") -ErrorAction SilentlyContinue)
$LocalUbuntu = @($LocalIsos | Where-Object { $_.Name -match $IsoNameRegex } |
                 Sort-Object { Get-IsoVersion $_.Name } -Descending)
$LocalNewest = $LocalUbuntu | Select-Object -First 1

if ($SkipIsoUpdate) {
    Write-Host "  -SkipIsoUpdate specified, using local ISOs only." -ForegroundColor Yellow
}
else {
    $RemoteIso = Get-LatestRemoteIso

    if (-not $RemoteIso) {
        Write-Host "  Version check failed - continuing with local ISOs." -ForegroundColor Yellow
    }
    else {
        $RemoteVer = Get-IsoVersion $RemoteIso
        $LocalVer  = if ($LocalNewest) { Get-IsoVersion $LocalNewest.Name } else { $null }
        $Target    = Join-Path $ISOPath $RemoteIso

        Write-Host "  Latest available: $RemoteIso"
        if ($LocalVer) { Write-Host "  Newest local:     $($LocalNewest.Name)" }
        else           { Write-Host "  Newest local:     (none)" }

        if ($LocalVer -and $LocalVer -ge $RemoteVer -and (Test-Path $Target)) {
            Write-Host "  Already current - no download needed." -ForegroundColor Green
        }
        else {
            if ($LocalVer -and $LocalVer -lt $RemoteVer) {
                Write-Host "  Newer point release found - downloading." -ForegroundColor Yellow
            }

            # Rough free-space sanity check (Ubuntu desktop images run ~6 GB)
            $drive = (Get-Item $ISOPath).PSDrive
            if ($drive.Free -and $drive.Free -lt 10GB) {
                Write-Host "  Only $([math]::Round($drive.Free/1GB,1))GB free on $($drive.Name): - aborting." -ForegroundColor Red
                exit 1
            }

            Write-Host "  Downloading $RemoteIso (this takes a while)..." -ForegroundColor Cyan
            try {
                Invoke-IsoDownload -Url "$UbuntuBaseUrl/$RemoteIso" -Destination $Target
            }
            catch {
                Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
                if (-not $LocalNewest) { exit 1 }
                Write-Host "  Falling back to existing local ISOs." -ForegroundColor Yellow
            }

            if ((Test-Path $Target) -and -not $SkipHashCheck) {
                Write-Host "  Verifying SHA256..." -ForegroundColor Cyan
                $expected = Get-PublishedHash -FileName $RemoteIso
                if (-not $expected) {
                    Write-Host "  Could not retrieve SHA256SUMS - skipping verification." -ForegroundColor Yellow
                }
                else {
                    $actual = (Get-FileHash -Path $Target -Algorithm SHA256).Hash
                    if ($actual -ieq $expected) {
                        Write-Host "  Hash OK." -ForegroundColor Green
                    }
                    else {
                        Write-Host "  HASH MISMATCH - deleting corrupt download." -ForegroundColor Red
                        Remove-Item $Target -Force
                        exit 1
                    }
                }
            }
        }
    }
}

# =============================================================================
# GATHER USER INPUT
# =============================================================================

$VMName     = Read-Host "`nVM Name"
$MemoryGB   = [int](Read-Host "Memory (GB)")
$CPUCount   = [int](Read-Host "CPU Count")
$DiskSizeGB = [int](Read-Host "Disk Size (GB)")

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "A VM named '$VMName' already exists." -ForegroundColor Red
    exit 1
}

# =============================================================================
# ISO SELECTION
# =============================================================================

$ISOs = @(Get-ChildItem -Path (Join-Path $ISOPath "*.iso") -ErrorAction SilentlyContinue |
          Sort-Object Name | Select-Object -ExpandProperty Name)

if ($ISOs.Count -eq 0) {
    Write-Host "No ISO files found in $ISOPath" -ForegroundColor Red
    exit 1
}

# Default to the newest Ubuntu image so you can just hit Enter
$DefaultIndex = 0
$NewestUbuntu = $ISOs | Where-Object { $_ -match $IsoNameRegex } |
                Sort-Object { Get-IsoVersion $_ } -Descending | Select-Object -First 1
if ($NewestUbuntu) { $DefaultIndex = [array]::IndexOf($ISOs, $NewestUbuntu) }

Write-Host "`nAvailable ISOs:"
for ($i = 0; $i -lt $ISOs.Count; $i++) {
    $tag = if ($i -eq $DefaultIndex) { " (default)" } else { "" }
    Write-Host "$($i + 1). $($ISOs[$i])$tag"
}

$answer = Read-Host "`nSelect ISO number [$($DefaultIndex + 1)]"
if ([string]::IsNullOrWhiteSpace($answer)) {
    $ISOIndex = $DefaultIndex
}
else {
    $ISOIndex = [int]$answer - 1
}

if ($ISOIndex -lt 0 -or $ISOIndex -ge $ISOs.Count) {
    Write-Host "Invalid ISO selection" -ForegroundColor Red
    exit 1
}
$SelectedISO = Join-Path $ISOPath $ISOs[$ISOIndex]

# =============================================================================
# NETWORK SWITCH SELECTION
# =============================================================================

$Switches = @(Get-VMSwitch | Select-Object -ExpandProperty Name)

if ($Switches.Count -eq 0) {
    Write-Host "No virtual switches found" -ForegroundColor Red
    exit 1
}

Write-Host "`nAvailable Network Switches:"
for ($i = 0; $i -lt $Switches.Count; $i++) {
    Write-Host "$($i + 1). $($Switches[$i])"
}

$SwitchIndex = [int](Read-Host "`nSelect Network Switch number") - 1
if ($SwitchIndex -lt 0 -or $SwitchIndex -ge $Switches.Count) {
    Write-Host "Invalid switch selection" -ForegroundColor Red
    exit 1
}
$SwitchName = $Switches[$SwitchIndex]

# =============================================================================
# CREATE THE VM
# =============================================================================

New-VM -Name $VMName `
       -MemoryStartupBytes ($MemoryGB * 1GB) `
       -Generation 2 `
       -Path $VMRoot `
       -SwitchName $SwitchName | Out-Null

Set-VM -Name $VMName `
       -ProcessorCount $CPUCount `
       -StaticMemory `
       -AutomaticStartAction Start `
       -AutomaticStopAction ShutDown `
       -CheckpointType Disabled

# =============================================================================
# CREATE AND ATTACH STORAGE
# =============================================================================

$VHDFolder = Join-Path $VMRoot "$VMName\Virtual Hard Disks"
if (-not (Test-Path $VHDFolder)) {
    New-Item -Path $VHDFolder -ItemType Directory -Force | Out-Null
}
$VHDPath = Join-Path $VHDFolder "$VMName.vhdx"

New-VHD -Path $VHDPath `
        -SizeBytes ($DiskSizeGB * 1GB) `
        -Dynamic | Out-Null

Add-VMHardDiskDrive -VMName $VMName `
                    -ControllerType SCSI `
                    -ControllerNumber 0 `
                    -ControllerLocation 0 `
                    -Path $VHDPath

# =============================================================================
# ATTACH ISO AND CONFIGURE BOOT
# =============================================================================

Add-VMDvdDrive -VMName $VMName `
               -ControllerNumber 0 `
               -ControllerLocation 1 `
               -Path $SelectedISO

$DVDDrive = Get-VMDvdDrive -VMName $VMName

Set-VMFirmware -VMName $VMName `
               -EnableSecureBoot Off `
               -FirstBootDevice $DVDDrive

# =============================================================================
# ENABLE INTEGRATION SERVICES
# =============================================================================

Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

# =============================================================================
# OUTPUT SUMMARY
# =============================================================================

Write-Host "`nVM '$VMName' created successfully!" -ForegroundColor Green
Write-Host "  Memory:  $($MemoryGB)GB (Static)" -ForegroundColor Cyan
Write-Host "  CPUs:    $CPUCount" -ForegroundColor Cyan
Write-Host "  Disk:    $($DiskSizeGB)GB (Dynamic)" -ForegroundColor Cyan
Write-Host "  ISO:     $($ISOs[$ISOIndex])" -ForegroundColor Cyan
Write-Host "  Network: $SwitchName" -ForegroundColor Cyan
Write-Host "  Path:    $VMRoot\$VMName" -ForegroundColor Cyan
Write-Host "  On host start: Always Start" -ForegroundColor Cyan
Write-Host "  On host stop:  Shut Down" -ForegroundColor Cyan
