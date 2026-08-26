<#
.SYNOPSIS
    Inventories the currently connected Wi-Fi profile, records whether
    "Connect automatically" is enabled, saves that original state, then
    enables auto-connect.

.DESCRIPTION
    Uses netsh wlan to read and modify the per-profile connection mode.
    All activity is written to the console (color coded) and appended to a
    timestamped log file in C:\temp. The original state is also written to a
    JSON snapshot file in C:\temp so it can be reviewed or restored later.

    Reading the inventory works without elevation. Changing the profile
    parameter requires an elevated (Administrator) session. If the session is
    not elevated, the inventory still runs and the change attempt is logged.

.NOTES
    netsh text parsing assumes English-language Windows.
#>

[CmdletBinding()]
param(
    [string]$LogDirectory = 'C:\temp\psp'
)

$ErrorActionPreference = 'Stop'

# --- Paths ---------------------------------------------------------------
$runStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile   = Join-Path $LogDirectory "wifi-autoconnect-$runStamp.log"
$StateFile = Join-Path $LogDirectory "wifi-autoconnect-state-$runStamp.json"

$LogDirectoryCreated = $false
if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    $LogDirectoryCreated = $true
}

# --- Logging -------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'INFO'  { Write-Host $line -ForegroundColor Gray }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
    }
    Add-Content -Path $LogFile -Value $line
}

# --- Helpers -------------------------------------------------------------
function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Pulls the value to the right of the first colon for a matching label line.
function Get-NetshValue {
    param(
        [Parameter(Mandatory)] [string[]]$Text,
        [Parameter(Mandatory)] [string]$Label
    )
    $match = $Text | Select-String -Pattern ("^\s*{0}\s*:\s*(.+)$" -f [regex]::Escape($Label)) |
             Select-Object -First 1
    if ($match) { return $match.Matches.Groups[1].Value.Trim() }
    return $null
}

# --- Begin ---------------------------------------------------------------
Write-Log "Script started. Log file: $LogFile"
if ($LogDirectoryCreated) {
    Write-Log "Log directory did not exist and was created: $LogDirectory" 'OK'
} else {
    Write-Log "Log directory already exists: $LogDirectory"
}
$elevated = Test-IsElevated
if ($elevated) {
    Write-Log "Session is elevated (Administrator)." 'OK'
} else {
    Write-Log "Session is NOT elevated. Inventory will run, but setting the profile parameter will likely fail." 'WARN'
}

# --- Step 1: find the connected profile ----------------------------------
Write-Log "Querying connected Wi-Fi interface."
$interfaceText = netsh wlan show interfaces

$state       = Get-NetshValue -Text $interfaceText -Label 'State'
$profileName = Get-NetshValue -Text $interfaceText -Label 'Profile'
$ssid        = Get-NetshValue -Text $interfaceText -Label 'SSID'
$ifaceName   = Get-NetshValue -Text $interfaceText -Label 'Name'

if (-not $profileName -or ($state -and $state -notmatch 'connected')) {
    Write-Log "No connected Wi-Fi profile was found (State: '$state'). Nothing to do." 'WARN'
    Write-Log "Script finished."
    return
}

Write-Log "Connected interface : $ifaceName" 'OK'
Write-Log "Connected SSID      : $ssid"       'OK'
Write-Log "Active profile      : $profileName" 'OK'

# --- Step 2: read current auto-connect state -----------------------------
Write-Log "Reading current connection mode for profile '$profileName'."
$profileText  = netsh wlan show profile name="$profileName"
$originalMode = Get-NetshValue -Text $profileText -Label 'Connection mode'

if (-not $originalMode) {
    Write-Log "Could not determine the connection mode from netsh output." 'ERROR'
    return
}

# "Connect automatically" contains 'auto'; "Connect manually" contains 'manual'.
$originalAutoConnect = $originalMode -match 'auto'
Write-Log "Original connection mode : $originalMode"
Write-Log ("Original auto-connect    : {0}" -f $originalAutoConnect)

# --- Step 3: save original state snapshot --------------------------------
$snapshot = [pscustomobject]@{
    Timestamp              = (Get-Date).ToString('o')
    InterfaceName          = $ifaceName
    SSID                   = $ssid
    ProfileName            = $profileName
    OriginalConnectionMode = $originalMode
    OriginalAutoConnect    = $originalAutoConnect
}
$snapshot | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
Write-Log "Original state saved to: $StateFile" 'OK'

# --- Step 4: set auto-connect to true ------------------------------------
if ($originalAutoConnect) {
    Write-Log "Auto-connect is already enabled. No change needed." 'OK'
} else {
    Write-Log "Setting connection mode to auto for profile '$profileName'."
    $setOutput = netsh wlan set profileparameter name="$profileName" connectionmode=auto 2>&1
    $exitCode  = $LASTEXITCODE
    Write-Log "netsh output: $setOutput"

    if ($exitCode -ne 0) {
        Write-Log "netsh returned exit code $exitCode. The change may not have applied (elevation required)." 'ERROR'
    } else {
        Write-Log "netsh reported success applying the change." 'OK'
    }

    # --- Step 5: verify -------------------------------------------------
    Write-Log "Verifying new connection mode."
    $verifyText = netsh wlan show profile name="$profileName"
    $newMode    = Get-NetshValue -Text $verifyText -Label 'Connection mode'
    $newAuto    = $newMode -match 'auto'
    Write-Log "New connection mode : $newMode"
    Write-Log ("New auto-connect    : {0}" -f $newAuto)

    if ($newAuto) {
        Write-Log "Auto-connect is now ENABLED." 'OK'
    } else {
        Write-Log "Auto-connect is still NOT enabled. Re-run in an elevated session." 'WARN'
    }
}

Write-Log "Script finished. Log: $LogFile  State: $StateFile" 'OK'
