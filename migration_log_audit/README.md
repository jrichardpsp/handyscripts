# Migration Log Audit

Scrapes a **PowerSyncPro Migration Agent log export** and produces a per-machine
spreadsheet of migration results, flagging machines where no user profile was
actually migrated.

## Why

A runbook can report "completed" while silently migrating zero user profiles
(for example, when a SID translation is missing for the user). The reliable
telltale is in the agent log itself:

| Evidence | Log line | Phase |
|---|---|---|
| Profile captured | `Backed up <N> AppX applications for user <SID>` | Device State |
| Profile restored | `<N> AppX applications restored` | AppX Migration |

One pair of lines appears **per migrated user** (the `LogonName` column on the
row identifies the user). A machine that ran a runbook but produced **no**
backup line did not migrate anyone - that is the failure this report catches.

The restore line fires via an Active Setup record at the user's **next logon**,
so a backup without a restore usually just means the user has not logged in
since the migration (reported as a warning, not a failure).

## Usage

```powershell
# Basic: report lands next to the input file as MigrationReport_<timestamp>.csv
.\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv"

# Explicit output path
.\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv" -OutputCsv "C:\Temp\Report.csv"

# Merge multiple exports (overlap is fine)
.\Get-MigrationReport.ps1 -LogPath "C:\Temp\Logs_week1.csv","C:\Temp\Logs_week2.csv"

# Failures only
.\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv" -FlaggedOnly
```

The report objects are also written to the pipeline, so you can filter further:

```powershell
.\Get-MigrationReport.ps1 -LogPath "C:\Temp\PSP Agent Logs.csv" |
    Where-Object { $_.Runbook -eq 'CONTOSO - Hybrid AD to Entra' }
```

### Input

The CSV export from the PSP portal's **Agent Logs** page, with columns:

```
ComputerName, LogonName, RunbookName, Action, Phase, Severity, Message, MessageDate
```

### Parameters

| Parameter | Description |
|---|---|
| `-LogPath` | One or more PSP Agent Logs CSV exports (merged before processing). |
| `-OutputCsv` | Report path. Default: `MigrationReport_<timestamp>.csv` next to the first input file. |
| `-FlaggedOnly` | Output only `FLAG:` rows (suppresses `WARN` and `OK`). |

## Statuses

Sorted worst-first in the output:

| Status | Meaning |
|---|---|
| `FLAG: No users migrated` | Runbook ran but no AppX backup line was found for any user. The Problems column lists any failed SID translations as the likely cause. |
| `FLAG: Runbook not completed` | Runbook started but never logged a completion line in the export window. |
| `WARN: Restore pending` | A user was backed up but no restore has been logged yet - usually the user simply has not logged in since the migration. Re-check with a later export. |
| `OK` | Runbook completed and every user was backed up and restored. |

Machines that appear in the log but never started a runbook (agents just
polling for work) are excluded from the report.

## Example output

```
ComputerName        Status                   UserCount UsersMigrated
------------        ------                   --------- -------------
PC-SALES07.corp.contoso.com FLAG: No users migrated    0
PC-HR12.corp.contoso.com    WARN: Restore pending      2 CONTOSO\asmith [105 backed up / restore pending]; CONTOSO\jdoe [105 backed up / 105 restored]
PC-ENG03.corp.contoso.com   OK                         1 CONTOSO\mjones [110 backed up / 110 restored]
```

Report columns: `ComputerName, Status, UserCount, UsersMigrated, Runbook,
RunbookStarted, RunbookCompleted, AgentVersion, Problems, ComputerFullName`.

## Notes

- PowerShell 5.1 compatible; ASCII only.
- Multiple users per machine are handled; restores are matched to users by
  `LogonName` (with app-count as a fallback for rows with a blank LogonName),
  so two users with identical app counts are attributed correctly.
- "Unable to find SID translation" warnings for SIDs ending in `-500`
  (built-in Administrator) are ignored - they appear even on successful
  migrations.
- If a machine ran the runbook more than once, the report reflects the most
  recent run's name/times while user evidence aggregates across runs.
