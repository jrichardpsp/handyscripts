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
| `-BadSid` | No* | The incorrect SID the profile was mistakenly translated to. If omitted, provide `-ProfilePath` and the script will look it up automatically. |
| `-ProfilePath` | No* | Path to the user's profile folder (e.g. `C:\Users\jsmith`). The script will find the Bad SID by searching the registry for a profile pointing to this path. |
| `-RunbookGuid` | No | The GUID of the Migration Agent runbook to recreate. The script will find this automatically from the existing install — only provide it manually if the script cannot determine it. |

*Either `-BadSid` or `-ProfilePath` must be supplied.

## Finding your SIDs

SIDs for all three values can be found in the PowerSyncPro translation table:

```
https://<PSP Server URL>/migrationAgent/CheckTranslationEntries
```

## Finding the Bad SID

In most cases you do not need to find the Bad SID yourself. Provide `-ProfilePath` (e.g. `C:\Users\jsmith`) and the script will search the registry for a `ProfileList` entry pointing to that folder and extract the Bad SID automatically.

If you do need to find it manually, it will appear as an unrecognized SID under:
```
HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
```
Look for a key whose `ProfileImagePath` value points to the affected user's profile folder.

## Finding the Runbook GUID

In most cases you do not need to provide this. The script will look for the runbook in the existing Migration Agent install at:
```
%ProgramData%\Declaration Software\Migration Agent\<runbook guid>\
```
It will match the correct runbook by checking the `TranslationTable.json` inside each folder for the expected Source → Bad SID mapping. If it finds exactly one match, it uses it automatically. You will only be prompted if it cannot determine the correct GUID on its own.

If you do need to look it up manually, use Developer Tools in a Chromium-based browser (Chrome, Edge, Brave, Opera, etc.):

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

### Minimal — all optional values auto-resolved

The Bad SID is looked up from the profile path and the Runbook GUID is discovered from the existing install.

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -ProfilePath "C:\Users\jsmith"
```

### Bad SID and Runbook GUID provided explicitly

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -BadSid      "S-1-12-1-856125190-1258027666-1451343766-332335133" `
    -RunbookGuid "df0a0278-9d4a-4c96-32dc-08de15914463"
```

### Bad SID looked up from profile path, Runbook GUID provided explicitly

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -ProfilePath "C:\Users\jsmith" `
    -RunbookGuid "df0a0278-9d4a-4c96-32dc-08de15914463"
```

### Bad SID provided explicitly, Runbook GUID auto-discovered

```powershell
.\PSP-FixBadTranslation.ps1 `
    -SourceSid   "S-1-5-21-3214081272-1437970042-2533267026-1111" `
    -TargetSid   "S-1-12-1-3174294469-1095778936-2869651892-298814751" `
    -BadSid      "S-1-12-1-856125190-1258027666-1451343766-332335133"
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
- The correct Source and Target SIDs must be confirmed in the PowerSyncPro translation table before running — incorrect SIDs will result in a broken profile mapping
