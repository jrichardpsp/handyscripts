# Edge Web Data Fix

Resets Microsoft Edge's search engine database for all user profiles on a machine.
After an identity migration (on-prem AD to Entra ID), Edge can lose its configured
search engines because the `keywords` table in its SQLite `Web Data` file is keyed
to the old identity. This script renames that file so Edge regenerates it cleanly on
next launch.

---

## What it does

For every eligible local user profile on the machine the script:

1. Locates `%LOCALAPPDATA%\Microsoft\Edge\User Data`
2. Enumerates every Edge profile folder (`Default`, `Profile 1`, `Profile 2`, ...)
3. Skips any profile whose Edge process is currently running (to avoid SQLite corruption)
4. Renames `Web Data`, `Web Data-journal`, `Web Data-wal`, and `Web Data-shm` to
   `<name>.bak-<timestamp>`

Edge regenerates the file on next launch with the new identity. Bookmarks, history,
passwords, cookies, extensions, and settings are not touched.

---

## Files

| File | Description |
|------|-------------|
| `edge-webdata-fix.ps1` | The PowerShell script |
| `cmdline.cmd` | Launcher used by PowerSyncPro post-migration scripting |
| `edge_search_fix.zip` | ZIP containing both files above, ready to attach to a PSP migration batch |

---

## Deploying via PowerSyncPro

The included `edge_search_fix.zip` can be attached directly as a **post-migration script**
to any PowerSyncPro migration batch:

1. In the PSP admin console, open the target migration batch.
2. Navigate to **Post-Migration Scripts** and attach `edge_search_fix.zip`.
3. PSP extracts the ZIP and invokes `cmdline.cmd`, which runs the PowerShell script
   as **NT AUTHORITY\SYSTEM**.

No additional configuration is required. The script auto-detects all user profiles
on the machine via the registry `ProfileList` key and handles both on-prem
(`S-1-5-21-*`) and Entra ID (`S-1-12-1-*`) SIDs.

---

## Running manually

```cmd
powershell.exe -ExecutionPolicy Bypass -File .\edge-webdata-fix.ps1
```

Dry run (shows what would be renamed without making changes):

```cmd
powershell.exe -ExecutionPolicy Bypass -File .\edge-webdata-fix.ps1 -WhatIf
```

Custom log path:

```cmd
powershell.exe -ExecutionPolicy Bypass -File .\edge-webdata-fix.ps1 -LogPath C:\Logs\edge-fix.log
```

Must be run as **SYSTEM or a local administrator**. Standard users cannot enumerate
other users' profile folders.

---

## Output

Console output is intentionally minimal for compatibility with RMM and migration tools
that ingest stdout into a database:

```
[2026-05-05 12:16:08] [INFO] Reset-EdgeWebData starting
[2026-05-05 12:16:09] [INFO] Found 2 eligible user profile(s) on this machine.
[2026-05-05 12:16:11] [INFO] Reset-EdgeWebData done -- profiles=2 files=4 skipped=0 users=miles.morales, Administrator
```

Full diagnostic detail (SID enumeration, path checks, per-file renames) is written
to the log file only. Default log path: `C:\Temp\Reset-EdgeWebData.log`.

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All profiles processed successfully |
| `1` | One or more profiles skipped because Edge was running -- retry after Edge closes |
| `2` | Hard failure (could not enumerate user profiles) |
