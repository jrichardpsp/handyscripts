<#
.SYNOPSIS
    Re-SIDs a Windows login after a Hybrid-AD -> Entra ID migration by dropping
    and recreating it (forcing a fresh OS SID lookup), then re-links every
    orphaned database user and reassigns any owned databases.

.DESCRIPTION
    Background:
      A Windows login stores a fixed SID; there is no ALTER LOGIN ... WITH SID.
      CREATE LOGIN ... FROM WINDOWS resolves the account name against the OS *at
      creation time* and stores whatever SID it gets back. After a machine moves
      from Hybrid AD to Entra, the same name resolves to a NEW (Entra) SID, so
      dropping and recreating the login is the only way to update it.

      Database users bind to logins by SID, not name. Recreating the login with a
      new SID orphans every database user that was mapped to the old SID. The fix
      is non-destructive:  ALTER USER [name] WITH LOGIN = [name];  -- re-binds the
      EXISTING user (matched by name) to the login's current SID and KEEPS all of
      its role memberships and grants. Never DROP/CREATE USER to fix this -- that
      wipes permissions.

    Workflow:
      1. Confirm the login exists and is a Windows login (refuses SQL logins --
         the SID-remap problem does not apply to them, and re-SIDing one would
         BREAK its mappings).
      2. Capture: disabled state, default DB/language, the OLD SID, server roles,
         and explicit server-scope permissions.
      3. Scan every online database for users bound to the OLD SID (these are the
         ones that will orphan) and record them + their role memberships.
      4. Find databases owned by the login.
      5. Reassign owned databases to a holding owner (default sa).
      6. DROP the login.
      7. CREATE LOGIN ... FROM WINDOWS  (NO SID -> picks up the new Entra SID).
      8. Restore disabled state, server roles, server permissions.
      9. ALTER USER ... WITH LOGIN in each affected database (re-link orphans).
     10. Reassign owned databases back to the login.
     11. Verify: scan for any remaining orphaned users.

    A JSON state backup and a runnable recovery .sql are written BEFORE any change.

.PARAMETER LoginName
    The Windows login to re-SID, e.g. 'DOMAIN\username' (or 'AzureAD\user@domain.com'
    if the account now resolves under that name post-migration).

.PARAMETER SqlInstance
    Target instance. Default 'localhost'.

.PARAMETER HoldingOwner
    Temporary owner for databases during the rebuild. Default 'sa'.

.PARAMETER DryRun
    Capture state, scan, and print the plan + generated T-SQL. Makes NO changes.

.PARAMETER Force
    Skip the interactive confirmation gate and bypass the self-rebuild safety check
    (allows rebuilding the login that the current session is connected as).


.PARAMETER Bootstrap
    Emergency recovery mode: stops SQL Server, injects -m so that local Windows
    Administrators get sysadmin access, grants BUILTIN\Administrators sysadmin,
    restarts normally, then proceeds with the login rebuild.
    This is triggered AUTOMATICALLY if the script cannot connect to the instance,
    so you typically do not need to pass this switch explicitly.
    Pass it explicitly to force bootstrap even when a connection would succeed.

    Requirements:
      - Script must run ELEVATED on the SQL Server machine (or with remote SC rights).
      - The account running the script must be a LOCAL ADMINISTRATOR on that machine.
      - The SQL Server service must be startable/stoppable by this account.

.PARAMETER LogDirectory
    Where transcript, JSON backup, and recovery .sql are written.
    Default: %USERPROFILE%\SqlLoginRebuild

.EXAMPLE
    .\Remap-EntraLogin.ps1 -LoginName 'JRR\miles.morales' -DryRun

.EXAMPLE
    .\Remap-EntraLogin.ps1 -LoginName 'JRR\miles.morales'

.NOTES
    - Run ELEVATED, connected as a sysadmin (so you are NOT the login being rebuilt).
    - Requires the 'SqlServer' module: Install-Module SqlServer -Scope CurrentUser
    - Run this AFTER the workstation has migrated and the name resolves to the new
      Entra SID. Confirm with: whoami /user  (you want the NEW SID to be live).
#>

[CmdletBinding()]
param(
    [string]$LoginName = (& whoami).Trim(),

    [string]$SqlInstance = 'localhost',

    [string]$HoldingOwner = 'sa',

    [switch]$DryRun,

    [switch]$Force,

    [switch]$Bootstrap,

    [string]$LogDirectory = "$env:USERPROFILE\SqlLoginRebuild"
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Setup & helpers
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw "The 'SqlServer' module is not installed. Run: Install-Module SqlServer -Scope CurrentUser -AllowClobber"
}
Import-Module SqlServer -ErrorAction Stop

if (-not (Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }

$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$safeName  = ($LoginName -replace '[\\/:*?"<>|]', '_')
$jsonPath  = Join-Path $LogDirectory "state_${safeName}_${stamp}.json"
$recovPath = Join-Path $LogDirectory "recovery_${safeName}_${stamp}.sql"
$logPath   = Join-Path $LogDirectory "transcript_${safeName}_${stamp}.txt"

Start-Transcript -Path $logPath | Out-Null

# Add -Credential here for SQL auth instead of integrated Windows auth.
$conn = @{
    ServerInstance         = $SqlInstance
    TrustServerCertificate = $true
    ErrorAction            = 'Stop'
}

function Esc-Ident([string]$n) { return ($n -replace '\]', ']]') }
function Esc-Lit  ([string]$n) { return ($n -replace "'", "''") }

function Invoke-Sql {
    param([string]$Query, [string]$Database, [switch]$NoResult)
    $p = $conn.Clone()
    if ($Database) { $p['Database'] = $Database }
    Write-Verbose "SQL[$Database]> $Query"
    if ($NoResult) { Invoke-Sqlcmd @p -Query $Query | Out-Null }
    else           { Invoke-Sqlcmd @p -Query $Query }
}

function Write-Step($m)  { Write-Host "==> $m"        -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host "    [ok] $m"   -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "    [warn] $m" -ForegroundColor Yellow }

function Get-SqlServiceName {
    # 'localhost', '.', bare hostname -> default instance -> MSSQLSERVER
    # 'host\INSTANCE' or 'host\INSTANCE,port' -> MSSQL$INSTANCE
    $stripped = ($SqlInstance -split ',')[0].Trim()
    if ($stripped -match '\\(.+)$') { return "MSSQL`$$($Matches[1].ToUpper())" }
    return 'MSSQLSERVER'
}

function Get-SqlAgentServiceName {
    $stripped = ($SqlInstance -split ',')[0].Trim()
    if ($stripped -match '\\(.+)$') { return "SQLAgent`$$($Matches[1].ToUpper())" }
    return 'SQLSERVERAGENT'
}

function Get-SqlStartupParamsPath {
    # SQL Server stores startup parameters (SQLArg0, SQLArg1 ...) in one of two places
    # depending on version and how Configuration Manager was used:
    #   1. SYSTEM\CurrentControlSet\Services\<svc>\Parameters  (older / some installs)
    #   2. SOFTWARE\Microsoft\Microsoft SQL Server\<verkey>\MSSQLServer\Parameters
    #      where <verkey> is discovered via Instance Names\SQL (e.g. MSSQL15.MSSQLSERVER)
    $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$bootstrapSvcName\Parameters"
    if (Test-Path $svcPath) { return $svcPath }

    $instanceNamesKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if ($bootstrapSvcName -eq 'MSSQLSERVER') {
        $instanceLabel = 'MSSQLSERVER'
    } else {
        $instanceLabel = $bootstrapSvcName -replace '^MSSQL\$', ''
    }
    $versionKey   = (Get-ItemProperty -Path $instanceNamesKey -Name $instanceLabel -ErrorAction Stop).$instanceLabel
    $softwarePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$versionKey\MSSQLServer\Parameters"
    if (Test-Path $softwarePath) { return $softwarePath }

    throw "Cannot locate SQL Server startup parameters registry key. Checked: '$svcPath' and '$softwarePath'."
}

# Bootstrap state -- set before the try so finally can always see them.
$bootstrapSvcName  = $null
$bootstrapArgName  = $null   # set only after -m is written to registry; cleared after removal
$bootstrapComplete = $false  # set after SQL restarts normally post-fixup
$sqlWasStopped     = $false  # set after Stop-Service succeeds; guards finally cleanup
$agentWasRunning   = $false

$qLogin   = "[$(Esc-Ident $LoginName)]"
$litLogin = Esc-Lit $LoginName
$qOwner   = "[$(Esc-Ident $HoldingOwner)]"

try {
    # -----------------------------------------------------------------------
    # 0a. Auto-detect: probe the connection; if it fails, enable bootstrap
    # -----------------------------------------------------------------------
    if (-not $Bootstrap) {
        try { Invoke-Sql -Query "SELECT 1" | Out-Null }
        catch {
            $msg = $_.Exception.Message
            # Only auto-bootstrap for authentication/login failures (broken SID after migration).
            # Network errors, wrong instance name, or a planned maintenance outage should not
            # silently grant BUILTIN\Administrators sysadmin on the server.
            if ($msg -match '18456|18452|Login failed') {
                Write-Warn2 "Login authentication failed on '$SqlInstance' -- likely a broken SID after Entra migration."
                Write-Warn2 "Auto-enabling bootstrap mode to restore access via local administrator."
                $Bootstrap = $true
            } else {
                throw "Cannot connect to '$SqlInstance': $msg"
            }
        }
    }

    # -----------------------------------------------------------------------
    # 0b. Bootstrap: stop SQL Server, inject -m, restore access, restart
    # -----------------------------------------------------------------------
    if ($Bootstrap) {
        $bootstrapSvcName = Get-SqlServiceName
        $agentSvcName     = Get-SqlAgentServiceName

        Write-Host ""
        Write-Host "*** BOOTSTRAP MODE ***" -ForegroundColor Red
        Write-Host "This will STOP '$bootstrapSvcName', start it with -m, grant BUILTIN\Administrators" -ForegroundColor Yellow
        Write-Host "sysadmin access, then restart normally so the login rebuild can proceed." -ForegroundColor Yellow
        Write-Host ""

        if (-not $Force) {
            $answer = Read-Host "Type 'YES' to confirm service restart"
            if ($answer -ne 'YES') { throw "Bootstrap aborted by user." }
        }

        # Stop SQL Agent first so it cannot steal the single -m connection slot.
        $agentSvc = Get-Service -Name $agentSvcName -ErrorAction SilentlyContinue
        if ($agentSvc -and $agentSvc.Status -eq 'Running') {
            $agentWasRunning = $true
            Write-Step "Stopping SQL Agent '$agentSvcName'"
            Stop-Service -Name $agentSvcName -Force -ErrorAction Stop
            Write-Ok "SQL Agent stopped"
        }

        Write-Step "Stopping SQL Server '$bootstrapSvcName'"
        Stop-Service -Name $bootstrapSvcName -Force -ErrorAction Stop
        $sqlWasStopped = $true
        Write-Ok "SQL Server stopped"

        # Locate the startup params registry key now that SQL is stopped.
        # Doing this after the stop means if it fails, finally correctly restarts SQL cleanly.
        $regPath = Get-SqlStartupParamsPath

        # Find the next free SQLArgN slot and inject -m.
        $idx = 0
        while ($null -ne (Get-ItemProperty -Path $regPath -Name "SQLArg$idx" -ErrorAction SilentlyContinue)) { $idx++ }
        $targetArg = "SQLArg$idx"
        Set-ItemProperty -Path $regPath -Name $targetArg -Value '-m' -Type String
        $bootstrapArgName = $targetArg   # set only after the registry write succeeds
        Write-Ok "Injected startup flag: $bootstrapArgName = -m"

        Write-Step "Starting SQL Server in single-user mode"
        Start-Service -Name $bootstrapSvcName -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds(90)
        $ready    = $false
        while ((Get-Date) -lt $deadline) {
            & sqlcmd -S $SqlInstance -E -C -Q "SELECT 1" -b 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Seconds 4
        }
        if (-not $ready) { throw "SQL Server did not become ready within 90 seconds. Check the SQL Server error log." }
        Write-Ok "SQL Server is up in single-user mode"

        # Single sqlcmd.exe call -- the only thing we do while in -m mode.
        # Grants BUILTIN\Administrators sysadmin so the normal multi-user run can connect.
        Write-Step "Granting BUILTIN\Administrators sysadmin access"
        $fixupSql = Join-Path $env:TEMP "sqlbootstrap_$stamp.sql"
        @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'BUILTIN\Administrators')
    CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;
IF NOT EXISTS (
    SELECT 1 FROM sys.server_role_members rm
    JOIN sys.server_principals r ON rm.role_principal_id  = r.principal_id
    JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = 'sysadmin' AND m.name = 'BUILTIN\Administrators')
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [BUILTIN\Administrators];
"@ | Set-Content -Path $fixupSql -Encoding ASCII
        & sqlcmd -S $SqlInstance -E -C -i $fixupSql -b
        $sqlExit = $LASTEXITCODE
        Remove-Item $fixupSql -ErrorAction SilentlyContinue
        if ($sqlExit -ne 0) { throw "Bootstrap sqlcmd fixup failed (exit $sqlExit). SQL Server may still be in -m mode." }
        Write-Ok "BUILTIN\Administrators is now sysadmin"

        # Remove -m and restart normally so the rest of the script runs as a normal session.
        Write-Step "Restarting SQL Server in normal multi-user mode"
        Stop-Service -Name $bootstrapSvcName -Force -ErrorAction Stop
        Remove-ItemProperty -Path $regPath -Name $bootstrapArgName -ErrorAction Stop
        $bootstrapArgName = $null   # cleared -- nothing left to clean up in finally
        Start-Service -Name $bootstrapSvcName -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds(90)
        $ready    = $false
        while ((Get-Date) -lt $deadline) {
            & sqlcmd -S $SqlInstance -E -C -Q "SELECT 1" -b 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Seconds 4
        }
        if (-not $ready) { throw "SQL Server did not come back up in normal mode within 90 seconds." }

        $bootstrapComplete = $true
        Write-Ok "SQL Server is up normally -- BUILTIN\Administrators has sysadmin; proceeding with login rebuild"
        Write-Warn2 "Note: BUILTIN\Administrators sysadmin login was left in place. Remove it when no longer needed."
        Write-Host ""
    }

    # -----------------------------------------------------------------------
    # 0. Pre-flight
    # -----------------------------------------------------------------------
    Write-Step "Connecting to '$SqlInstance' and running pre-flight checks"
    $who = Invoke-Sql -Query "SELECT SUSER_SNAME() AS cur, ORIGINAL_LOGIN() AS orig, SERVERPROPERTY('ProductVersion') AS ver"
    Write-Ok "Connected as '$($who.cur)' (original: '$($who.orig)') | SQL $($who.ver)"
    if (($LoginName -ieq $who.cur -or $LoginName -ieq $who.orig) -and (-not $Bootstrap) -and (-not $Force)) {
        throw "Refusing to rebuild '$LoginName' -- it is the login this session is connected as. Use -Force to override, or reconnect as a different sysadmin."
    }

    # -----------------------------------------------------------------------
    # 1. Confirm login exists & is a Windows login
    # -----------------------------------------------------------------------
    Write-Step "Confirming Windows login '$LoginName' exists"
    $principal = Invoke-Sql -Query @"
SELECT sp.type, sp.type_desc, sp.is_disabled,
       sp.default_database_name, sp.default_language_name,
       CONVERT(varchar(max), sp.sid, 1) AS sid_hex
FROM sys.server_principals sp
WHERE sp.name = N'$litLogin' AND sp.type IN ('U','G','S');
"@
    if (-not $principal) { throw "Login '$LoginName' was not found on '$SqlInstance'. Nothing to do." }

    $loginType = "$($principal.type)".Trim()
    if ($loginType -eq 'S') {
        throw "'$LoginName' is a SQL login. The Entra SID-remap problem does not apply to SQL logins, and re-SIDing one would BREAK its database mappings. Aborting on purpose."
    }
    $isDisabled  = [bool]$principal.is_disabled
    $defaultDb   = if ($principal.default_database_name) { "$($principal.default_database_name)" } else { 'master' }
    $defaultLang = if ($principal.default_language_name) { "$($principal.default_language_name)" } else { $null }
    $oldSid      = "$($principal.sid_hex)"   # hex literal, e.g. 0x0105...
    Write-Ok "Found '$LoginName' ($($principal.type_desc)); disabled=$isDisabled; old SID=$oldSid"

    # -----------------------------------------------------------------------
    # 2. Capture server roles + explicit server-scope permissions
    # -----------------------------------------------------------------------
    Write-Step "Capturing server role memberships"
    $roles = @(Invoke-Sql -Query @"
SELECT r.name AS role_name
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id  = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE m.name = N'$litLogin' ORDER BY r.name;
"@ | Select-Object -ExpandProperty role_name)
    Write-Ok ("Server roles: " + ($(if ($roles) { $roles -join ', ' } else { '(none beyond public)' })))

    Write-Step "Capturing explicit server-scope permissions"
    $perms = @(Invoke-Sql -Query @"
SELECT p.state_desc, p.permission_name
FROM sys.server_permissions p
JOIN sys.server_principals sp ON p.grantee_principal_id = sp.principal_id
WHERE sp.name = N'$litLogin' AND p.class = 100 ORDER BY p.permission_name;
"@)
    Write-Ok ("Explicit permissions: " + ($(if ($perms) { ($perms | ForEach-Object { "$($_.state_desc) $($_.permission_name)" }) -join '; ' } else { '(none)' })))

    # -----------------------------------------------------------------------
    # 3. Scan all online databases for users bound to the OLD SID
    #    (these orphan when the login is re-SIDed). Capture role memberships
    #    for audit -- ALTER USER WITH LOGIN preserves them, this is just a record.
    # -----------------------------------------------------------------------
    Write-Step "Scanning databases for users mapped to the old SID"
    $dbList = @(Invoke-Sql -Query "SELECT name FROM sys.databases WHERE state_desc='ONLINE' AND name <> 'tempdb' ORDER BY name" |
                Select-Object -ExpandProperty name)

    $mappedUsers = @()      # { Database, User, Roles }   (excludes dbo -- handled by ownership)
    $scanSkipped = @()
    foreach ($db in $dbList) {
        try {
            $users = @(Invoke-Sql -Database $db -Query @"
SELECT name FROM sys.database_principals
WHERE sid = $oldSid AND name <> 'dbo';
"@ | Select-Object -ExpandProperty name)
            foreach ($uname in $users) {
                $litUser = Esc-Lit $uname
                $dbRoles = @(Invoke-Sql -Database $db -Query @"
SELECT r.name AS role_name
FROM sys.database_role_members rm
JOIN sys.database_principals r ON rm.role_principal_id  = r.principal_id
JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
WHERE m.name = N'$litUser' ORDER BY r.name;
"@ | Select-Object -ExpandProperty role_name)
                $mappedUsers += [PSCustomObject]@{ Database = $db; User = $uname; Roles = $dbRoles }
                Write-Ok "[$db] user '$uname' (roles: $($(if($dbRoles){$dbRoles -join ', '}else{'none'})))"
            }
        }
        catch {
            $scanSkipped += $db
            Write-Warn2 "Could not scan [$db]: $($_.Exception.Message)"
        }
    }
    if (-not $mappedUsers) { Write-Ok "No database users mapped to this login (sysadmin-only case -- nothing to re-link)" }
    if ($scanSkipped)      { Write-Warn2 "Skipped (offline/read-only/secondary?): $($scanSkipped -join ', ')" }

    # -----------------------------------------------------------------------
    # 4. Databases owned by the login (matched by old SID)
    # -----------------------------------------------------------------------
    Write-Step "Finding databases owned by '$LoginName'"
    $ownedDbs = @(Invoke-Sql -Query "SELECT name FROM sys.databases WHERE owner_sid = $oldSid ORDER BY name" |
                  Select-Object -ExpandProperty name)
    Write-Ok ("Owned databases: " + ($(if ($ownedDbs) { $ownedDbs -join ', ' } else { '(none)' })))

    # -----------------------------------------------------------------------
    # 5. Build the recreate / restore / re-link T-SQL
    # -----------------------------------------------------------------------
    $createStmt = "CREATE LOGIN $qLogin FROM WINDOWS WITH DEFAULT_DATABASE=[$(Esc-Ident $defaultDb)]"
    if ($defaultLang) { $createStmt += ", DEFAULT_LANGUAGE=[$(Esc-Ident $defaultLang)]" }
    $createStmt += ";"

    $disableStmt = if ($isDisabled) { "ALTER LOGIN $qLogin DISABLE;" } else { $null }
    $roleStmts   = foreach ($r in $roles) { "ALTER SERVER ROLE [$(Esc-Ident $r)] ADD MEMBER $qLogin;" }
    $permStmts   = foreach ($p in $perms) {
        $pn = "$($p.permission_name)"
        switch ("$($p.state_desc)") {
            'GRANT'            { "GRANT $pn TO $qLogin;" }
            'GRANT_WITH_GRANT' { "GRANT $pn TO $qLogin WITH GRANT OPTION;" }
            'DENY'             { "DENY $pn TO $qLogin;" }
            default            { "GRANT $pn TO $qLogin;" }
        }
    }
    # Re-link statements are paired with their database context.
    $relink = foreach ($m in $mappedUsers) {
        [PSCustomObject]@{ Database = $m.Database; Sql = "ALTER USER [$(Esc-Ident $m.User)] WITH LOGIN = $qLogin;" }
    }
    $reassignBack = foreach ($db in $ownedDbs) {
        [PSCustomObject]@{ Database = $db; Sql = "ALTER AUTHORIZATION ON DATABASE::[$(Esc-Ident $db)] TO $qLogin;" }
    }

    # -----------------------------------------------------------------------
    # 6. Persist state + recovery script BEFORE any change
    # -----------------------------------------------------------------------
    $state = [PSCustomObject]@{
        Timestamp         = $stamp
        SqlInstance       = $SqlInstance
        LoginName         = $LoginName
        LoginType         = $principal.type_desc
        OldSid            = $oldSid
        IsDisabled        = $isDisabled
        DefaultDatabase   = $defaultDb
        DefaultLanguage   = $defaultLang
        ServerRoles       = $roles
        ServerPermissions = ($perms | ForEach-Object { "$($_.state_desc) $($_.permission_name)" })
        MappedUsers       = $mappedUsers
        OwnedDatabases    = $ownedDbs
        ScannedDatabases  = $dbList
        ScanSkipped       = $scanSkipped
        HoldingOwner      = $HoldingOwner
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Ok "State backup: $jsonPath"

    $rl = @(
        "-- Recovery for [$LoginName] on [$SqlInstance], generated $stamp.",
        "-- Run as sysadmin if the rebuild was interrupted after DROP LOGIN.",
        "-- Note: CREATE LOGIN FROM WINDOWS picks up the CURRENT (Entra) SID by design.",
        $(if ($bootstrapComplete) { "-- BOOTSTRAP CLEANUP: DROP LOGIN [BUILTIN\Administrators]; -- remove when access is fully restored." } else { $null }),
        "USE [master];", "GO", $createStmt, "GO"
    ) | Where-Object { $null -ne $_ }
    if ($disableStmt) { $rl += $disableStmt; $rl += "GO" }
    foreach ($s in $roleStmts) { $rl += $s; $rl += "GO" }
    foreach ($s in $permStmts) { $rl += $s; $rl += "GO" }
    foreach ($r in $relink)       { $rl += "USE [$(Esc-Ident $r.Database)];"; $rl += "GO"; $rl += $r.Sql; $rl += "GO" }
    foreach ($r in $reassignBack) { $rl += "USE [master];"; $rl += "GO"; $rl += $r.Sql; $rl += "GO" }
    $rl | Set-Content -Path $recovPath -Encoding UTF8
    Write-Ok "Recovery script: $recovPath"

    # -----------------------------------------------------------------------
    # 7. Plan
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "------------------------- PLAN -------------------------" -ForegroundColor Magenta
    Write-Host "Login            : $LoginName ($($principal.type_desc))   [old SID $oldSid -> new Entra SID]"
    Write-Host "Disabled         : $isDisabled"
    Write-Host "Server roles     : $([string]::Join(', ', $roles))"
    Write-Host "Server perms     : $([string]::Join('; ', $state.ServerPermissions))"
    Write-Host "Re-link users    : $($mappedUsers.Count) across $((@($mappedUsers.Database | Select-Object -Unique)).Count) database(s)"
    foreach ($m in $mappedUsers) { Write-Host "    [$($m.Database)] $($m.User)  (roles: $($(if($m.Roles){$m.Roles -join ', '}else{'none'})))" }
    Write-Host "Owned databases  : $([string]::Join(', ', $ownedDbs))  --> '$HoldingOwner' then back"
    if ($Bootstrap -and $bootstrapComplete)  { Write-Host "Bootstrap mode   : COMPLETE -- BUILTIN\Administrators sysadmin added; server running normally" -ForegroundColor Green }
    if ($Bootstrap -and (-not $bootstrapComplete)) { Write-Host "Bootstrap mode   : ACTIVE  -- SQL Server is currently running with -m" -ForegroundColor Red }
    Write-Host "--------------------------------------------------------" -ForegroundColor Magenta
    Write-Host ""

    if ($DryRun) { Write-Warn2 "DryRun -- no changes made. Backup + recovery script were still written."; return }

    # -----------------------------------------------------------------------
    # 8. Confirmation gate
    # -----------------------------------------------------------------------
    if (-not $Force) {
        $answer = Read-Host "This DROPS and RECREATES the login with a NEW SID. Type the login name to confirm"
        if ($answer -ine $LoginName) { throw "Confirmation did not match. Aborted; no changes made." }
    }

    # -----------------------------------------------------------------------
    # PHASE A: reassign owned databases to holding owner (rollback on failure)
    # -----------------------------------------------------------------------
    $moved = @()
    Write-Step "Reassigning owned databases to '$HoldingOwner'"
    foreach ($db in $ownedDbs) {
        try {
            Invoke-Sql -Query "ALTER AUTHORIZATION ON DATABASE::[$(Esc-Ident $db)] TO $qOwner;" -NoResult
            $moved += $db; Write-Ok "[$db] owner -> $HoldingOwner"
        }
        catch {
            Write-Warn2 "Failed to reassign [$db]: $($_.Exception.Message). Rolling back; login will NOT be dropped."
            foreach ($rb in $moved) {
                try { Invoke-Sql -Query "ALTER AUTHORIZATION ON DATABASE::[$(Esc-Ident $rb)] TO $qLogin;" -NoResult; Write-Ok "[$rb] owner restored" }
                catch { Write-Warn2 "ROLLBACK FAILED for [$rb]: $($_.Exception.Message). Fix manually." }
            }
            throw "Aborted before any destructive change (database ownership reassignment failed)."
        }
    }

    # -----------------------------------------------------------------------
    # PHASE B: drop login  (destructive; recovery .sql is your net from here)
    # -----------------------------------------------------------------------
    Write-Step "Dropping login '$LoginName'"
    Invoke-Sql -Query "DROP LOGIN $qLogin;" -NoResult
    Write-Ok "Login dropped (database users are now orphaned; will re-link below)"

    # -----------------------------------------------------------------------
    # PHASE C: recreate login (NO SID -> new Entra SID) + state + roles + perms
    # -----------------------------------------------------------------------
    Write-Step "Recreating login from Windows (fresh SID lookup)"
    Invoke-Sql -Query $createStmt -NoResult
    $newSid = "$((Invoke-Sql -Query "SELECT CONVERT(varchar(max), sid, 1) AS s FROM sys.server_principals WHERE name = N'$litLogin'").s)"
    Write-Ok "Login recreated; new SID=$newSid"
    if ($newSid -eq $oldSid) {
        Write-Warn2 "New SID equals old SID. The OS resolved the same SID -- has this machine actually migrated to Entra yet? (Check: whoami /user)"
    }

    if ($disableStmt) { Invoke-Sql -Query $disableStmt -NoResult; Write-Ok "Login DISABLED to match original" }
    foreach ($s in $roleStmts) { Invoke-Sql -Query $s -NoResult; Write-Ok $s }
    foreach ($s in $permStmts) { Invoke-Sql -Query $s -NoResult; Write-Ok $s }

    # -----------------------------------------------------------------------
    # PHASE D: re-link orphaned database users (preserves their roles/grants)
    # -----------------------------------------------------------------------
    Write-Step "Re-linking orphaned database users (ALTER USER WITH LOGIN)"
    $relinkFailed = @()
    foreach ($r in $relink) {
        try {
            Invoke-Sql -Database $r.Database -Query $r.Sql -NoResult
            Write-Ok "[$($r.Database)] $($r.Sql)"
        }
        catch {
            $relinkFailed += $r
            Write-Warn2 "[$($r.Database)] re-link FAILED: $($_.Exception.Message)"
        }
    }

    # -----------------------------------------------------------------------
    # PHASE E: reassign owned databases back to the login
    # -----------------------------------------------------------------------
    Write-Step "Reassigning database ownership back to '$LoginName'"
    foreach ($r in $reassignBack) { Invoke-Sql -Query $r.Sql -NoResult; Write-Ok $r.Sql }

    # -----------------------------------------------------------------------
    # 9. Verify -- look for any users still orphaned for this login by NAME
    # -----------------------------------------------------------------------
    Write-Step "Verifying no orphaned users remain"
    $remainingOrphans = @()
    foreach ($db in ($mappedUsers.Database | Select-Object -Unique)) {
        try {
            $bad = @(Invoke-Sql -Database $db -Query @"
SELECT dp.name
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.name = N'$litLogin' AND sp.sid IS NULL;
"@ | Select-Object -ExpandProperty name)
            foreach ($b in $bad) { $remainingOrphans += "[$db] $b" }
        } catch { Write-Warn2 "Verify scan of [$db] failed: $($_.Exception.Message)" }
    }

    Write-Host ""
    Write-Host "----------------------- RESULT -------------------------" -ForegroundColor Green
    Write-Host "Login            : $LoginName"
    Write-Host "Old SID -> New   : $oldSid  ->  $newSid"
    Write-Host "Re-linked users  : $($relink.Count - $relinkFailed.Count) / $($relink.Count)"
    Write-Host "Owned dbs back   : $([string]::Join(', ', $ownedDbs))"
    if ($relinkFailed)     { Write-Host "Re-link FAILURES : $([string]::Join(', ', ($relinkFailed | ForEach-Object { $_.Database })))" -ForegroundColor Yellow }
    if ($remainingOrphans) { Write-Host "STILL ORPHANED   : $([string]::Join('; ', $remainingOrphans))" -ForegroundColor Yellow }
    if (-not $relinkFailed -and -not $remainingOrphans) { Write-Host "All users re-linked cleanly." -ForegroundColor Green }
    if ($bootstrapComplete) { Write-Host "Bootstrap cleanup: DROP LOGIN [BUILTIN\Administrators];  -- run this once access is confirmed restored" -ForegroundColor Yellow }
    Write-Host "--------------------------------------------------------" -ForegroundColor Green
    Write-Ok "Done."
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "If the login was already dropped, finish manually with the recovery script:" -ForegroundColor Yellow
    Write-Host "    $recovPath" -ForegroundColor Yellow
    Write-Host "Captured state: $jsonPath" -ForegroundColor Yellow
    throw
}
finally {
    if ($sqlWasStopped -and (-not $bootstrapComplete)) {
        # Bootstrap did not complete normally -- SQL may still be in -m mode or stopped.
        Write-Host ""
        Write-Step "Bootstrap emergency cleanup: removing -m and restarting SQL Server"
        try { Stop-Service -Name $bootstrapSvcName -Force -ErrorAction Stop; Write-Ok "SQL Server stopped" }
        catch { Write-Warn2 "Could not stop SQL Server: $($_.Exception.Message)" }
        if ($bootstrapArgName) {
            try { Remove-ItemProperty -Path $regPath -Name $bootstrapArgName -ErrorAction Stop; Write-Ok "Removed $bootstrapArgName (-m) from registry" }
            catch { Write-Host "CRITICAL: Remove $bootstrapArgName manually from registry before next start: $regPath" -ForegroundColor Red }
        }
        try { Start-Service -Name $bootstrapSvcName -ErrorAction Stop; Write-Ok "SQL Server restarted normally" }
        catch { Write-Host "CRITICAL: Could not restart '$bootstrapSvcName'. Start it manually!" -ForegroundColor Red }
    }
    if ($Bootstrap -and $agentWasRunning) {
        $agentSvcCleanup = Get-SqlAgentServiceName
        try { Start-Service -Name $agentSvcCleanup -ErrorAction Stop; Write-Ok "SQL Agent restarted" }
        catch { Write-Warn2 "Could not restart SQL Agent '$agentSvcCleanup'. Start it manually if needed." }
    }
    Stop-Transcript | Out-Null
}