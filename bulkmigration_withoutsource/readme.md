# Bulk Migrate Workgroup, AD, or Entra Joined Endpoints Without Source Directory Access

## Maintained By
Jamie Richard - jamie.richard@powersyncpro.com

## Description

This guide walks you through bulk migrating endpoints to AD or Entra when the source directory is unavailable, compromised, or withheld — by building the user translation table manually via RMM or other remote management tooling. This includes Workgroup joined machines where a source directory does not exist.

> **Full documentation:** See `PSP_-_Bulk_Migration_without_Source_Directory_Access.docx` in this repository.

---

## Repository Contents

| File | Description |
|------|-------------|
| `PSP_MigrationKickoff.ps1` | Main deployment script — push to endpoints via RMM |
| `1-Lookup_User_GUID_or_SID.ps1` | Resolves target user identities (Entra GUIDs or AD SIDs) into the CSV |
| `2-Create_Dummy_AD_Objects.ps1` | Creates dummy computer objects in AD for PSP to use as a source directory |
| `mig_db.csv` | Blank migration CSV template |
| `PSPMigrationAgentInstaller.msi` | PSP Migration Agent installer (with .NET) |

---

## Use Case

PowerSyncPro can natively migrate endpoints from an existing AD domain or Entra tenant, but doing so requires access to the source — either a service account with read permissions (AD) or an application registration (Entra). In some situations, that access simply isn't available.

This process covers scenarios where the source directory is inaccessible or cannot be trusted, including:

- **Hostile divestitures** — where the parent organization withholds or revokes access to the source directory as part of a separation.
- **Crypto malware or ransomware attacks** — where the source directory is compromised, partially destroyed, or taken offline.
- **Workgroup-only environments** — where machines were never joined to any directory and no source exists.
- **Mergers and acquisitions** — where access to the source tenant was never established or has lapsed before migration begins.

In these cases, the user translation table that PowerSyncPro would normally build automatically must be constructed manually. These scripts support all three endpoint join states: Workgroup, AD-joined, and Entra-joined.

---

## High-Level Process

### For an Entra Target

1. **Prepare the migration CSV** — compile a list of endpoints, their local usernames, and the target Entra UPN for each user.
2. **Resolve Entra Object IDs** — run `1-Lookup_User_GUID_or_SID.ps1` to populate each user's Entra GUID into the CSV, or populate manually from the Entra portal.
3. **Create dummy AD computer objects** — run `2-Create_Dummy_AD_Objects.ps1` to create matching computer objects in a dummy (or existing) AD domain.
4. **Configure PowerSyncPro** — add the dummy domain as a source and Entra as the target, set up a bulk enrollment token, create a Match Only sync profile, and run a sync to import the computer objects.
5. **Build a Runbook and Batch** — create a runbook targeting Entra, configure the Device State tab for Entra Join, and assign it to a batch covering your endpoints.
6. **Customise and deploy** — update `PSP_MigrationKickoff.ps1` with your PSP server details, runbook GUID, and CSV path, then push to endpoints via RMM.

### For an Active Directory Target

1. **Prepare the migration CSV** — compile a list of endpoints, their local usernames, and the target AD UPN for each user.
2. **Resolve AD SIDs** — run `1-Lookup_User_GUID_or_SID.ps1` against the target AD to populate each user's SID into the CSV, or populate manually from ADUC.
3. **Create dummy AD computer objects** — create matching computer objects in an AD domain to act as the PSP source. This can be the target domain itself, a dedicated dummy domain, or the PSP server promoted to a domain controller — see the full documentation for requirements for each approach.
4. **Configure PowerSyncPro** — add the source domain, create a Match Only sync profile, and run a sync to import the computer objects.
5. **Build a Runbook and Batch** — create a runbook targeting the AD domain, configure the Device State tab for AD Domain Join (including OU and join credentials), and assign it to a batch.
6. **Customise and deploy** — update `PSP_MigrationKickoff.ps1` with your PSP server details, runbook GUID, and CSV path, then push to endpoints via RMM. Endpoints must have line-of-sight to target domain controllers at migration time.

---

## Quick Start

### 1. Populate the CSV

Create `mig_db.csv` with the following headers (a blank template is included):

```
computer_name,username,source_account_type,target_upn,target_identity
```

| Field | Description |
|-------|-------------|
| `computer_name` | Workstation hostname (e.g. `CLIENT-WRK001`) |
| `username` | Current account name on the endpoint (e.g. `JohnSmith`, `DOMAIN\user.name`, `user@domain.com`) |
| `source_account_type` | Join state of the account: `Local`, `AD`, or `Entra` |
| `target_upn` | Target UPN/email (e.g. `john.smith@company.com`) |
| `target_identity` | Leave blank — auto-populated by the lookup script |

### 2. Resolve Target Identities

**For an Entra target** (requires Microsoft Graph PowerShell):
```powershell
.\1-Lookup_User_GUID_or_SID.ps1 -CsvPath .\mig_db.csv -TargetType Entra
```

**For an AD target** (requires connectivity to target DC):
```powershell
.\1-Lookup_User_GUID_or_SID.ps1 -CsvPath .\mig_db.csv -TargetType AD
```

### 3. Create Dummy AD Computer Objects

```powershell
.\2-Create_Dummy_AD_Objects.ps1 -CsvPath .\mig_db.csv

# Optional: specify a target OU
.\2-Create_Dummy_AD_Objects.ps1 -CsvPath .\mig_db.csv -TargetOU "OU=PSP Computers,DC=pspdummy,DC=local"
```

### 4. Configure the Deployment Script

Edit the following variables in `PSP_MigrationKickoff.ps1` before deploying:

| Variable | Description |
|----------|-------------|
| `$basePath` | Directory where RMM will place the CSV and MSI (e.g. `C:\Temp`) |
| `$csvName` | Name of the CSV file (e.g. `mig_db.csv`) |
| `$domainName` | Dummy domain FQDN (e.g. `dummy.local`) or target domain FQDN if using target as source |
| `$RunbookGUIDs` | GUID(s) of the PSP runbook to execute |
| `$PspMsiName` | Filename of the PSP Migration Agent MSI |
| `$PSPServerUrl` | PSP server Agent endpoint URL (e.g. `https://psp1.company.com/Agent`) |
| `$PspPsk` | Migration Agent PSK for your server |
| `$TargetIdentityType` | `Entra` or `AD` depending on target directory |

### 5. Deploy via RMM

Your RMM should copy the CSV, MSI, and PowerShell script to `$basePath`, then execute `PSP_MigrationKickoff.ps1` as **Administrator** or **SYSTEM**.

The script will load the CSV, verify the hostname, install and register the PSP Migration Agent, and build the translation table. If the device is already part of an active batch it will prompt for migration immediately; otherwise it will wait for standard PSP batch scheduling.

Logs are written to `C:\Temp\Migration_Kickoff_Log.log`.

---

## Limitations

- **Only one local profile per device can be migrated.** If multiple local profiles exist, designate which one to migrate in the CSV. Additional users may sign in post-migration but their prior profiles will not be automatically migrated.
- **Windows 10/11 Professional or higher is required.** Home versions do not support AD or Entra join. Verify using your RMM before deploying.
- **AD target migrations require line-of-sight to domain controllers.** Offline Domain Join is not supported. Endpoints must be on the corporate network (or have VPN connectivity) to target DCs for the duration of the migration.

---

## Appendix: Using the Target AD Domain as the PSP Source

If you do not want to stand up a separate dummy domain, the target AD domain can serve as both the PSP source and target. This requires the following specific changes:

**Licensing:** Your PSP licence must have the target domain listed as both source and target (e.g. `domain.company.com` → `domain.company.com`).

**Computer Objects:** Create objects in a dedicated OU within the target domain, then import manually via **Sync Service → Jobs → Import Containers / Import Objects**. There is no automatic sync without a sync profile, so this must be repeated whenever the computer object list changes.

**Runbook:** Set both Source Directory and Target Directory to the target AD domain.

**Batch:** Set both source and target to the target domain — this is expected and correct.

**Deployment Script:** Set `$domainName` to the target domain FQDN rather than a dummy domain.