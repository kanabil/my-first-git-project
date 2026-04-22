[CmdletBinding()]
param(
    [ValidateSet("Monitor", "Once", "Apply", "Status")]
    [string]$Mode = "Monitor",

    # Apply mode: explicit policy to apply
    [string]$PolicyPath,

    # Automatic switching
    [string]$VmwareRunningPolicyPath,
    [string]$VmwareStoppedPolicyPath,

    # Monitoring behavior
    [int]$IntervalSeconds = 5,
    [string[]]$VmwareProcessNames = @(
        "vmware",
        "vmware-vmx",
        "vmware-tray",
        "vmware-authdconsole"
    ),

    # Policy application behavior
    [switch]$Merge,
    [switch]$StartAppIdSvc,
    [switch]$LoopForever = $true,

    # Logging
    [string]$LogPath = "$env:ProgramData\VmwareGamePolicyGuard\guard.log",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    $logDir = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -LiteralPath $LogPath -Value $line

    if (-not $Quiet) {
        switch ($Level) {
            "ERROR" { Write-Error $Message }
            "WARN"  { Write-Warning $Message }
            default { Write-Host $Message }
        }
    }
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-AppLockerCmdlets {
    if (-not (Get-Command -Name Set-AppLockerPolicy -ErrorAction SilentlyContinue)) {
        throw "Set-AppLockerPolicy cmdlet not found. AppLocker PowerShell cmdlets are unavailable on this system."
    }
}

function Ensure-AppIdService {
    param([switch]$TryStart)

    $svc = Get-Service -Name "AppIDSvc" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Application Identity service (AppIDSvc) was not found." "WARN"
        return
    }

    if ($TryStart) {
        if ($svc.StartType -eq "Disabled") {
            Set-Service -Name "AppIDSvc" -StartupType Manual
            Write-Log "Changed AppIDSvc startup type to Manual."
        }

        if ($svc.Status -ne "Running") {
            Start-Service -Name "AppIDSvc"
            Write-Log "Started AppIDSvc."
        }
    }
    else {
        Write-Log "AppIDSvc status: $($svc.Status), startup type: $($svc.StartType)"
    }
}

function Resolve-FullPathOrThrow {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-VmwareRunningState {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    return $false
}

function Get-PolicyFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-FullPathOrThrow -Path $Path
    $hash = Get-FileHash -LiteralPath $resolved -Algorithm SHA256
    return $hash.Hash
}

function Get-StateFilePath {
    $dir = "$env:ProgramData\VmwareGamePolicyGuard"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir "last-state.json"
}

function Read-LastState {
    $stateFile = Get-StateFilePath
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Failed to read prior state file. A new one will be created." "WARN"
        return $null
    }
}

function Save-LastState {
    param(
        [bool]$VmwareRunning,
        [string]$AppliedPolicyPath,
        [string]$AppliedPolicyHash
    )

    $state = [pscustomobject]@{
        Timestamp         = (Get-Date).ToString("o")
        VmwareRunning     = $VmwareRunning
        AppliedPolicyPath = $AppliedPolicyPath
        AppliedPolicyHash = $AppliedPolicyHash
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath (Get-StateFilePath) -Encoding UTF8
}

function Apply-AppLockerPolicyFile {
    param(
        [Parameter(Mandatory)][string]$XmlPolicyPath,
        [switch]$UseMerge
    )

    $resolvedPolicy = Resolve-FullPathOrThrow -Path $XmlPolicyPath

    Write-Log "Applying AppLocker policy: $resolvedPolicy"

    if ($UseMerge) {
        Set-AppLockerPolicy -XmlPolicy $resolvedPolicy -Merge
        Write-Log "Policy merged successfully."
    }
    else {
        Set-AppLockerPolicy -XmlPolicy $resolvedPolicy
        Write-Log "Policy applied successfully."
    }

    return $resolvedPolicy
}

function Invoke-AutoSwitch {
    param(
        [Parameter(Mandatory)][string]$RunningPolicy,
        [Parameter(Mandatory)][string]$StoppedPolicy,
        [switch]$UseMerge
    )

    $runningPolicyResolved = Resolve-FullPathOrThrow -Path $RunningPolicy
    $stoppedPolicyResolved = Resolve-FullPathOrThrow -Path $StoppedPolicy

    $runningHash = Get-PolicyFingerprint -Path $runningPolicyResolved
    $stoppedHash = Get-PolicyFingerprint -Path $stoppedPolicyResolved

    $vmwareRunning = Get-VmwareRunningState -Names $VmwareProcessNames
    $targetPolicy = if ($vmwareRunning) { $runningPolicyResolved } else { $stoppedPolicyResolved }
    $targetHash   = if ($vmwareRunning) { $runningHash } else { $stoppedHash }

    $lastState = Read-LastState

    $mustApply = $true
    if ($lastState) {
        if (($lastState.VmwareRunning -eq $vmwareRunning) -and
            ($lastState.AppliedPolicyHash -eq $targetHash) -and
            ($lastState.AppliedPolicyPath -eq $targetPolicy)) {
            $mustApply = $false
        }
    }

    if ($mustApply) {
        $applied = Apply-AppLockerPolicyFile -XmlPolicyPath $targetPolicy -UseMerge:$UseMerge
        Save-LastState -VmwareRunning:$vmwareRunning -AppliedPolicyPath $applied -AppliedPolicyHash $targetHash

        if ($vmwareRunning) {
            Write-Log "VMware is running. Applied BLOCK/SAFE policy."
        }
        else {
            Write-Log "VMware is not running. Applied NORMAL/ALLOW policy."
        }
    }
    else {
        if ($vmwareRunning) {
            Write-Log "VMware is running. BLOCK/SAFE policy already active; no change needed."
        }
        else {
            Write-Log "VMware is not running. NORMAL/ALLOW policy already active; no change needed."
        }
    }
}

# --- main ---

if (-not (Test-IsAdministrator)) {
    throw "This script must be run as Administrator."
}

Ensure-AppLockerCmdlets

if ($StartAppIdSvc) {
    Ensure-AppIdService -TryStart
}
else {
    Ensure-AppIdService
}

switch ($Mode) {
    "Apply" {
        if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
            throw "Mode=Apply requires -PolicyPath."
        }

        $applied = Apply-AppLockerPolicyFile -XmlPolicyPath $PolicyPath -UseMerge:$Merge
        $hash = Get-PolicyFingerprint -Path $applied
        Save-LastState -VmwareRunning:(Get-VmwareRunningState -Names $VmwareProcessNames) -AppliedPolicyPath $applied -AppliedPolicyHash $hash
        Write-Log "Done."
    }

    "Once" {
        if ([string]::IsNullOrWhiteSpace($VmwareRunningPolicyPath) -or [string]::IsNullOrWhiteSpace($VmwareStoppedPolicyPath)) {
            throw "Mode=Once requires both -VmwareRunningPolicyPath and -VmwareStoppedPolicyPath."
        }

        Invoke-AutoSwitch -RunningPolicy $VmwareRunningPolicyPath -StoppedPolicy $VmwareStoppedPolicyPath -UseMerge:$Merge
    }

    "Monitor" {
        if ([string]::IsNullOrWhiteSpace($VmwareRunningPolicyPath) -or [string]::IsNullOrWhiteSpace($VmwareStoppedPolicyPath)) {
            throw "Mode=Monitor requires both -VmwareRunningPolicyPath and -VmwareStoppedPolicyPath."
        }

        do {
            try {
                Invoke-AutoSwitch -RunningPolicy $VmwareRunningPolicyPath -StoppedPolicy $VmwareStoppedPolicyPath -UseMerge:$Merge
            }
            catch {
                Write-Log $_.Exception.Message "ERROR"
            }

            Start-Sleep -Seconds $IntervalSeconds
        } while ($LoopForever)
    }

    "Status" {
        $vmwareRunning = Get-VmwareRunningState -Names $VmwareProcessNames
        $lastState = Read-LastState

        $status = [pscustomobject]@{
            VmwareRunning           = $vmwareRunning
            VmwareProcessNames      = ($VmwareProcessNames -join ", ")
            LastAppliedPolicyPath   = if ($lastState) { $lastState.AppliedPolicyPath } else { $null }
            LastAppliedPolicyHash   = if ($lastState) { $lastState.AppliedPolicyHash } else { $null }
            LastDecisionTimestamp   = if ($lastState) { $lastState.Timestamp } else { $null }
            LogPath                 = $LogPath
        }

        $status | Format-List | Out-String | Write-Host
    }
}
