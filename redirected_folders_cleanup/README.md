# PSP Folder Redirection Cleanup

Reverses Active Directory Folder Redirection for AD-to-Entra (Azure AD Join) migration. Copies the user's redirected folders (Desktop, Documents, Pictures, Music, Videos, Downloads) from their UNC server paths back to the local profile, rewrites the shell folder registry values to local paths, and clears the Group Policy Folder Redirection CSE state.

Designed to run as SYSTEM via RMM (Atera, NinjaOne, etc.) or as a PowerSyncPro startup script, with no manual steps required on the endpoint. Includes a full user-facing GUI that explains the migration, prompts for VPN if needed, closes applications safely, shows copy progress, and logs the user off when complete.

---

## Before You Run This Script

> **This step is mandatory. If skipped, Group Policy will re-redirect the user's folders on the next logon, undoing the migration.**

**Remove the user (or computer) from the Folder Redirection GPO scope before deploying this script.**

How you remove them depends on how your GPO is targeted:

- **Security group filtering** — Remove the user or computer account from the group that has Apply permission on the GPO.
- **OU-based** — Move the computer object to an OU that is out of scope (blocked inheritance or no link).
- **WMI filter** — Adjust the filter so the target machine no longer matches.

After removing them from scope, allow time for AD replication to complete before deploying the script. The script runs `gpupdate /force` automatically once VPN/file server connectivity is confirmed, which is what picks up the GPO change on the endpoint. No manual `gpupdate` is required.

---

## Requirements

- **PowerShell 5.1** (Windows 10 / 11 inbox version — no upgrade required)
- **Windows 10 or Windows 11**
- No external modules or dependencies
- The endpoint must be able to reach the file server (SMB, TCP 445) — either on the internal network, via VPN, or via the local Offline Files (CSC) cache (see [Offline Files Support](#offline-files-support) below). The script will prompt the user to connect to VPN if the file server is unreachable and no local cache is available.
- Run as **SYSTEM** (RMM deployment) or as the **logged-in user** (direct execution)

---

## Deployment

Deploy `cleanup_redirection.ps1` via your RMM as a script task running as SYSTEM. No other files are required — the script is entirely self-contained.

If no user is currently logged in when the script runs, it will wait silently in the background (polling every 60 seconds) for up to 100 hours by default. This means you can push the script on a Friday and it will be ready to run when the user logs in on Monday.

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `VpnClientName` | string | `your VPN` | Name of the VPN client shown in user-facing dialogs |
| `VpnTimeoutMinutes` | int | `30` | Minutes to wait for VPN before giving up |
| `WaitForLoginMinutes` | int | `6000` | Minutes to wait for a user to log in when running as SYSTEM with nobody logged in (~100 hours) |
| `LogoffCountdownSeconds` | int | `30` | Countdown duration before automatic logoff after migration completes |
| `LogPath` | string | `C:\ProgramData\Migration` | Directory for log files and migration manifest |
| `TestMode` | switch | off | Runs all steps except registry rewrite, CSE clear, and logoff. Safe for piloting. |
| `SkipLogoff` | switch | off | Skips the logoff step after successful completion |
| `SkipGpUpdate` | switch | off | Skips the `gpupdate /force` step. Use when the calling software has already applied policy updates. |
| `SkipIntro` | switch | off | Skips the intro dialog when servers are already reachable. The intro is still shown if VPN is needed. |
| `ForceCloseApps` | switch | off | Silently force-closes all target applications without prompting the user. Useful for fully automated deployments. |
| `MigrationReady` | switch | off | Uses alternate intro dialog text for migration software context. Shows messaging appropriate for a user who has already acknowledged and started the migration (e.g. via PowerSyncPro). |
| `AdditionalAppsToClose` | string[] | `@()` | Additional process names (without .exe) to include in the app-close dialog or force-close list |

---

## Usage Examples

**Standard RMM deployment (GlobalProtect VPN, 45-minute wait):**
```powershell
.\cleanup_redirection.ps1 -VpnClientName 'GlobalProtect' -VpnTimeoutMinutes 45
```

**Pilot run — no registry changes, no logoff:**
```powershell
.\cleanup_redirection.ps1 -TestMode -SkipLogoff
```

**Include additional apps in the close prompt:**
```powershell
.\cleanup_redirection.ps1 -AdditionalAppsToClose @('VISIO','PROJECT','zoom')
```

**Custom log path (e.g., redirected to a network share):**
```powershell
.\cleanup_redirection.ps1 -LogPath 'C:\ProgramData\PSP\Migration'
```

**PowerSyncPro migration (recommended):**
```powershell
.\cleanup_redirection.ps1 -SkipLogoff -ForceCloseApps -SkipGpUpdate -SkipIntro -MigrationReady
```

> When called from PowerSyncPro during an AD-to-Entra migration, use this combination. The user has already clicked "Ok, Start Migration" in PowerSyncPro, so the intro dialog is skipped entirely (the user is already on-net or VPN at this point), apps are closed silently without prompting, `gpupdate` is skipped (PowerSyncPro handles policy), logoff is suppressed so PowerSyncPro can manage the reboot and Entra join sequence itself, and `-MigrationReady` ensures any remaining dialogs use migration-specific wording.

---

## Offline Files Support

If Windows Offline Files (CSC) is enabled and the file server is unreachable, the script automatically detects that the redirected folders are available in the local cache and proceeds without requiring VPN. No flags or configuration are needed — detection is fully automatic.

When this path is taken:
- The VPN connectivity prompt is skipped entirely
- robocopy reads from the UNC paths as normal — the CSC filter driver transparently serves files from the local cache at the driver level
- `UsingOfflineFiles: true` is recorded in the migration manifest

**Important caveat:** If there are unsynced changes in the CSC cache (files modified offline that have not yet synced back to the server), those local changes are what gets copied — the server version is not consulted. This is generally the correct behavior for a migration, but if the machine can reach the server, sync should be confirmed complete in Sync Center (`mobsync.exe`) before running the script to avoid any possibility of conflict.

If the server IS reachable when Offline Files is enabled, robocopy reads from the server directly (standard behavior).

---

## Customizing Dialog Text

Near the top of the script, before any functions, there are two labeled text blocks you can edit to match your organization's messaging. No other changes to the script are needed.

**Standard deployment text** — shown when the script is run without `-MigrationReady`:

```powershell
$Script:IntroText1   = 'Your IT team is preparing this computer...'
$Script:IntroText2   = 'Once complete, you will be asked to log off...'
$Script:IntroVpnText = 'To begin, please connect to {VPN}...'
```

**MigrationReady text** — shown when `-MigrationReady` is used (e.g. called from PowerSyncPro):

```powershell
$Script:MRIntroText1   = 'Your migration is now underway...'
$Script:MRIntroText2   = 'Once this process is completed your machine will be rebooted...'
$Script:MRIntroVpnText = 'To begin, please connect to {VPN}...'
```

`IntroVpnText` and `MRIntroVpnText` are only shown when the file server is unreachable at launch (VPN not connected). The `{VPN}` placeholder in both VPN strings is replaced at runtime with the value passed to `-VpnClientName`.

**Formatting constraints:**
- Do not use double quotes (`"`) inside the strings — use single quotes or rephrase.
- Keep all characters ASCII — no curly quotes, em-dashes, or other Unicode characters. PowerShell 5.1 misreads UTF-8 without BOM and will corrupt non-ASCII text.

---

## What the Script Does

1. **Waits for a user to log in** — If running as SYSTEM with no interactive user, polls every 60 seconds up to `WaitForLoginMinutes`. If nobody logs in within the timeout, exits with code 2 and the RMM can retry.

2. **Reads redirected folder locations** — Reads the user's `User Shell Folders` registry key under their hive and identifies any values pointing to UNC paths (`\\server\...`).

3. **Idempotency check** — If all folders are already local, logs "nothing to do" and exits cleanly with code 0.

4. **Tests file server connectivity** — Tests TCP port 445 to each referenced file server. If any server is unreachable, checks whether the Offline Files (CSC) cache is available for those paths (test runs in the user's session). If the cache covers all unreachable paths, the script proceeds without VPN and robocopy reads from the local cache.

5. **Shows the migration intro dialog** — Explains the migration to the user in plain language. If file servers are unreachable and no local cache is available, this dialog includes a VPN connectivity prompt that auto-proceeds once connectivity is detected.

6. **Runs `gpupdate /force`** — Picks up the FR GPO removal so Group Policy will not re-redirect folders on next logon.

7. **Prompts the user to close applications** — Lists running applications from a default set (Outlook, Office, browsers, OneDrive, Teams, etc.) plus any specified via `AdditionalAppsToClose`. Includes a Force Close button.

8. **Copies folders via robocopy** — Copies each folder from its UNC source to the local profile path. Nested folders (e.g., Pictures inside Documents) are handled correctly with exclusions to avoid double-copying. A progress window is shown during the copy.

9. **Rewrites registry** — Updates `User Shell Folders` (REG_EXPAND_SZ) and `Shell Folders` (REG_SZ) to local `%USERPROFILE%\...` paths.

10. **Clears FR CSE state** — Removes the `Group Policy\FolderRedirection` registry key so the Folder Redirection CSE does not re-apply stale policy on next logon.

11. **Writes a migration manifest** — Saves a JSON file to `LogPath` with the outcome, which folders were migrated, robocopy exit codes, and which apps were force-closed.

12. **Logoff countdown** — Shows a 30-second (configurable) countdown before logging the user off. A "Log Off Now" button is available to skip the countdown.

Throughout execution, a timestamped log is written to `LogPath` (`C:\ProgramData\Migration\unredirect-<username>-<timestamp>.log`). A migration manifest (`unredirect-<username>.json`) is written at the end of each run with the full outcome, folder-level copy results, and any apps that were force-closed.

A persistent "Migration in Progress" banner is displayed from step 3 onward (immediately after confirming there is work to do) through step 12, ensuring the user has visible confirmation throughout the entire process including during connectivity checks and dialog transitions.

---

## Default Applications Prompted to Close

The script prompts the user to close the following applications before copying begins. These are closed gracefully where possible; the user can also choose Force Close.

`Outlook, Word, Excel, PowerPoint, OneNote, Access, Visio, Project, Adobe Acrobat/Reader, Edge, Chrome, Firefox, Brave, Opera, OneDrive, Dropbox, Google Drive, VS Code, Notepad++, Sublime Text, Teams, Slack`

Additional process names can be appended via the `AdditionalAppsToClose` parameter.

---

## Log Files

All files are written to `LogPath` (`C:\ProgramData\Migration` by default).

| File | Description |
|---|---|
| `unredirect-<username>-<timestamp>.log` | Full execution log with timestamps |
| `unredirect-<username>.json` | Migration manifest — outcome, folder results, apps killed, `UsingOfflineFiles` flag |
| `robocopy-<folder>-<timestamp>.log` | Per-folder robocopy log |

The manifest file is overwritten on each run (no timestamp in the filename), so the latest run is always at `unredirect-<username>.json`.

---

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to do (folders were already local) |
| 1 | Unexpected error |
| 2 | No user logged in within `WaitForLoginMinutes` — retry later |
| 3 | User cancelled a dialog |
| 4 | VPN connection timed out — retry when user is connected |
| 5 | File copy failure — registry was NOT changed, retry is safe |
| 6 | Registry rewrite failure — files were copied but registry not updated |
| 7 | Could not determine user profile path |

Exit code **5** is safe to retry — no registry changes are made unless all copies succeed. Exit code **6** requires manual review; the data is local but the shell folder pointers may still point to the server.

---

## Notes

- **Running as the user (non-SYSTEM):** The script detects its own context. When not running as SYSTEM, it assumes the current user is the target and skips the scheduled task IPC mechanism. Useful for manual testing.
- **Multiple users logged in:** If more than one interactive user session is detected, the script exits with code 1 and logs the ambiguity. It will not guess which user to target.
- **Retrying after a failure:** Exit codes 2, 3, and 4 are safe to retry unconditionally. Exit code 5 is also safe to retry. Exit code 6 requires verifying the manifest before retrying.
- **TestMode:** Use `-TestMode -SkipLogoff` to do a dry run. All GUI dialogs appear and robocopy runs, but registry keys are not changed and the user is not logged off.
