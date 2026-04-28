<#
.SYNOPSIS
    Fixes a bad SID translation in a PowerSyncPro Migration Agent migration.

.DESCRIPTION
    This script handles the situation where a user was incorrectly mapped to the wrong
    target SID during a PowerSyncPro migration. The user's profile exists under its
    original path but is associated with an incorrect "Bad SID" in the registry, while
    the user received a fresh temporary profile when they logged in with their real
    target credentials.

    It performs the following actions:

        1.  Validates that the script is running with administrative rights.
        2.  Validates SID formats for all provided SIDs.
        3.  Resolves the Bad SID from the registry by ProfileImagePath lookup if not supplied.
        4.  Determines the Runbook GUID from the Migration Agent data folder, or prompts
            the user to choose if multiple runbooks are present.
        5.  Enumerates all profiles under ProfileList for troubleshooting.
        6.  Renames the Bad SID registry key to the Source SID and updates the binary SID value.
        7.  Locates the temporary profile folder created for the Target SID and renames it to .bak.
        8.  Stops the PowerSyncPro Migration Agent service.
        9.  Clears the Migration Agent working directory.
        10. Creates the Runbook folder and writes a corrected TranslationTable.json.
        11. Restarts the PowerSyncPro Migration Agent service.
        12. Logs all actions to a transcript file in C:\Temp.

    !! WARNING !!
    You MUST correct the translation table in the PowerSyncPro Web Admin Panel BEFORE
    running this script. If the bad translation entry still exists in PowerSyncPro, the
    Migration Agent will re-apply the incorrect mapping and undo the fix.

    This script must be run as a local administrator account that is NOT one of the
    affected users - for example, the PSP Fallback Account. Do not run this script
    while logged in as the Source, Target, or Bad SID user.

    After this script completes, re-run the PowerSyncPro migration. The agent will
    re-permission the profile from SourceSid to TargetSid and remove the Bad SID.

    SIDs can be found in the translation table at:
        <PSP Server URL>/migrationAgent/CheckTranslationEntries

.PARAMETER SourceSid
    The original (pre-migration) SID for the user whose translation was incorrect.

.PARAMETER TargetSid
    The correct target SID the user should be translated to.

.PARAMETER BadSid
    The incorrect SID that the profile was mistakenly translated to. If omitted,
    -ProfilePath must be provided so the script can look it up from the registry.

.PARAMETER ProfilePath
    The path to the user's existing profile folder (e.g. C:\Users\jsmith). Used to
    locate the Bad SID in the registry when -BadSid is not provided.

.PARAMETER RunbookGuid
    The GUID of the PowerSyncPro Migration Agent runbook to recreate. If omitted,
    the script will attempt to discover it from the Migration Agent data folder.
    If multiple runbooks are found, the script will prompt for the correct GUID.

    You will need the GUID of the runbook that was deployed to this workstation.
    This can be obtained directly from the SQL database or via Developer Mode in your browser:

        1. Open the Runbooks page in PowerSyncPro in a Chromium-based browser
           (Chrome, Edge, Brave, Opera, etc.).
        2. Press F12 to open Developer Tools (or Ctrl+Shift+I).
        3. Click the "Network" tab.
        4. Click the "Edit" button on your selected runbook.
        5. In the Network tab, find the request for "EditModal" - the runbook GUID
           appears as the "runbookId" query parameter.
           Ex: https://psp1.company.com/migrationAgent/Runbooks/EditModal?runbookId=df0a0278-9d4a-4c96-32dc-08de15914463
        6. Right-click the request and select "Copy URL" to grab the full URL,
           or note the GUID after the "=" sign.
           Ex: df0a0278-9d4a-4c96-32dc-08de15914463

.NOTES
    Author: Jamie Richard / PowerSyncPro
    Script Name: PSP-FixBadTranslation.ps1
    Requirements:
        - Must be run as Administrator
        - PowerShell 5.1 or later
        - Requires access to HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
    Output:
        Transcript log written to C:\Temp\PSP-FixBadTranslation-<timestamp>.log
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $SourceSid,

    [Parameter(Mandatory = $true)]
    [string] $TargetSid,

    [Parameter(Mandatory = $false)]
    [string] $BadSid,

    [Parameter(Mandatory = $false)]
    [string] $ProfilePath,

    [Parameter(Mandatory = $false)]
    [string] $RunbookGuid
)

# Console logger helpers
function _info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function _ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function _warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function _err($m)  { Write-Host "[-] $m" -ForegroundColor Red }

function Assert-ValidSid {
    param([string]$Sid, [string]$ParamName)
    if ($Sid -notmatch '^S-1-\d+(-\d+)+$') {
        _err "Invalid SID format for ${ParamName}: [$Sid]. Expected format: S-1-X-X-..."
        throw "Invalid SID: $ParamName"
    }
}

# Start transcript
$logDir = "C:\Temp"
if (-not (Test-Path -Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "PSP-FixBadTranslation-$timeStamp.log"
Start-Transcript -Path $logFile -Force | Out-Null

$asciiLogo = @"
 ____                        ____                   ____
|  _ \ _____      _____ _ __/ ___| _   _ _ __   ___|  _ \ _ __ ___
| |_) / _ \ \ /\ / / _ \ '__\___ \| | | | '_ \ / __| |_) | '__/ _ \
|  __/ (_) \ V  V /  __/ |   ___) | |_| | | | | (__|  __/| | | (_) |
|_|   \___/ \_/\_/ \___|_|  |____/ \__, |_| |_|\___|_|   |_|  \___/
                                   |___/
"@

try {
    Write-Host $asciiLogo -ForegroundColor Cyan
    _info "Starting PowerSyncPro bad translation fix."

    # Elevation check
    $currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        _err "This script must be run as Administrator."
        throw "Not running as Administrator."
    }

    # Validate SID formats for known SIDs up front
    Assert-ValidSid -Sid $SourceSid -ParamName "SourceSid"
    Assert-ValidSid -Sid $TargetSid -ParamName "TargetSid"
    if ($BadSid) { Assert-ValidSid -Sid $BadSid -ParamName "BadSid" }

    # Require at least BadSid or ProfilePath
    if (-not $BadSid -and -not $ProfilePath) {
        _err "You must supply either -BadSid or -ProfilePath so the script can identify the incorrect profile registry key."
        throw "Missing BadSid or ProfilePath."
    }

    $profileListBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    # Resolve BadSid from registry ProfileImagePath if not provided directly
    if (-not $BadSid) {
        _info "No BadSid provided - searching registry for a profile matching path [$ProfilePath]."
        $normalizedSearch = $ProfilePath.TrimEnd('\').ToLower()
        $resolved = $null
        foreach ($p in (Get-ChildItem -Path $profileListBase -ErrorAction SilentlyContinue)) {
            try {
                $pip = (Get-ItemProperty -Path $p.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
                if ($pip.TrimEnd('\').ToLower() -eq $normalizedSearch) {
                    $resolved = $p.PSChildName
                    break
                }
            } catch { }
        }
        if (-not $resolved) {
            _err "Could not find a ProfileList registry key whose ProfileImagePath matches [$ProfilePath]."
            throw "BadSid lookup failed."
        }
        $BadSid = $resolved
        _ok "Resolved BadSid from registry: [$BadSid]"
        Assert-ValidSid -Sid $BadSid -ParamName "BadSid (resolved)"
    }

    _info "  SourceSid  : $SourceSid"
    _info "  TargetSid  : $TargetSid"
    _info "  BadSid     : $BadSid"

    # Verify the current session is not running as any of the affected SIDs
    $currentSid = $currentIdentity.User.Value
    _info "Current process SID is [$currentSid]."
    foreach ($affected in @($SourceSid, $TargetSid, $BadSid)) {
        if ($currentSid -eq $affected) {
            _err "You are running this script under one of the affected SIDs [$affected]. Log off and run this as a different admin account."
            throw "Cannot run while logged in as an affected SID."
        }
    }

    # Enumerate existing profiles for troubleshooting
    _info "Enumerating existing profile mappings..."
    foreach ($p in (Get-ChildItem -Path $profileListBase -ErrorAction SilentlyContinue)) {
        try {
            $enumPath = (Get-ItemProperty -Path $p.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            $sidStr   = $p.PSChildName
            $userName = try { (New-Object System.Security.Principal.SecurityIdentifier($sidStr)).Translate([System.Security.Principal.NTAccount]).Value } catch { "Unknown" }
            _info "Profile: $userName | SID: $sidStr | Path: $enumPath"
        } catch {
            _warn "Failed to enumerate a profile key: $($_.Exception.Message)"
        }
    }

    # Resolve RunbookGuid from the Migration Agent data folder if not provided
    $agentDataPath = Join-Path $env:ProgramData "Declaration Software\Migration Agent"
    $guidPattern   = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    function Read-RunbookGuid {
        param([string]$Prompt)
        $input = (Read-Host $Prompt).Trim()
        if ($input -notmatch $guidPattern) { throw "Invalid GUID format entered: [$input]" }
        return $input
    }

    if (-not $RunbookGuid) {
        _info "No RunbookGuid provided - scanning [$agentDataPath] for runbook folders."
        $runbookDirs = @()
        if (Test-Path -Path $agentDataPath) {
            $runbookDirs = @(Get-ChildItem -Path $agentDataPath -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match $guidPattern })
        }

        if ($runbookDirs.Count -eq 0) {
            _warn "No runbook folders found in [$agentDataPath]."
            $RunbookGuid = Read-RunbookGuid "Enter the RunbookGuid manually"
        } else {
            # Try to match by TranslationTable.json content: look for SourceSid -> BadSid entry
            $matched = @()
            foreach ($dir in $runbookDirs) {
                $ttFile = Join-Path $dir.FullName "TranslationTable.json"
                if (Test-Path -Path $ttFile) {
                    try {
                        $raw = (Get-Content -Path $ttFile -Raw).Trim()
                        if ([string]::IsNullOrEmpty($raw)) {
                            _info "TranslationTable.json in [$($dir.Name)] is empty - skipping."
                        } else {
                            $tt  = $raw | ConvertFrom-Json
                            $hit = $tt.PSObject.Properties | Where-Object { $_.Name -eq $SourceSid -and $_.Value -eq $BadSid }
                            if ($hit) { $matched += $dir.Name }
                        }
                    } catch {
                        _warn "Could not parse TranslationTable.json in [$($dir.Name)]: $($_.Exception.Message)"
                    }
                }
            }

            if ($matched.Count -eq 1) {
                $RunbookGuid = $matched[0]
                _ok "Matched RunbookGuid by TranslationTable.json: [$RunbookGuid]"
            } elseif ($matched.Count -gt 1) {
                _warn "Multiple runbooks matched the translation table:"
                $matched | ForEach-Object { Write-Host "    $_" }
                $RunbookGuid = Read-RunbookGuid "Enter the correct RunbookGuid from the list above"
            } elseif ($runbookDirs.Count -eq 1) {
                _warn "TranslationTable.json did not match SourceSid/BadSid - only one runbook folder found, using it."
                $RunbookGuid = $runbookDirs[0].Name
            } else {
                _warn "Could not match any runbook by TranslationTable.json. Folders found:"
                $runbookDirs | ForEach-Object { Write-Host "    $($_.Name)" }
                $RunbookGuid = Read-RunbookGuid "Enter the correct RunbookGuid from the list above"
            }
        }
    }

    _info "  RunbookGuid: $RunbookGuid"

    # ── Registry: rename BadSid key to SourceSid ─────────────────────────────

    $badKeyPath    = Join-Path $profileListBase $BadSid
    $sourceKeyPath = Join-Path $profileListBase $SourceSid

    if (-not (Test-Path -Path $badKeyPath)) {
        _err "ProfileList registry key for BadSid [$BadSid] does not exist."
        throw "BadSid profile key not found."
    }
    if (Test-Path -Path $sourceKeyPath) {
        _err "ProfileList key for SourceSid [$SourceSid] already exists - manual investigation required."
        throw "SourceSid profile key already exists."
    }

    _info "Renaming ProfileList key from [$BadSid] to [$SourceSid]."
    Rename-Item -Path $badKeyPath -NewName $SourceSid -ErrorAction Stop
    _ok "Registry key renamed."

    _info "Updating binary Sid value to [$SourceSid]."
    $sidObj   = New-Object System.Security.Principal.SecurityIdentifier($SourceSid)
    $sidBytes = New-Object byte[] ($sidObj.BinaryLength)
    $sidObj.GetBinaryForm($sidBytes, 0)
    Set-ItemProperty -Path $sourceKeyPath -Name "Sid" -Value $sidBytes -Type Binary -ErrorAction Stop
    _ok "Binary Sid value updated."

    # ── Rename the temporary TargetSid profile folder out of the way ──────────

    $targetKeyPath = Join-Path $profileListBase $TargetSid
    if (Test-Path -Path $targetKeyPath) {
        $tempProfileFolder = (Get-ItemProperty -Path $targetKeyPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($tempProfileFolder -and (Test-Path -Path $tempProfileFolder)) {
            $bakPath = "$tempProfileFolder.bak"
            $suffix  = 1
            while (Test-Path -Path $bakPath) {
                $bakPath = "$tempProfileFolder.bak$suffix"
                $suffix++
            }
            _info "Renaming temporary Target SID profile folder [$tempProfileFolder] to [$bakPath]."
            try {
                Rename-Item -Path $tempProfileFolder -NewName (Split-Path $bakPath -Leaf) -ErrorAction Stop
                _ok "Temporary profile folder renamed."
            } catch {
                _warn "Could not rename temporary profile folder: $($_.Exception.Message)"
            }
        } else {
            _warn "TargetSid registry key exists but profile folder [$tempProfileFolder] was not found on disk - skipping folder rename."
        }

        _info "Renaming TargetSid registry key [$TargetSid] to [$TargetSid.bak]."
        try {
            Rename-Item -Path $targetKeyPath -NewName "$TargetSid.bak" -ErrorAction Stop
            _ok "TargetSid registry key renamed."
        } catch {
            _warn "Could not rename TargetSid registry key: $($_.Exception.Message)"
        }
    } else {
        _info "No registry entry found for TargetSid [$TargetSid] - no temporary profile to rename."
    }

    # ── Stop Migration Agent service ──────────────────────────────────────────

    $serviceName = "PowerSyncPro Migration Agent"
    _info "Stopping service [$serviceName]."
    try {
        $svc = Get-Service -Name $serviceName -ErrorAction Stop
        if ($svc.Status -ne "Stopped") {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            $svc.WaitForStatus("Stopped", (New-TimeSpan -Seconds 60))
        }
        _ok "Service [$serviceName] stopped."
    } catch {
        _warn "Could not stop service [$serviceName]: $($_.Exception.Message)"
    }

    # ── Clear Migration Agent data folder ─────────────────────────────────────

    _info "Clearing Migration Agent data folder: $agentDataPath"
    if (Test-Path -Path $agentDataPath) {
        try {
            Remove-Item -Path $agentDataPath -Recurse -Force -ErrorAction Stop
            _ok "Migration Agent data folder cleared."
        } catch {
            _warn "Failed to clear Migration Agent data folder: $($_.Exception.Message)"
        }
    } else {
        _warn "Migration Agent data folder does not exist: $agentDataPath"
    }

    # ── Create runbook folder and TranslationTable.json ───────────────────────

    $runbookPath     = Join-Path $agentDataPath $RunbookGuid
    $translationFile = Join-Path $runbookPath "TranslationTable.json"

    _info "Creating runbook folder: $runbookPath"
    New-Item -Path $runbookPath -ItemType Directory -Force | Out-Null

    $translationTable = [ordered]@{
        $SourceSid = $TargetSid
        $BadSid    = $TargetSid
    }
    $translationJson = $translationTable | ConvertTo-Json -Depth 2
    $translationJson | Out-File -FilePath $translationFile -Encoding utf8 -Force
    _ok "TranslationTable.json written to: $translationFile"
    _info "Translation table contents:"
    Write-Host $translationJson

    # ── Start Migration Agent service ─────────────────────────────────────────

    _info "Starting service [$serviceName]."
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        _ok "Service [$serviceName] started."
    } catch {
        _warn "Failed to start service [$serviceName]: $($_.Exception.Message)"
    }

    _ok "Bad translation fix complete."
    _info "Next steps:"
    _info "  1. Re-run the PowerSyncPro migration for this device or user."
    _info "  2. The agent will re-permission the profile from SourceSid to TargetSid and remove the Bad SID."
    _info "  3. Confirm login with the affected user account."
    _info "Transcript log saved to: $logFile"
}
catch {
    _err "An error occurred: $($_.Exception.Message)"
    _info "See transcript log for details: $logFile"
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
