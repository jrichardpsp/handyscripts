<#
.SYNOPSIS
    Scrapes PowerSyncPro Migration Agent logs (CSV export) and reports migration
    status per machine, flagging machines where no user profile was migrated.

.DESCRIPTION
    Parses the PSP Agent Logs CSV export and, for each machine that ran a
    migration runbook, extracts the users that were migrated. Evidence used:

      1. Device State phase:  "Backed up <N> AppX applications for user <SID>"
         - The LogonName column on that row identifies the migrated user.
         - If this line is missing for a machine that ran a runbook, something
           went wrong with the migration (commonly a failed SID translation).
      2. AppX Migration:      "<N> AppX applications restored"
         - Confirms the user's profile was restored after the migration.
         - The restore fires via an Active Setup record at the user's next
           logon, so it can legitimately lag the runbook by hours or days.

    A machine can have multiple users migrated; each gets its own evidence pair.

    Machines with no runbook activity (polling only) are ignored.

    Status values (worst first - the report is sorted in this order):
      FLAG: No users migrated     - Runbook ran but no AppX backup line was
                                    found. This is the primary failure signal.
                                    Any "Unable to find SID translation"
                                    warnings are surfaced in Problems.
      FLAG: Runbook not completed - Runbook started but no completion line
                                    was found in the log window.
      WARN: Restore pending       - A user was backed up but no restore line
                                    yet. Usually means the user has not logged
                                    in since the migration; worth re-checking
                                    on a later log export.
      OK                          - Runbook completed, every user backed up
                                    and restored.

.PARAMETER LogPath
    Path(s) to one or more PSP Agent Logs CSV exports. Multiple files are
    merged before processing, so overlapping exports are fine.

.PARAMETER OutputCsv
    Path for the report CSV. Defaults to MigrationReport_<timestamp>.csv next
    to the first input file.

.PARAMETER FlaggedOnly
    Only output rows with a FLAG status (WARN and OK rows are suppressed).

.EXAMPLE
    .\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv"

.EXAMPLE
    .\Get-MigrationReport.ps1 -LogPath "C:\Temp\Logs1.csv","C:\Temp\Logs2.csv" -OutputCsv C:\Temp\Report.csv

.EXAMPLE
    .\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv" -FlaggedOnly |
        Where-Object { $_.Runbook -eq 'CONTOSO - Hybrid AD to Entra' }

.NOTES
    PowerShell 5.1 compatible. ASCII only.
    The report objects are also written to the pipeline for further filtering.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv,

    [switch]$FlaggedOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- Load and merge all log rows ---------------------------------------------
# Expected columns (as exported by the PSP portal's Agent Logs page):
#   ComputerName, LogonName, RunbookName, Action, Phase, Severity, Message, MessageDate
$rows = @()
foreach ($path in $LogPath) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Log file not found: $path"
    }
    Write-Verbose "Importing $path"
    $rows += Import-Csv -LiteralPath $path
}
if ($rows.Count -eq 0) {
    throw "No rows found in the supplied log file(s)."
}

# The export is newest-first; sort oldest-first so start/complete pairing and
# backup-then-restore ordering read naturally. MessageDate format
# (yyyy-MM-dd HH:mm) sorts correctly as a plain string.
$rows = $rows | Sort-Object MessageDate

# --- Regex patterns -----------------------------------------------------------
# All matching is done on the Message column only; Phase/Action columns are not
# relied upon because several key lines carry an empty Action.
$reStart    = "^Starting runbook '(?<name>.+)' \(ID: '(?<id>[^']+)'\)"
$reComplete = "^Runbook '(?<name>.+)' \(ID: '(?<id>[^']+)'\) completed"
$reBackup   = "^Backed up (?<count>\d+) AppX applications for user (?<sid>S-[0-9-]+)"
$reRestore  = "^(?<count>\d+) AppX applications restored"
$reSidWarn  = "^Unable to find SID translation for (?<sid>S-[0-9-]+)"

# --- Walk the log per machine --------------------------------------------------
$report = @()
$machines = $rows | Group-Object ComputerName

foreach ($machine in $machines) {
    # ComputerName looks like "domain\host.fqdn" while the device is domain
    # joined, or "tenantguid\HOST" once it is Entra joined. Keep both: the
    # short name for readability, the full name for traceability.
    $computerFull = $machine.Name
    $computerShort = $computerFull
    if ($computerFull -match '\\') {
        $computerShort = ($computerFull -split '\\')[-1]
    }

    $runbookName   = ''
    $startTime     = ''
    $completeTime  = ''
    $startCount    = 0
    $completeCount = 0
    $agentVersion  = ''

    # Keyed by source SID; each entry tracks the user name plus backup/restore
    # evidence. RestoreCount of -1 means "no restore seen yet".
    $users = @{}
    # Restore lines whose LogonName did not match any backed-up user (e.g. a
    # blank LogonName). Held aside for count-based matching later.
    $orphanRestores = @()
    # Failed SID translations, used to explain a "No users migrated" flag.
    # SIDs ending in -500 (built-in Administrator) are excluded because that
    # warning appears even on perfectly successful migrations.
    $sidWarnings = @()

    # Single pass over this machine's rows, oldest first.
    foreach ($row in $machine.Group) {
        $msg = $row.Message

        if ($msg -match $reStart) {
            # A new runbook run. If a machine ran more than once, the fields
            # end up reflecting the most recent run; users/evidence aggregate
            # across runs.
            $startCount++
            $runbookName = $Matches['name']
            $startTime = $row.MessageDate
            if ($msg -match 'Migration Agent Version (?<ver>[0-9.]+)') {
                $agentVersion = $Matches['ver']
            }
            continue
        }

        if ($msg -match $reComplete) {
            $completeCount++
            $completeTime = $row.MessageDate
            continue
        }

        if ($msg -match $reBackup) {
            # The telltale line: one per migrated user, in the Device State
            # phase. The row's LogonName column names the user; the SID in the
            # message is the user's SOURCE (pre-migration) SID.
            $sid = $Matches['sid']
            $count = [int]$Matches['count']
            if (-not $users.ContainsKey($sid)) {
                $users[$sid] = New-Object PSObject -Property @{
                    LogonName     = $row.LogonName
                    Sid           = $sid
                    BackupCount   = 0
                    RestoreCount  = -1
                }
            }
            $users[$sid].BackupCount = $count
            if ($row.LogonName) { $users[$sid].LogonName = $row.LogonName }
            continue
        }

        if ($msg -match $reRestore) {
            # Restore confirmation. The message itself does not name the user,
            # so match on the row's LogonName against the backed-up users.
            # This stays correct even when two users backed up identical app
            # counts (count is only a fallback, below).
            $count = [int]$Matches['count']
            $logon = $row.LogonName
            $matched = $false
            if ($logon) {
                foreach ($entry in $users.Values) {
                    if ($entry.LogonName -eq $logon) {
                        $entry.RestoreCount = $count
                        $matched = $true
                        break
                    }
                }
            }
            if (-not $matched) {
                $orphanRestores += $count
            }
            continue
        }

        if ($msg -match $reSidWarn) {
            $sid = $Matches['sid']
            if ($sid -notmatch '-500$') {
                if ($sidWarnings -notcontains $sid) { $sidWarnings += $sid }
            }
            continue
        }
    }

    # --- Decide status -----------------------------------------------------
    $userList = @($users.Values | Sort-Object LogonName)
    $problems = @()

    # Machines that never started a runbook were only polling for work;
    # they do not belong in a migration report.
    if ($startCount -eq 0) {
        continue
    }

    if ($userList.Count -eq 0) {
        # Runbook ran but nothing was backed up for any user - the primary
        # failure case this report exists to catch. Attach any failed SID
        # translations as the likely explanation.
        $status = 'FLAG: No users migrated'
        foreach ($sid in $sidWarnings) {
            $problems += ("No SID translation found for {0}" -f $sid)
        }
    }
    else {
        foreach ($u in $userList) {
            if ($u.RestoreCount -lt 0) {
                # No LogonName-matched restore for this user. Fall back to an
                # unclaimed orphan restore whose app count matches the backup
                # count; consume it so it cannot satisfy two users.
                $idx = -1
                for ($i = 0; $i -lt $orphanRestores.Count; $i++) {
                    if ($orphanRestores[$i] -eq $u.BackupCount) { $idx = $i; break }
                }
                if ($idx -ge 0) {
                    $u.RestoreCount = $orphanRestores[$idx]
                    $orphanRestores[$idx] = -1
                }
            }
            if ($u.RestoreCount -lt 0) {
                $problems += ("{0}: backed up, restore pending (user has not logged in yet)" -f $u.LogonName)
            }
        }

        # Precedence: an incomplete runbook outranks pending restores, which
        # outrank OK.
        if ($completeCount -eq 0) {
            $status = 'FLAG: Runbook not completed'
        }
        elseif ($problems.Count -gt 0) {
            $status = 'WARN: Restore pending'
        }
        else {
            $status = 'OK'
        }
    }

    # --- Format the per-user summary column ---------------------------------
    # One entry per user, e.g. "CONTOSO\jdoe [110 backed up / 110 restored]".
    $userSummaries = @()
    foreach ($u in $userList) {
        if ($u.RestoreCount -ge 0) {
            $userSummaries += ("{0} [{1} backed up / {2} restored]" -f $u.LogonName, $u.BackupCount, $u.RestoreCount)
        }
        else {
            $userSummaries += ("{0} [{1} backed up / restore pending]" -f $u.LogonName, $u.BackupCount)
        }
    }

    $report += New-Object PSObject -Property @{
        ComputerName     = $computerShort
        ComputerFullName = $computerFull
        Runbook          = $runbookName
        AgentVersion     = $agentVersion
        RunbookStarted   = $startTime
        RunbookCompleted = $completeTime
        UserCount        = $userList.Count
        UsersMigrated    = ($userSummaries -join '; ')
        Problems         = ($problems -join '; ')
        Status           = $status
    }
}

# --- Output --------------------------------------------------------------------
$columns = @('ComputerName','Status','UserCount','UsersMigrated','Runbook',
             'RunbookStarted','RunbookCompleted','AgentVersion','Problems','ComputerFullName')

# Sort the worst news to the top: flags first, then warnings, then OK.
$sorted = $report | Sort-Object @{Expression = {
        if ($_.Status -like 'FLAG*') { 0 }
        elseif ($_.Status -like 'WARN*') { 1 }
        else { 2 }
    }}, ComputerName

if ($FlaggedOnly) {
    $sorted = @($sorted | Where-Object { $_.Status -like 'FLAG*' })
}

if (-not $OutputCsv) {
    # Default: timestamped report alongside the first input file.
    $firstDir = Split-Path -Parent (Resolve-Path -LiteralPath $LogPath[0]).Path
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputCsv = Join-Path $firstDir ("MigrationReport_{0}.csv" -f $stamp)
}

$sorted | Select-Object $columns | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding ASCII

# Console summary for a quick eyeball; the CSV holds the full detail.
Write-Host ""
Write-Host ("Migration report: {0} machines ({1} flagged)" -f @($sorted).Count, @($sorted | Where-Object { $_.Status -like 'FLAG*' }).Count)
Write-Host ("Saved to: {0}" -f $OutputCsv)
Write-Host ""
$sorted | Select-Object ComputerName, Status, UserCount, UsersMigrated | Format-Table -AutoSize -Wrap

# Return the report objects for pipeline use.
$sorted | Select-Object $columns
