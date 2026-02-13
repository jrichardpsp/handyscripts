<#
.SYNOPSIS
    Uninstalls the SCCM/ConfigMgr client from a Windows system.

.DESCRIPTION
    This script removes the Microsoft System Center Configuration Manager (SCCM) client
    by executing ccmsetup.exe /uninstall and monitoring the uninstall process until completion.

    The script provides detailed progress logging with stage-aware status messages:
    - Phase 1: Service stopping
    - Phase 2: File cleanup
    - Phase 3: Complete removal

    Designed to run as SYSTEM in enterprise deployment scenarios (Intune, GPO, etc.).
    Compatible with PowerShell 5.1+.

.PARAMETER LogPath
    Path to the log file where uninstall progress will be recorded.
    Default: C:\Temp\UninstallSCCM.log

.PARAMETER TimeoutSeconds
    Maximum time (in seconds) to wait for uninstall completion per attempt.
    Default: 300 (5 minutes)

.PARAMETER PollIntervalSeconds
    How often (in seconds) to check uninstall progress during the wait loop.
    Default: 10

.PARAMETER MaxAttempts
    Number of times to retry the uninstall if it doesn't complete within the timeout.
    Default: 2

.EXAMPLE
    .\Uninstall-SCCMClient.ps1
    Runs with default parameters.

.EXAMPLE
    .\Uninstall-SCCMClient.ps1 -TimeoutSeconds 600 -MaxAttempts 3
    Increases timeout to 10 minutes and allows up to 3 attempts.

.EXAMPLE
    .\Uninstall-SCCMClient.ps1 -LogPath "C:\Logs\SCCM_Removal.log"
    Uses a custom log file path.

.NOTES
    Author: System Administrator
    Requires: PowerShell 5.1+, Administrative privileges
    Exit Codes:
        0 = Success or SCCM not installed
        1 = Failed to start uninstall process
        2 = Uninstall did not complete within timeout/attempts

.LINK
    https://docs.microsoft.com/en-us/mem/configmgr/core/clients/deploy/uninstall-client
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$LogPath = 'C:\Temp\UninstallSCCM.log',

    [Parameter()]
    [int]$TimeoutSeconds = 300,

    [Parameter()]
    [int]$PollIntervalSeconds = 10,

    [Parameter()]
    [int]$MaxAttempts = 2
)

$ErrorActionPreference = 'Stop'
$TempDir = Split-Path -Parent $LogPath

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERR','OK')][string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "{0} [{1}] {2}" -f $ts, $Level, $Message

    # Console
    Write-Host $line

    # File
    try {
        if (-not (Test-Path $TempDir)) {
            New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $line
    } catch {
        Write-Host ("{0} [ERR] Failed to write log file: {1}" -f $ts, $_.Exception.Message)
    }
}

function Get-SCCMInstallState {
    <#
    .SYNOPSIS
        Returns detailed state of SCCM installation components
    .OUTPUTS
        PSCustomObject with ServiceExists, CCMExists, CCMSetupExists, IsInstalled properties
    #>

    $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
    $ccmPath = Test-Path 'C:\Windows\CCM'
    $ccmSetupPath = Test-Path 'C:\Windows\CCMSetup'

    $state = [PSCustomObject]@{
        ServiceExists    = ($null -ne $svc)
        ServiceStatus    = if ($svc) { $svc.Status } else { 'NotFound' }
        CCMExists        = $ccmPath
        CCMSetupExists   = $ccmSetupPath
        IsInstalled      = ($null -ne $svc) -or $ccmPath -or $ccmSetupPath
    }

    return $state
}

function Test-SCCMInstalled {
    $state = Get-SCCMInstallState
    return $state.IsInstalled
}

function Start-SCCMUninstall {
    $ccmsetup = Join-Path $env:windir 'ccmsetup\ccmsetup.exe'

    if (-not (Test-Path $ccmsetup)) {
        throw "ccmsetup.exe not found at: $ccmsetup"
    }

    Write-Log "Starting SCCM uninstall: `"$ccmsetup`" /uninstall" "INFO"

    # Kick off uninstall (do not wait)
    $p = Start-Process -FilePath $ccmsetup -ArgumentList '/uninstall' -PassThru -WindowStyle Hidden

    Write-Log "Uninstall process started. PID=$($p.Id)" "INFO"
    return $p
}

function Wait-SCCMUninstall {
    param(
        [Parameter(Mandatory=$true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory=$true)]
        [int]$PollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds

        # Get detailed state
        $state = Get-SCCMInstallState

        # Fully uninstalled - success
        if (-not $state.IsInstalled) {
            Write-Log "SCCM client fully removed." "OK"
            return $true
        }

        # Check ccmsetup process
        $ccmsetupProc = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
        $procState = if ($ccmsetupProc) { 'Running' } else { 'NotRunning' }

        $remaining = [int]([Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds))

        # Build detailed status message
        if ($state.ServiceExists) {
            # Service still exists - early stage
            Write-Log "Waiting... Service=CcmExec:$($state.ServiceStatus) | CCM=$($state.CCMExists) | CCMSetup=$($state.CCMSetupExists) | Process=ccmsetup:$procState | Remaining=${remaining}s" "INFO"
        }
        else {
            # Service is gone, but files remain - later stage
            if ($state.CCMExists -or $state.CCMSetupExists) {
                Write-Log "Service removed. Waiting for file cleanup... CCM=$($state.CCMExists) | CCMSetup=$($state.CCMSetupExists) | Process=ccmsetup:$procState | Remaining=${remaining}s" "INFO"
            }
        }
    }

    # Timeout - log final state
    $finalState = Get-SCCMInstallState
    Write-Log "Timeout reached. Final state: Service=$($finalState.ServiceExists) | CCM=$($finalState.CCMExists) | CCMSetup=$($finalState.CCMSetupExists)" "WARN"
    return $false
}

# ----------------- Main -----------------
Write-Log "==== SCCM Client Uninstall Start ====" "INFO"
Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" "INFO"
Write-Log "Log file: $LogPath" "INFO"

if (-not (Test-SCCMInstalled)) {
    Write-Log "SCCM client not detected. Nothing to uninstall." "OK"
    exit 0
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Log "Attempt $attempt of $MaxAttempts" "INFO"

    try {
        Start-SCCMUninstall | Out-Null
    } catch {
        Write-Log "Failed to start uninstall on attempt $($attempt): $($_.Exception.Message)" "ERR"
        if ($attempt -eq $MaxAttempts) { exit 1 }
        continue
    }

    $ok = Wait-SCCMUninstall -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollIntervalSeconds
    if ($ok) {
        Write-Log "SCCM uninstall completed successfully." "OK"
        exit 0
    }

    $timeoutMinutes = [math]::Round($TimeoutSeconds / 60, 1)
    Write-Log "Attempt $attempt did not complete within $timeoutMinutes minutes." "WARN"

    if ($attempt -lt $MaxAttempts) {
        Write-Log "Retrying uninstall..." "WARN"
    }
}

Write-Log "SCCM client still detected after $MaxAttempts attempts. Failing." "ERR"
exit 2
