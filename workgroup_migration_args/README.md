# Workgroup Migration - Argument Driven

`WorkgroupMigrator_Args.ps1` kicks off a PowerSyncPro user migration on a single
workgroup endpoint. Every value it needs is passed as a parameter, so it suits RMM
platforms that template variables per device.

Two target types are supported, selected with `-TargetIdentityType`:

* **Entra** (default) - targets are Entra **ObjectId GUIDs**, converted by the
  script into the `S-1-12-1-*` SIDs Windows uses for cloud identities.
* **AD** - targets are **AD SIDs** (`S-1-5-21-*`), validated and used as-is.

The source side is always a local workgroup account, either way. See
[Target identity types](#target-identity-types) for the full comparison.

The script is self-contained: drop it on the endpoint, call it with the arguments
below, and it handles agent installation, the SID translation table, and the agent
restart in one pass.

For background on the overall migration process, see the KB article:
https://kb.powersyncpro.com/en_US/migration-agent/how-to-bulk-migrate-workgroup-joined-endpoints-to-entra-id

---

## Baseline arguments for a Workgroup migration

These are the minimum arguments required. Supply an identity mapping (pick one of
the three forms below) plus all four environment values. That is the complete set
for a **workgroup-to-Entra** migration; a **workgroup-to-AD** migration adds one
more argument, `-TargetIdentityType AD`.

### 1. The identity mapping - pick ONE form

| Form | Arguments | Use when |
|---|---|---|
| Single user by name | `-LocalUsername` + `-TargetIdentity` | The normal case: one local account on the device. |
| Single user by SID | `-LocalUserSid` + `-TargetIdentity` | The local account was renamed or deleted but the profile SID is known. |
| Many users | `-Mapping` | A shared device with several local profiles to migrate. |

PowerShell enforces that exactly one form is used - mixing them fails at parameter
binding before anything runs.

| Argument | Description |
|---|---|
| `-LocalUsername` | The local Windows account being migrated **from**, for example `Peter`. Resolved to its SID via `Win32_UserAccount`, filtered to `LocalAccount=True` so a domain account can never match. The script fails if the account does not exist. |
| `-LocalUserSid` | The source SID, supplied directly instead of a username, for example `S-1-5-21-1111111111-2222222222-3333333333-1001`. Use this when the account no longer exists but its profile does. See [Finding a source SID](#finding-a-source-sid). |
| `-TargetIdentity` | The user being migrated **to**. Under the default `-TargetIdentityType Entra` this is an Entra **ObjectId GUID**, for example `3f2504e0-4f89-11d3-9a0c-0305e82c3301` - the user's **Object ID** in the Entra admin centre, not their UPN. Under `-TargetIdentityType AD` it is an **AD SID** instead, for example `S-1-5-21-9999999999-8888888888-7777777777-1105`. See [Target identity types](#target-identity-types). |
| `-Mapping` | One or more `"<source>=<target>"` pairs for multi-user devices. See [Multiple users on one device](#multiple-users-on-one-device). |

### 2. Environment values - all four required

| Argument | Description |
|---|---|
| `-RunbookGuid` | The GUID of the PSP runbook driving this migration. The translation table is written into `C:\ProgramData\Declaration Software\Migration Agent\<GUID>\`, so this must match the runbook the agent is executing or the agent will never read the mapping. See [Finding the runbook GUID](#finding-the-runbook-guid). Validated as a real GUID - see [Input validation](#input-validation). |
| `-DomainName` | Written to the agent registry key as the device's domain context. For workgroup migrations this is normally the **dummy domain** holding the AD object for the workstation, for example `dummy.local`. It is not the Entra tenant domain. |
| `-PspServerUrl` | The PSP server agent endpoint, **including the `/Agent` suffix**, for example `https://psp.contoso.com/Agent`. Passed to the MSI as `URL=`. Only consulted when the agent has to be installed, but always required so a fresh device does not fail halfway through. |
| `-PspPsk` | The pre-shared key from the PSP server, passed to the MSI as `PSK=`. Treat it as a secret: the script never echoes it, including in whitespace warnings. |

### 3. Target type - only when migrating to AD

`-TargetIdentityType` defaults to `Entra`, so a workgroup-to-Entra migration does
not pass it at all. Add `-TargetIdentityType AD` when your targets are AD SIDs.

### Minimum viable command - Entra

```powershell
.\WorkgroupMigrator_Args.ps1 `
    -LocalUsername "Peter" `
    -TargetIdentity "3f2504e0-4f89-11d3-9a0c-0305e82c3301" `
    -RunbookGuid    "d73976d7-d004-425f-8163-08de576995ae" `
    -DomainName     "dummy.local" `
    -PspServerUrl   "https://psp.contoso.com/Agent" `
    -PspPsk         "<psk from PSP server>"
```

### Minimum viable command - AD

Identical apart from the target value and the added `-TargetIdentityType`:

```powershell
.\WorkgroupMigrator_Args.ps1 `
    -LocalUsername      "Peter" `
    -TargetIdentity     "S-1-5-21-9999999999-8888888888-7777777777-1105" `
    -TargetIdentityType AD `
    -RunbookGuid        "d73976d7-d004-425f-8163-08de576995ae" `
    -DomainName         "dummy.local" `
    -PspServerUrl       "https://psp.contoso.com/Agent" `
    -PspPsk             "<psk from PSP server>"
```

---

## Target identity types

`-TargetIdentityType` controls how **every** target value in the run is
interpreted. It is a per-run setting, not per-user - you cannot mix Entra GUIDs
and AD SIDs in a single `-Mapping` list.

| | `Entra` (default) | `AD` |
|---|---|---|
| Target format | ObjectId GUID | SID string |
| Example | `3f2504e0-4f89-11d3-9a0c-0305e82c3301` | `S-1-5-21-9999999999-8888888888-7777777777-1105` |
| Where to get it | **Object ID** on the user in the Entra admin centre (not the UPN) | The AD user's `objectSid` |
| Accepted variants | Dashed, `{braced}`, `(parens)`, or 32-char no-dash | Any valid SID string |
| What the script does | Converts the GUID to its `S-1-12-1-*` SID, the form Windows uses for cloud identities | Validates the SID and uses it unchanged |
| Written to the table | `S-1-12-1-a-b-c-d` | The SID exactly as supplied |

The two formats are mutually exclusive and the script rejects the wrong one
outright rather than producing a broken translation table:

* An AD SID passed under `Entra` fails with `Target identity ... is not a valid GUID`.
* An Entra GUID passed under `AD` fails with `Invalid SID format`.

Everything else - source resolution, the runbook folder, registry stamping, agent
install and restart - is identical between the two modes.

---

## Optional arguments

| Argument | Default | Description |
|---|---|---|
| `-TargetIdentityType` | `Entra` | `Entra` treats every target as an ObjectId GUID; `AD` treats every target as a SID string used as-is. |
| `-TargetUpn` | none | Traceability only - written to the log, never used to build the mapping. Single-user modes only. |
| `-MsiUrl` | PSP CDN current build | Where to download the Migration Agent MSI from. |
| `-UseLocalMsi` | off | Use a staged MSI instead of downloading. |
| `-LocalMsiPath` | `<BasePath>\PSPMigrationAgentInstallerSelfContained.msi` | Path to the staged MSI when `-UseLocalMsi` is set. |
| `-BasePath` | `C:\Temp` | Working directory for the transcript, translation table and downloaded MSI. |
| `-ComputerName` | this machine's hostname | Value stamped into the agent registry key. Override only if you need to stamp something other than the real hostname. |
| `-ServiceName` | `PowerSyncPro Migration Agent` | Windows service name (not display name) of the agent. |

---

## Multiple users on one device

`-Mapping` takes one or more `"<source>=<target>"` strings:

```powershell
.\WorkgroupMigrator_Args.ps1 `
    -Mapping "Peter=3f2504e0-4f89-11d3-9a0c-0305e82c3301",
             "Miles=7c9e6679-7425-40de-944b-e07fc1f90ae7",
             "S-1-5-21-1111111111-2222222222-3333333333-1005=9b2a1f3c-1111-2222-3333-444455556666" `
    -RunbookGuid  "d73976d7-d004-425f-8163-08de576995ae" `
    -DomainName   "dummy.local" `
    -PspServerUrl "https://psp.contoso.com/Agent" `
    -PspPsk       "<psk>"
```

* **Source side** may be a local username *or* a source SID. Anything starting with
  `S-1-` is treated as a SID and used as-is; anything else is looked up as a local
  account. A Windows account name cannot start with `S-1-`, so this is unambiguous.
* **Target side** is an Entra ObjectId GUID by default, or an AD SID under
  `-TargetIdentityType AD`. All entries in one run must use the same target type.
* Whitespace around the `=` is trimmed, and blank entries are skipped - RMM variable
  templating often produces them.
* Only the **first** `=` is treated as the delimiter.
* **Duplicate sources are a hard error.** They would collide as duplicate keys in
  the translation table. The check runs on *resolved SIDs*, so passing both `Peter`
  and Peter's SID is caught.
* **Duplicate targets warn but proceed**, since mapping two local profiles to one
  target user is occasionally deliberate.

The same list works for AD targets - swap the GUIDs for SIDs and add
`-TargetIdentityType AD`:

```powershell
    -Mapping "Peter=S-1-5-21-9999999999-8888888888-7777777777-1105",
             "Miles=S-1-5-21-9999999999-8888888888-7777777777-1106" `
    -TargetIdentityType AD `
```

All pairs land in a single translation table, source SID on the left and target
SID on the right. Entra targets appear as `S-1-12-1-*`:

```json
{"S-1-5-21-...-1001":"S-1-12-1-a-b-c-d","S-1-5-21-...-1002":"S-1-12-1-e-f-g-h"}
```

Under `-TargetIdentityType AD` the right-hand values are the AD SIDs as supplied:

```json
{"S-1-5-21-...-1001":"S-1-5-21-999-888-777-1105","S-1-5-21-...-1002":"S-1-5-21-999-888-777-1106"}
```

---

## Finding the runbook GUID

`-RunbookGuid` must match the runbook the Migration Agent is executing. The GUID is
not shown directly on the Runbooks page, so use one of the following.

### Method 1 - browser developer tools

1. Open the **Runbooks** page in the PSP web interface.
2. Press **F12** to open developer tools and select the **Network** tab.
3. Click **Edit** on the runbook you are targeting.
4. Look for the `EditModal` request. Its URL carries the runbook ID as a query
   parameter:

   ```
   https://psp1.company.com/migrationAgent/Runbooks/EditModal?runbookId=df0a0278-9d4a-4c96-32dc-08de15914463
   ```

5. The GUID is everything after `runbookId=`. In this example:
   `df0a0278-9d4a-4c96-32dc-08de15914463`.

### Method 2 - query the PSP database

Connect to the PowerSyncPro database in SQL Server Management Studio and run:

```sql
USE PowerSyncProDb;
SELECT Id, Name FROM dbo.Runbooks;
```

`Id` is the GUID to pass; `Name` lets you confirm you picked the right runbook.
Equivalently, browse **Databases -> PowerSyncProDb -> Tables -> dbo.Runbooks** and
right-click to select the top 1000 rows.

### Method 3 - read it off an already-migrated endpoint

Only works where the agent is installed and has already pulled runbook data, but it
is useful for confirming a GUID before a wider rollout. The agent creates one
folder per runbook:

```powershell
Get-ChildItem 'C:\ProgramData\Declaration Software\Migration Agent' -Directory |
    Select-Object Name
```

Each GUID-named folder is a runbook ID, and it is exactly where this script places
`TranslationTable.json`.

Whichever method you use, the value is validated before anything is written - a
typo or a stray space fails the run rather than silently writing the translation
table where the agent will not look. See [Input validation](#input-validation).

---

## Finding a source SID

`-LocalUsername` is the usual way to identify the source account - the script
resolves the SID itself. You only need a raw SID when the local account has been
renamed or deleted and just the profile remains.

For an account that still exists:

```powershell
Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
    Select-Object Name, SID
```

For a profile whose account is gone, read the profile list directly - local
accounts are the `S-1-5-21-*` entries:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' |
    Select-Object @{n='SID';e={$_.PSChildName}}, ProfileImagePath
```

Match the `ProfileImagePath` (for example `C:\Users\Peter`) to the user you are
migrating, and pass the corresponding SID as `-LocalUserSid`.

---

## Migration Agent MSI

The MSI is acquired **only if the agent service is missing**, so devices that
already have the agent never download anything.

* **Default:** downloads the self-contained MSI (~120 MB) from
  `https://downloads.powersyncpro.com/current/PSPMigrationAgentInstallerSelfContained.msi`
  into `-BasePath`. TLS 1.2 is forced, since PowerShell 5.1 can still default to
  TLS 1.0 and the CDN rejects it. The download writes to a `.partial` file and is
  only renamed on success, so an interrupted transfer cannot leave a truncated MSI
  for a later run to install.
* **Staged:** pass `-UseLocalMsi` (optionally with `-LocalMsiPath`) to install from
  a copy your RMM already pushed. Nothing is downloaded.

Installation treats msiexec exit code `0` as success and `3010` as success-with-
reboot-required, then polls up to 60 seconds for the service to register.

---

## Input validation

Values are validated and normalized before anything is written:

* **`-RunbookGuid` is validated as a real GUID** and normalized to canonical dashed
  form. This matters because the value becomes a directory name: a stray leading
  space would create ` <guid>` while the agent reads `<guid>`, and the migration
  would silently do nothing while the script still reported success. Braces,
  parentheses and the 32-character no-dash form are all accepted and normalized.
* **Entra targets (GUIDs)** go through the same GUID validation. In `-Mapping` mode
  the error names the offending entry, for example
  `Target identity for source 'Peter' is not a valid GUID: 'oops'`.
* **AD targets (SIDs)** and every source SID are validated by constructing a
  `SecurityIdentifier`, so a malformed SID fails immediately rather than producing
  a broken translation table.
* **Target type mismatches are caught**, not silently accepted: an AD SID supplied
  under `Entra`, or an Entra GUID supplied under `AD`, aborts the run.
* **Surrounding whitespace** is stripped from the remaining free-form values and a
  warning is logged so the correction is visible. The `-PspPsk` warning never
  echoes the key.
* **A source that maps to itself** is rejected as a no-op.

---

## What the script does

1. Verifies the machine is **not domain-joined** - this is workgroup-only and aborts otherwise.
2. Resolves every source identity to a local SID and every target to its SID.
3. Writes `TranslationTable.json` into `-BasePath`.
4. Installs the Migration Agent if the service is absent.
5. Stops the agent service, stamps `DomainName` and `ComputerName` into
   `HKLM:\SOFTWARE\Declaration Software\Migration Agent`, copies the translation
   table into the runbook folder, and deletes `Runbooks.json` to force a refresh.
6. Restarts the service and confirms it reaches Running.

---

## Requirements and output

* **Elevated** - the script declares `#Requires -RunAsAdministrator`. Run as SYSTEM or an elevated admin.
* **Workgroup machines only** - aborts on domain-joined devices.
* Windows PowerShell 5.1 compatible.

| Output | Location |
|---|---|
| Transcript | `<BasePath>\Migration_Kickoff_Log.log` |
| Translation table | `<BasePath>\TranslationTable.json`, copied to the runbook folder |
| MSI install log | `<BasePath>\PSPAgent_Install.log` (only if an install occurred) |

Exit code `0` on success, `1` on any error, with the message written to stderr for
the RMM to surface.

Run `Get-Help .\WorkgroupMigrator_Args.ps1 -Full` for complete parameter help.
