# ==========================================================================
# PowerSyncPro Startup Wi-Fi Switch Script
#
# Purpose:
#   Runs at the start of a PSP migration, on machines that reach the network
#   over the corporate cert-based Wi-Fi. That network is unavailable to a
#   machine which is migrating, so the device is moved onto a temporary PSK network
#   before the migration proceeds. If it cannot be moved, the migration is
#   halted and the device is rolled back rather than left stranded.
#
# Flow:
#   - No WLAN service, no wireless adapter, or adapter disconnected -> exit 0
#     (assumed to be an Ethernet device; not our problem)
#   - A live default route on any non-wireless interface -> exit 0
#     (wired devices keep their path to PSP through the migration)
#   - Connected to something other than $CorporateSSID -> exit 0
#   - Connected to $CorporateSSID:
#       force a Wi-Fi scan and read the migration network's security settings
#       generate and import a matching WLAN profile
#       set it to top priority and auto-connect
#       connect, wait for association, then DHCP
#       read the PSP endpoint from the agent's registry and test reachability
#   - Any failure from that point -> Fail-Migration (see below)
#
# On failure:
#   PSP does not honour script exit codes, so exiting non-zero will not stop
#   the runbook. Fail-Migration instead: writes an IT-facing notice to the
#   console (which PSP copies into the agent log), stops and disables the
#   agent service, rolls back the changes PSP has already made, resets the
#   agent state so a restart begins a fresh migration, kills the tray app,
#   and shows the user a dialog.
#
# What PSP has already done by the time this script runs:
#   legal notice set, lock screen replaced, break-glass local admin created,
#   in-scope users blocked from logging in, BitLocker protectors disabled.
#   The rollback undoes all but the break-glass admin, which is deliberately
#   left in place as a recovery path.
#
# Notes:
#   - Runs as SYSTEM via the PSP Startup Package. Output goes to the PSP agent
#     log; a transcript is also written to $LogFile.
#   - Locale independent where it can be. Adapter identity and link state come
#     from Get-NetAdapter's numeric ifType and ifOperStatus enum rather than
#     netsh text, whose labels AND values are translated. netsh is still used
#     for the SSID and the network scan, where no cmdlet gives a correct
#     answer, but only standards names -- 'WPA2', 'WPA3', 'CCMP', 'SSID' --
#     are matched, never localised words such as 'Name', 'State' or
#     'connected'. See Get-WlanInterfaceInfo.
#   - Do NOT use Get-NetConnectionProfile to read the SSID. It returns the AD
#     domain on domain-authenticated networks, which is every device this
#     script targets. See Get-WlanInterfaceInfo.
#   - netsh only reports the SSID when Location services are enabled. The
#     script enables them itself (SystemSettingsAdminFlows.exe, since the
#     consent registry value cannot be written directly) and restores the
#     original state on exit. Set $DoNotRunLocationPrivacyCheck to $true
#     where another process manages Location on the device. See
#     Enable-LocationForSsidRead / Restore-LocationConsent.
#   - The scan is FORCED via WlanScan() (wlanapi.dll). 'netsh wlan show
#     networks' only reads the adapter's cache, which at startup holds little
#     more than the connected network. See Get-MigrationNetworkSecurity.
#   - The migration network's security type (WPA2PSK / WPA3SAE) is detected
#     from the scan, not configured. The profile XML is generated at run time,
#     so nothing needs to be shipped alongside this script.
#   - The PSP server tested for reachability is read from the agent's own
#     registry key so it always matches the agent. $PSPServer / $PSPPort are a
#     fallback. See Get-PSPServerFromRegistry.
#
# -DryRun:
#   Performs the real Wi-Fi work -- scan, detect, generate and import the
#   profile, connect, wait for association and DHCP, probe the PSP server --
#   but on failure only DESCRIBES the halt instead of carrying it out. Nothing
#   is stopped, rolled back, renamed or killed.
#
#   Note the Wi-Fi switch itself is NOT simulated: a dry run leaves the device
#   on the migration network with a new profile installed. That is the point of
#   it. What it protects is the destructive half, which on an idle machine is
#   pure damage to repair by hand.
#
# Change log:
#   2026-08-28  Location services are now enabled automatically before the
#               SSID read and restored to their previous state on every exit
#               path (via Stop-Logging). New $DoNotRunLocationPrivacyCheck
#               config flag to skip this where Location is managed elsewhere.
#               An unreadable SSID is now a Fail-Migration instead of a
#               silent exit 0, since the script has already tried to fix the
#               only known cause.
#   2026-07-17  Initial release.
# ==========================================================================

param(
    [switch]$DryRun
)

#
# Configuration
#
$CorporateSSID = "CORP"
$MigrationSSID = "CORP Migration"

# Set to $true when another process (e.g. a separate policy script) already
# manages Location services on this device; the script will then neither
# enable nor restore it.
$DoNotRunLocationPrivacyCheck = $false

#
# Pre-shared key for the migration network.
#
# Held in clear by design: this is a disposable network that exists only for
# the duration of the migration and is retired afterwards. The script refuses
# to run while this is still the placeholder.
#
$MigrationPSK = "CHANGE-ME"

# Fallback only. At run time the agent's own endpoint is read from the registry
# (HKLM\SOFTWARE\Declaration Software\Migration Agent\URL) and these are
# overwritten with its host and port. That tests the exact server the agent
# uses and removes a value that could drift. These apply only if that key is
# missing or unreadable.
$PSPServer = "psp.company.com"
$PSPPort   = 443

#
# Detection timings
#
# Failing halts the migration and rolls the device back, so a slow but healthy
# device must not be mistaken for a broken one. Each stage may take as long as
# it likes; only a stage that never completes is a failure. PSP does not kill
# long-running scripts, so a slow detection is safe.
#
# WlanScan is asynchronous; Microsoft documents results as taking about 4
# seconds, so the retry delay must not be shorter than that.
$ScanTimeoutSec            = 30
$ScanRetryDelaySec         = 4
$AssociationTimeoutSec     = 30
$DhcpTimeoutSec            = 30
$ConnectivityAttempts      = 3
$ConnectivityRetryDelaySec = 5

$LogFolder = "C:\MigTemp"
$LogFile   = Join-Path $LogFolder "WiFiMigration.log"

#
# PSP agent state directory.
#
$PSPStateDir = Join-Path $env:ProgramData "Declaration Software\Migration Agent"

#
# PSP tray application process name. Runs in the user's session and shows the
# "Migration in Progress" message.
#
$PSPTrayProcess = "MigrationAgentTrayApplication"

#
# User-facing notification. Customise the wording freely.
#
$UserDialogTitle = "Migration Halted"

$UserDialogHeading = "Your migration could not be started"

$UserDialogMessage = @"
This computer was unable to connect to the migration Wi-Fi network, so the
migration has been stopped before any lasting changes were made.

Your computer has been returned to its normal state and is safe to use. You
can carry on working as usual.

Please contact the IT Helpdesk and let them know the Wi-Fi transition failed
on this device. No action is needed from you until they get in touch.
"@

#
# Logging
#
New-Item -ItemType Directory -Force -Path $LogFolder | Out-Null

try
{
    Start-Transcript -Path $LogFile -Force | Out-Null
}
catch
{
}

function Write-Log
{
    param([string]$Message)

    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

#
# Stop-Transcript throws if Start-Transcript above failed, so every exit path
# goes through this rather than calling it directly.
#
function Stop-Logging
{
    # Every exit path in this script goes through here, including
    # Fail-Migration, so this is the one place the restore needs to live.
    Restore-LocationConsent
    
    try
    {
        Stop-Transcript | Out-Null
    }
    catch
    {
    }
}

Write-Log "ATTEMPTING TO CONNECT $env:COMPUTERNAME TO THE MIGRATION WI-FI NETWORK."

if ($DryRun)
{
    Write-Log "*** DRY RUN: the Wi-Fi switch is real; a halt would only be described, not performed. ***"
}


# --------------------------------------------------------------------------
# Location services
# --------------------------------------------------------------------------

$LocationConsentPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
$SysSettingsFlows    = Join-Path $env:SystemRoot "System32\SystemSettingsAdminFlows.exe"

$script:LocationChangedByUs = $false
$script:LocationRestored    = $false

#
# Reading the consent value IS reliable; only writing it is not.
# Anything unreadable is treated as Deny, so we enable it and
# importantly, restore it to Deny afterwards.
#
function Get-LocationConsent
{
    try
    {
        $v = (Get-ItemProperty -Path $LocationConsentPath -Name Value -ErrorAction Stop).Value
        if ($v) { return $v }
    }
    catch
    {
    }

    return "Deny"
}

function Enable-LocationForSsidRead
{
    if ($DoNotRunLocationPrivacyCheck)
    {
        Write-Log "Location handling skipped - DoNotRunLocationPrivacyCheck is set."
        return
    }

    $original = Get-LocationConsent
    Write-Log "Location services currently: $original"

    if ($original -eq "Allow")
    {
        Write-Log "Location already enabled. Nothing to change, nothing to restore."
        return
    }

    if (!(Test-Path $SysSettingsFlows))
    {
        Write-Log "WARNING: $SysSettingsFlows not found. Cannot enable Location; the SSID read may fail."
        return
    }

    try
    {
        # Settings throws a prompt and goes semi-frozen if it is open on the
        # Location page while this runs. The change applies regardless.
        taskkill /f /im SystemSettings.exe /t 2>$null | Out-Null

        & $SysSettingsFlows SetCamSystemGlobal location 1
        Start-Sleep -Seconds 3

        if ((Get-LocationConsent) -eq "Allow")
        {
            $script:LocationChangedByUs = $true
            Write-Log "Location services enabled for the SSID read. Will be restored to '$original' on exit."
        }
        else
        {
            Write-Log "WARNING: Location still not enabled after SetCamSystemGlobal."
        }
    }
    catch
    {
        Write-Log "WARNING: Unable to enable Location services: $($_.Exception.Message)"
    }
}

#
# Restores only what this script changed. Idempotent - called from
# Stop-Logging, which every exit path goes through.
#
function Restore-LocationConsent
{
    if (!$script:LocationChangedByUs -or $script:LocationRestored)
    {
        return
    }

    $script:LocationRestored = $true

    if (!(Test-Path $SysSettingsFlows))
    {
        Write-Log "WARNING: $SysSettingsFlows not found. Location left ENABLED on this device."
        return
    }

    try
    {
        taskkill /f /im SystemSettings.exe /t 2>$null | Out-Null

        & $SysSettingsFlows SetCamSystemGlobal location 0
        Start-Sleep -Seconds 3

        Write-Log "Location services restored to Deny."
    }
    catch
    {
        Write-Log "WARNING: Unable to restore Location services: $($_.Exception.Message)"
        Write-Log "WARNING: Location has been left ENABLED on this device."
    }
}

# --------------------------------------------------------------------------
# WLAN helpers
# --------------------------------------------------------------------------

#
# Read the current wireless interface state in one pass.
#
# Deliberately does NOT parse netsh for the adapter or its state, because that
# output is localised in both its labels and its values. On a German machine
# 'State : disconnected' reads 'Status : Nicht verbunden', so any text match
# fails and the script would quietly decide a working Wi-Fi laptop is an
# Ethernet device and exit. Get-NetAdapter is used instead:
#
#   InterfaceType 71 = IEEE 802.11, a numeric IANA ifType
#   ifOperStatus     = IF-MIB enum (Up=1, Down=2); .NET enum member names are
#                      compile-time constants and never translated
#
# The adapter's .Status property IS a localised string and is not used.
#
# Note on state comparison generally: never test WLAN state with
# `-match 'connected'`. 'disconnected' contains the substring 'connected', so
# that test silently means its own opposite. This is why the enum is used.
#
# Returns $null when the device has no wireless radio at all.
#
function Get-WlanInterfaceInfo
{
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceType -eq 71 }

    if (!$adapters)
    {
        return $null
    }

    # Prefer a connected radio where a device has more than one
    $adapter = $adapters | Where-Object { $_.ifOperStatus -eq 'Up' } | Select-Object -First 1

    if (!$adapter)
    {
        $adapter = $adapters | Select-Object -First 1
    }

    $isConnected = ($adapter.ifOperStatus -eq 'Up')

    #
    # SSID comes from netsh, and must NOT come from Get-NetConnectionProfile.
    #
    # Get-NetConnectionProfile.Name is the network PROFILE name, not the SSID.
    # On a domain-authenticated network Windows sets it to the AD domain, so a
    # machine associated with SSID 'CORP' reports 'contoso.local'. That is the
    # normal state of every device this script targets -- they are domain
    # joined by definition -- so the SSID gate would never match and every
    # machine would silently exit 0 without switching. Observed on a real
    # device: associated with 'ANSAiot', profile name 'migrate2.me'.
    #
    # netsh's 'SSID' label is an acronym Windows leaves untranslated, as it
    # does 'GUID'. That is a smaller risk than the profile-name bug above, and
    # it is why 'Name' and 'State' are read from the adapter rather than parsed
    # here -- those two ARE translated.
    #
    $ssid = $null

    if ($isConnected)
    {
        $ssid = netsh wlan show interfaces |
            Where-Object { $_ -match '^\s*SSID\s*:' -and $_ -notmatch 'BSSID' } |
            ForEach-Object { ($_ -split ':', 2)[1].Trim() } |
            Select-Object -First 1
    }

    return @{
        Name        = $adapter.Name
        IfIndex     = $adapter.ifIndex
        Ssid        = $ssid
        State       = $adapter.ifOperStatus.ToString()
        IsConnected = $isConnected
    }
}

#
# Does this device have a route to the network that is not over the Wi-Fi?
#
# Deliberately asks that, rather than 'is an Ethernet cable plugged in'. Link
# state alone lies in both directions:
#
#   A dock or USB NIC in a dead port reports ifOperStatus 'Up' with no DHCP
#   lease. Treating that as wired connectivity would skip the Wi-Fi switch on
#   a device that has no other way out.
#
#   On a machine with a Hyper-V external switch the physical NIC is 'Up' but
#   holds no address at all; the IP and gateway live on a virtual adapter. The
#   device is genuinely connected, just not through the adapter a naive check
#   would inspect.
#
# A default gateway on any non-wireless interface answers both: it means
# traffic has somewhere to go that is not the radio we are about to reconfigure.
#
function Get-NonWirelessRoute
{
    param([int]$WirelessIfIndex)

    # Interface indices whose adapter is actually up right now. Get-NetIPConfiguration
    # reports gateways from the route table, and a default route can linger there after
    # its interface goes down -- an undocked laptop still shows the dock's gateway on a
    # 'Down' Ethernet adapter. Cross-checking ifOperStatus (the same locale-proof enum
    # used elsewhere) discards those stale routes. Reported on a real device: after
    # pulling the cable, 'Non-wireless route present (Ethernet via 10.11.12.1)'.
    $upIfIndex = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.ifOperStatus -eq 'Up' } |
        ForEach-Object { $_.ifIndex }

    return Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceIndex -ne $WirelessIfIndex -and
            $_.IPv4DefaultGateway -and
            $upIfIndex -contains $_.InterfaceIndex
        }
}

#
# Force the wireless adapter to scan now.
#
# There is no netsh command for this. 'netsh wlan show networks' reads the
# adapter's cached results and never triggers a scan, and every other suggested
# workaround (disable/enable the adapter, disconnect/reconnect) forces a scan by
# breaking the connection -- unusable here, since this script runs while sitting
# on the corporate Wi-Fi it still needs.
#
# WlanScan() in wlanapi.dll is the supported way. It needs no elevation, and
# returns immediately: the scan itself is asynchronous and Microsoft documents
# results as taking around 4 seconds, which is what the poll loop below is for.
#
# Best effort by design. If Add-Type cannot compile here, the caller still
# polls and will pick up whatever periodic scan Windows performs on its own --
# slower and less certain, but not broken.
#
$WlanScannerSource = @'
using System;
using System.Runtime.InteropServices;

public static class WlanScanner
{
    [DllImport("wlanapi.dll")]
    public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
    [DllImport("wlanapi.dll")]
    public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
    [DllImport("wlanapi.dll")]
    public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);
    [DllImport("wlanapi.dll")]
    public static extern uint WlanScan(IntPtr hClientHandle, ref Guid pInterfaceGuid, IntPtr pDot11Ssid, IntPtr pIeData, IntPtr pReserved);
    [DllImport("wlanapi.dll")]
    public static extern void WlanFreeMemory(IntPtr pMemory);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_INTERFACE_INFO
    {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strInterfaceDescription;
        public uint isState;
    }

    // Returns the number of interfaces a scan was requested on, or -1 on failure.
    public static int ScanAll()
    {
        uint negotiated;
        IntPtr handle;
        int scanned = 0;

        if (WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle) != 0) { return -1; }
        try
        {
            IntPtr list;
            if (WlanEnumInterfaces(handle, IntPtr.Zero, out list) != 0) { return -1; }
            try
            {
                // WLAN_INTERFACE_INFO_LIST: dwNumberOfItems, dwIndex, then the array
                int numItems = Marshal.ReadInt32(list);
                IntPtr basePtr = new IntPtr(list.ToInt64() + 8);
                int size = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));

                for (int i = 0; i < numItems; i++)
                {
                    WLAN_INTERFACE_INFO info = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(
                        new IntPtr(basePtr.ToInt64() + (i * size)), typeof(WLAN_INTERFACE_INFO));
                    Guid g = info.InterfaceGuid;
                    if (WlanScan(handle, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) { scanned++; }
                }
            }
            finally { WlanFreeMemory(list); }
        }
        finally { WlanCloseHandle(handle, IntPtr.Zero); }
        return scanned;
    }
}
'@

function Invoke-WlanScan
{
    if (-not ('WlanScanner' -as [type]))
    {
        try
        {
            Add-Type -TypeDefinition $WlanScannerSource -ErrorAction Stop
        }
        catch
        {
            Write-Log "WARNING: Could not compile the WLAN scan helper: $($_.Exception.Message)"
            Write-Log "WARNING: Falling back to the adapter's own periodic scan. Detection may be slower."
            return
        }
    }

    try
    {
        $n = [WlanScanner]::ScanAll()

        if ($n -lt 0)
        {
            Write-Log "WARNING: WlanScan request failed. Relying on the adapter's own scan."
        }
        else
        {
            Write-Log "Requested a fresh scan on $n wireless interface(s)."
        }
    }
    catch
    {
        Write-Log "WARNING: WlanScan threw: $($_.Exception.Message)"
    }
}

#
# Read one network's advertised security out of a single scan listing.
#
# Returns $null when the SSID is not in this listing, which is not the same as
# "not in range" -- see Get-MigrationNetworkSecurity below.
#
# Matches on values rather than labels: netsh output is localised, but 'WPA2',
# 'WPA3' and 'CCMP' are standards names and survive translation where labels
# such as 'Authentication' do not.
#
# mode=bssid is not used. It adds per-AP detail (MAC, signal, channel) that
# nothing here reads; only Authentication and Encryption are needed and both
# appear in the plain listing.
#
function Read-WlanScanEntry
{
    param(
        [string]$Ssid,
        [string]$Interface
    )

    $lines = netsh wlan show networks interface="$Interface"

    $inBlock = $false
    $authRaw = $null
    $encRaw  = $null

    foreach ($line in $lines)
    {
        # 'BSSID 1 :' does not match here, as the pattern anchors on SSID
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*)$')
        {
            $name = $Matches[1].Trim()

            # Reached the next network's block, so our block is finished
            if ($inBlock) { break }

            $inBlock = ($name -eq $Ssid)
            continue
        }

        if (!$inBlock) { continue }

        if (!$authRaw -and ($line -match 'WPA|WEP|Open'))
        {
            $authRaw = $line.Trim()
        }
        elseif (!$encRaw -and ($line -match 'CCMP|TKIP|GCMP|None'))
        {
            $encRaw = $line.Trim()
        }
    }

    if (!$authRaw)
    {
        return $null
    }

    return @{
        AuthRaw = $authRaw
        EncRaw  = $encRaw
    }
}

#
# Read the migration network's security settings off the air, retrying until
# the adapter has actually scanned for it.
#
# Detecting beats a configurable auth type at the top of this script, which is
# a trap: point it at a WPA3 network with WPA2 configured and the profile
# imports cleanly, then silently never associates. Detecting removes the
# decision, and there is nothing for a non-expert to get wrong.
#
# FORCING THE SCAN IS NOT OPTIONAL. 'netsh wlan show networks' reports the
# adapter's CACHED results; it never triggers a scan. This script runs at
# startup, exactly when the radio has just come up and the cache holds little
# more than the network it associated with. Worse, Windows scans infrequently
# once it is connected and content -- which is our situation precisely. Asking
# once returns a short list, exit code 0, no warning: indistinguishable from
# the network genuinely being absent, and the device then halts its own
# migration over a network that was sitting right there.
#
# Observed on a real device: the first scan returned only the connected
# network; the same command moments later returned all five.
#
# So each miss forces a scan via WlanScan() and polls again. The cache is read
# BEFORE the first forced scan, so a warm cache costs nothing.
#
# Returns $null if the network never appears, or appears but is not PSK
# protected. Note a non-broadcast network can never be seen: a hidden SSID does
# not advertise its name and will not appear in any scan.
#
function Get-MigrationNetworkSecurity
{
    param(
        [string]$Ssid,
        [string]$Interface,
        [int]$TimeoutSec,
        [int]$RetryDelaySec
    )

    $entry   = $null
    $attempt = 0
    $elapsed = 0

    while ($true)
    {
        $attempt++
        $entry = Read-WlanScanEntry -Ssid $Ssid -Interface $Interface

        if ($entry)
        {
            Write-Log "Found '$Ssid' in scan results on attempt $attempt (after $elapsed second(s))."
            break
        }

        if ($elapsed -ge $TimeoutSec)
        {
            Write-Log "'$Ssid' did not appear in any scan within $TimeoutSec seconds ($attempt attempts). It is not in range, or the adapter could not scan for it."
            return $null
        }

        Write-Log "'$Ssid' not in scan results (attempt $attempt). Forcing a rescan..."

        Invoke-WlanScan

        Start-Sleep -Seconds $RetryDelaySec
        $elapsed += $RetryDelaySec
    }

    $authRaw = $entry.AuthRaw
    $encRaw  = $entry.EncRaw

    #
    # WPA2 wins over WPA3 where an AP advertises both (transition mode). Any
    # client that can do WPA3 can also do WPA2, and it is driver-level WPA3
    # support across a mixed fleet that tends to be patchy. The migration
    # depends on this network, so favour the option that connects more widely.
    #
    if ($authRaw -match 'WPA2')
    {
        $auth = 'WPA2PSK'
    }
    elseif ($authRaw -match 'WPA3|SAE')
    {
        $auth = 'WPA3SAE'
    }
    elseif ($authRaw -match 'WPA')
    {
        $auth = 'WPAPSK'
    }
    else
    {
        Write-Log "'$Ssid' does not appear to be PSK protected. Detected: $authRaw"
        return $null
    }

    if ($encRaw -match 'TKIP')
    {
        $enc = 'TKIP'
    }
    else
    {
        $enc = 'AES'
    }

    Write-Log "Detected security for '$Ssid': [$authRaw] [$encRaw] -> $auth / $enc"

    return @{
        Authentication = $auth
        Encryption     = $enc
    }
}

#
# Build a WLAN profile XML for a PSK network.
#
# Generated at run time so the script is self-contained: there is no XML file
# to ship alongside it, lose, or point at the wrong network. Verified field by
# field against a profile exported by Windows itself.
#
# MacRandomization is deliberately omitted. Windows adds it when exporting a
# profile it created, but it is not required on import and the adapter default
# applies without it. Add an explicit <enableRandomization>false</...> here if
# the migration network ever needs MAC allowlisting or DHCP reservations.
#
function New-WifiProfileXml
{
    param(
        [string]$Ssid,
        [string]$Passphrase,
        [string]$Authentication,
        [string]$Encryption
    )

    #
    # SSID hex is the UTF8 bytes of the name. Windows matches on this, so it
    # must be correct for names containing spaces or non-ASCII characters.
    #
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Ssid)
    $hex   = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ''

    $ssidEsc = [System.Security.SecurityElement]::Escape($Ssid)
    $keyEsc  = [System.Security.SecurityElement]::Escape($Passphrase)

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$ssidEsc</name>
  <SSIDConfig>
    <SSID>
      <hex>$hex</hex>
      <name>$ssidEsc</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>$Authentication</authentication>
        <encryption>$Encryption</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$keyEsc</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
}

#
# Read the PSP server's host and port from the agent's own registry key.
#
# The agent stores its endpoint at HKLM\SOFTWARE\Declaration Software\Migration
# Agent, value 'URL' (e.g. https://psp1.jrr.me/Agent). Reading it means the
# reachability test targets the exact server the agent uses, and removes a
# hardcoded value that could be wrong or drift out of date.
#
# WOW6432Node is checked as well, in case the agent is a 32-bit process whose
# writes Windows redirected there.
#
# Returns @{ ServerHost; Port } or $null. A URL with no host (a bare name with
# no scheme) is treated as unreadable so the caller falls back to its default.
#
function Get-PSPServerFromRegistry
{
    $keys = @(
        'HKLM:\SOFTWARE\Declaration Software\Migration Agent',
        'HKLM:\SOFTWARE\WOW6432Node\Declaration Software\Migration Agent'
    )

    foreach ($key in $keys)
    {
        $url = (Get-ItemProperty -Path $key -Name 'URL' -ErrorAction SilentlyContinue).URL

        if (!$url)
        {
            continue
        }

        try
        {
            $uri = [System.Uri]$url
        }
        catch
        {
            Write-Log "WARNING: PSP agent URL '$url' in $key is not a valid URI. Ignoring it."
            continue
        }

        if (!$uri.Host)
        {
            Write-Log "WARNING: PSP agent URL '$url' in $key has no host. Ignoring it."
            continue
        }

        return @{
            ServerHost = $uri.Host
            Port       = $uri.Port
        }
    }

    return $null
}

# --------------------------------------------------------------------------
# Failure path
# --------------------------------------------------------------------------

#
# Locate the PSP agent service.
#
# Matched on DisplayName rather than a hard-coded service name. If this matches
# nothing, the migration cannot be stopped and the caller says so loudly.
#
function Get-PSPService
{
    return Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*PowerSyncPro*' }
}

#
# Write the IT-facing halt notice.
#
# PSP watches this script's console output and copies it into the agent log, so
# this is how the IT team learns what happened and what to do about it. It must
# be written BEFORE the service stops: nothing is listening afterwards.
#
# Deliberately future tense about the rollback, which has not happened yet at
# this point. Claiming otherwise would be a lie if the rollback then failed, or
# if this process were killed as a child of the service we are about to stop.
#
function Write-HaltNotice
{
    param(
        [string]$Reason,
        $Services
    )

    if ($Services)
    {
        $svcNames = ($Services | ForEach-Object { $_.Name }) -join ', '
    }
    else
    {
        $svcNames = '<PSP agent service>'
    }

    Write-Log "MIGRATION HALTED: could not move onto '$MigrationSSID'. Reason: $Reason"
    Write-Log "IT ACTION: fix the Wi-Fi issue, then re-enable and start '$svcNames' to restart the migration."
}

#
# Stop and disable the PSP agent service.
#
# PSP does not honour script exit codes, so this is the only lever available to
# stop the runbook. Disabling matters as much as stopping: the agent resumes
# its state machine at next boot otherwise.
#
function Stop-MigrationAgent
{
    param($Services)

    try
    {
        if (!$Services)
        {
            Write-Log "CRITICAL: No PowerSyncPro service found. The migration will continue and will undo the rollback below."
            return
        }

        foreach ($s in $Services)
        {
            Write-Log "Stopping service '$($s.DisplayName)' ($($s.Name))."

            #
            # Disabled before stopped, deliberately. If the stop hangs, or this
            # process is killed as a child of the service, the disable has
            # already landed and the agent will not resume at next boot.
            #
            Set-Service -Name $s.Name -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue

            $after = Get-Service -Name $s.Name -ErrorAction SilentlyContinue

            if ($after -and $after.Status -ne 'Stopped')
            {
                Write-Log "CRITICAL: Service '$($s.Name)' is still $($after.Status). The migration may proceed on a rolled back device."
            }
            else
            {
                Write-Log "Service '$($s.Name)' stopped and disabled."
            }
        }
    }
    catch
    {
        Write-Log "CRITICAL: Unable to stop PSP Migration Agent: $($_.Exception.Message)"
    }
}

#
# Undo what PSP changed.
#
# Ported from CompletionRepair\CompletionCleanup.ps1, which repairs the same
# items when PSP leaves them behind. Restores defaults rather than prior state,
# which is all that is possible: this script runs after PSP has already made
# its changes, so there is no pre-migration snapshot to restore.
#
# Every step is wrapped independently. CompletionCleanup relies on
# $ErrorActionPreference = 'Stop' and exits outright on failure; that behaviour
# in a rollback would abandon the remaining steps and leave the device in a
# worse state than doing nothing.
#
function Invoke-MigrationRollback
{
    #
    # Deny logon rights: preserve Guest, drop everything PSP added.
    #
    try
    {
        Write-Log "Rollback: clearing deny logon rights."

        $secedit   = Join-Path $env:SystemRoot 'System32\secedit.exe'
        $temp      = [System.IO.Path]::GetTempPath()
        $ts        = Get-Date -Format 'yyyyMMdd_HHmmss'
        $exportInf = Join-Path $temp "sec_export_$ts.inf"
        $modInf    = Join-Path $temp "sec_mod_$ts.inf"
        $seLog     = Join-Path $temp "sec_apply_$ts.log"

        & $secedit /export /cfg $exportInf /areas USER_RIGHTS /quiet

        if (!(Test-Path $exportInf))
        {
            Write-Log "WARNING: secedit export failed. Deny logon rights NOT cleared - users may remain locked out."
        }
        else
        {
            $newContent = Get-Content $exportInf -Encoding Unicode -Raw

            if ($newContent -match '(?m)^SeDenyInteractiveLogonRight\s*=\s*(.*)')
            {
                $oldVal = $Matches[1].Trim()

                # '*' or empty both mean "no entries" in an secedit export
                if ($oldVal -eq '*' -or $oldVal -eq '')
                {
                    $entries = @()
                }
                else
                {
                    $entries = $oldVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                }

                $keep = $entries | Where-Object { $_ -like '*Guest*' }

                if ($keep) { $newVal = $keep -join ',' } else { $newVal = '*' }

                Write-Log "Deny log on locally was [$oldVal], setting to [$newVal]."

                $newContent = $newContent -replace '(?m)^(SeDenyInteractiveLogonRight\s*=\s*).*$', "`$1$newVal"
            }
            else
            {
                $newContent += "`nSeDenyInteractiveLogonRight = Guest`r`n"
            }

            $newContent = $newContent -replace '(?m)^(SeDenyRemoteInteractiveLogonRight\s*=\s*).*$', '$1*'

            $newContent | Out-File $modInf -Encoding Unicode -Force

            & $secedit /configure /db "$env:windir\security\local.sdb" /cfg $modInf /areas USER_RIGHTS /log $seLog /quiet

            if ($LASTEXITCODE -ne 0)
            {
                Write-Log "secedit returned $LASTEXITCODE. Retrying against a temp database."

                $tempDb = Join-Path $temp "tempdb_$ts.sdb"
                & $secedit /configure /db $tempDb /cfg $modInf /areas USER_RIGHTS /overwrite /log $seLog /quiet
            }

            if ($LASTEXITCODE -eq 0)
            {
                Write-Log "Deny logon rights cleared."
            }
            else
            {
                Write-Log "WARNING: secedit failed with $LASTEXITCODE. Users may remain locked out."
            }

            Remove-Item -Path $exportInf, $modInf, $seLog -Force -ErrorAction SilentlyContinue
        }
    }
    catch
    {
        Write-Log "WARNING: Deny logon rights rollback failed: $($_.Exception.Message)"
    }

    #
    # Lock screen. Path and values confirmed against lockscreen-poc.
    #
    try
    {
        Write-Log "Rollback: resetting lock screen to default."

        $cspPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

        if (Test-Path $cspPath)
        {
            foreach ($name in @("LockScreenImagePath", "LockScreenImageUrl", "LockScreenImageStatus"))
            {
                Remove-ItemProperty -Path $cspPath -Name $name -ErrorAction SilentlyContinue
            }

            Write-Log "Lock screen CSP values removed."
        }
        else
        {
            Write-Log "No PersonalizationCSP key present."
        }
    }
    catch
    {
        Write-Log "WARNING: Lock screen rollback failed: $($_.Exception.Message)"
    }

    #
    # Legal notice.
    #
    # Only the Winlogon values are cleared. If the notice is pushed by domain
    # GPO it will return at the next policy refresh, which is correct: that is
    # the corporate baseline, not something PSP set.
    #
    try
    {
        Write-Log "Rollback: clearing legal notice."

        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

        foreach ($name in @("LegalNoticeCaption", "LegalNoticeText"))
        {
            Remove-ItemProperty -Path $winlogonPath -Name $name -ErrorAction SilentlyContinue
        }

        Write-Log "Legal notice cleared."
    }
    catch
    {
        Write-Log "WARNING: Legal notice rollback failed: $($_.Exception.Message)"
    }

    #
    # BitLocker. Not covered by CompletionCleanup.ps1: PSP disables protectors
    # before this script runs, so without this the disk is left unprotected on
    # a device we have just declared safe to keep using.
    #
    try
    {
        Write-Log "Rollback: resuming BitLocker protection."

        if (!(Get-Command Resume-BitLocker -ErrorAction SilentlyContinue))
        {
            Write-Log "BitLocker cmdlets unavailable. Skipping."
        }
        else
        {
            $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue |
                Where-Object { $_.ProtectionStatus -ne 'On' -and $_.VolumeStatus -ne 'FullyDecrypted' }

            if (!$vols)
            {
                Write-Log "No suspended BitLocker volumes found."
            }
            else
            {
                foreach ($v in $vols)
                {
                    Resume-BitLocker -MountPoint $v.MountPoint -ErrorAction SilentlyContinue | Out-Null
                    Write-Log "Resumed BitLocker protection on $($v.MountPoint)."
                }
            }
        }
    }
    catch
    {
        Write-Log "WARNING: BitLocker rollback failed: $($_.Exception.Message)"
    }

    #
    # The break-glass local admin PSP creates is deliberately left in place. If
    # the deny-rights rollback above failed, it may be the only way the
    # helpdesk can sign in to this device.
    #
}

#
# Reset the PSP agent state so a restart begins a fresh migration.
#
# The WHOLE folder is renamed, not its contents. Renaming the folder is what
# makes a re-enabled agent start over rather than resume where it stopped,
# which is required here: the rollback below has undone the work it would
# otherwise carry on from.
#
# Renamed rather than deleted so the previous state can be inspected, or put
# back if a migration needs to be picked apart after the fact. The agent
# re-fetches what it needs from the server on restart.
#
# Only valid after the service has stopped, or the agent holds these files open
# and rewrites what we move.
#
function Reset-PSPState
{
    try
    {
        if (!(Test-Path $PSPStateDir))
        {
            Write-Log "No PSP state directory at '$PSPStateDir'."
            return
        }

        $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backup = "$PSPStateDir.aborted-$stamp"

        Rename-Item -Path $PSPStateDir -NewName (Split-Path $backup -Leaf) -ErrorAction Stop

        Write-Log "PSP state reset. Previous state preserved at '$backup'."
    }
    catch
    {
        Write-Log "WARNING: Unable to reset PSP state directory: $($_.Exception.Message)"
        Write-Log "WARNING: A restarted agent may resume the migration instead of starting fresh."
    }
}

#
# Stop the PSP tray application.
#
# Runs as the logged-on user and shows "Migration in Progress" via a named pipe
# to the service. Killed after the service stops so it is not respawned. No-op
# when nobody is logged on, as there is no tray process in that case.
#
function Stop-TrayApplication
{
    try
    {
        $procs = Get-Process -Name $PSPTrayProcess -ErrorAction SilentlyContinue

        if (!$procs)
        {
            Write-Log "PSP tray application is not running (likely no interactive session)."
            return
        }

        foreach ($p in $procs)
        {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Log "Stopped tray application PID $($p.Id) in session $($p.SessionId)."
        }
    }
    catch
    {
        Write-Log "WARNING: Unable to stop the tray application: $($_.Exception.Message)"
    }
}

#
# Show the user a dialog explaining what happened.
#
# This script runs as SYSTEM in session 0, so a WPF window created here would
# render on a desktop nobody can see. The dialog is instead launched via a
# scheduled task registered against the interactive user, which places it in
# their session. Best effort: if nobody is logged on there is nothing to show,
# and the halt is recorded in the log regardless.
#
function Show-UserNotification
{
    $taskName = 'PSP-WiFi-Migration-Halted'

    try
    {
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName

        if (!$user)
        {
            Write-Log "No interactive user logged on. Skipping user notification."
            return
        }

        Write-Log "Presenting notification to '$user'."

        #
        # The message is passed in a file rather than through task arguments,
        # which avoids quoting and escaping problems entirely.
        #
        $noticeFile = Join-Path $LogFolder 'MigrationNotice.txt'
        $dialogFile = Join-Path $LogFolder 'ShowMigrationNotice.ps1'

        Set-Content -Path $noticeFile -Value $UserDialogMessage -Encoding UTF8 -Force

        #
        # Single-quoted here-string: this is the child script's source, so
        # nothing in it should expand in this scope. Placeholders are
        # substituted below rather than interpolated, as the XAML is full of
        # braces and quotes.
        #
        $dialog = @'
# Hide this PowerShell's own console window before anything is drawn on screen,
# so no blank command prompt sits behind the dialog. SW_HIDE = 0.
$hide = Add-Type -Name Win -Namespace Native -PassThru -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
$hwnd = $hide::GetConsoleWindow()
if ($hwnd -ne [System.IntPtr]::Zero) { $hide::ShowWindow($hwnd, 0) | Out-Null }

Add-Type -AssemblyName PresentationFramework

$noticeFile = Join-Path $PSScriptRoot 'MigrationNotice.txt'
$body       = Get-Content -Path $noticeFile -Raw

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="__TITLE__" Height="330" Width="560"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Topmost="True" Background="#FFF4F4F4">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="__HEADING__" FontSize="18" FontWeight="SemiBold"
               Foreground="#FF1A1A1A" Margin="0,0,0,14" TextWrapping="Wrap"/>
    <TextBlock Grid.Row="1" x:Name="Body" FontSize="13" Foreground="#FF333333"
               TextWrapping="Wrap"/>
    <Button Grid.Row="2" x:Name="OkButton" Content="OK" Width="96" Height="30"
            HorizontalAlignment="Right" Margin="0,16,0,0"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$window.FindName('Body').Text = $body
$window.FindName('OkButton').Add_Click({ $window.Close() })

$window.ShowDialog() | Out-Null
'@

        $dialog = $dialog.Replace('__TITLE__',   $UserDialogTitle)
        $dialog = $dialog.Replace('__HEADING__', $UserDialogHeading)

        Set-Content -Path $dialogFile -Value $dialog -Encoding UTF8 -Force

        #
        # -STA is required for WPF. The principal is what places the window in
        # the user's session instead of session 0.
        #
        # '-WindowStyle Hidden' is kept as a first cut, but on its own it hides
        # the PowerShell window only AFTER conhost has drawn it -- leaving the
        # blank console behind the dialog. The dialog script hides its own
        # console window immediately via ShowWindow (see the dialog source
        # above), which removes it for the whole time ShowDialog blocks.
        #
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dialogFile`""

        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Principal $principal `
            -Force `
            -ErrorAction Stop | Out-Null

        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        Write-Log "User notification launched."

        #
        # Unregistering does not terminate the process the task started, so the
        # dialog stays on screen. The wait is to let Task Scheduler spawn it
        # before the registration disappears underneath it.
        #
        Start-Sleep -Seconds 5
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch
    {
        Write-Log "WARNING: Unable to show user notification: $($_.Exception.Message)"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

#
# Halt the migration and return the device to normal.
#
# Never returns.
#
function Fail-Migration
{
    param([string]$Reason)

    Write-Log "FAILURE: $Reason"

    #
    # Order matters, and PSP must be stopped before the rollback. A live agent
    # would carry on through its runbook, re-apply the legal notice, lock
    # screen and logon blocks we are about to clear, and reboot anyway.
    #
    # The risk of that order is that this script is spawned by the agent, so
    # stopping the service may terminate this process mid-rollback. If that
    # happens it is legible in the log: the halt notice appears and the
    # rollback lines do not.
    #

    $Services = Get-PSPService

    # 1. Notify the logs, while PSP is still reading our console output
    Write-HaltNotice -Reason $Reason -Services $Services

    #
    # Dry run stops here.
    #
    # Everything below is described rather than done, and each line reports what
    # was actually FOUND on this device -- not a generic plan. That makes a dry
    # run a live check of the things the halt path depends on: whether the
    # service wildcard matches, whether the state directory is where we expect,
    # whether the tray process name is right, whether a user is detected. All
    # read only.
    #
    if ($DryRun)
    {
        Write-Log ""
        Write-Log "=============================================================="
        Write-Log "DRY RUN -- NOTHING BELOW WAS DONE"
        Write-Log ""

        if ($Services)
        {
            foreach ($s in $Services)
            {
                Write-Log "WOULD stop and disable '$($s.DisplayName)' ($($s.Name)) - currently $($s.Status), startup $($s.StartType)."
            }
        }
        else
        {
            Write-Log "WOULD FAIL TO STOP THE MIGRATION: no service matching '*PowerSyncPro*' found."
            Write-Log "  In a real run the migration would continue and undo the rollback."
        }

        Write-Log "WOULD roll back: deny logon rights, lock screen, legal notice, BitLocker protectors."

        if (Test-Path $PSPStateDir)
        {
            Write-Log "WOULD rename '$PSPStateDir' to '$PSPStateDir.aborted-<timestamp>'."
        }
        else
        {
            Write-Log "WOULD skip the state reset: '$PSPStateDir' does not exist."
        }

        $tray = Get-Process -Name $PSPTrayProcess -ErrorAction SilentlyContinue

        if ($tray)
        {
            foreach ($t in $tray)
            {
                Write-Log "WOULD kill tray application PID $($t.Id) in session $($t.SessionId)."
            }
        }
        else
        {
            Write-Log "WOULD skip the tray application: '$PSPTrayProcess' is not running."
        }

        $dryUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName

        if ($dryUser)
        {
            Write-Log "WOULD show the halt dialog to '$dryUser'."
        }
        else
        {
            Write-Log "WOULD skip the halt dialog: no interactive user is logged on."
        }

        Write-Log ""
        Write-Log "Re-run without -DryRun to actually do the above."
        Write-Log "=============================================================="

        Stop-Logging

        exit 1
    }

    # 2. Stop PSP
    Stop-MigrationAgent -Services $Services

    #
    # PSP issues its 60 second delayed reboot after this script returns, so
    # there is normally nothing pending to abort and this is a no-op (netsh
    # reports error 1116). Kept as cheap insurance in case something scheduled
    # a shutdown earlier than expected.
    #
    shutdown.exe /a 2>$null

    if ($LASTEXITCODE -eq 0)
    {
        Write-Log "A pending shutdown was found and aborted."
    }
    else
    {
        Write-Log "No pending shutdown to abort (expected at this stage)."
    }

    # 3. Undo PSP's changes, and reset its state so a restart starts over
    Invoke-MigrationRollback
    Reset-PSPState

    # 4. Remove the "Migration in Progress" tray message
    Stop-TrayApplication

    # 5. Tell the user. Best effort; no-op if nobody is logged on
    Show-UserNotification

    Write-Log "Migration halted and device rolled back."

    Stop-Logging

    exit 1
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

#
# WLAN service. Absent or stopped is taken to mean an Ethernet device, which
# is not this script's problem: exit cleanly and let the migration proceed.
#
$WlanSvc = Get-Service wlansvc -ErrorAction SilentlyContinue

if (!$WlanSvc)
{
    Write-Log "No WLAN service installed. Assuming Ethernet device."
    Stop-Logging
    exit 0
}

if ($WlanSvc.Status -ne 'Running')
{
    Write-Log "WLAN service not running. Assuming Ethernet device."
    Stop-Logging
    exit 0
}

#
# Enable Location before any SSID read - see Enable-LocationForSsidRead.
#
Enable-LocationForSsidRead


#
# Wireless interface state
#
$Wlan = Get-WlanInterfaceInfo

if (!$Wlan)
{
    Write-Log "No wireless interface detected."
    Stop-Logging
    exit 0
}

$InterfaceName = $Wlan.Name

Write-Log "Wireless interface = $InterfaceName"
Write-Log "Interface state    = $($Wlan.State)"
Write-Log "Current SSID       = $($Wlan.Ssid)"

#
# Wired devices need no Wi-Fi switch.
#
# A device with another route keeps its path to PSP through the migration, so
# there is nothing to do here. It also must not be tested: with two interfaces
# up, route selection follows the lowest interface metric, and Ethernet is
# normally lower than Wi-Fi. The reachability test at the end of this script
# would answer for the wired link and report success even if the migration
# Wi-Fi were completely broken. A docked laptop would then be migrated,
# rebooted, and stranded the moment it left the dock, with a log line claiming
# its Wi-Fi had been verified.
#
# Test-NetConnection cannot be constrained to an interface (-ConstrainInterface
# exists only in the NetRouteDiagnostics parameter set, which takes no -Port),
# so binding the probe to the wireless adapter would mean a raw TcpClient bound
# to the Wi-Fi's local address. Not worth it while wired devices are safe.
#
# TODO: assumes corporate Ethernet is NOT 802.1X cert-based. If it is, a wired
# device is stranded by the migration exactly as a wireless one would be, this
# exit is wrong, and the bound-TcpClient probe above becomes necessary.
#
$WiredRoute = Get-NonWirelessRoute -WirelessIfIndex $Wlan.IfIndex

if ($WiredRoute)
{
    $via = ($WiredRoute | ForEach-Object {
        "$($_.InterfaceAlias) via $(($_.IPv4DefaultGateway | Select-Object -First 1).NextHop)"
    }) -join '; '

    Write-Log "Non-wireless route present ($via). Device does not need the migration Wi-Fi. Exiting."
    Stop-Logging
    exit 0
}

if (!$Wlan.IsConnected)
{
    Write-Log "Wireless adapter present but not connected."
    Stop-Logging
    exit 0
}

#
# A connected adapter with no readable SSID.
#
# netsh needs Location permission to report the SSID. As SYSTEM -- how PSP runs
# this -- it is granted. An interactive admin session is refused, and the SSID
# comes back EMPTY rather than erroring.
#
# This must not fall through to the gate below, which would log 'not connected
# to corporate Wi-Fi' and exit 0. That is a guess stated as a fact: we did not
# establish the device is elsewhere, we failed to read where it is. Reported as
# normal, it would hide a fleet-wide failure behind a reassuring log line.
#
if (!$Wlan.Ssid)
{
    Fail-Migration "The wireless adapter is connected but its SSID could not be read. netsh requires Location services, which this script attempted to enable. Without the SSID we cannot tell whether this device is on '$CorporateSSID', so it has NOT been switched - migrating it would strand it."
}

#
# Only devices on the corporate Wi-Fi need moving. Anything else is either
# already fine or none of our business.
#
if ($Wlan.Ssid -ne $CorporateSSID)
{
    Write-Log "Connected to '$($Wlan.Ssid)', which is not the corporate Wi-Fi ('$CorporateSSID'). Nothing to do. Exiting."
    Stop-Logging
    exit 0
}

#
# Validate configuration before touching anything.
#
# These are config errors rather than network faults, but they still halt the
# migration: PSP has already made its changes by this point, so the device
# cannot simply be left as-is.
#
if ([string]::IsNullOrWhiteSpace($MigrationPSK) -or $MigrationPSK -eq "CHANGE-ME")
{
    Fail-Migration "The migration Wi-Fi pre-shared key has not been set. Edit `$MigrationPSK at the top of this script."
}

if ($MigrationPSK.Length -lt 8 -or $MigrationPSK.Length -gt 63)
{
    Fail-Migration "The migration Wi-Fi pre-shared key must be 8 to 63 characters. Current length: $($MigrationPSK.Length)."
}

#
# Find the migration network and read its security settings
#
Write-Log "Scanning for '$MigrationSSID' (up to $ScanTimeoutSec seconds)..."

$Security = Get-MigrationNetworkSecurity -Ssid $MigrationSSID `
                                         -Interface $InterfaceName `
                                         -TimeoutSec $ScanTimeoutSec `
                                         -RetryDelaySec $ScanRetryDelaySec

if (!$Security)
{
    Fail-Migration "'$MigrationSSID' was not found in range, or is not a PSK protected network. This device cannot be moved onto the migration network."
}

#
# Generate and import the profile.
#
# The XML contains the PSK in clear, so it is written to disk only for as long
# as netsh needs to read it. The finally block removes it on every path,
# including the Fail-Migration exit.
#
Write-Log "Generating migration profile."

$ProfileXml = New-WifiProfileXml -Ssid $MigrationSSID `
                                 -Passphrase $MigrationPSK `
                                 -Authentication $Security.Authentication `
                                 -Encryption $Security.Encryption

$ProfilePath = Join-Path $LogFolder "migrationwifi.xml"

try
{
    Set-Content -Path $ProfilePath -Value $ProfileXml -Encoding UTF8 -Force

    Write-Log "Importing migration profile."

    #
    # netsh's own text is captured rather than discarded. It is the only place
    # the actual cause appears, and it is worth reading. An adapter too old for
    # the network's security, for example, reports:
    #
    #   "The security or connectivity setting in profile "X" is not supported
    #    by wireless adapter "Wi-Fi"."
    #
    # which tells the IT team exactly what is wrong. "exit code 1" does not.
    #
    $netshOutput = netsh wlan add profile filename="$ProfilePath" user=all 2>&1

    if ($LASTEXITCODE -ne 0)
    {
        $detail = ($netshOutput | Out-String).Trim()

        Fail-Migration "Failed to import the generated migration profile for '$MigrationSSID' ($($Security.Authentication)/$($Security.Encryption), netsh exit code $LASTEXITCODE). netsh reported: $detail"
    }
}
finally
{
    Remove-Item -Path $ProfilePath -Force -ErrorAction SilentlyContinue
}

#
# Prioritise the migration profile.
#
# Non-fatal: the explicit connect below does not depend on profile order. It
# matters for what the device reconnects to on its own afterwards.
#
Write-Log "Setting migration profile priority."

netsh wlan set profileorder `
    name="$MigrationSSID" `
    interface="$InterfaceName" | Out-Null

if ($LASTEXITCODE -ne 0)
{
    Write-Log "WARNING: Unable to set profile priority (netsh exit code $LASTEXITCODE)."
}

#
# Auto-connect. Non-fatal for the same reason.
#
Write-Log "Configuring '$MigrationSSID' for automatic connection."

netsh wlan set profileparameter `
    name="$MigrationSSID" `
    connectionmode=auto | Out-Null

if ($LASTEXITCODE -ne 0)
{
    Write-Log "WARNING: Unable to configure automatic connection (netsh exit code $LASTEXITCODE)."
}

#
# Connect
#
Write-Log "Connecting to '$MigrationSSID'..."

netsh wlan connect `
    name="$MigrationSSID" `
    interface="$InterfaceName" | Out-Null

if ($LASTEXITCODE -ne 0)
{
    Write-Log "WARNING: netsh wlan connect returned $LASTEXITCODE. Waiting for association anyway."
}

#
# Wait for association.
#
# Both SSID and state are checked. netsh reports the SSID while the interface
# is still authenticating, so matching on SSID alone can break out of this loop
# mid-handshake and fail a device that was about to connect. On a PSK network a
# wrong key shows as associated but never reaches 'connected'.
#
Write-Log "Waiting up to $AssociationTimeoutSec seconds to associate with '$MigrationSSID'..."

$Connected  = $false
$WaitedSecs = 0
$Last       = $null

for ($i = 1; $i -le $AssociationTimeoutSec; $i++)
{
    Start-Sleep 1
    $WaitedSecs = $i

    $Last = Get-WlanInterfaceInfo

    if ($Last -and $Last.Ssid -eq $MigrationSSID -and $Last.IsConnected)
    {
        $Connected = $true
        break
    }
}

if (!$Connected)
{
    if ($Last)
    {
        $detail = "Last seen SSID '$($Last.Ssid)', state '$($Last.State)'."
    }
    else
    {
        $detail = "The wireless interface disappeared."
    }

    Fail-Migration "Timed out after $AssociationTimeoutSec seconds waiting to associate with '$MigrationSSID'. $detail"
}

Write-Log "Associated with migration Wi-Fi after $WaitedSecs second(s)."

#
# Wait for DHCP.
#
# Association is not connectivity. Without an address, gateway and working DNS
# the reachability test below fails for a device that is merely slow rather
# than broken. A 169.254.x.x address means DHCP never answered.
#
Write-Log "Waiting up to $DhcpTimeoutSec seconds for an IP address and gateway..."

$HasAddress = $false
$LastAddr   = "none"

for ($i = 1; $i -le $DhcpTimeoutSec; $i++)
{
    $Cfg = Get-NetIPConfiguration -InterfaceAlias $InterfaceName -ErrorAction SilentlyContinue

    if ($Cfg -and $Cfg.IPv4Address -and $Cfg.IPv4DefaultGateway)
    {
        $LastAddr = ($Cfg.IPv4Address | Select-Object -First 1).IPAddress

        if ($LastAddr -notlike '169.254.*')
        {
            $Gateway    = ($Cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
            $HasAddress = $true

            Write-Log "Address $LastAddr, gateway $Gateway."
            break
        }
    }

    Start-Sleep 1
}

if (!$HasAddress)
{
    Fail-Migration "Associated with '$MigrationSSID' but no usable DHCP address after $DhcpTimeoutSec seconds. Last address: $LastAddr."
}

#
# Resolve the PSP endpoint from the agent's own registry key, so the check
# below tests the exact server the agent uses. Falls back to the configured
# default if the key is missing or unreadable.
#
$RegServer = Get-PSPServerFromRegistry

if ($RegServer)
{
    $PSPServer = $RegServer.ServerHost
    $PSPPort   = $RegServer.Port
    Write-Log "PSP endpoint from agent registry: ${PSPServer}:$PSPPort"
}
else
{
    Write-Log "PSP endpoint not found in registry; using configured default ${PSPServer}:$PSPPort"
}

#
# Verify connectivity to PSP.
#
# Retried, because a single probe makes one dropped packet indistinguishable
# from a broken network, and a false failure here costs a halted migration and
# a helpdesk ticket.
#
Write-Log "Testing connectivity to ${PSPServer}:$PSPPort..."

$Reachable = $false

for ($i = 1; $i -le $ConnectivityAttempts; $i++)
{
    $Reachable = Test-NetConnection `
        -ComputerName $PSPServer `
        -Port $PSPPort `
        -InformationLevel Quiet `
        -WarningAction SilentlyContinue

    if ($Reachable)
    {
        Write-Log "PowerSyncPro server reachable (attempt $i of $ConnectivityAttempts)."
        break
    }

    Write-Log "Connectivity attempt $i of $ConnectivityAttempts failed."

    if ($i -lt $ConnectivityAttempts)
    {
        Start-Sleep -Seconds $ConnectivityRetryDelaySec
    }
}

if (!$Reachable)
{
    Fail-Migration "Unable to reach $PSPServer on port $PSPPort after $ConnectivityAttempts attempts."
}

Write-Log "Startup Wi-Fi migration completed successfully. Handing back to PowerSyncPro."

Stop-Logging

exit 0
