<#
.SYNOPSIS
    Removes Dropbox Cloud Files (SyncRootManager) registrations from the local
    machine as part of pre-migration cleanup.

.DESCRIPTION
    Designed to run as SYSTEM or Administrator (e.g., via Intune, SCCM, or a
    startup script) before migration. It will:
      1. Stop any running Dropbox process so its Cloud Files handles release.
      2. Enumerate the SyncRootManager registry key for Dropbox! registrations.
      3. Remove every matching SyncRoot registration (removes the Dropbox
         placeholder / On-Demand icons and shell integration left behind).
      4. Log all actions to C:\Windows\Logs\DropboxCleanup.log and a transcript
         to C:\Temp\DropboxCleanup.log.

    The SyncRootManager key lives at:
      HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager
    Dropbox registrations are keyed as "Dropbox!<...>".

    This script only removes registry registrations. It does not uninstall the
    Dropbox client or delete any user data / files on disk.

.NOTES
    Author : Jamie Richard - PowerSyncPro
    Runs as: SYSTEM or Administrator
    Safe to re-run (idempotent) - if nothing matches, it logs and exits 0.

.EXAMPLE
    .\DropboxCleanup.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param()

#region --- Configuration ---
$LogFile      = "C:\Windows\Logs\DropboxCleanup.log"
$SyncRootPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager"
#endregion

#region --- Logging ---
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        default { Write-Host $entry }
    }
}
#endregion

#region --- Transcript ---
$TranscriptPath = "C:\Temp\DropboxCleanup.log"
if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
}
Start-Transcript -Path $TranscriptPath -Append | Out-Null
#endregion

#region --- Main ---
Write-Log "========================================================"
Write-Log "Dropbox Cloud Files cleanup started."
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# Require SYSTEM / admin
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Script must run as Administrator or SYSTEM. Exiting." -Level ERROR
    Stop-Transcript | Out-Null
    exit 1
}

# 1. Stop Dropbox before removing its Cloud Files registrations
$dropboxProcs = Get-Process -Name 'Dropbox' -ErrorAction SilentlyContinue
if ($dropboxProcs) {
    Write-Log "Stopping $($dropboxProcs.Count) Dropbox process(es)."
    try {
        $dropboxProcs | Stop-Process -Force -ErrorAction Stop
        Write-Log "Dropbox process(es) stopped."
    } catch {
        Write-Log "Failed to stop one or more Dropbox processes: $_" -Level WARN
    }
} else {
    Write-Log "No running Dropbox process found."
}

# 2 & 3. Remove all Dropbox SyncRootManager registrations
$removed = 0
if (Test-Path -LiteralPath $SyncRootPath) {
    $dropboxRoots = Get-ChildItem -LiteralPath $SyncRootPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'Dropbox!*' }

    if ($dropboxRoots) {
        Write-Log "Found $($dropboxRoots.Count) Dropbox SyncRoot registration(s)."
        foreach ($root in $dropboxRoots) {
            Write-Log "  Removing SyncRoot: $($root.PSChildName)"
            if ($PSCmdlet.ShouldProcess($root.PSPath, "Remove registry key")) {
                try {
                    Remove-Item -LiteralPath $root.PSPath -Recurse -Force -ErrorAction Stop
                    $removed++
                    Write-Log "  Removed: $($root.PSChildName)"
                } catch {
                    Write-Log "  ERROR removing $($root.PSChildName): $_" -Level ERROR
                }
            }
        }
    } else {
        Write-Log "No Dropbox SyncRoot registrations found - nothing to remove."
    }
} else {
    Write-Log "SyncRootManager key not present: $SyncRootPath" -Level WARN
}

Write-Log "Removed $removed Dropbox SyncRoot registration(s)."
Write-Log "Dropbox Cloud Files cleanup complete."
Write-Log "========================================================"

Stop-Transcript | Out-Null
exit 0
#endregion
