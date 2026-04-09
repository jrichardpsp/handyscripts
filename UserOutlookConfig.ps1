<#
.SYNOPSIS
    Injects Office and Outlook configuration registry keys into all user hives on the local machine.

.DESCRIPTION
    Designed to run as SYSTEM (e.g., via Intune, SCCM, or a startup script) before
    user login. It will:
      1. Load each user's registry hive (NTUSER.DAT) if not already loaded.
      2. Ensure the destination Office registry paths exist.
      3. Inject DisableAccountDetection (REG_DWORD) = 1
      4. Inject DisableOutlookMobileHyperlink (REG_DWORD) = 1
      5. Inject SetupOutlookMobileWebPageOpened (REG_DWORD) = 0
      6. Unload any hives that were temporarily loaded.
      7. Log all actions to C:\Windows\Logs\OfficeConfigDeploy.log
#>

[CmdletBinding(SupportsShouldProcess)]
param ()

#region --- Configuration ---
$LogFile  = "C:\Windows\Logs\OfficeConfigDeploy.log"
$HivesLoaded = [System.Collections.Generic.List[string]]::new()
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

#region --- Registry Helpers ---
function Mount-UserHive {
    param([string]$SID, [string]$NTUserDatPath)
    $mountPoint = "HKU\$SID"
    if (Test-Path "Registry::HKEY_USERS\$SID") {
        Write-Log "Hive already loaded for SID $SID  -  skipping mount."
        return $false   # caller should NOT unload this
    }
    Write-Log "Loading hive: $NTUserDatPath -> $mountPoint"
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

function Set-OfficeRegistryKeys {
    param([string]$SID)
    
    $success = $true

    # 1. Disable Account Detection
    $setupPath = "Registry::HKEY_USERS\$SID\Software\Microsoft\Office\16.0\Outlook\Setup"
    try {
        if (-not (Test-Path $setupPath)) {
            Write-Log "  Creating registry path: $setupPath"
            if ($PSCmdlet.ShouldProcess($setupPath, "Create registry path")) {
                New-Item -Path $setupPath -Force -ErrorAction Stop | Out-Null
            }
        }

        Write-Log "  Setting DisableAccountDetection = 1"
        if ($PSCmdlet.ShouldProcess($setupPath, "Set DisableAccountDetection")) {
            New-ItemProperty -Path $setupPath -Name "DisableAccountDetection" -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log "  ERROR setting DisableAccountDetection for SID $(SID): $_" -Level ERROR
        $success = $false
    }

    # 2. Disable Outlook Mobile Hyperlink
    $generalPath = "Registry::HKEY_USERS\$SID\Software\Microsoft\Office\16.0\Outlook\Options\General"
    try {
        if (-not (Test-Path $generalPath)) {
            Write-Log "  Creating registry path: $generalPath"
            if ($PSCmdlet.ShouldProcess($generalPath, "Create registry path")) {
                New-Item -Path $generalPath -Force -ErrorAction Stop | Out-Null
            }
        }

        Write-Log "  Setting DisableOutlookMobileHyperlink = 1"
        if ($PSCmdlet.ShouldProcess($generalPath, "Set DisableOutlookMobileHyperlink")) {
            New-ItemProperty -Path $generalPath -Name "DisableOutlookMobileHyperlink" -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log "  ERROR setting DisableOutlookMobileHyperlink for SID $(SID): $_" -Level ERROR
        $success = $false
    }

    # 3. Disable Outlook Mobile Setup Web Page
    try {
        if (-not (Test-Path $setupPath)) {
            Write-Log "  Creating registry path: $setupPath"
            if ($PSCmdlet.ShouldProcess($setupPath, "Create registry path")) {
                New-Item -Path $setupPath -Force -ErrorAction Stop | Out-Null
            }
        }

        Write-Log "  Setting SetupOutlookMobileWebPageOpened = 0"
        if ($PSCmdlet.ShouldProcess($setupPath, "Set SetupOutlookMobileWebPageOpened")) {
            New-ItemProperty -Path $setupPath -Name "SetupOutlookMobileWebPageOpened" -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
        
    } catch {
        Write-Log "  ERROR setting SetupOutlookMobileWebPageOpened for SID $(SID): $_" -Level ERROR
        $success = $false
    }

    return $success
}
#endregion

#region --- Transcript ---
$TranscriptPath = "C:\Temp\OfficeConfigDeploy_Transcript.log"
if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
}
Start-Transcript -Path $TranscriptPath -Append
#endregion

#region --- Main ---
Write-Log "========================================================"
Write-Log "Office Configuration Deployment started."
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# Require SYSTEM / admin
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Script must run as Administrator or SYSTEM. Exiting." -Level ERROR
    exit 1
}

# Enumerate local user profiles from the registry
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profiles = Get-ChildItem -Path $profileListPath | Where-Object {
    # Filter to real user SIDs (S-1-5-21-...)  -  skip service/system accounts
    $_.PSChildName -match '^S-1-5-21-'
}

Write-Log "Found $($profiles.Count) user profile(s) to process."

foreach ($profile in $profiles) {
    $sid         = $profile.PSChildName
    $profilePath = (Get-ItemProperty -Path $profile.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath

    if (-not $profilePath) {
        Write-Log "Could not determine profile path for SID $sid  -  skipping." -Level WARN
        continue
    }

    $ntUserDat = Join-Path $profilePath "NTUSER.DAT"
    Write-Log "Processing SID: $sid  |  Profile: $profilePath"

    if (-not (Test-Path $ntUserDat)) {
        Write-Log "  NTUSER.DAT not found at $ntUserDat  -  skipping." -Level WARN
        continue
    }

    $didMount = Mount-UserHive -SID $sid -NTUserDatPath $ntUserDat

    # Execute modifications
    $result = Set-OfficeRegistryKeys -SID $sid

    if ($didMount) {
        Dismount-UserHive -SID $sid
    }
}

Write-Log "Office Configuration Deployment complete."
Write-Log "========================================================"

Stop-Transcript
#endregion