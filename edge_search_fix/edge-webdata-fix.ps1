<#
.SYNOPSIS
    Renames Microsoft Edge 'Web Data' databases for all user profiles on a machine.

.DESCRIPTION
    Designed to run as SYSTEM (e.g. as a post-migration step in PowerSyncPro,
    Intune Win32 app, scheduled task, or RMM) after a user identity migration
    that causes Edge to drop search engines from its keywords table.

    For every local user profile on the machine, the script:
      1. Locates %LOCALAPPDATA%\Microsoft\Edge\User Data
      2. Enumerates every Edge profile folder (Default, Profile 1, Profile 2, ...)
      3. Checks whether Edge is running for that user; skips with a warning if so
         (renaming a locked SQLite file would either fail or be reverted)
      4. Renames 'Web Data', 'Web Data-journal', 'Web Data-wal', 'Web Data-shm'
         to '<name>.bak-<timestamp>' so Edge regenerates them on next launch.

    Existing .bak-* files from prior runs are left in place. Original ACLs are
    preserved by Rename-Item (it does not modify the security descriptor).

    The script does NOT touch bookmarks, history, passwords, cookies, extensions,
    or settings -- only the Web Data SQLite database that holds the keywords table.

.PARAMETER WhatIf
    Standard PowerShell -WhatIf. Shows what would be renamed without renaming.

.PARAMETER LogPath
    Optional path to a log file. Defaults to
    C:\Temp\Reset-EdgeWebData.log. The parent directory will be created if it
    does not exist.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Reset-EdgeWebData.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Reset-EdgeWebData.ps1 -WhatIf

.NOTES
    Run as SYSTEM or an administrator. Standard users cannot enumerate other
    users' profile folders.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$LogPath = 'C:\Temp\Reset-EdgeWebData.log'
)

# ---------- Logging ----------
# Ensure the log directory exists once at startup rather than on every write.
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    try {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "[WARN] Could not create log directory '$logDir': $($_.Exception.Message). Logging to console only."
        $LogPath = $null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SKIP','OK')][string]$Level = 'INFO',
        [switch]$FileOnly
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $FileOnly) { Write-Host $line }
    if ($LogPath) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop
        } catch { }
    }
}

# ---------- Profile enumeration ----------
function Get-LocalUserProfilePaths {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $allKeys = @(Get-ChildItem -Path $key -ErrorAction Stop)
    Write-Log "ProfileList: $($allKeys.Count) SID entries found in registry." -FileOnly
    $allKeys | ForEach-Object {
            $sid = Split-Path $_.Name -Leaf
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            $rawPath = $props.ProfileImagePath

            if (-not $rawPath) {
                Write-Log "  SID $sid -- SKIP: no ProfileImagePath value" -Level SKIP -FileOnly
                return
            }
            $sidMatch = ($sid -match '^S-1-5-21-' -or $sid -match '^S-1-12-1-')
            if (-not $sidMatch) {
                Write-Log "  SID $sid -- SKIP: not a user SID (path: $rawPath)" -Level SKIP -FileOnly
                return
            }
            $pathExists = Test-Path -LiteralPath $rawPath
            if (-not $pathExists) {
                Write-Log "  SID $sid -- SKIP: profile path not on disk: $rawPath" -Level SKIP -FileOnly
                return
            }
            Write-Log "  SID $sid -- OK: $rawPath" -FileOnly
            [pscustomobject]@{
                Sid         = $sid
                ProfilePath = $rawPath
            }
        }
}

# ---------- Edge running check ----------
function Test-EdgeRunningForUser {
    param([Parameter(Mandatory)][string]$UserProfilePath)

    # Get all msedge.exe processes with their owner. If any have a command line
    # referencing this user's profile, treat as running. We use CIM to get owner
    # info without needing -IncludeUserName (which requires elevation differently).
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop
    } catch {
        Write-Log "Could not query msedge.exe processes: $($_.Exception.Message)" -Level WARN
        return $false  # Assume not running rather than blocking everything
    }

    foreach ($p in $procs) {
        # Owner lookup
        $owner = $null
        try {
            $ownerResult = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($ownerResult.ReturnValue -eq 0) {
                $owner = "$($ownerResult.Domain)\$($ownerResult.User)"
            }
        } catch { }

        # Match if the command line references this profile's user folder. Edge
        # processes inherit the launching user's profile path, so checking the
        # command line for the username folder name is the most reliable signal.
        $userFolder = Split-Path $UserProfilePath -Leaf
        if ($p.CommandLine -and $p.CommandLine -match [regex]::Escape("\Users\$userFolder\")) {
            return $true
        }
        # Fallback: owner matches the leaf folder name (covers case where Edge
        # was launched without a custom --user-data-dir)
        if ($owner -and ($owner -split '\\')[-1] -ieq $userFolder) {
            return $true
        }
    }
    return $false
}

# ---------- Rename a single file with sidecars ----------
function Rename-WebDataFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProfileFolder,
        [Parameter(Mandatory)][string]$Stamp
    )

    # SQLite stores the main DB plus optional sidecars. Rename all that exist.
    $names = @('Web Data', 'Web Data-journal', 'Web Data-wal', 'Web Data-shm')
    $renamed = 0
    foreach ($name in $names) {
        $src = Join-Path $ProfileFolder $name
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $dst = "$src.bak-$Stamp"
        try {
            if ($PSCmdlet.ShouldProcess($src, "Rename to $dst")) {
                Rename-Item -LiteralPath $src -NewName (Split-Path $dst -Leaf) -ErrorAction Stop
                Write-Log "Renamed: $src -> $(Split-Path $dst -Leaf)" -Level OK -FileOnly
                $renamed++
            }
        } catch {
            Write-Log "Failed to rename '$src': $($_.Exception.Message)" -Level ERROR
        }
    }
    return $renamed
}

# ---------- Main ----------
Write-Log "Reset-EdgeWebData starting"
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -FileOnly

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summary = [pscustomobject]@{
    ProfilesScanned        = 0
    EdgeProfilesFound      = 0
    EdgeProfilesProcessed  = 0
    EdgeProfilesSkippedRunning = 0
    FilesRenamed           = 0
    Errors                 = 0
}
$processedUsers = [System.Collections.Generic.List[string]]::new()

try {
    $userProfiles = @(Get-LocalUserProfilePaths)
} catch {
    Write-Log "Failed to enumerate user profiles: $($_.Exception.Message)" -Level ERROR
    exit 2
}

Write-Log "Found $($userProfiles.Count) eligible user profile(s) on this machine."

foreach ($up in $userProfiles) {
    $summary.ProfilesScanned++
    Write-Log "--- Profile: SID=$($up.Sid) Path=$($up.ProfilePath)" -FileOnly

    $appData      = Join-Path $up.ProfilePath 'AppData'
    $local        = Join-Path $up.ProfilePath 'AppData\Local'
    $msEdge       = Join-Path $up.ProfilePath 'AppData\Local\Microsoft\Edge'
    $edgeUserData = Join-Path $up.ProfilePath 'AppData\Local\Microsoft\Edge\User Data'
    Write-Log "  AppData exists:         $(Test-Path -LiteralPath $appData)" -FileOnly
    Write-Log "  AppData\Local exists:   $(Test-Path -LiteralPath $local)" -FileOnly
    Write-Log "  ...\Edge exists:        $(Test-Path -LiteralPath $msEdge)" -FileOnly
    Write-Log "  ...\Edge\User Data:     $(Test-Path -LiteralPath $edgeUserData)" -FileOnly

    if (-not (Test-Path -LiteralPath $edgeUserData)) {
        Write-Log "No Edge user data for $($up.ProfilePath) -- skipping." -Level SKIP -FileOnly
        continue
    }

    $edgeProfiles = @(
        Get-ChildItem -LiteralPath $edgeUserData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }
    )

    if ($edgeProfiles.Count -eq 0) {
        $allDirs = @(Get-ChildItem -LiteralPath $edgeUserData -Directory -ErrorAction SilentlyContinue)
        if ($allDirs.Count -gt 0) {
            Write-Log "  Subdirs present (none matched filter): $($allDirs.Name -join ', ')" -Level WARN -FileOnly
        } else {
            $dirErr = $null
            Get-ChildItem -LiteralPath $edgeUserData -Directory -ErrorVariable dirErr -ErrorAction SilentlyContinue | Out-Null
            if ($dirErr) {
                Write-Log "  Get-ChildItem error: $($dirErr[0].Exception.Message)" -Level ERROR -FileOnly
            } else {
                Write-Log "  Directory is empty or inaccessible (no error returned)" -Level WARN -FileOnly
            }
        }
        Write-Log "No Edge profile folders under '$edgeUserData' -- skipping." -Level SKIP -FileOnly
        continue
    }

    Write-Log "Edge profile folders found: $($edgeProfiles.Name -join ', ')" -FileOnly

    $isRunning = Test-EdgeRunningForUser -UserProfilePath $up.ProfilePath
    if ($isRunning) {
        Write-Log "Edge running for $($up.ProfilePath) -- skipping to avoid corruption." -Level WARN -FileOnly
        $summary.EdgeProfilesSkippedRunning += $edgeProfiles.Count
        $summary.EdgeProfilesFound += $edgeProfiles.Count
        continue
    }

    foreach ($ep in $edgeProfiles) {
        $summary.EdgeProfilesFound++
        Write-Log "Processing: $($ep.FullName)" -FileOnly
        $count = Rename-WebDataFile -ProfileFolder $ep.FullName -Stamp $stamp
        if ($count -gt 0) {
            $summary.EdgeProfilesProcessed++
            $summary.FilesRenamed += $count
            $username = Split-Path $up.ProfilePath -Leaf
            if (-not $processedUsers.Contains($username)) { $processedUsers.Add($username) }
        } else {
            Write-Log "  No Web Data files present in $($ep.FullName)" -Level SKIP -FileOnly
        }
    }
}

Write-Log ("  Profiles scanned: {0} | Edge profiles processed: {1} | Files renamed: {2} | Skipped (Edge running): {3}" -f `
    $summary.ProfilesScanned, $summary.EdgeProfilesProcessed, $summary.FilesRenamed, $summary.EdgeProfilesSkippedRunning) -FileOnly
$usersStr = if ($processedUsers.Count -gt 0) { $processedUsers -join ', ' } else { 'none' }
Write-Log ("Reset-EdgeWebData done -- profiles={0} files={1} skipped={2} users={3}" -f `
    $summary.EdgeProfilesProcessed, $summary.FilesRenamed, $summary.EdgeProfilesSkippedRunning, $usersStr)

# Exit code: 0 = success, 1 = some skipped due to Edge running (caller may want to retry), 2 = hard error
if ($summary.EdgeProfilesSkippedRunning -gt 0) { exit 1 } else { exit 0 }