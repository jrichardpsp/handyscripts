# PSP-FixBadTranslation.ps1

Fixes a bad SID translation in a PowerSyncPro Migration Agent migration.

## When to use this script

This script is for situations where a user was incorrectly mapped to the wrong target SID during a PowerSyncPro migration. The symptoms look like this:

- The user logs into the machine with their correct target credentials and receives a **fresh or temporary profile** instead of their existing one.
- The user's real profile folder (e.g. `C:\Users\jsmith`) exists on disk, but is associated with a completely wrong SID in the registry — the **Bad SID**.
- The correct Source → Target SID mapping was never applied to the existing profile.

## WARNING — Do this before running the script

> **You MUST correct the translation table in the PowerSyncPro Web Admin Panel BEFORE running this script.**
>
> If the bad translation entry still exists in PowerSyncPro, the Migration Agent will re-apply the incorrect mapping and undo the fix.

You must also **run this script as a local administrator that is not one of the affected users** — for example, the PSP Fallback Account. Do not run it while logged in as the Source, Target, or Bad SID user.

## What the script does

1. Validates SID formats for all provided SIDs.
2. Resolves the Bad SID from the registry by `ProfileImagePath` lookup (if not provided directly).
3. Discovers the Runbook GUID from the Migration Agent data folder, or prompts if multiple are found.
4. Renames the Bad SID registry key under `ProfileList` to the Source SID and updates the binary SID value.
5. Renames the temporary profile folder and registry key created for the Target SID to `.bak`.
6. Stops the PowerSyncPro Migration Agent service.
7. Clears the Migration Agent working directory (`%ProgramData%\Declaration Software\Migration Agent`).
8. Creates a new Runbook folder with a corrected `TranslationTable.json`.
9. Restarts the PowerSyncPro Migration Agent service.
10. Writes a transcript log to `C:\Temp\PSP-FixBadTranslation-<timestamp>.log`.

After the script completes, re-run the PowerSyncPro migration. The agent will re-permission the profile from SourceSid to TargetSid and remove the Bad SID.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SourceSid` | Yes | The original (pre-migration) SID for the affected user. |
| `-TargetSid` | Yes | The correct target SID the user should be translated to. |
| `-BadSid` | No* | The incorrect SID the profile was mistakenly translated to. |
| `-ProfilePath` | No* | Path to the user's profile folder (e.g. `C:\Users\jsmith`). Used to look up the Bad SID if `-BadSid` is not provided. |
| `-RunbookGuid` | No | The GUID of the Migration Agent runbook to recreate. Auto-discovered if only one runbook exists. |

*Either `-BadSid` or `-ProfilePath` must be supplied.

## Finding your SIDs

SIDs for all three values can be found in the PowerSyncPro translation table:

```
https://<PSP Server URL>/migrationAgent/CheckTranslationEntries
```

## Finding the Runbook GUID

The Runbook GUID can be found via Developer Tools in a Chromium-based browser (Chrome, Edge, Brave, Opera, etc.):

1. Open the **Runbooks** page in the PowerSyncPro Web Admin Panel.
2. Press `F12` to open Developer Tools (or `Ctrl+Shift+I`).
3. Click the **Network** tab.
4. Click the **Edit** button on your selected runbook.
5. Find the `EditModal` request in the Network tab — the GUID is the `runbookId` query parameter.
   ```
   https://psp1.company.com/migrationAgent/Runbooks/EditModal?runbookId=df0a0278-9d4a-4c96-32dc-08de15914463
   ```
6. The Runbook GUID is everything after the `=` sign: `df0a0278-9d4a-4c96-32dc-08de15914463`

## Example commands

### All parameters provided explicitly

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -BadSid      "S-1-12-1-856125190-1258027666-1451343766-332335133" `
    -RunbookGuid "df0a0278-9d4a-4c96-32dc-08de15914463"
```

### Bad SID looked up from the user's profile path

Use this when you know the profile folder but not the Bad SID. The script will search the registry for a `ProfileList` key whose `ProfileImagePath` matches the provided path.

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -ProfilePath "C:\Users\jsmith" `
    -RunbookGuid "df0a0278-9d4a-4c96-32dc-08de15914463"
```

### Runbook GUID auto-discovered

If only one runbook folder exists in the Migration Agent data directory, the GUID will be detected automatically.

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -BadSid      "S-1-12-1-856125190-1258027666-1451343766-332335133"
```

### Minimal — all optional values auto-resolved

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -ProfilePath "C:\Users\jsmith"
```

## Output

The script writes a full transcript to:
```
C:\Temp\PSP-FixBadTranslation-<yyyyMMdd_HHmmss>.log
```

## Requirements

- PowerShell 5.1 or later
- Must be run as a local Administrator
- Must **not** be run as any of the affected user accounts (Source, Target, or Bad SID)
