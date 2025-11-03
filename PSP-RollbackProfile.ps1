<#
.SYNOPSIS
    Rolls back a Windows user profile registry mapping from a TargetSID to a SourceSID,
    and resets the PowerSyncPro Migration Agent state.

.DESCRIPTION
    This script is used when a user profile was migrated or re-permissioned to a new SID
    (for example, during a PowerSyncPro Migration Agent migration) and must be reverted back to
    the original SourceSID. It performs the following actions:

        1. Validates that the script is running with administrative rights.
        2. Confirms that the current user session is NOT associated with the TargetSID.
        3. Enumerates all profiles under HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
           and logs their associated usernames, SIDs, and profile paths for troubleshooting.
        4. Verifies that the TargetSID exists in the registry and the SourceSID does not.
        5. Renames the TargetSID registry key back to SourceSID and updates the binary SID value.
        6. Stops the "PowerSyncPro Migration Agent" service.
        7. Clears the Migration Agent working directory under:
               %ProgramData%\Declaration Software\Migration Agent
        8. Restarts the PowerSyncPro Migration Agent service.
        9. Logs all actions to a transcript file in C:\Temp for review.

    After rollback, the administrator should re-run the PowerSyncPro migration and attempt
    login with the account associated with the SourceSID.

    You can find the Source / Target SIDs in the translation table within PowerSyncPro Web Admin Panel at <PSP Server URL>/migrationAgent/CheckTranslationEntries

.PARAMETER SourceSID
    The original (pre-migration) Windows Security Identifier (SID) to restore the profile to.
    This can be found in the translation table at <PSP Server URL>/migrationAgent/CheckTranslationEntries

.PARAMETER TargetSID
    The current (migrated) SID that should be rolled back to the SourceSID.
    This can be found in the translation table at <PSP Server URL>/migrationAgent/CheckTranslationEntries

.NOTES
    Author: Jamie Richard / PowerSyncPro
    Script Name: PSP-RollbackProfile.ps1
    Requirements:
        - Must be run as Administrator
        - PowerShell 5.1 or later
        - Requires access to HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
    Output:
        Transcript log written to C:\Temp\PSP-RollbackProfile-<timestamp>.log
#>


param(
    [Parameter(Mandatory = $true)]
    [string] $SourceSid,

    [Parameter(Mandatory = $true)]
    [string] $TargetSid
)

# Console logger helpers
function _info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function _ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function _warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function _err($m)  { Write-Host "[-] $m" -ForegroundColor Red }

# Start transcript
$logDir = "C:\Temp"
if (-not (Test-Path -Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "PSP-RollbackProfile-$timeStamp.log"
Start-Transcript -Path $logFile -Force | Out-Null

try {
    _info "Starting PowerSyncPro profile rollback from TargetSid [$TargetSid] to SourceSid [$SourceSid]."

    # Elevation check
    $currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        _err "This script must be run as Administrator."
        throw "Not running as Administrator."
    }

    # Verify not running as TargetSID
    $currentSid = $currentIdentity.User.Value
    _info "Current process SID is [$currentSid]."
    if ($currentSid -eq $TargetSid) {
        _err "You are currently running this script under the TargetSid account. Log off that account and run this as a different user.  If you can login as the target user, you likely should not be running this script."
        throw "Cannot run while logged in as TargetSid."
    }

    # Enumerate existing profiles
    _info "Enumerating existing profile mappings..."
    $profileListBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $profiles = Get-ChildItem -Path $profileListBase -ErrorAction SilentlyContinue

    foreach ($p in $profiles) {
        try {
            $profilePath = (Get-ItemProperty -Path $p.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            $sidString = Split-Path $p.PSChildName -Leaf
            $userName = try { (New-Object System.Security.Principal.SecurityIdentifier($sidString)).Translate([System.Security.Principal.NTAccount]).Value } catch { "Unknown" }
            Write-Host ("    {0,-50} {1}" -f $userName, $sidString)
            _info "Profile: $userName | SID: $sidString | Path: $profilePath"
        } catch {
            _warn "Failed to enumerate a profile key: $($_.Exception.Message)"
        }
    }

    # Validate TargetSID presence
    $targetKeyPath = Join-Path $profileListBase $TargetSid
    $sourceKeyPath = Join-Path $profileListBase $SourceSid

    if (-not (Test-Path -Path $targetKeyPath)) {
        _err "ProfileList registry key for TargetSid [$TargetSid] does not exist: $targetKeyPath"
        throw "TargetSid profile key not found."
    }
    _ok "Found TargetSid profile key: $targetKeyPath"

    if (Test-Path -Path $sourceKeyPath) {
        _err "ProfileList key for SourceSid [$SourceSid] already exists: $sourceKeyPath"
        throw "SourceSid profile key already exists."
    }

    # Rename key back to SourceSID
    _info "Renaming ProfileList key from [$TargetSid] back to [$SourceSid]."
    Rename-Item -Path $targetKeyPath -NewName $SourceSid -ErrorAction Stop

    # Update binary Sid value
    _info "Updating binary Sid value to [$SourceSid]."
    $sidObj = New-Object System.Security.Principal.SecurityIdentifier($SourceSid)
    $sidBytes = New-Object byte[] ($sidObj.BinaryLength)
    $sidObj.GetBinaryForm($sidBytes, 0)
    Set-ItemProperty -Path $sourceKeyPath -Name "Sid" -Value $sidBytes -Type Binary -ErrorAction Stop
    _ok "ProfileList key updated successfully."

    # Handle PowerSyncPro Migration Agent
    $serviceName = "PowerSyncPro Migration Agent"
    $agentDataPath = Join-Path $env:ProgramData "Declaration Software\Migration Agent"

    _info "Stopping service [$serviceName]."
    try {
        $svc = Get-Service -Name $serviceName -ErrorAction Stop
        if ($svc.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            $svc.WaitForStatus("Stopped", (New-TimeSpan -Seconds 60))
        }
        _ok "Service [$serviceName] stopped."
    } catch {
        _warn "Could not stop service [$serviceName]. It may not exist or may already be stopped. Error: $($_.Exception.Message)"
    }

    # Clear data folder
    _info "Clearing Migration Agent data folder: $agentDataPath"
    if (Test-Path -Path $agentDataPath) {
        try {
            Remove-Item -Path $agentDataPath -Recurse -Force -ErrorAction Stop
            _ok "Cleared Migration Agent data folder."
        } catch {
            _warn "Failed to clear Migration Agent data folder. Error: $($_.Exception.Message)"
        }
    } else {
        _warn "Migration Agent data folder does not exist: $agentDataPath"
    }

    # Restart service
    _info "Starting service [$serviceName]."
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        _ok "Service [$serviceName] started successfully."
    } catch {
        _warn "Failed to start service [$serviceName]. Error: $($_.Exception.Message)"
    }

    _ok "Rollback complete."
    _info "Next steps:"
    _info "  1. Re run the PowerSyncPro migration for this device or user."
    _info "  2. Attempt login again with the SourceSid account [$SourceSid]."
    _info "Transcript log saved to: $logFile"
}
catch {
    _err "An error occurred: $($_.Exception.Message)"
    _info "See transcript log for details: $logFile"
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
