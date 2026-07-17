# PowerSyncPro Startup Wi-Fi Switch

`SwitchWifi.ps1` runs at the very start of a PowerSyncPro (PSP) migration. On
machines that reach the network over the corporate cert-based Wi-Fi, that
network stops working the moment the device is migrated off the domain. This
script moves the device onto a temporary pre-shared-key (PSK) migration network
first, and confirms it can still reach the PSP server. If it cannot, it **halts
the migration and rolls the device back** rather than letting PSP reboot a
machine that will come up stranded with no route home.

It is designed to run **as SYSTEM**, invoked by the PSP Startup Package.

---

## What it does

1. **Skips machines that do not need it.** No wireless adapter, adapter down, or
   a live wired default route (a docked laptop) -> exit cleanly and let the
   migration proceed. A device not on the corporate SSID -> also exit.
2. **Detects the migration network.** Forces a Wi-Fi scan and reads the
   migration SSID's security type (WPA2 vs WPA3) off the air, so nothing about
   the network's security has to be configured by hand.
3. **Switches to it.** Generates a matching WLAN profile, imports it, sets it to
   top priority and auto-connect, and connects.
4. **Verifies the switch worked.** Waits for association, then a real DHCP lease,
   then tests TCP reachability to the PSP server (read from the agent's own
   registry key so it always matches the agent).
5. **Halts and rolls back on any failure** from step 2 onward (see below).

On success it logs a completion line and hands control back to PSP.

---

## Configuration

All settings are near the top of `SwitchWifi.ps1`.

| Setting | Purpose |
|---|---|
| `$CorporateSSID` | The Wi-Fi the device is on *now*. Only devices on this SSID are switched. **This is a gate** — if it is wrong, the script exits without doing anything. |
| `$MigrationSSID` | The migration network to move onto. |
| `$MigrationPSK` | Pre-shared key for the migration network. **Must be set** — the script refuses to run while it is still `CHANGE-ME`. 8–63 characters. |
| `$PSPServer` / `$PSPPort` | **Fallback only.** At run time the PSP endpoint is read from `HKLM\SOFTWARE\Declaration Software\Migration Agent\URL`. These apply only if that key is missing or unreadable — but keep them pointed at a real server just in case. |
| `$UserDialogTitle` / `$UserDialogHeading` / `$UserDialogMessage` | The dialog shown to the logged-on user if the migration is halted. Customise freely. |

### Timing knobs

Each detection stage waits for a slow-but-healthy device rather than failing it
early. Worst case is roughly **2.5 minutes** before a halt is even reached. PSP
does not kill long-running scripts, so that is safe.

| Setting | Default | |
|---|---|---|
| `$ScanTimeoutSec` / `$ScanRetryDelaySec` | 30 / 4 | Forced-scan budget. The 4s delay tracks how long `WlanScan` takes to return results; do not lower it. |
| `$AssociationTimeoutSec` | 30 | Wait to associate with the migration network. |
| `$DhcpTimeoutSec` | 30 | Wait for a usable (non-169.254) DHCP address. |
| `$ConnectivityAttempts` / `$ConnectivityRetryDelaySec` | 3 / 5 | Reachability probes to PSP before giving up. |

---

## Deployment

1. Set `$CorporateSSID`, `$MigrationSSID`, and `$MigrationPSK`.
2. Confirm `$PSPServer` / `$PSPPort` point at a real server (fallback).
3. Add the script to the PSP migration's Startup Package so it runs **as SYSTEM**
   at the beginning of the runbook.

Nothing else ships with it — the WLAN profile is generated at run time.

Logs go to the PSP agent log (PSP captures the script's console output) and to a
local transcript at `C:\MigTemp\WiFiMigration.log`.

---

## What happens on failure

PSP does not honour script exit codes, so exiting non-zero will **not** stop the
migration. Instead, `Fail-Migration` does the following, in order:

1. Writes a two-line halt notice to the log (PSP copies it into the agent log).
2. **Stops and disables** the `PowerSyncPro Migration Agent` service — the only
   real lever to stop the runbook. Disabling matters: the agent would otherwise
   resume at next boot.
3. Rolls the device back to a usable state:
   - clears the deny-logon rights PSP set (preserving `Guest`),
   - resets the lock screen to default,
   - clears the legal notice,
   - resumes BitLocker protectors PSP suspended.
4. Renames the agent state folder so a restart begins a **fresh** migration
   rather than resuming a half-done one.
5. Kills the "Migration in Progress" tray application.
6. Shows the logged-on user a dialog explaining the machine is safe to use.

The **break-glass local admin** PSP creates is deliberately left in place, as a
recovery path in case the logon-rights rollback did not fully take.

### Recovering a halted device

Once the underlying Wi-Fi issue is fixed, re-enable the agent:

```powershell
Set-Service -Name 'PowerSyncPro Migration Agent' -StartupType Automatic
Start-Service -Name 'PowerSyncPro Migration Agent'
```

The renamed state folder (`Migration Agent.aborted-<timestamp>` under
`%ProgramData%\Declaration Software`) can be deleted once the device has
migrated successfully; it is kept only for post-mortem.

---

## Testing: `-DryRun`

```powershell
.\SwitchWifi.ps1 -DryRun
```

A dry run does the **real Wi-Fi work** — scan, detect, generate, import,
connect, wait for association/DHCP, probe PSP — but on failure it only
*describes* what the halt would do instead of doing it. Nothing is stopped,
rolled back, renamed, or killed.

**Important:** the Wi-Fi switch itself is not simulated. A dry run that gets that
far leaves the device sitting on the migration network with a new profile
installed. That is intentional — the point is to protect the destructive rollback
half, which on an idle machine is just damage to repair by hand.

Run test invocations **as SYSTEM** (e.g. `psexec -s -i powershell.exe`). As an
interactive admin, `netsh` withholds SSIDs (Location permission) and results will
not reflect how PSP actually runs the script.

---

## Design notes

- **Locale independent where it can be.** Adapter identity and link state come
  from `Get-NetAdapter`'s numeric `ifType` (71 = wireless) and `ifOperStatus`
  enum, never from parsed `netsh` text — whose labels *and* values are
  translated. `netsh` is used only for the SSID and the scan, matching on
  standards names (`WPA2`, `WPA3`, `CCMP`, `SSID`) that Windows does not
  translate.
- **The scan is forced.** `netsh wlan show networks` only reads the adapter's
  cache, which at startup holds little more than the connected network. The
  script calls `WlanScan()` in `wlanapi.dll` to trigger a fresh scan first.
- **The wired-route check requires the interface to be *up*.** A default route
  can linger in the table briefly after a cable is pulled, so the interface's
  `ifOperStatus` is cross-checked to avoid treating a stale route as live wired
  connectivity.

---

## Known limitations / untested

- **802.1X corporate Ethernet is assumed absent.** The script treats any device
  with a wired default route as safe and exits. If corporate Ethernet is
  802.1X cert-based, a docked device is stranded by the migration exactly as a
  wireless one would be, and this exit is wrong. Marked `TODO` in the code.
- **Hidden (non-broadcast) migration SSID is not supported.** A hidden network
  never appears in a scan, so detection cannot see it.
- **The rollback surviving service stop is unverified.** If PSP spawns this
  script as a child of the agent service, `Stop-Service` *may* terminate the
  script mid-rollback. If a real PSP-invoked run shows the halt notice with no
  rollback lines after it, that is what happened — move the rollback into a
  scheduled task.
