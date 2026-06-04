#Requires -Version 5.1
<#
.SYNOPSIS
    Reverses Folder Redirection for AD-to-Entra migration prep.

.DESCRIPTION
    Copies redirected folders (Desktop, Documents, Pictures, etc.) from their
    UNC server locations back to local profile paths, rewrites the shell folder
    registry values, and clears the Group Policy Folder Redirection CSE state.

    Designed to run via RMM (Atera, NinjaOne, etc.) as SYSTEM or as the user.
    Must be deployed AFTER removing the user from the Folder Redirection GPO
    scope, so re-redirection will not occur on next logon.

    When run as SYSTEM, user-context operations (GUI dialogs, file copies) are
    spawned as temporary scheduled tasks in the logged-in user's session.
    Results are communicated back via a temp JSON file.

.PARAMETER VpnClientName
    Display name of the VPN client shown in user-facing dialogs.
    Default: 'your VPN'

.PARAMETER VpnTimeoutMinutes
    How long to wait for VPN connectivity before giving up.
    Default: 30

.PARAMETER LogoffCountdownSeconds
    Countdown duration (seconds) before automatic logoff.
    Default: 30

.PARAMETER LogPath
    Directory for log files and manifests.
    Default: C:\ProgramData\Migration

.PARAMETER TestMode
    Perform all steps except registry rewrite, CSE clear, and logoff.
    Writes log and manifest with TESTMODE marker. Safe for piloting.

.PARAMETER SkipLogoff
    Skip the logoff step after successful completion.

.PARAMETER AdditionalAppsToClose
    Additional process names (without .exe) to include in the app-close dialog.

.EXAMPLE
    .\cleanup_redirection.ps1

.EXAMPLE
    .\cleanup_redirection.ps1 -VpnClientName 'GlobalProtect' -VpnTimeoutMinutes 45

.EXAMPLE
    .\cleanup_redirection.ps1 -TestMode -SkipLogoff

.NOTES
    Exit codes:
      0 = Success (or nothing to do - already local)
      1 = Unexpected error
      2 = No user logged in (deferred - retry later)
      3 = User cancelled
      4 = VPN timeout
      5 = File copy failure (no registry changes made)
      6 = Registry rewrite failure (data copied but registry not updated)
      7 = User profile path could not be determined

    Compatibility: PowerShell 5.1, Windows 10/11
    No external dependencies. No PS modules required.
    Encoding: ASCII-safe (no Unicode characters)
#>
param(
    [string]$VpnClientName = 'your VPN',
    [int]$VpnTimeoutMinutes = 30,
    [int]$LogoffCountdownSeconds = 30,
    [string]$LogPath = 'C:\ProgramData\Migration',
    [switch]$TestMode,
    [switch]$SkipLogoff,
    [int]$WaitForLoginMinutes = 6000,
    [string[]]$AdditionalAppsToClose = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Script-scope globals
# ---------------------------------------------------------------------------
$Script:LogFile          = $null
$Script:RunningAsSystem  = $false
$Script:TargetUser       = $null   # hashtable: Username, Domain, SID, ProfilePath
$Script:ManifestData     = $null

# Shell folder registry value names to inspect
$Script:ShellFolderNames = @(
    'Desktop',
    'Personal',
    'My Pictures',
    'My Music',
    'My Video',
    'Favorites',
    '{374DE290-123F-4565-9164-39C4925E467B}',
    'Start Menu',
    'Programs',
    'Startup'
)

# Map from shell folder value name to relative path under USERPROFILE
$Script:LocalTargets = [ordered]@{
    'Desktop'     = 'Desktop'
    'Personal'    = 'Documents'
    'My Pictures' = 'Pictures'
    'My Music'    = 'Music'
    'My Video'    = 'Videos'
    'Favorites'   = 'Favorites'
    '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
    'Start Menu'  = 'AppData\Roaming\Microsoft\Windows\Start Menu'
    'Programs'    = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
    'Startup'     = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
}

# Default apps to prompt the user to close before migration
$Script:DefaultAppsToClose = @(
    'OUTLOOK', 'WINWORD', 'EXCEL', 'POWERPNT', 'ONENOTE', 'MSACCESS', 'VISIO', 'PROJECT',
    'AcroRd32', 'Acrobat',
    'msedge', 'chrome', 'firefox', 'brave', 'opera',
    'OneDrive', 'Dropbox', 'googledrivesync',
    'Code', 'notepad++', 'sublime_text',
    'Teams', 'ms-teams', 'slack'
)


# ===========================================================================
# SECTION: Logging
# ===========================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if ($Script:LogFile) {
        try {
            Add-Content -Path $Script:LogFile -Value $line -Encoding ASCII -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Initialize-LogFile {
    # Ensure log directory exists and is writable by the user
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        # Grant Users group write access so user-context tasks can write logs
        try {
            $acl = Get-Acl $LogPath
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Users',
                'Modify',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $LogPath -AclObject $acl
        } catch {
            Write-Host "[WARN] Could not set ACL on $LogPath - user-context tasks may fail to write logs"
        }
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $username = if ($Script:TargetUser) { $Script:TargetUser.Username } else { 'unknown' }
    $Script:LogFile = Join-Path $LogPath "unredirect-$username-$ts.log"
    Write-Log "Log initialized: $($Script:LogFile)"
    if ($TestMode) { Write-Log "*** TEST MODE - no registry changes or logoff will occur ***" }
}


# ===========================================================================
# SECTION: Manifest
# ===========================================================================

function Write-Manifest {
    param([hashtable]$Data)
    if (-not $Script:TargetUser) { return }
    $manifestPath = Join-Path $LogPath "unredirect-$($Script:TargetUser.Username).json"
    try {
        # Build a simple JSON string manually - avoids ConvertTo-Json depth issues in PS5.1
        $lines = @()
        $lines += '{'
        $lines += "  `"SchemaVersion`": `"1.0`","
        $lines += "  `"Timestamp`": `"$(Get-Date -Format 'o')`","
        $lines += "  `"TestMode`": $(if ($TestMode) { 'true' } else { 'false' }),"
        $lines += "  `"Username`": `"$($Data.Username)`","
        $lines += "  `"SID`": `"$($Data.SID)`","
        $lines += "  `"ProfilePath`": `"$($Data.ProfilePath -replace '\\', '\\')`","
        $lines += "  `"Result`": `"$($Data.Result)`","
        $lines += "  `"ForceCloseUsed`": $(if ($Data.ForceCloseUsed) { 'true' } else { 'false' }),"

        $killedArr = if ($Data.AppsKilled -and $Data.AppsKilled.Count -gt 0) {
            '["' + ($Data.AppsKilled -join '","') + '"]'
        } else { '[]' }
        $lines += "  `"AppsKilled`": $killedArr,"

        # Folders array
        $lines += '  "Folders": ['
        $folderLines = @()
        foreach ($f in $Data.Folders) {
            $fl = @()
            $fl += '    {'
            $fl += "      `"ValueName`": `"$($f.ValueName)`","
            $fl += "      `"SourcePath`": `"$($f.SourcePath -replace '\\', '\\')`","
            $fl += "      `"LocalTarget`": `"$($f.LocalTarget -replace '\\', '\\')`","
            $fl += "      `"CopyExitCode`": $($f.CopyExitCode),"
            $fl += "      `"CopyResult`": `"$($f.CopyResult)`""
            $fl += '    }'
            $folderLines += $fl -join "`n"
        }
        $lines += $folderLines -join ",`n"
        $lines += '  ]'
        $lines += '}'

        $lines -join "`n" | Set-Content -Path $manifestPath -Encoding ASCII
        Write-Log "Manifest written: $manifestPath"
    } catch {
        Write-Log "Could not write manifest: $_" -Level WARN
    }
}


# ===========================================================================
# SECTION: User Detection
# ===========================================================================

function Get-LoggedInUser {
    <#
    Detects whether we are running as SYSTEM, finds the logged-in user,
    resolves their SID, and locates their profile path.
    Returns a hashtable, or $null on failure.
    #>
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $Script:RunningAsSystem = ($currentIdentity.User.Value -eq 'S-1-5-18')

    if ($Script:RunningAsSystem) {
        Write-Log "Running as SYSTEM - discovering logged-in user via explorer.exe"

        $explorerProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue)
        if (-not $explorerProcs -or $explorerProcs.Count -eq 0) {
            Write-Log "No explorer.exe processes found - no interactive user logged in" -Level WARN
            return $null
        }

        $users = @()
        foreach ($proc in $explorerProcs) {
            try {
                $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($owner -and $owner.ReturnValue -eq 0 -and $owner.User) {
                    $users += [PSCustomObject]@{
                        Username = $owner.User
                        Domain   = $owner.Domain
                    }
                }
            } catch { }
        }

        # Deduplicate by username
        $uniqueUsers = @($users | Sort-Object Username -Unique)

        if ($uniqueUsers.Count -eq 0) {
            Write-Log "Could not determine owner of explorer.exe" -Level WARN
            return $null
        }

        if ($uniqueUsers.Count -gt 1) {
            $names = ($uniqueUsers | ForEach-Object { "$($_.Domain)\$($_.Username)" }) -join ', '
            Write-Log "Multiple users logged in: $names - ambiguous, cannot target one user" -Level ERROR
            return $null
        }

        $username = $uniqueUsers[0].Username
        $domain   = $uniqueUsers[0].Domain
        Write-Log "Detected logged-in user: $domain\$username"

    } else {
        Write-Log "Running in user context as $env:USERDOMAIN\$env:USERNAME"
        $username = $env:USERNAME
        $domain   = $env:USERDOMAIN
    }

    # Resolve SID - try domain\user first, then just user
    $sid = $null
    foreach ($accountForm in @("$domain\$username", $username)) {
        try {
            $ntAccount = New-Object System.Security.Principal.NTAccount($accountForm)
            $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
            break
        } catch { }
    }

    if (-not $sid) {
        Write-Log "Could not resolve SID for $domain\$username" -Level ERROR
        return $null
    }
    Write-Log "SID: $sid"

    # Resolve profile path from ProfileList registry
    $profilePath = $null
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    if (Test-Path $profileKey) {
        $profilePath = (Get-ItemProperty $profileKey -ErrorAction SilentlyContinue).ProfileImagePath
    }

    if (-not $profilePath -or -not (Test-Path $profilePath)) {
        # Fallback: check C:\Users\<username>
        $guess = "C:\Users\$username"
        if (Test-Path $guess) {
            $profilePath = $guess
            Write-Log "Profile path from ProfileList not found, using fallback: $profilePath" -Level WARN
        } else {
            Write-Log "Could not locate profile path for $username" -Level ERROR
            return $null
        }
    }

    Write-Log "Profile path: $profilePath"

    return @{
        Username    = $username
        Domain      = $domain
        SID         = $sid
        ProfilePath = $profilePath
    }
}

function Wait-ForLoggedInUser {
    param([int]$TimeoutMinutes)
    <#
    If running as SYSTEM and no user is logged in, polls every 60 seconds
    until a user logs in or the timeout expires.
    Sets $Script:RunningAsSystem as a side effect.
    Returns the user hashtable, or $null on timeout.
    #>

    # Determine execution context up front
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $Script:RunningAsSystem = ($currentIdentity.User.Value -eq 'S-1-5-18')

    if (-not $Script:RunningAsSystem) {
        # Running as the user already - no wait needed
        return Get-LoggedInUser
    }

    # Quick check: is someone already logged in?
    $explorerCount = (Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" `
                          -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($explorerCount -gt 0) {
        return Get-LoggedInUser
    }

    $hours    = [math]::Round($TimeoutMinutes / 60, 1)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Host "[INFO] No user currently logged in - will check every 60 seconds for up to $TimeoutMinutes minutes ($hours hours)"

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 60
        $explorerCount = (Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" `
                              -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($explorerCount -gt 0) {
            Write-Host "[INFO] User login detected - proceeding"
            return Get-LoggedInUser
        }
        $remaining = [int](($deadline - (Get-Date)).TotalMinutes)
        Write-Host "[INFO] Waiting for user login ($remaining min remaining)"
    }

    Write-Host "[WARN] No user logged in after $TimeoutMinutes minutes"
    return $null
}


# ===========================================================================
# SECTION: Registry - Read Shell Folders
# ===========================================================================

function Get-RedirectedFolders {
    param([hashtable]$User)
    <#
    Reads the User Shell Folders registry key and returns an array of
    hashtables for any values that point to UNC paths (\\...).
    Each entry: ValueName, SourcePath (expanded), LocalTarget, Exclusions
    #>

    $regPath = "Registry::HKEY_USERS\$($User.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

    if (-not (Test-Path $regPath)) {
        Write-Log "User Shell Folders key not found - hive may not be loaded" -Level WARN
        return @()
    }

    $redirected = [System.Collections.ArrayList]::new()

    foreach ($name in $Script:ShellFolderNames) {
        $value = $null
        try {
            $prop = Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
            if ($prop) { $value = $prop.$name }
        } catch { continue }

        if (-not $value) { continue }

        # Expand common env vars against the target user's profile (not SYSTEM's)
        $expanded = $value
        $expanded = $expanded -replace [regex]::Escape('%USERPROFILE%'), $User.ProfilePath
        $expanded = $expanded -replace [regex]::Escape('%USERNAME%'),    $User.Username

        if ($expanded -like '\\*') {
            if (-not $Script:LocalTargets.Contains($name)) {
                Write-Log "  No local target mapping for '$name' - skipping" -Level WARN
                continue
            }
            $localTarget = Join-Path $User.ProfilePath $Script:LocalTargets[$name]
            $entry = @{
                ValueName   = $name
                SourcePath  = $expanded
                LocalTarget = $localTarget
                Exclusions  = @()   # populated below
                CopyExitCode = -1
                CopyResult   = 'not_run'
            }
            [void]$redirected.Add($entry)
            Write-Log "  Redirected: $name"
            Write-Log "    Source:  $expanded"
            Write-Log "    Target:  $localTarget"
        } else {
            Write-Log "  Already local: $name -> $expanded"
        }
    }

    # Detect nesting: if one source path is a child of another, mark exclusions.
    # Example: My Pictures source = \\srv\share\user\Documents\Pictures
    #          Personal (Documents) source = \\srv\share\user\Documents
    # When copying Documents we must /XD the Pictures child path.
    foreach ($entry in $redirected) {
        foreach ($other in $redirected) {
            if ($other.SourcePath -eq $entry.SourcePath) { continue }
            # $other is nested inside $entry
            if ($other.SourcePath -like "$($entry.SourcePath)\*") {
                $entry.Exclusions += $other.SourcePath
                Write-Log "  Nesting detected: '$($other.ValueName)' is inside '$($entry.ValueName)' - will exclude during parent copy"
            }
        }
    }

    return @($redirected)
}


# ===========================================================================
# SECTION: Registry - Rewrite Shell Folders
# ===========================================================================

function Update-ShellFolderRegistry {
    param(
        [hashtable]$User,
        [array]$Redirected
    )
    <#
    Rewrites the shell folder registry values to local paths.
    User Shell Folders (REG_EXPAND_SZ) gets %USERPROFILE%\... form.
    Shell Folders (REG_SZ) gets the fully-expanded path.
    Only values that were previously UNC are changed.
    #>

    $usfPath = "Registry::HKEY_USERS\$($User.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $sfPath  = "Registry::HKEY_USERS\$($User.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

    $errors = 0

    foreach ($entry in $Redirected) {
        $relPath = $Script:LocalTargets[$entry.ValueName]
        $expandSzValue = "%USERPROFILE%\$relPath"
        $fullPath      = Join-Path $User.ProfilePath $relPath

        # Write User Shell Folders as REG_EXPAND_SZ
        try {
            Set-ItemProperty -Path $usfPath -Name $entry.ValueName -Value $expandSzValue -Type ExpandString -ErrorAction Stop
            Write-Log "  USF: $($entry.ValueName) -> $expandSzValue"
        } catch {
            Write-Log "  Failed to write USF $($entry.ValueName): $_" -Level ERROR
            $errors++
        }

        # Write Shell Folders as REG_SZ (fully expanded)
        if (Test-Path $sfPath) {
            try {
                Set-ItemProperty -Path $sfPath -Name $entry.ValueName -Value $fullPath -Type String -ErrorAction Stop
                Write-Log "  SF:  $($entry.ValueName) -> $fullPath"
            } catch {
                Write-Log "  Failed to write SF $($entry.ValueName): $_" -Level WARN
                # Non-fatal - USF is the authoritative key
            }
        }
    }

    return $errors
}


# ===========================================================================
# SECTION: Registry - Clear FR CSE State
# ===========================================================================

function Clear-FolderRedirectionState {
    param([hashtable]$User)

    $frKey = "Registry::HKEY_USERS\$($User.SID)\Software\Microsoft\Windows\CurrentVersion\Group Policy\FolderRedirection"

    if (Test-Path $frKey) {
        try {
            Remove-Item -Path $frKey -Recurse -Force -ErrorAction Stop
            Write-Log "Cleared Folder Redirection CSE state"
        } catch {
            Write-Log "Could not clear FR CSE state (non-fatal): $_" -Level WARN
        }
    } else {
        Write-Log "No FR CSE state key found (nothing to clear)"
    }
}


# ===========================================================================
# SECTION: Connectivity
# ===========================================================================

function Get-ServersFromPaths {
    param([array]$Redirected)
    # Extract unique server names from UNC paths: \\server\share\...
    $servers = @()
    foreach ($entry in $Redirected) {
        if ($entry.SourcePath -like '\\*') {
            $parts = $entry.SourcePath.TrimStart('\') -split '\\'
            if ($parts.Count -gt 0 -and $parts[0]) {
                $servers += $parts[0]
            }
        }
    }
    return @($servers | Sort-Object -Unique)
}

function Test-ServerConnectivity {
    param([string[]]$Servers)
    # Tests TCP port 445 (SMB) to each server with a 3-second timeout.
    # Returns a hashtable: server -> $true/$false
    $results = @{}
    foreach ($server in $Servers) {
        Write-Log "Testing SMB connectivity to $server (port 445)..."
        $reachable = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $tcp.BeginConnect($server, 445, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
            if ($ok -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                $reachable = $true
            }
            $tcp.Close()
        } catch { }
        $results[$server] = $reachable
        $label = if ($reachable) { 'reachable' } else { 'UNREACHABLE' }
        Write-Log "  $server : $label"
    }
    return $results
}


# ===========================================================================
# SECTION: User-Context Task Runner
# ===========================================================================

function Invoke-InUserContext {
    <#
    Runs a PowerShell script in the logged-in user's context.

    When running as SYSTEM: registers a temporary scheduled task for the user.
    When running as user:   spawns a new powershell.exe process (-STA for WPF).

    The script content receives $ResultPath as a pre-defined variable.
    Write a JSON object to $ResultPath to pass results back to the caller.

    Returns: @{ ExitCode = int; ResultData = hashtable-or-null }
    #>
    param(
        [string]$TaskName,
        [string]$ScriptContent,
        [int]$TimeoutSeconds = 7200
    )

    # Create working paths in LogPath (accessible to both SYSTEM and user)
    $guid       = [System.Guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $LogPath "ipc-result-$guid.json"
    $scriptPath = Join-Path $LogPath "ipc-task-$guid.ps1"

    # Prepend result path variable so the script can use $ResultPath directly
    $fullScript = "`$ResultPath = '$resultPath'`n$ScriptContent"
    [System.IO.File]::WriteAllText($scriptPath, $fullScript, [System.Text.Encoding]::ASCII)

    $psArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$scriptPath`""

    try {
        if ($Script:RunningAsSystem) {
            return Invoke-UserContextTask -TaskName $TaskName -PsArgs $psArgs `
                                          -TimeoutSeconds $TimeoutSeconds `
                                          -ResultPath $resultPath -ScriptPath $scriptPath
        } else {
            return Invoke-DirectUserProcess -PsArgs $psArgs -TimeoutSeconds $TimeoutSeconds `
                                            -ResultPath $resultPath -ScriptPath $scriptPath
        }
    } finally {
        Remove-Item $scriptPath  -Force -ErrorAction SilentlyContinue
        Remove-Item $resultPath  -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UserContextTask {
    # Registers a scheduled task to run in the logged-in user's interactive session.
    # Used when the main script is running as SYSTEM.
    param(
        [string]$TaskName,
        [string]$PsArgs,
        [int]$TimeoutSeconds,
        [string]$ResultPath,
        [string]$ScriptPath
    )

    $fullTaskName = "Migration-Temp-$TaskName"
    $domainUser   = "$($Script:TargetUser.Domain)\$($Script:TargetUser.Username)"

    # Clean up any leftover task from a previous run
    Unregister-ScheduledTask -TaskName $fullTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $PsArgs
    $principal = New-ScheduledTaskPrincipal -UserId $domainUser -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds) `
                     -MultipleInstances IgnoreNew

    try {
        Register-ScheduledTask -TaskName $fullTaskName -Action $action `
            -Principal $principal -Settings $settings -Force | Out-Null

        Write-Log "Starting user-context task: $fullTaskName"
        Start-ScheduledTask -TaskName $fullTaskName

        # Poll for task completion
        $exitCode = -1
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            $info = Get-ScheduledTask -TaskName $fullTaskName -ErrorAction SilentlyContinue
            if (-not $info) { break }
            if ($info.State -eq 'Ready') {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $fullTaskName -ErrorAction SilentlyContinue
                if ($taskInfo) { $exitCode = $taskInfo.LastTaskResult }
                break
            }
        }

        Write-Log "Task $fullTaskName exit code: $exitCode"
        return Read-IpcResult -ResultPath $resultPath -ExitCode $exitCode

    } finally {
        Unregister-ScheduledTask -TaskName $fullTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-DirectUserProcess {
    # Spawns a new PowerShell process in the current user's context.
    # Used when the main script is already running as the user.
    param(
        [string]$PsArgs,
        [int]$TimeoutSeconds,
        [string]$ResultPath,
        [string]$ScriptPath
    )

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $PsArgs `
                -PassThru -ErrorAction Stop

    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        $proc.Kill()
        Write-Log "User-context process timed out" -Level WARN
        return @{ ExitCode = -1; ResultData = $null }
    }

    return Read-IpcResult -ResultPath $resultPath -ExitCode $proc.ExitCode
}

function Read-IpcResult {
    param([string]$ResultPath, [int]$ExitCode)
    $resultData = $null
    if (Test-Path $resultPath) {
        try {
            $json = Get-Content $resultPath -Raw -Encoding ASCII
            $resultData = $json | ConvertFrom-Json
        } catch {
            Write-Log "Could not parse IPC result JSON: $_" -Level WARN
        }
    }
    return @{ ExitCode = $ExitCode; ResultData = $resultData }
}


# ===========================================================================
# SECTION: Migration Intro Dialog
# ===========================================================================

function Show-MigrationIntroDialog {
    param(
        [string[]]$Servers,
        [string]$VpnName,
        [int]$TimeoutMinutes,
        [bool]$NeedsVpn
    )
    <#
    Shows a WPF dialog explaining the migration to the user.

    If NeedsVpn is true: includes VPN connectivity status and polls every 5
    seconds, closing automatically when all servers become reachable.

    If NeedsVpn is false: shows a Continue/Cancel acknowledgement dialog.

    Returns: 'proceed' or 'connected' (success path), 'cancelled', 'timeout'
    #>

    $serversLiteral  = "'" + ($Servers -join "','") + "'"
    $timeoutSec      = $TimeoutMinutes * 60
    $needsVpnLiteral = if ($NeedsVpn) { '$true' } else { '$false' }

    $scriptContent = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

`$needsVpn   = $needsVpnLiteral
`$vpnName    = '$VpnName'
`$servers    = @($serversLiteral)
`$timeoutSec = $timeoutSec

`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="File Migration - Action Required"
        Width="560"
        SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="True">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Margin" Value="4,0"/>
            <Setter Property="MinWidth" Value="90"/>
        </Style>
    </Window.Resources>
    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="14" FontWeight="Bold" TextWrapping="Wrap"
                   Text="File Migration" Margin="0,0,0,14"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Your IT team is preparing this computer for an upcoming update. Your files (Desktop, Documents, Pictures, Music, Videos, and Downloads) will be copied from the file server to this computer. This may take several minutes depending on the amount of data stored."/>
        <TextBlock Grid.Row="2" TextWrapping="Wrap" Margin="0,0,0,14"
                   Text="Once complete, you will be asked to close your open applications and log off. When you log back in, your files will be in their usual locations, stored locally on this computer."/>
        <StackPanel Grid.Row="3" x:Name="VpnPanel" Margin="0,0,0,14">
            <TextBlock x:Name="VpnInstructText" TextWrapping="Wrap"
                       FontWeight="SemiBold" Margin="0,0,0,8"/>
            <TextBlock x:Name="StatusText" Foreground="#666666"
                       FontStyle="Italic" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="ContinueBtn" Content="Continue" IsDefault="True"/>
            <Button x:Name="CancelBtn" Content="Cancel" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Test-SmbReachable {
    param([string]`$Server)
    try {
        `$tcp = New-Object System.Net.Sockets.TcpClient
        `$ar  = `$tcp.BeginConnect(`$Server, 445, `$null, `$null)
        `$ok  = `$ar.AsyncWaitHandle.WaitOne(2000, `$false)
        if (`$ok -and `$tcp.Connected) { `$tcp.EndConnect(`$ar); `$tcp.Close(); return `$true }
        `$tcp.Close(); return `$false
    } catch { return `$false }
}

`$reader      = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new(`$xaml))
`$window      = [System.Windows.Markup.XamlReader]::Load(`$reader)
`$vpnPanel    = `$window.FindName('VpnPanel')
`$vpnInstrTxt = `$window.FindName('VpnInstructText')
`$statusTxt   = `$window.FindName('StatusText')
`$continueBtn = `$window.FindName('ContinueBtn')
`$cancelBtn   = `$window.FindName('CancelBtn')

`$script:outcome   = 'cancelled'
`$script:cancelled = `$false

`$cancelBtn.Add_Click({
    `$script:cancelled = `$true
    `$window.Close()
})

if (`$needsVpn) {
    `$continueBtn.Visibility = [System.Windows.Visibility]::Collapsed
    `$vpnInstrTxt.Text = "To begin, please connect to `$vpnName. This window will continue automatically once the connection is established."
    `$statusTxt.Text   = "Checking connectivity..."

    `$script:started = [DateTime]::Now
    `$timer = New-Object System.Windows.Threading.DispatcherTimer
    `$timer.Interval = [System.TimeSpan]::FromSeconds(5)
    `$timer.Add_Tick({
        if (`$script:cancelled) { `$timer.Stop(); return }

        `$elapsed = ([DateTime]::Now - `$script:started).TotalSeconds
        if (`$elapsed -ge `$timeoutSec) {
            `$script:outcome = 'timeout'
            `$timer.Stop()
            `$window.Close()
            return
        }

        `$remaining_disp = [int](`$timeoutSec - `$elapsed)
        `$statusTxt.Text = "Waiting for connection... (`$remaining_disp s remaining)"

        `$allOk = `$true
        foreach (`$s in `$servers) {
            if (-not (Test-SmbReachable `$s)) { `$allOk = `$false; break }
        }

        if (`$allOk) {
            `$statusTxt.Text = "Connected - continuing..."
            `$script:outcome = 'connected'
            `$timer.Stop()
            `$window.Close()
        }
    })
    `$timer.Start()
} else {
    `$vpnPanel.Visibility = [System.Windows.Visibility]::Collapsed
    `$continueBtn.Add_Click({
        `$script:outcome = 'proceed'
        `$window.Close()
    })
}

`$null = `$window.ShowDialog()
if (`$needsVpn) { `$timer.Stop() }

if (`$script:cancelled) { `$script:outcome = 'cancelled' }

@{ Outcome = `$script:outcome } | ConvertTo-Json | Set-Content -Path `$ResultPath -Encoding ASCII
exit 0
"@

    Write-Log "Showing migration intro dialog (VPN needed: $NeedsVpn)"
    $result = Invoke-InUserContext -TaskName 'IntroDialog' -ScriptContent $scriptContent `
                  -TimeoutSeconds ($TimeoutMinutes * 60 + 120)

    $outcome = 'cancelled'
    if ($result.ResultData -and $result.ResultData.Outcome) {
        $outcome = $result.ResultData.Outcome
    }
    Write-Log "Intro dialog outcome: $outcome"
    return $outcome
}


# ===========================================================================
# SECTION: App Close Dialog
# ===========================================================================

function Show-AppCloseDialog {
    param([string[]]$AppNames)
    <#
    Shows a WPF dialog listing running apps that should be closed.
    Continue button enables only when none are running.
    Force Close button kills them after confirmation.
    Returns a hashtable: Outcome ('proceed'/'force_closed'/'cancelled'),
                         AppsKilled (array of process names)
    #>

    # Build a PS array literal for the app names list
    $appNamesLiteral = "'" + ($AppNames -join "','") + "'"

    $scriptContent = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

`$appNames = @($appNamesLiteral)

`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Migration - Please Close Applications"
        Width="540" Height="420"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="True">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Margin" Value="4,0"/>
            <Setter Property="MinWidth" Value="100"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="14" FontWeight="Bold"
                   Text="File Migration - Close Applications" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="Please save your work and close these applications before continuing:"/>
        <ListBox Grid.Row="2" x:Name="AppList" Margin="0,0,0,12"
                 FontFamily="Consolas" FontSize="12"/>
        <TextBlock Grid.Row="3" x:Name="StatusText" Foreground="#666666"
                   FontStyle="Italic" Margin="0,0,0,10" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="ContinueBtn" Content="Continue" IsDefault="True" IsEnabled="False"/>
            <Button x:Name="ForceBtn"    Content="Force Close Apps"/>
            <Button x:Name="CancelBtn"   Content="Cancel"   IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Get-RunningApps {
    param([string[]]`$Names)
    `$running = @()
    foreach (`$n in `$Names) {
        if (Get-Process -Name `$n -ErrorAction SilentlyContinue) {
            `$running += `$n
        }
    }
    return `$running
}

`$reader      = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new(`$xaml))
`$window      = [System.Windows.Markup.XamlReader]::Load(`$reader)
`$listBox     = `$window.FindName('AppList')
`$statusTxt   = `$window.FindName('StatusText')
`$continueBtn = `$window.FindName('ContinueBtn')
`$forceBtn    = `$window.FindName('ForceBtn')
`$cancelBtn   = `$window.FindName('CancelBtn')

`$outcome    = 'cancelled'
`$appsKilled = @()

function Update-AppList {
    `$running = Get-RunningApps `$appNames
    `$listBox.Items.Clear()
    foreach (`$a in `$running) { `$null = `$listBox.Items.Add(`$a) }
    if (`$running.Count -eq 0) {
        `$continueBtn.IsEnabled = `$true
        `$statusTxt.Text = "All applications closed. Click Continue to proceed."
    } else {
        `$continueBtn.IsEnabled = `$false
        `$statusTxt.Text = "Waiting for `$(`$running.Count) application(s) to close..."
    }
}

Update-AppList

`$cancelBtn.Add_Click({
    `$script:outcome = 'cancelled'
    `$window.Close()
})

`$continueBtn.Add_Click({
    `$script:outcome = 'proceed'
    `$window.Close()
})

`$forceBtn.Add_Click({
    `$confirm = [System.Windows.MessageBox]::Show(
        "This will forcibly close the listed applications. Any unsaved work will be lost.`nContinue?",
        "Confirm Force Close",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if (`$confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    `$running = Get-RunningApps `$appNames
    foreach (`$a in `$running) {
        `$procs = @(Get-Process -Name `$a -ErrorAction SilentlyContinue)
        foreach (`$p in `$procs) {
            # Try graceful close first
            try { `$null = `$p.CloseMainWindow() } catch { }
        }
    }
    # Wait up to 5 seconds for graceful close
    Start-Sleep -Seconds 5

    # Force-kill anything still running
    foreach (`$a in `$running) {
        `$procs = @(Get-Process -Name `$a -ErrorAction SilentlyContinue)
        foreach (`$p in `$procs) {
            try { Stop-Process -Id `$p.Id -Force -ErrorAction SilentlyContinue } catch { }
            `$script:appsKilled += `$a
        }
    }
    `$script:outcome = 'force_closed'
    `$window.Close()
})

`$timer = New-Object System.Windows.Threading.DispatcherTimer
`$timer.Interval = [System.TimeSpan]::FromSeconds(2)
`$timer.Add_Tick({ Update-AppList })
`$timer.Start()

`$null = `$window.ShowDialog()
`$timer.Stop()

@{
    Outcome    = `$script:outcome
    AppsKilled = `$script:appsKilled
} | ConvertTo-Json | Set-Content -Path `$ResultPath -Encoding ASCII

exit 0
"@

    Write-Log "Showing app-close dialog for $($AppNames.Count) app(s)"
    $result = Invoke-InUserContext -TaskName 'AppCloseDialog' -ScriptContent $scriptContent `
                  -TimeoutSeconds 3600

    $outcome    = 'cancelled'
    $appsKilled = @()

    if ($result.ResultData) {
        if ($result.ResultData.Outcome)    { $outcome    = $result.ResultData.Outcome }
        if ($result.ResultData.AppsKilled) { $appsKilled = @($result.ResultData.AppsKilled) }
    }

    Write-Log "App-close dialog outcome: $outcome"
    if ($appsKilled.Count -gt 0) {
        Write-Log "Force-killed: $($appsKilled -join ', ')"
    }

    return @{ Outcome = $outcome; AppsKilled = $appsKilled }
}


# ===========================================================================
# SECTION: Persistent Status Window
# ===========================================================================

function Start-PersistentStatusWindow {
    param([string]$SignalPath)
    <#
    Starts a non-blocking background window in the user's session.
    The window shows "Migration in Progress" with Topmost=False so all
    modal dialogs appear in front of it. It polls for $SignalPath every 2
    seconds and closes when the file is created.

    Returns the path of the temp script file (for cleanup).
    #>

    $signalPathEsc = $SignalPath -replace "'", "''"

    $scriptContent = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

`$signalPath = '$signalPathEsc'

`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="File Migration in Progress"
        Width="460" Height="110"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="False"
        ShowInTaskbar="True">
    <Grid Margin="20,16,20,16">
        <StackPanel VerticalAlignment="Center">
            <TextBlock FontSize="13" FontWeight="Bold"
                       Text="File Migration in Progress" Margin="0,0,0,8"/>
            <TextBlock TextWrapping="Wrap" Foreground="#444444"
                       Text="Please keep this computer on and do not log off."/>
        </StackPanel>
    </Grid>
</Window>
'@

`$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new(`$xaml))
`$window = [System.Windows.Markup.XamlReader]::Load(`$reader)

`$timer = New-Object System.Windows.Threading.DispatcherTimer
`$timer.Interval = [System.TimeSpan]::FromSeconds(2)
`$timer.Add_Tick({
    if (Test-Path `$signalPath) {
        `$timer.Stop()
        `$window.Close()
    }
})
`$timer.Start()
`$null = `$window.ShowDialog()
`$timer.Stop()
exit 0
"@

    $guid       = [System.Guid]::NewGuid().ToString('N')
    $scriptPath = Join-Path $LogPath "ipc-bg-$guid.ps1"
    $fullScript = "`$ResultPath = ''`n$scriptContent"
    [System.IO.File]::WriteAllText($scriptPath, $fullScript, [System.Text.Encoding]::ASCII)

    $psArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -STA -File `"$scriptPath`""

    try {
        if ($Script:RunningAsSystem) {
            $taskName   = 'Migration-Temp-StatusWindow'
            $domainUser = "$($Script:TargetUser.Domain)\$($Script:TargetUser.Username)"

            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
            $principal = New-ScheduledTaskPrincipal -UserId $domainUser -LogonType Interactive -RunLevel Limited
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                             -MultipleInstances IgnoreNew

            Register-ScheduledTask -TaskName $taskName -Action $action `
                -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Write-Log "Background status window started (task: $taskName)"
        } else {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -ErrorAction Stop
            Write-Log "Background status window started (direct process)"
        }
    } catch {
        Write-Log "Could not start background status window (non-fatal): $_" -Level WARN
    }

    return $scriptPath
}

function Stop-PersistentStatusWindow {
    param(
        [string]$SignalPath,
        [string]$ScriptPath
    )
    # Write signal file so the window closes itself
    try { '1' | Set-Content -Path $SignalPath -Encoding ASCII -ErrorAction Stop } catch { }
    # Give it a few seconds to detect the signal and exit before we delete the script
    Start-Sleep -Seconds 4
    Unregister-ScheduledTask -TaskName 'Migration-Temp-StatusWindow' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $ScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item $SignalPath -Force -ErrorAction SilentlyContinue
}


# ===========================================================================
# SECTION: File Copy
# ===========================================================================

function Invoke-FolderCopy {
    param(
        [hashtable]$User,
        [array]$Redirected
    )
    <#
    Copies each redirected folder from its UNC source to the local target
    via robocopy. Runs in user context (scheduled task or direct) so that
    the UNC share access uses the user's credentials.

    Robocopy exit codes: 0-7 = success variants, 8+ = at least one failure.
    Populates CopyExitCode and CopyResult on each entry in $Redirected.

    Returns $true if all copies succeeded, $false otherwise.
    #>

    # Build the copy operations as a series of robocopy invocations
    # Serialize as a JSON array embedded in the script
    $opsJson = ConvertTo-Json -InputObject @(
        $Redirected | ForEach-Object {
            @{
                Source      = $_.SourcePath
                Destination = $_.LocalTarget
                Exclusions  = $_.Exclusions
                ValueName   = $_.ValueName
            }
        }
    ) -Depth 4 -Compress

    # Escape backslashes and single quotes for embedding in the script string
    # Do NOT double-escape backslashes here. ConvertTo-Json already encodes them
    # correctly for JSON (\ -> \\). The inner script embeds this as a single-quoted
    # PS string and passes it straight to ConvertFrom-Json, which decodes \\ back to \.
    # Applying an extra replace would produce triple/quadruple backslashes in UNC paths.
    $opsJsonEsc = $opsJson -replace "'", "''"
    $logDir     = $LogPath

    $scriptContent = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

`$script:ops    = @() + ('$opsJsonEsc' | ConvertFrom-Json)
`$script:logDir = '$logDir'
`$script:results = @()

`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Migration - Copying Files"
        Width="500" Height="200"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="14" FontWeight="Bold"
                   Text="Copying your files to this computer..."
                   Margin="0,0,0,12" TextWrapping="Wrap"/>
        <TextBlock Grid.Row="1" x:Name="StatusText" FontSize="12"
                   TextWrapping="Wrap" Margin="0,0,0,8"/>
        <ProgressBar Grid.Row="2" x:Name="CopyProgress" Height="22"
                     Minimum="0" Value="0" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="3" x:Name="SubText" Foreground="#888888"
                   FontStyle="Italic" FontSize="11"/>
    </Grid>
</Window>
'@

`$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new(`$xaml))
`$window = [System.Windows.Markup.XamlReader]::Load(`$reader)

`$script:statusTx = `$window.FindName('StatusText')
`$script:progBar  = `$window.FindName('CopyProgress')
`$script:subTx    = `$window.FindName('SubText')

`$script:progBar.Maximum = `$script:ops.Count
`$script:progBar.Value   = 0
`$script:opIndex         = 0
`$script:curProc         = `$null
`$script:stopwatch       = [System.Diagnostics.Stopwatch]::StartNew()

# Quotes a single robocopy argument if it contains spaces.
# Used when building the Arguments string for ProcessStartInfo.
function Get-QuotedArg {
    param([string]`$a)
    if (`$a -match '\s') { return '"' + `$a + '"' }
    return `$a
}

# Starts robocopy for the current folder index as a non-blocking process.
# Uses System.Diagnostics.Process directly so HasExited and ExitCode are reliable
# in scheduled-task sessions that have no console window.
function Start-FolderCopy {
    `$op    = `$script:ops[`$script:opIndex]
    `$src   = `$op.Source
    `$dest  = `$op.Destination
    `$name  = `$op.ValueName
    `$idx   = `$script:opIndex + 1
    `$total = `$script:ops.Count

    `$script:statusTx.Text = "Copying `$name (`$idx of `$total)..."

    if (-not (Test-Path `$dest)) {
        New-Item -ItemType Directory -Path `$dest -Force | Out-Null
    }

    `$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
    `$logFile = Join-Path `$script:logDir "robocopy-`$name-`$ts.log"

    `$rcArgs = @(`$src, `$dest, '/E', '/COPY:DAT', '/R:3', '/W:5', '/XJ', '/MT:8', "/LOG+:`$logFile")
    if (`$op.Exclusions -and `$op.Exclusions.Count -gt 0) {
        `$rcArgs += '/XD'
        foreach (`$excl in `$op.Exclusions) { `$rcArgs += `$excl }
    }

    `$argStr = (`$rcArgs | ForEach-Object { Get-QuotedArg `$_ }) -join ' '

    `$psi                = New-Object System.Diagnostics.ProcessStartInfo
    `$psi.FileName       = 'robocopy.exe'
    `$psi.Arguments      = `$argStr
    `$psi.UseShellExecute = `$false
    `$psi.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Hidden

    `$script:curProc = [System.Diagnostics.Process]::Start(`$psi)
    Write-Host "  started robocopy for `$name (`$idx of `$total)"
}

# Kick off the first copy before entering the WPF message loop
Start-FolderCopy

`$timer          = New-Object System.Windows.Threading.DispatcherTimer
`$timer.Interval = [System.TimeSpan]::FromSeconds(1)
`$timer.Add_Tick({
    # Update elapsed time on every tick regardless of copy state
    `$elapsedStr        = `$script:stopwatch.Elapsed.ToString('mm\:ss')
    `$script:subTx.Text = 'Elapsed: ' + `$elapsedStr

    # Not started yet, or still running - nothing to do this tick
    if (-not `$script:curProc)           { return }
    if (-not `$script:curProc.HasExited) { return }

    # Current copy finished - record result
    `$rc     = `$script:curProc.ExitCode
    `$label  = if (`$rc -lt 8) { 'success' } else { 'failed' }
    `$opName = `$script:ops[`$script:opIndex].ValueName
    Write-Host "  `$opName : exit `$rc (`$label)"

    `$script:results += @{ ValueName = `$opName; ExitCode = `$rc; Result = `$label }
    `$script:curProc.Dispose()
    `$script:curProc       = `$null
    `$script:opIndex++
    `$script:progBar.Value = `$script:opIndex

    if (`$script:opIndex -lt `$script:ops.Count) {
        Start-FolderCopy
    } else {
        `$script:statusTx.Text = 'All folders copied.'
        `$script:subTx.Text    = 'Complete.'
        `$script:timer.Stop()
        `$script:window.Close()
    }
})
`$script:timer  = `$timer
`$script:window = `$window
`$timer.Start()
`$null = `$window.ShowDialog()
`$timer.Stop()

# Safety net: if the window was closed before all copies finished (e.g. user hit X),
# wait for any in-flight robocopy and record it, then mark remaining as cancelled.
if (`$script:curProc -and -not `$script:curProc.HasExited) {
    Write-Host "Waiting for in-flight robocopy to finish..."
    `$script:curProc.WaitForExit()
}
if (`$script:curProc -and `$script:curProc.HasExited) {
    `$rc    = `$script:curProc.ExitCode
    `$label = if (`$rc -lt 8) { 'success' } else { 'failed' }
    `$script:results += @{
        ValueName = `$script:ops[`$script:opIndex].ValueName
        ExitCode  = `$rc
        Result    = `$label
    }
    `$script:curProc.Dispose()
    `$script:opIndex++
}
# Any folders beyond opIndex were never started - mark them cancelled
while (`$script:opIndex -lt `$script:ops.Count) {
    `$script:results += @{
        ValueName = `$script:ops[`$script:opIndex].ValueName
        ExitCode  = -1
        Result    = 'cancelled'
    }
    `$script:opIndex++
}

`$script:results | ConvertTo-Json -Depth 3 | Set-Content -Path `$ResultPath -Encoding ASCII
exit 0
"@

    Write-Log "Starting file copy for $($Redirected.Count) folder(s) in user context (with progress window)"
    $ipcResult = Invoke-InUserContext -TaskName 'FileCopy' -ScriptContent $scriptContent `
                     -TimeoutSeconds 14400   # 4 hours

    $allOk = $true

    if ($ipcResult.ResultData) {
        # ResultData may be a single object or array; normalise
        $items = @($ipcResult.ResultData)
        foreach ($item in $items) {
            # Find the matching entry in $Redirected and update it
            foreach ($entry in $Redirected) {
                if ($entry.ValueName -eq $item.ValueName) {
                    $entry.CopyExitCode = [int]$item.ExitCode
                    $entry.CopyResult   = $item.Result
                    Write-Log "  Copy result for $($item.ValueName): exit=$($item.ExitCode) ($($item.Result))"
                    if ($item.Result -ne 'success') { $allOk = $false }
                    break
                }
            }
        }
    } else {
        Write-Log "No copy results returned from user-context task" -Level ERROR
        $allOk = $false
    }

    return $allOk
}


# ===========================================================================
# SECTION: Logoff Countdown Dialog
# ===========================================================================

function Show-LogoffCountdown {
    param([int]$CountdownSeconds)

    $scriptContent = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

`$countdownSec = $CountdownSeconds

`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Migration Complete - Logging Off"
        Width="480" Height="180"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Topmost="True">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="Margin" Value="4,0"/>
            <Setter Property="MinWidth" Value="120"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontSize="14" FontWeight="Bold"
                   Text="Migration Complete" Margin="0,0,0,10"/>
        <TextBlock Grid.Row="1" x:Name="CountdownText" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="LogoffNowBtn" Content="Log Off Now"/>
        </StackPanel>
    </Grid>
</Window>
'@

`$reader      = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new(`$xaml))
`$window      = [System.Windows.Markup.XamlReader]::Load(`$reader)
`$countTxt    = `$window.FindName('CountdownText')
`$logoffBtn   = `$window.FindName('LogoffNowBtn')

`$remaining = `$countdownSec

function Update-Countdown {
    `$countTxt.Text = "Your file migration is complete. Please save any open work. " +
                      "You will be logged off in `$remaining seconds to finish the process."
}

Update-Countdown

`$logoffBtn.Add_Click({ `$script:remaining = 0; `$window.Close() })

`$timer = New-Object System.Windows.Threading.DispatcherTimer
`$timer.Interval = [System.TimeSpan]::FromSeconds(1)
`$timer.Add_Tick({
    `$script:remaining--
    if (`$script:remaining -le 0) {
        `$timer.Stop()
        `$window.Close()
        return
    }
    Update-Countdown
})
`$timer.Start()

`$null = `$window.ShowDialog()
`$timer.Stop()

'{}' | Set-Content -Path `$ResultPath -Encoding ASCII
exit 0
"@

    Write-Log "Showing logoff countdown ($CountdownSeconds seconds)"
    $null = Invoke-InUserContext -TaskName 'LogoffCountdown' -ScriptContent $scriptContent `
                -TimeoutSeconds ($CountdownSeconds + 60)
}


# ===========================================================================
# SECTION: Logoff
# ===========================================================================

function Invoke-Logoff {
    param([hashtable]$User)
    <#
    Finds the user's session ID via quser.exe and calls logoff.exe.
    #>
    Write-Log "Logging off user $($User.Username)..."

    try {
        # quser output: USERNAME SESSIONNAME ID STATE IDLE TIME LOGON TIME
        $quserOut = & quser.exe 2>$null | Where-Object { $_ -match $User.Username }
        if (-not $quserOut) {
            Write-Log "quser did not return a session for $($User.Username) - trying logoff without session ID" -Level WARN
            & logoff.exe
            return
        }

        # Parse the session ID (3rd whitespace-delimited token)
        $sessionId = ($quserOut -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)

        if ($sessionId) {
            Write-Log "Logging off session ID: $sessionId"
            & logoff.exe $sessionId /v
        } else {
            Write-Log "Could not parse session ID from quser - calling logoff without session ID" -Level WARN
            & logoff.exe
        }
    } catch {
        Write-Log "Error during logoff: $_" -Level ERROR
    }
}


# ===========================================================================
# SECTION: Main
# ===========================================================================

function Main {
    $exitCode     = 0
    $bgSignalPath = $null
    $bgScriptPath = $null

    # --- Identify logged-in user (waits up to $WaitForLoginMinutes if nobody is logged in) ---
    $Script:TargetUser = Wait-ForLoggedInUser -TimeoutMinutes $WaitForLoginMinutes
    if (-not $Script:TargetUser) {
        Initialize-LogFile
        Write-Log "No user logged in after $WaitForLoginMinutes minutes - exiting (code 2)" -Level WARN
        return 2
    }

    Initialize-LogFile

    Write-Log "===================================================================="
    Write-Log "PSP Folder Redirection Cleanup"
    Write-Log "User:    $($Script:TargetUser.Domain)\$($Script:TargetUser.Username)"
    Write-Log "SID:     $($Script:TargetUser.SID)"
    Write-Log "Profile: $($Script:TargetUser.ProfilePath)"
    if ($TestMode)  { Write-Log "Mode:    TEST (no registry changes or logoff)" }
    if ($SkipLogoff){ Write-Log "Logoff:  SKIPPED" }
    Write-Log "===================================================================="

    # --- Read redirected folders ---
    $redirected = @()
    try {
        $redirected = @(Get-RedirectedFolders -User $Script:TargetUser)
    } catch {
        Write-Log "Failed to read shell folder registry: $_" -Level ERROR
        return 1
    }

    # --- Idempotency check ---
    if ($redirected.Count -eq 0) {
        Write-Log "No UNC-redirected folders found - nothing to do (already local or no redirection active)"
        Write-Manifest -Data @{
            Username     = $Script:TargetUser.Username
            SID          = $Script:TargetUser.SID
            ProfilePath  = $Script:TargetUser.ProfilePath
            Result       = 'already_local'
            ForceCloseUsed = $false
            AppsKilled   = @()
            Folders      = @()
        }
        return 0
    }

    Write-Log "$($redirected.Count) folder(s) need to be un-redirected"

    # --- Discover servers and test connectivity ---
    $servers = @(Get-ServersFromPaths -Redirected $redirected)
    Write-Log "File server(s) referenced: $($servers -join ', ')"

    $connectivity = Test-ServerConnectivity -Servers $servers
    $unreachable  = @($connectivity.Keys | Where-Object { -not $connectivity[$_] })

    # --- Start persistent background window (provides visual continuity between dialogs) ---
    # Launched before the intro dialog so it is running by the time the intro closes.
    # Topmost=False keeps it behind all modal dialogs; it stays visible during the
    # ~15-second gpupdate gap and the brief IPC startup gaps between dialogs.
    $bgSignalPath = Join-Path $LogPath "bg-signal-$($Script:TargetUser.Username).tmp"
    $bgScriptPath = Start-PersistentStatusWindow -SignalPath $bgSignalPath

    # --- Migration intro dialog (combined with VPN wait if servers unreachable) ---
    $needsVpn = ($unreachable.Count -gt 0)
    Write-Log "Showing migration intro dialog (VPN needed: $needsVpn)"
    $introOutcome = Show-MigrationIntroDialog -Servers $servers -VpnName $VpnClientName `
                        -TimeoutMinutes $VpnTimeoutMinutes -NeedsVpn $needsVpn

    switch ($introOutcome) {
        'cancelled' { Write-Log "User cancelled"; return 3 }
        'timeout'   { Write-Log "VPN wait timed out ($VpnTimeoutMinutes min)"; return 4 }
        default     {
            if ($needsVpn) {
                Write-Log "VPN connected - re-testing connectivity"
                $connectivity = Test-ServerConnectivity -Servers $servers
                $unreachable  = @($connectivity.Keys | Where-Object { -not $connectivity[$_] })
                if ($unreachable.Count -gt 0) {
                    Write-Log "Servers still unreachable after VPN: $($unreachable -join ', ')" -Level ERROR
                    return 4
                }
            }
        }
    }

    # --- gpupdate /force ---
    # Run now that the file server is reachable (VPN connected if needed).
    # This picks up the FR GPO removal so Group Policy won't re-redirect on
    # next logon even if something triggers a policy refresh before the user's
    # FR CSE state is cleared later in this script.
    Write-Log "Running gpupdate /force to pick up Group Policy changes..."
    try {
        $gpProc = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' `
                      -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        Write-Log "gpupdate completed (exit code $($gpProc.ExitCode))"
    } catch {
        Write-Log "gpupdate failed (non-fatal): $_" -Level WARN
    }

    # --- Build app list (default + additional) ---
    $appList = $Script:DefaultAppsToClose
    if ($AdditionalAppsToClose -and $AdditionalAppsToClose.Count -gt 0) {
        $appList = $appList + $AdditionalAppsToClose
    }
    $appList = @($appList | Sort-Object -Unique)

    # --- App close dialog ---
    $forceCloseUsed = $false
    $appsKilled     = @()

    $appResult = Show-AppCloseDialog -AppNames $appList

    switch ($appResult.Outcome) {
        'cancelled'    { Write-Log "User cancelled at app-close dialog"; return 3 }
        'force_closed' {
            $forceCloseUsed = $true
            $appsKilled     = @($appResult.AppsKilled)
        }
        'proceed'      { Write-Log "User clicked Continue - all target apps closed" }
    }

    # --- File copy (in user context) ---
    Write-Log "Starting file copy phase"
    $copyOk = $false
    try {
        $copyOk = Invoke-FolderCopy -User $Script:TargetUser -Redirected $redirected
    } catch {
        Write-Log "Unexpected error during file copy: $_" -Level ERROR
    }

    if (-not $copyOk) {
        Write-Log "One or more file copies failed - aborting before registry changes" -Level ERROR
        Write-Manifest -Data @{
            Username       = $Script:TargetUser.Username
            SID            = $Script:TargetUser.SID
            ProfilePath    = $Script:TargetUser.ProfilePath
            Result         = 'copy_failed'
            ForceCloseUsed = $forceCloseUsed
            AppsKilled     = $appsKilled
            Folders        = $redirected
        }
        return 5
    }

    Write-Log "All file copies succeeded"

    # --- Registry rewrite ---
    if (-not $TestMode) {
        Write-Log "Rewriting shell folder registry values"
        $regErrors = 0
        try {
            $regErrors = Update-ShellFolderRegistry -User $Script:TargetUser -Redirected $redirected
        } catch {
            Write-Log "Unexpected error during registry rewrite: $_" -Level ERROR
            $regErrors = 999
        }

        if ($regErrors -gt 0) {
            Write-Log "Registry rewrite had $regErrors error(s)" -Level ERROR
            Write-Manifest -Data @{
                Username       = $Script:TargetUser.Username
                SID            = $Script:TargetUser.SID
                ProfilePath    = $Script:TargetUser.ProfilePath
                Result         = 'registry_failed'
                ForceCloseUsed = $forceCloseUsed
                AppsKilled     = $appsKilled
                Folders        = $redirected
            }
            return 6
        }

        Write-Log "Registry rewrite complete"

        # --- Clear FR CSE state ---
        Clear-FolderRedirectionState -User $Script:TargetUser

    } else {
        Write-Log "[TESTMODE] Skipping registry rewrite and CSE clear"
    }

    # --- Write manifest ---
    Write-Manifest -Data @{
        Username       = $Script:TargetUser.Username
        SID            = $Script:TargetUser.SID
        ProfilePath    = $Script:TargetUser.ProfilePath
        Result         = if ($TestMode) { 'success_testmode' } else { 'success' }
        ForceCloseUsed = $forceCloseUsed
        AppsKilled     = $appsKilled
        Folders        = $redirected
    }

    # --- Logoff ---
    if (-not $SkipLogoff -and -not $TestMode) {
        # Background window stays visible behind the logoff countdown (Topmost covers it).
        # When the session ends the OS kills the background window process automatically.
        Show-LogoffCountdown -CountdownSeconds $LogoffCountdownSeconds
        Invoke-Logoff -User $Script:TargetUser
    } else {
        Write-Log "Logoff skipped$(if ($TestMode) {' (test mode)'} else {''})"
        # No logoff means the session stays alive - explicitly close the background window.
        if ($bgSignalPath) {
            Stop-PersistentStatusWindow -SignalPath $bgSignalPath -ScriptPath $bgScriptPath
        }
    }

    Write-Log "===================================================================="
    Write-Log "Folder redirection cleanup complete"
    Write-Log "===================================================================="

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
$result = 1
try {
    $result = Main
} catch {
    $msg = $_.ToString()
    Write-Host "[ERROR] Unhandled exception: $msg"
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value "[ERROR] Unhandled: $msg" -Encoding ASCII } catch { }
    }
    $result = 1
}

Write-Log "Exiting with code $result"
exit $result
