<#
.SYNOPSIS
    Removes all Outlook OST and NST files from every user profile on the local machine.

.DESCRIPTION
    Designed to run as SYSTEM (e.g., via Intune, SCCM, or a startup script).
    It will:
      1. Enumerate all real user profiles from the registry ProfileList.
      2. Load each user's registry hive (NTUSER.DAT) if not already loaded.
      3. Delete all subkeys under HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\.
      4. Search each profile's known Outlook data folder for *.ost and *.nst files.
      5. Delete any OST files found, logging each action.
      6. Unload any hives that were temporarily loaded.
      7. Log all actions to C:\Windows\Logs\RemoveOSTFiles.log

    NOTE: Run this at machine startup before user login to ensure OST files
    and profile hive keys are not locked by a running Outlook process.

.NOTES
    Supports -WhatIf to preview deletions without removing anything.
#>

[CmdletBinding(SupportsShouldProcess)]
param ()

#region --- Configuration ---
$LogFile = "C:\Windows\Logs\RemoveOSTFiles.log"

# Relative path within a user profile where Outlook stores OST files by default.
# Additional paths can be added to this array if needed.
$OSTSearchPaths = @(
    "AppData\Local\Microsoft\Outlook"
)
#endregion

#region --- Registry Helpers ---
function Mount-UserHive {
    param([string]$SID, [string]$NTUserDatPath)
    if (Test-Path "Registry::HKEY_USERS\$SID") {
        Write-Log "Hive already loaded for SID $SID  -  skipping mount."
        return $false   # caller should NOT unload this
    }
    Write-Log "Loading hive: $NTUserDatPath -> HKU\$SID"
    $result = & reg.exe load "HKU\$SID" "$NTUserDatPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to load hive for SID $SID. reg.exe output: $result" -Level WARN
        return $false
    }
    return $true
}

function Dismount-UserHive {
    param([string]$SID)
    Write-Log "Unloading hive for SID: $SID"
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    $result = & reg.exe unload "HKU\$SID" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to unload hive for SID $SID. reg.exe output: $result" -Level WARN
    }
}

function Remove-OutlookProfileKeys {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$SID)

    $profilesPath = "Registry::HKEY_USERS\$SID\Software\Microsoft\Office\16.0\Outlook\Profiles"

    if (-not (Test-Path $profilesPath)) {
        Write-Log "  Outlook Profiles registry key not found  -  skipping: $profilesPath"
        return
    }

    $profileKeys = Get-ChildItem -Path $profilesPath -ErrorAction SilentlyContinue
    if (-not $profileKeys) {
        Write-Log "  No Outlook profile subkeys found under $profilesPath"
        return
    }

    foreach ($key in $profileKeys) {
        Write-Log "  Removing Outlook profile key: $($key.PSChildName)"
        try {
            if ($PSCmdlet.ShouldProcess($key.PSPath, "Delete Outlook profile registry key")) {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "  Deleted registry key: $($key.PSChildName)"
            }
        } catch {
            Write-Log "  Failed to delete registry key $($key.PSChildName): $_" -Level ERROR
        }
    }
}
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

#region --- OST/NST Removal ---
function Remove-ProfileOSTFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ProfilePath
    )

    $removedCount = 0
    $failedCount  = 0

    foreach ($relPath in $OSTSearchPaths) {
        $ostFolder = Join-Path $ProfilePath $relPath

        if (-not (Test-Path $ostFolder)) {
            Write-Log "  Outlook folder not found, skipping: $ostFolder"
            continue
        }

        $ostFiles = Get-ChildItem -Path "$ostFolder\*" -Include '*.ost','*.nst' -File -ErrorAction SilentlyContinue

        if (-not $ostFiles) {
            Write-Log "  No OST/NST files found in: $ostFolder"
            continue
        }

        foreach ($file in $ostFiles) {
            Write-Log "  Removing: $($file.FullName) ($([math]::Round($file.Length / 1MB, 2)) MB)"
            try {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Delete OST/NST file")) {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    Write-Log "  Deleted: $($file.FullName)"
                    $removedCount++
                }
            } catch {
                Write-Log "  Failed to delete $($file.FullName): $_" -Level ERROR
                $failedCount++
            }
        }
    }

    return [PSCustomObject]@{ Removed = $removedCount; Failed = $failedCount }
}
#endregion

#region --- Transcript ---
$TranscriptPath = "C:\Windows\Logs\RemoveOSTFiles_Transcript.log"
Start-Transcript -Path $TranscriptPath -Append
#endregion

#region --- Main ---
Write-Log "========================================================"
Write-Log "OST File Removal started."
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# Require SYSTEM / admin
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Script must run as Administrator or SYSTEM. Exiting." -Level ERROR
    Stop-Transcript
    exit 1
}

# Enumerate local user profiles from the registry
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profiles = Get-ChildItem -Path $profileListPath | Where-Object {
    # Filter to real user SIDs (S-1-5-21-...)  -  skip service/system accounts
    $_.PSChildName -match '^S-1-5-21-'
}

Write-Log "Found $($profiles.Count) user profile(s) to process."

$totalRemoved = 0
$totalFailed  = 0

foreach ($profileEntry in $profiles) {
    $sid         = $profileEntry.PSChildName
    $profilePath = (Get-ItemProperty -Path $profileEntry.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath

    if (-not $profilePath) {
        Write-Log "Could not determine profile path for SID $sid  -  skipping." -Level WARN
        continue
    }

    if (-not (Test-Path $profilePath)) {
        Write-Log "Profile path does not exist: $profilePath  -  skipping." -Level WARN
        continue
    }

    $ntUserDat = Join-Path $profilePath "NTUSER.DAT"
    Write-Log "Processing SID: $sid  |  Profile: $profilePath"

    if (-not (Test-Path $ntUserDat)) {
        Write-Log "  NTUSER.DAT not found at $ntUserDat  -  skipping." -Level WARN
        continue
    }

    $didMount = Mount-UserHive -SID $sid -NTUserDatPath $ntUserDat

    # Remove Outlook profile registry keys
    Remove-OutlookProfileKeys -SID $sid

    # Remove OST files from the profile folder
    $result       = Remove-ProfileOSTFiles -ProfilePath $profilePath
    $totalRemoved += $result.Removed
    $totalFailed  += $result.Failed

    if ($didMount) {
        Dismount-UserHive -SID $sid
    }
}

Write-Log "OST/NST File Removal complete. Removed: $totalRemoved  |  Failed: $totalFailed"
Write-Log "========================================================"

Stop-Transcript
#endregion
 