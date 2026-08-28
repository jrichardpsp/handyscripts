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

    Must run as SYSTEM (PSP invokes it that way). An elevated administrator
    session is NOT sufficient: SystemSettingsAdminFlows will not enable
    Location services and netsh withholds the SSID. The script refuses to
    run as anything else. For manual testing use: psexec -s -i powershell.exe

    netsh withholds the SSID and profile name unless Windows Location services
    are enabled (even for SYSTEM). The script enables them for the duration of
    the run and restores the original setting on exit. Use -SkipLocationCheck
    where Location is managed by something else.

.NOTES
    netsh text parsing assumes English-language Windows.
#>

[CmdletBinding()]
param(
    [string]$LogDirectory = 'C:\temp\psp',
    # Set when another process already manages Location services on the
    # device; the script will then neither enable nor restore them.
    [switch]$SkipLocationCheck
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
function Test-IsSystem {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ($id.User.Value -eq 'S-1-5-18')
}

# Pulls the value to the right of the first colon for a matching label line.
function Get-NetshValue {
    param(
        [AllowEmptyString()] [AllowNull()] [string[]]$Text,
        [Parameter(Mandatory)] [string]$Label
    )
    # netsh output always contains blank lines; Mandatory on a string[] would
    # reject the whole array for that, so the empty-input check is done here.
    if (-not $Text) { return $null }
    $match = $Text | Select-String -Pattern ("^\s*{0}\s*:\s*(.+)$" -f [regex]::Escape($Label)) |
             Select-Object -First 1
    if ($match) { return $match.Matches.Groups[1].Value.Trim() }
    return $null
}

# netsh lists every wireless adapter as its own block starting with a "Name :"
# line. Pick the one that is connected so a second adapter (USB dongle, Wi-Fi
# Direct virtual adapter) does not shadow the real one.
function Select-ConnectedInterfaceBlock {
    param([string[]]$Lines)
    $blocks  = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*Name\s*:') {
            $current = New-Object System.Collections.Generic.List[string]
            $blocks.Add($current)
        }
        if ($null -ne $current) { $current.Add($line) }
    }
    if ($blocks.Count -eq 0) { return $Lines }
    foreach ($b in $blocks) {
        if ((Get-NetshValue -Text $b -Label 'State') -match '^connected$') { return [string[]]$b }
    }
    return [string[]]$blocks[0]
}

# --- Location services ---------------------------------------------------
# netsh withholds the SSID and profile name unless Location services are
# enabled - even for SYSTEM. The consent value below can be read reliably but
# not written, so SystemSettingsAdminFlows.exe is used to flip it. Only what
# this script changed is restored, and the restore runs on every exit path
# via the finally block around the main flow.
$LocationConsentPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$SysSettingsFlows    = Join-Path $env:SystemRoot 'System32\SystemSettingsAdminFlows.exe'

$script:LocationChangedByUs = $false
$script:LocationRestored    = $false

function Get-LocationConsent {
    try {
        $v = (Get-ItemProperty -Path $LocationConsentPath -Name Value -ErrorAction Stop).Value
        if ($v) { return $v }
    } catch { }
    return 'Deny'
}

function Enable-LocationForSsidRead {
    if ($SkipLocationCheck) {
        Write-Log "Location handling skipped (-SkipLocationCheck)."
        return
    }

    $original = Get-LocationConsent
    Write-Log "Location services currently: $original"

    if ($original -eq 'Allow') {
        Write-Log "Location already enabled. Nothing to change, nothing to restore."
        return
    }

    if (-not (Test-Path $SysSettingsFlows)) {
        Write-Log "$SysSettingsFlows not found. Cannot enable Location; the SSID read may fail." 'WARN'
        return
    }

    try {
        # Settings throws a prompt and goes semi-frozen if it is open on the
        # Location page while this runs. The change applies regardless.
        Stop-Process -Name SystemSettings -Force -ErrorAction SilentlyContinue

        & $SysSettingsFlows SetCamSystemGlobal location 1
        Start-Sleep -Seconds 3

        if ((Get-LocationConsent) -eq 'Allow') {
            $script:LocationChangedByUs = $true
            Write-Log "Location services enabled for the SSID read. Will be restored to '$original' on exit." 'OK'
        } else {
            Write-Log "Location still not enabled after SetCamSystemGlobal." 'WARN'
        }
    } catch {
        Write-Log "Unable to enable Location services: $($_.Exception.Message)" 'WARN'
    }
}

function Restore-LocationConsent {
    if (-not $script:LocationChangedByUs -or $script:LocationRestored) { return }
    $script:LocationRestored = $true

    if (-not (Test-Path $SysSettingsFlows)) {
        Write-Log "$SysSettingsFlows not found. Location left ENABLED on this device." 'WARN'
        return
    }

    try {
        Stop-Process -Name SystemSettings -Force -ErrorAction SilentlyContinue

        & $SysSettingsFlows SetCamSystemGlobal location 0
        Start-Sleep -Seconds 3

        Write-Log "Location services restored to Deny." 'OK'
    } catch {
        Write-Log "Unable to restore Location services: $($_.Exception.Message)" 'WARN'
        Write-Log "Location has been left ENABLED on this device." 'WARN'
    }
}

# --- Begin ---------------------------------------------------------------
Write-Log "Script started. Log file: $LogFile"
if ($LogDirectoryCreated) {
    Write-Log "Log directory did not exist and was created: $LogDirectory" 'OK'
} else {
    Write-Log "Log directory already exists: $LogDirectory"
}
# Enabling Location via SystemSettingsAdminFlows and reading the SSID from
# netsh both only work as SYSTEM - an elevated administrator is not enough.
# PSP runs this script as SYSTEM; for manual testing use psexec -s.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if (Test-IsSystem) {
    Write-Log "Running as SYSTEM ($identity)." 'OK'
} else {
    Write-Log "Running as '$identity', not SYSTEM. Location services cannot be enabled and netsh will withhold the SSID." 'ERROR'
    Write-Log "Run this script as SYSTEM (PSP does this; for testing use: psexec -s -i powershell.exe)." 'ERROR'
    Write-Log "Script finished. No changes made."
    return
}

# Enable Location before any SSID read; restored in the finally block below.
Enable-LocationForSsidRead

try {
    # --- Step 1: find the connected profile ----------------------------------
    Write-Log "Querying connected Wi-Fi interface."
    $interfaceText = netsh wlan show interfaces
    if ($LASTEXITCODE -ne 0 -or -not $interfaceText) {
        Write-Log "netsh wlan show interfaces failed (exit $LASTEXITCODE): $interfaceText" 'ERROR'
        Write-Log "Script finished."
        return
    }

    $interfaceText = Select-ConnectedInterfaceBlock -Lines $interfaceText
    $state       = Get-NetshValue -Text $interfaceText -Label 'State'
    $profileName = Get-NetshValue -Text $interfaceText -Label 'Profile'
    $ssid        = Get-NetshValue -Text $interfaceText -Label 'SSID'
    $ifaceName   = Get-NetshValue -Text $interfaceText -Label 'Name'

    if ($state -match '^connected$' -and -not $profileName) {
        Write-Log "Interface is connected but netsh withheld the SSID and profile name." 'ERROR'
        Write-Log "Windows hides these from netsh when Location services are off. This script tried to enable them (see above); check for a Location policy on this device." 'ERROR'
        Write-Log "Script finished."
        return
    }

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
        # netsh reports errors on stdout, but if it ever writes to stderr the 2>&1
        # combined with $ErrorActionPreference = Stop would terminate the script on
        # PS 5.1 before the exit code is logged. Catch that and carry on.
        try {
            $setOutput = netsh wlan set profileparameter name="$profileName" connectionmode=auto 2>&1
            $exitCode  = $LASTEXITCODE
        } catch {
            $setOutput = $_.Exception.Message
            $exitCode  = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
        }
        Write-Log "netsh output: $setOutput"

        if ($exitCode -ne 0) {
            Write-Log "netsh returned exit code $exitCode. The change may not have applied." 'ERROR'
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
            Write-Log "Auto-connect is still NOT enabled. Check the netsh output above." 'WARN'
        }
    }

    Write-Log "Script finished. Log: $LogFile  State: $StateFile" 'OK'
} finally {
    Restore-LocationConsent
}
