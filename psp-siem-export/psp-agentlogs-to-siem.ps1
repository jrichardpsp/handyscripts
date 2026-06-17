#requires -version 5.1
<#
.SYNOPSIS
    Incrementally exports PowerSyncPro RunbookLogEntries to formatted log files for SIEM ingestion.

.DESCRIPTION
    - Pulls only new rows each run using a durable high-water mark on the clustered PK (Id).
    - Id > @LastId comparison is performed SERVER-SIDE so SQL Server uniqueidentifier sort order
      is always used -- never .NET or string ordering.
    - TenantId filter is MANDATORY: multi-tenant DB; omitting it leaks other tenants' data.
    - Resolves AgentId -> MachineName/Domain/Version and RunbookId -> Name via LEFT JOIN.
    - Pluggable output formatter: ECS NDJSON (default), CEF stub, RFC 5424 syslog stub.
    - Atomic publish: writes .tmp then renames into the watched folder.
    - Single-instance via a named mutex -- a slow run never overlaps the next trigger.
    - Watermark persisted ONLY after each batch file is safely renamed into place.
    - Optional dedupe-over-window mode catches late-arriving rows from concurrent writers (off by default).
    - Run log appended to StateDir\psp_siem_runlog.ndjson after each run.
    - Transient DB failures exit cleanly (exit code 2); no partial files, no watermark advance.

    No external modules required (uses System.Data.SqlClient, built into Windows PowerShell 5.1).
    Works on SQL Server and SQL Server Express (named instances).
    See README.md for full setup, scheduling, and least-privilege DB instructions.

.PARAMETER ConfigFile
    Path to a JSON config file. Defaults to psp-siem-export.json in the script directory.
    CLI parameters always override config file values.

.PARAMETER OutputFormat
    ECS    = Elastic Common Schema NDJSON (default, production-ready).
    CEF    = ArcSight Common Event Format (stub -- implement before production use).
    Syslog = RFC 5424 syslog (stub -- implement before production use).

.PARAMETER EnableDedupeWindow
    Enable only if PSP runs multiple concurrent writer processes. Off by default.
    When on, a lookback query re-fetches rows whose Id landed behind the watermark, and a
    persisted seen-ID set prevents re-emitting rows already exported in a prior run.

.PARAMETER DryRun
    Query and format rows but write nothing to disk and advance no watermark.
    Useful for verifying connectivity and estimated row counts before the first live run.

.NOTES
    Schedule via Windows Task Scheduler (Register-PSPLogExportTask.ps1) every 5 minutes.
    For full SQL Server, a SQL Agent job is also supported -- see psp-siem-export-permissions.sql.
    Run as a gMSA or dedicated service account with least-privilege DB access.

    SQL Express / named instances: the SQL Server Browser service must be running for port
    resolution, unless you hard-code the port in the instance string (e.g. HOST\SQLEXPRESS,52317).
#>

[CmdletBinding()]
param(
    [string]$ConfigFile           = '',

    # ----- Connection -----
    [string]$SqlInstance          = 'YOURHOST\SQLEXPRESS',
    [string]$Database             = 'PowerSyncProDB',

    # ----- Scope (mandatory security control: never remove or default this away) -----
    [int]   $TenantId             = 1,

    # ----- Output / state -----
    [string]$OutputDir            = 'C:\PSPLogExport\out',
    [string]$StateDir             = 'C:\PSPLogExport\state',
    [int]   $BatchSize            = 5000,
    [string]$EventDataset         = 'powersyncpro.runbooklog',

    # ----- Formatter -----
    [ValidateSet('ECS','CEF','Syslog')]
    [string]$OutputFormat         = 'ECS',

    # ----- Dedupe-over-window mode (off by default) -----
    [switch]$EnableDedupeWindow,
    [int]   $DedupeWindowMinutes  = 10,
    [int]   $DedupeMaxSeenIds     = 50000,

    # ----- Run mode -----
    [switch]$DryRun
)

# ============================================================================
#  CONFIG FILE
#  Looks for psp-siem-export.json in the script directory, or use -ConfigFile.
#  CLI params always win; config fills in any that were not explicitly passed.
# ============================================================================
$cfgPath = if ($ConfigFile) { $ConfigFile } else { Join-Path $PSScriptRoot 'psp-siem-export.json' }
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in @('SqlInstance','Database','TenantId','OutputDir','StateDir','BatchSize',
                         'EventDataset','OutputFormat','EnableDedupeWindow',
                         'DedupeWindowMinutes','DedupeMaxSeenIds')) {
            if (-not $PSBoundParameters.ContainsKey($k) -and $null -ne $cfg.$k) {
                Set-Variable -Name $k -Value $cfg.$k
            }
        }
    } catch {
        Write-Warning "Could not load config '$cfgPath': $($_.Exception.Message)"
    }
}

# ============================================================================
#  LOOKUP TABLES  --  confirm with FK discovery query before first run:
#    SELECT fk.name, OBJECT_NAME(fk.referenced_object_id)
#    FROM sys.foreign_keys fk
#    WHERE fk.parent_object_id = OBJECT_ID('dbo.RunbookLogEntries');
# ============================================================================
$AgentTable        = 'dbo.Agents'
$AgentKeyColumn    = 'Id'
$AgentNameColumn   = 'MachineName'       # FQDN host name, e.g. LAB-XXXX.contoso.com
$RunbookTable      = 'dbo.Runbooks'
$RunbookKeyColumn  = 'Id'
$RunbookNameColumn = 'Name'

# ============================================================================
#  SEVERITY MAP  --  0 = Information, 1 = Warning, 2 = Error
# ============================================================================
$SeverityMap = @{ 0 = 'Information'; 1 = 'Warning'; 2 = 'Error' }

# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$utf8NoBom   = New-Object System.Text.UTF8Encoding($false)
$EmptyGuid   = [Guid]::Empty
$StateFile   = Join-Path $StateDir ("tenant_{0}.json" -f $TenantId)
$RunLogFile  = Join-Path $StateDir 'psp_siem_runlog.ndjson'
$MutexName   = "Global\PSPLogExport_{0}_{1}" -f ($Database -replace '\W','_'), $TenantId
$ScriptStart = Get-Date

# ============================================================================
#  HELPERS
# ============================================================================
function New-DirIfMissing([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-Watermark {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $s = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            if ($s.LastId) { return [Guid]$s.LastId }
        } catch {
            Write-Warning "State file unreadable ($($_.Exception.Message)); starting from zero."
        }
    }
    return $EmptyGuid
}

function Get-SeenIds {
    if (-not $EnableDedupeWindow) { return @{} }
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $s = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            if ($s.SeenIds) {
                $set = @{}
                # @() wrapping handles both JSON array and single-string edge case
                foreach ($id in @($s.SeenIds)) { $set[$id] = $true }
                return $set
            }
        } catch {}
    }
    return @{}
}

function Set-Watermark([Guid]$LastId, [hashtable]$SeenIds) {
    $obj = [ordered]@{
        LastId     = $LastId.ToString()
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($EnableDedupeWindow -and $SeenIds -and $SeenIds.Count -gt 0) {
        $ids = @($SeenIds.Keys)
        if ($ids.Count -gt $DedupeMaxSeenIds) { $ids = $ids | Select-Object -Last $DedupeMaxSeenIds }
        $obj.SeenIds = $ids
    }
    $tmp = "$StateFile.tmp"
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json), $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

function Write-RunLog {
    param(
        [int]   $RowsExported  = 0,
        [int]   $Batches       = 0,
        [string]$LastWatermark = '',
        [string]$RunError      = $null
    )
    $entry = [ordered]@{
        timestamp      = (Get-Date).ToUniversalTime().ToString('o')
        tenant_id      = $TenantId
        rows_exported  = $RowsExported
        batches        = $Batches
        last_watermark = $LastWatermark
        duration_ms    = [int]((Get-Date) - $ScriptStart).TotalMilliseconds
        output_format  = $OutputFormat
        dry_run        = [bool]$DryRun
        error          = $RunError
    }
    $line = ($entry | ConvertTo-Json -Compress) + "`n"
    try { [System.IO.File]::AppendAllText($RunLogFile, $line, $utf8NoBom) } catch {}
}

function Get-OutputExtension {
    switch ($OutputFormat) {
        'CEF'    { return '.cef'    }
        'Syslog' { return '.log'    }
        default  { return '.ndjson' }
    }
}

# ============================================================================
#  OUTPUT FORMATTERS
# ============================================================================

function ConvertTo-EcsRecord($row) {
    $v = { param($x) if ($x -is [System.DBNull]) { $null } else { $x } }

    $sev   = [int](& $v $row['Severity'])
    $level = if ($SeverityMap.ContainsKey($sev)) { $SeverityMap[$sev] } else { "level$sev" }

    $mdOff = [System.DateTimeOffset]$row['MessageDate']
    $tsUtc = $mdOff.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')

    $logon = & $v $row['LogonName']
    $uName = $null; $uDom = $null
    if ($logon) {
        if ($logon -match '^(?<dom>[^\\]+)\\(?<usr>.+)$') { $uDom = $Matches.dom; $uName = $Matches.usr }
        else { $uName = $logon }
    }

    $agentId     = & $v $row['AgentId']
    $agentName   = & $v $row['AgentName']
    $agentDomain = & $v $row['AgentDomain']
    $agentVer    = & $v $row['AgentVersion']
    $rbId        = & $v $row['RunbookId']
    $rbName      = & $v $row['RunbookName']
    $phase       = & $v $row['Phase']
    $action      = & $v $row['Action']
    $message     = & $v $row['Message']

    $rec = [ordered]@{
        '@timestamp' = $tsUtc
        message      = $message
        log          = [ordered]@{ level = $level }
        event        = [ordered]@{
            id       = ([Guid]$row['Id']).ToString()
            dataset  = $EventDataset
            severity = $sev
            kind     = 'event'
            module   = 'powersyncpro'
        }
        organization = [ordered]@{ id = ([string]$row['TenantId']) }
        psp          = [ordered]@{ tenant_id = [int]$row['TenantId'] }
    }

    if ($uName) {
        $rec.user = [ordered]@{ name = $uName }
        if ($uDom) { $rec.user.domain = $uDom }
    }
    if ($agentId) {
        $rec.agent = [ordered]@{ id = ([Guid]$agentId).ToString() }
        if ($agentName) { $rec.agent.name    = $agentName }
        if ($agentVer)  { $rec.agent.version = $agentVer  }
        if ($agentName -or $agentDomain) {
            $rec.host = [ordered]@{}
            if ($agentName)   { $rec.host.name = $agentName; $rec.host.hostname = $agentName }
            if ($agentDomain) { $rec.host.domain = $agentDomain }
        }
    }
    if ($agentId)         { $rec.psp.agent_id     = ([Guid]$agentId).ToString() }
    if ($agentName)       { $rec.psp.agent_name   = $agentName }
    if ($rbId)            { $rec.psp.runbook_id   = ([Guid]$rbId).ToString() }
    if ($rbName)          { $rec.psp.runbook_name = $rbName; $rec.event.action = $rbName }
    if ($null -ne $phase) { $rec.psp.phase        = [int]$phase }
    if ($action)          { $rec.psp.action = $action; $rec.event.provider = $action }

    return ($rec | ConvertTo-Json -Compress -Depth 6)
}

function ConvertTo-CefRecord($row) {
    # CEF (ArcSight Common Event Format) -- STUB
    # Full implementation must:
    #   Map Severity 0/1/2 to CEF severity bands (0-3 / 4-6 / 7-10)
    #   Build extension as key=value pairs; escape = and \ in values; escape | in header fields
    #   Format: CEF:0|Vendor|Product|Version|SignatureId|Name|Severity|extension
    Write-Warning "CEF formatter is a stub -- implement ConvertTo-CefRecord before production use."
    $id  = ([Guid]$row['Id']).ToString()
    $sev = [int]$row['Severity']
    return ("CEF:0|PowerSyncPro|RunbookLog|1.0|{0}|STUB|{1}|stub=true" -f $id, $sev)
}

function ConvertTo-SyslogRecord($row) {
    # RFC 5424 syslog -- STUB
    # Full implementation must:
    #   Choose a facility (local0-7 = 16-23); PRI = (facility * 8) + mapped-severity
    #   Populate HOSTNAME, APP-NAME, PROCID, MSGID fields
    #   Encode structured data; escape ] \ " inside SD param values
    #   Format: <PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID [SD-ELEMENT] MSG
    Write-Warning "Syslog formatter is a stub -- implement ConvertTo-SyslogRecord before production use."
    $id = ([Guid]$row['Id']).ToString()
    $ts = ([System.DateTimeOffset]$row['MessageDate']).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    return ('<134>1 {0} - PSPLogExport - - - [psp id="{1}"] STUB' -f $ts, $id)
}

function Format-LogRow($row) {
    switch ($OutputFormat) {
        'CEF'    { return ConvertTo-CefRecord    $row }
        'Syslog' { return ConvertTo-SyslogRecord $row }
        default  { return ConvertTo-EcsRecord    $row }
    }
}

# ============================================================================
#  SQL
#  Table/column identifiers come from operator-controlled config, never from data.
#  All row VALUES are passed as SqlParameters -- log content has no injection surface.
# ============================================================================
$sql = @"
SELECT TOP (@BatchSize)
       le.Id, le.TenantId, le.AgentId, le.LogonName, le.RunbookId,
       le.Phase, le.[Action], le.Severity, le.[Message], le.MessageDate,
       a.[$AgentNameColumn]   AS AgentName,
       a.[Domain]             AS AgentDomain,
       a.[Version]            AS AgentVersion,
       r.[$RunbookNameColumn] AS RunbookName
FROM dbo.RunbookLogEntries le
LEFT JOIN $AgentTable   a ON a.[$AgentKeyColumn]   = le.AgentId
LEFT JOIN $RunbookTable r ON r.[$RunbookKeyColumn] = le.RunbookId
WHERE le.TenantId = @TenantId
  AND le.Id > @LastId
ORDER BY le.Id;
"@

# Used only when -EnableDedupeWindow is set.
# Fetches rows whose Id landed BEHIND the current watermark but whose MessageDate falls
# within the lookback window, indicating a late-arriving concurrent write.
# Already-seen IDs are filtered in PowerShell to avoid a large T-SQL NOT IN list.
$sqlLookback = @"
SELECT le.Id, le.TenantId, le.AgentId, le.LogonName, le.RunbookId,
       le.Phase, le.[Action], le.Severity, le.[Message], le.MessageDate,
       a.[$AgentNameColumn]   AS AgentName,
       a.[Domain]             AS AgentDomain,
       a.[Version]            AS AgentVersion,
       r.[$RunbookNameColumn] AS RunbookName
FROM dbo.RunbookLogEntries le
LEFT JOIN $AgentTable   a ON a.[$AgentKeyColumn]   = le.AgentId
LEFT JOIN $RunbookTable r ON r.[$RunbookKeyColumn] = le.RunbookId
WHERE le.TenantId = @TenantId
  AND le.Id <= @LastId
  AND le.MessageDate >= DATEADD(minute, -@Window, SYSDATETIMEOFFSET())
ORDER BY le.Id;
"@

# ============================================================================
#  MAIN
# ============================================================================
New-DirIfMissing $OutputDir
New-DirIfMissing $StateDir

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Host "Another instance is already running for tenant $TenantId. Exiting."
    return
}

if ($DryRun) { Write-Host "[DRY RUN] No files will be written and no watermark will advance." }

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$SqlInstance;Database=$Database;Integrated Security=SSPI;" +
                         "Connect Timeout=15;Encrypt=True;TrustServerCertificate=True;" +
                         "Application Name=PSPLogExport"

$lastId       = $EmptyGuid
$seenIds      = @{}
$totalRows    = 0
$totalBatches = 0
$runError     = $null
$fileExt      = Get-OutputExtension

try {
    # Separate catch for the Open() call so a DB-unreachable condition exits cleanly
    # with a distinct exit code instead of being treated as a script bug.
    try { $conn.Open() }
    catch [System.Data.SqlClient.SqlException] {
        $runError = "DB connection failed ($SqlInstance): $($_.Exception.Message)"
        Write-Warning $runError
        Write-RunLog -RunError $runError
        exit 2
    }

    $lastId  = Get-Watermark
    $seenIds = Get-SeenIds

    Write-Host ("[{0}] Tenant {1}: resuming after Id {2}{3}" -f `
        (Get-Date -Format s), $TenantId, $lastId, $(if ($DryRun) { ' [DRY RUN]' } else { '' }))

    if ($EnableDedupeWindow) {
        Write-Host ("  Dedupe-window ON: {0}-min lookback, up to {1} seen IDs persisted" -f `
            $DedupeWindowMinutes, $DedupeMaxSeenIds)
    }

    # --- Dedupe lookback (only when enabled and not on the very first run) ---
    if ($EnableDedupeWindow -and ($lastId -ne $EmptyGuid)) {
        $lbCmd = $conn.CreateCommand()
        $lbCmd.CommandText  = $sqlLookback
        $lbCmd.CommandTimeout = 120
        [void]$lbCmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@TenantId', [System.Data.SqlDbType]::Int)))
        $pLbId = New-Object System.Data.SqlClient.SqlParameter('@LastId', [System.Data.SqlDbType]::UniqueIdentifier)
        $pWin  = New-Object System.Data.SqlClient.SqlParameter('@Window',  [System.Data.SqlDbType]::Int)
        [void]$lbCmd.Parameters.Add($pLbId)
        [void]$lbCmd.Parameters.Add($pWin)
        $lbCmd.Parameters['@TenantId'].Value = $TenantId
        $pLbId.Value = $lastId
        $pWin.Value  = $DedupeWindowMinutes

        $lbTable  = New-Object System.Data.DataTable
        $lbDa     = New-Object System.Data.SqlClient.SqlDataAdapter $lbCmd
        $lbCount  = $lbDa.Fill($lbTable)

        if ($lbCount -gt 0) {
            $lateRows = @($lbTable.Rows | Where-Object { -not $seenIds.ContainsKey(([Guid]$_['Id']).ToString()) })
            if ($lateRows.Count -gt 0) {
                $lbLines = New-Object System.Collections.Generic.List[string]
                foreach ($r in $lateRows) {
                    $lbLines.Add((Format-LogRow $r))
                    $seenIds[([Guid]$r['Id']).ToString()] = $true
                }
                if (-not $DryRun) {
                    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
                    $final = Join-Path $OutputDir ("psp_runbooklog_{0}_{1}_dedupe_{2}{3}" -f $TenantId, $stamp, $lateRows.Count, $fileExt)
                    $tmp   = "$final.tmp"
                    [System.IO.File]::WriteAllText($tmp, (([string]::Join("`n", $lbLines)) + "`n"), $utf8NoBom)
                    Move-Item -LiteralPath $tmp -Destination $final -Force
                    $totalRows    += $lateRows.Count
                    $totalBatches++
                    Write-Host ("  [dedupe] wrote {0,5} late-arriving row(s) -> {1}" -f $lateRows.Count, (Split-Path $final -Leaf))
                } else {
                    Write-Host ("  [dedupe][DRY RUN] {0} late-arriving row(s) would be written" -f $lateRows.Count)
                }
            } else {
                Write-Host ("  [dedupe] {0} row(s) in window, all already seen -- skipped" -f $lbCount)
            }
        }
        $lbTable.Dispose()
    }

    # --- Standard incremental batch loop ---
    do {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText  = $sql
        $cmd.CommandTimeout = 120
        [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@BatchSize', [System.Data.SqlDbType]::Int)))
        [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@TenantId',  [System.Data.SqlDbType]::Int)))
        $pLast = New-Object System.Data.SqlClient.SqlParameter('@LastId', [System.Data.SqlDbType]::UniqueIdentifier)
        [void]$cmd.Parameters.Add($pLast)
        $cmd.Parameters['@BatchSize'].Value = $BatchSize
        $cmd.Parameters['@TenantId'].Value  = $TenantId
        $pLast.Value = $lastId

        $table    = New-Object System.Data.DataTable
        $da       = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $rowCount = $da.Fill($table)

        if ($rowCount -eq 0) { break }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($row in $table.Rows) {
            $lines.Add((Format-LogRow $row))
            if ($EnableDedupeWindow) { $seenIds[([Guid]$row['Id']).ToString()] = $true }
        }

        $newLastId = [Guid]$table.Rows[$rowCount - 1]['Id']

        if (-not $DryRun) {
            $stamp  = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
            $final  = Join-Path $OutputDir ("psp_runbooklog_{0}_{1}_{2}{3}" -f $TenantId, $stamp, $rowCount, $fileExt)
            $tmp    = "$final.tmp"
            [System.IO.File]::WriteAllText($tmp, (([string]::Join("`n", $lines)) + "`n"), $utf8NoBom)
            Move-Item -LiteralPath $tmp -Destination $final -Force

            # Advance watermark ONLY after the file is safely in place
            $lastId = $newLastId
            Set-Watermark -LastId $lastId -SeenIds $seenIds
            Write-Host ("  wrote {0,5} rows -> {1}" -f $rowCount, (Split-Path $final -Leaf))
        } else {
            $lastId = $newLastId
            Write-Host ("  [DRY RUN] {0,5} rows (lastId would advance to {1})" -f $rowCount, $lastId)
        }

        $totalRows    += $rowCount
        $totalBatches++
        $table.Dispose()

    } while ($rowCount -eq $BatchSize)

    $doneMsg = if ($DryRun) { ' [DRY RUN -- nothing written]' } else { '' }
    Write-Host ("[{0}] Done. {1} row(s) in {2} batch(es).{3}" -f `
        (Get-Date -Format s), $totalRows, $totalBatches, $doneMsg)

    if (-not $DryRun) {
        Write-RunLog -RowsExported $totalRows -Batches $totalBatches -LastWatermark $lastId.ToString()
    }
}
catch [System.Data.SqlClient.SqlException] {
    $runError = "SQL error during export: $($_.Exception.Message)"
    Write-Error $runError
    Write-RunLog -RowsExported $totalRows -Batches $totalBatches -LastWatermark $lastId.ToString() -RunError $runError
    throw
}
catch {
    $runError = "Export failed: $($_.Exception.Message)"
    Write-Error $runError
    Write-RunLog -RowsExported $totalRows -Batches $totalBatches -LastWatermark $lastId.ToString() -RunError $runError
    throw
}
finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
