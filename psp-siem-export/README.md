# PSP SIEM Log Exporter

Incrementally exports PowerSyncPro `RunbookLogEntries` to formatted log files on disk. A SIEM collector (Filebeat, Splunk UF, etc.) tails the output folder and ingests the files. Deliberately decoupled from any specific SIEM product.

## Files

| File | Purpose |
|---|---|
| `psp-agentlogs-to-siem.ps1` | Main exporter script |
| `psp-siem-export.example.json` | Config template — copy to `psp-siem-export.json` and fill in |
| `psp-siem-export-permissions.sql` | Least-privilege SQL login setup |
| `Register-PSPLogExportTask.ps1` | Windows Task Scheduler registration |

## Prerequisites

- Windows PowerShell 5.1 (no additional modules required)
- A service account or gMSA with SELECT on three tables (see [SQL setup](#sql-setup))
- Windows Task Scheduler (on SQL Express) or SQL Agent (full SQL Server only)

## Quick start

**1. Create the config file**

```powershell
Copy-Item psp-siem-export.example.json psp-siem-export.json
notepad psp-siem-export.json
```

At minimum set `SqlInstance`, `Database`, `TenantId`, `OutputDir`, and `StateDir`.

**SQL Express / named instance notes:**
- Instance string format: `HOSTNAME\SQLEXPRESS` (SQL Browser must be running) or `HOSTNAME\SQLEXPRESS,<port>` to bypass Browser
- To find the dynamic port: SQL Server Configuration Manager → TCP/IP → IP Addresses → IPAll → TCP Dynamic Ports
- Default SQL Express instance name is `SQLEXPRESS`; verify yours with `SELECT @@SERVERNAME`

**2. Set up the SQL login**

Open `psp-siem-export-permissions.sql` and make the following edits before running it:

- **STEP 1 — choose your login type.** Uncomment exactly one `CREATE LOGIN` line and substitute your actual domain and account name:
  - gMSA: `CREATE LOGIN [DOMAIN\svc_psp_export$] FROM WINDOWS;` *(trailing `$` required)*
  - Domain service account: `CREATE LOGIN [DOMAIN\svc_psp_export] FROM WINDOWS;`
  - SQL auth (only if Windows auth unavailable): `CREATE LOGIN [svc_psp_export] WITH PASSWORD = N'...'`

- **STEP 2 — match the database name.** If your database is not named `PowerSyncProDB`, update the `USE [PowerSyncProDB];` line.

- **STEP 2 — match the user name.** The `CREATE USER [svc_psp_export]` line and all three `GRANT`/`DENY` lines must use the same short username. If your account is `DOMAIN\svc_psp_export$`, the user name is typically just `svc_psp_export` (without domain or `$`), but you can name it anything as long as it's consistent across all five lines.

Once edited, run the script as a sysadmin against the target SQL instance:

```powershell
# From SSMS, sqlcmd, or the SQL Express command-line tools
sqlcmd -S YOURHOST\SQLEXPRESS -E -i psp-siem-export-permissions.sql
```

Verify access using the `EXECUTE AS USER` block at the bottom of the file before moving on.

**3. Test with -DryRun**

```powershell
.\psp-agentlogs-to-siem.ps1 -DryRun
```

This runs the query and formats every row but writes nothing to disk and does not advance the watermark. Use this to verify connectivity and check estimated row counts before the first live run.

**4. Register the scheduled task**

```powershell
# Run as local administrator
.\Register-PSPLogExportTask.ps1 `
    -ScriptPath       'C:\PSPLogExport\psp-agentlogs-to-siem.ps1' `
    -ConfigFile       'C:\PSPLogExport\psp-siem-export.json' `
    -RunAsAccount     'DOMAIN\psp_siem_export$' `
    -LogonType        ServiceAccount `
    -IntervalMinutes  5
```

`-IntervalMinutes` defaults to 5 and accepts any value from 1 to 1440. The task uses `MultipleInstances = IgnoreNew`, so a slow export run is never interrupted by the next trigger. To change the interval later, re-run the registration script with the new value — it will replace the existing task.

## Scheduling: Task Scheduler vs SQL Agent

| | Task Scheduler | SQL Agent |
|---|---|---|
| **SQL Express** | Yes | No — not available on Express |
| **Full SQL Server** | Yes | Yes |
| **Job history / alerting** | Windows Event Log | Built into SSMS — history, alerts, email on failure |
| **Manage alongside other DB jobs** | No | Yes |
| **PS session behaviour** | Predictable | Slightly different — verify execution policy and working directory on first run |
| **Host-level monitoring integration** | Natural fit | Separate from host monitoring |

**Use Task Scheduler** (the default) when:
- You are on SQL Express, or
- You prefer to keep scheduling separate from the database, or
- Your existing monitoring already watches Task Scheduler / host-level exit codes

**Use SQL Agent** when:
- You are on full SQL Server and the DBA team wants everything in one place, or
- You want job failure alerting and history inside SSMS without setting up separate monitoring

A ready-to-use SQL Agent job script is included at the bottom of `psp-siem-export-permissions.sql` (commented out). To use it, uncomment the block, update the script path, and run it as a sysadmin. One thing to verify on first run: SQL Agent executes PowerShell jobs via its own subsystem, which may apply a different execution policy or working directory than a normal session — confirm the script path is absolute and that the Agent service account has the same DB permissions as your Task Scheduler service account.

## Service account types

The exporter runs as a dedicated account with read-only DB access. Three options, in order of preference:

**gMSA (recommended)**

A Group Managed Service Account is the cleanest option — the domain manages the password automatically, it never expires, and you never touch it again after setup.

```powershell
.\Register-PSPLogExportTask.ps1 `
    -RunAsAccount 'DOMAIN\psp_siem_export$' `   # note the trailing $
    -LogonType    ServiceAccount
```

Requirements: Windows Server 2012+ domain functional level; the machine running the task must be in the gMSA's `PrincipalsAllowedToRetrieveManagedPassword` list.

**Domain service account**

A regular AD user account dedicated to this task. The password must be provided at registration time and updated again whenever it rotates.

```powershell
.\Register-PSPLogExportTask.ps1 `
    -RunAsAccount 'DOMAIN\psp_siem_export' `
    -LogonType    Password
# Script will prompt securely for the password
```

If the account's password rotates, re-run the registration script to update the stored credential in Task Scheduler.

**Local account (lab / standalone only)**

For a machine that is not domain-joined or for quick testing only. Use a local account with a strong password and no interactive logon rights. Not recommended for production — local accounts have no centralised management or auditing.

```powershell
.\Register-PSPLogExportTask.ps1 `
    -RunAsAccount "$env:COMPUTERNAME\psp_siem_export" `
    -LogonType    Password
```

For all account types, run `psp-siem-export-permissions.sql` using the matching login name to grant the account SELECT on the three required tables.

## SIEM collector and file cleanup

The exporter writes batch files to `OutputDir` and never deletes them — that is intentionally the SIEM collector's job.

The expected flow is:
1. Exporter writes `psp_runbooklog_1_20260101T000000000Z_427.ndjson` to `OutputDir`
2. SIEM collector (Filebeat, Splunk UF, NXLog, etc.) detects the new file, ships the lines to the SIEM backend, then deletes or archives the file
3. Disk usage in `OutputDir` stays flat under normal operation

**Collector cleanup configuration** varies by agent:

- **Filebeat** — does not delete files by default. Set `close_inactive`, `clean_inactive`, and `clean_removed: true` in the input configuration, or use a harvester close timeout. Without this, Filebeat tracks its read position but leaves files on disk indefinitely.
- **Splunk Universal Forwarder** — by default moves consumed files to a `done` subfolder. Configure `_BlacklistUsage` or monitor stanza options to delete instead.
- **NXLog** — configure the `im_file` module's `SavePos` and `Recursive` options; pair with a post-processing command or separate cleanup step.

If the collector stops working or falls behind, files will accumulate in `OutputDir`. Monitor the folder size as part of your standard host monitoring. A future version of the exporter may add an optional disk-cap safety net for this scenario.

## How it works

Each run the script:

1. Acquires a named mutex (single-instance guarantee)
2. Reads the watermark (`StateDir\tenant_<N>.json`) to find the last exported row ID
3. Queries `dbo.RunbookLogEntries WHERE TenantId = @TenantId AND Id > @LastId ORDER BY Id` in batches
4. JOINs `dbo.Agents` and `dbo.Runbooks` for enrichment
5. Formats each row, writes a `.tmp` file, then atomically renames it into `OutputDir`
6. Advances the watermark **only after** the file is safely in place
7. Appends a run summary to `StateDir\psp_siem_runlog.ndjson`

The watermark is a `uniqueidentifier`. SQL Server's sort order for this type does not match .NET or string ordering, so the `Id > @LastId` comparison is always done server-side in T-SQL — never in PowerShell.

**First run** backfills the entire table in batches. If interrupted, the next run resumes exactly where it stopped.

## Output format

Output is Elastic Common Schema (ECS) NDJSON — one JSON object per line, UTF-8 without BOM, LF line endings. Files are written to `OutputDir` with a `.ndjson` extension.

Example line (pretty-printed here for readability — actual output is a single line):

```json
{
  "@timestamp": "2026-06-17T14:32:07.1234567Z",
  "message": "User account synchronised successfully.",
  "log": { "level": "Information" },
  "event": {
    "id": "a3f1c2d4-5e6b-7890-abcd-ef1234567890",
    "dataset": "powersyncpro.runbooklog",
    "severity": 0,
    "kind": "event",
    "module": "powersyncpro",
    "action": "AD to Entra"
  },
  "organization": { "id": "1" },
  "user": { "name": "jsmith", "domain": "CONTOSO" },
  "agent": {
    "id": "b1e2d3c4-0000-1111-2222-333344445555",
    "name": "DC01.contoso.com",
    "version": "3.2.1"
  },
  "host": { "name": "DC01.contoso.com", "hostname": "DC01.contoso.com", "domain": "contoso.com" },
  "psp": {
    "tenant_id": 1,
    "agent_id": "b1e2d3c4-0000-1111-2222-333344445555",
    "agent_name": "DC01.contoso.com",
    "runbook_id": "c9d8e7f6-aaaa-bbbb-cccc-ddddeeee0000",
    "runbook_name": "AD to Entra",
    "phase": 2,
    "action": "SyncUser"
  }
}
```

ECS fields of note:

| ECS field | Source |
|---|---|
| `@timestamp` | `MessageDate` normalised to UTC |
| `log.level` | `Severity` mapped (0=Information, 1=Warning, 2=Error) |
| `event.id` | `Id` (row GUID) |
| `agent.name` / `host.name` | `dbo.Agents.MachineName` |
| `agent.version` | `dbo.Agents.Version` |
| `host.domain` | `dbo.Agents.Domain` |
| `user.name` / `user.domain` | `LogonName` split on `\` |
| `psp.runbook_name` | `dbo.Runbooks.Name` |
| `organization.id` | `TenantId` |

## SQL setup

Run `psp-siem-export-permissions.sql` on the target SQL instance. It grants SELECT on exactly three tables and explicitly denies write operations:

```
dbo.RunbookLogEntries  (SELECT only)
dbo.Agents             (SELECT only)
dbo.Runbooks           (SELECT only)
```

The script supports Windows domain accounts, gMSAs, and SQL authentication (see the commented options at the top of the file).

## Self-observability

After each run the script appends one JSON line to `StateDir\psp_siem_runlog.ndjson`:

```json
{"timestamp":"2026-01-01T00:00:00.000Z","tenant_id":1,"rows_exported":427,"batches":1,"last_watermark":"xxxxxxxx-...","duration_ms":312,"output_format":"ECS","dry_run":false,"error":null}
```

If the database is unreachable the script logs the error, prints a warning, and exits with **code 2** (transient / retryable). Code 0 = success. Any other non-zero code = script error. Task Scheduler can be configured to alert on non-zero exit codes if desired.

## Dedupe-over-window mode

Disabled by default. Enable only if PSP is configured with multiple concurrent writer processes that could commit rows out of sequential-GUID order.

```json
"EnableDedupeWindow": true,
"DedupeWindowMinutes": 10
```

When enabled, each run runs a second query to re-fetch rows whose `MessageDate` falls within the lookback window but whose `Id` is behind the current watermark (late-arriving concurrent writes). A persisted seen-ID set (stored in the state file, capped at `DedupeMaxSeenIds`) prevents re-emitting rows already exported in a prior run.

This mode does not change the default watermark logic; it is purely additive.

## Parameters / config keys

All parameters can be set in `psp-siem-export.json`. CLI parameters always override the config file.

| Parameter | Default | Description |
|---|---|---|
| `SqlInstance` | `YOURHOST\SQLEXPRESS` | SQL Server or Express instance |
| `Database` | `PowerSyncProDB` | Target database name |
| `TenantId` | `1` | **Mandatory security scope** — never omit |
| `OutputDir` | `C:\PSPLogExport\out` | Folder tailed by the SIEM collector |
| `StateDir` | `C:\PSPLogExport\state` | Watermark and run log storage |
| `BatchSize` | `5000` | Rows per output file |
| `EventDataset` | `powersyncpro.runbooklog` | ECS `event.dataset` value |
| `OutputFormat` | `ECS` | Output format (`ECS`) |
| `EnableDedupeWindow` | `false` | Enable dedupe lookback |
| `DedupeWindowMinutes` | `10` | Lookback window in minutes |
| `DedupeMaxSeenIds` | `50000` | Max seen-ID entries persisted in state |
| `-DryRun` (CLI only) | — | Query and format without writing |
