# SCCM Client Removal

Performs a complete removal of the SCCM (Configuration Manager) client from a Windows machine, using the official uninstaller with full manual fallback cleanup.

---

## The Problem

Machines being migrated to Entra ID (Azure AD join), re-imaged, or decommissioned from SCCM management often need the ConfigMgr client fully stripped before the transition. An incomplete removal leaves behind services, WMI namespaces, registry keys, and certificates that can conflict with new management tooling or cause policy errors.

---

## What the Script Does

1. Runs `ccmsetup.exe /uninstall` and waits for the spawned child process to fully finish (up to 5 minutes).
2. Stops and deletes all SCCM-related Windows services (`CcmExec`, `smstsmgr`, `CmRcService`, `ccmsetup`).
3. Removes SCCM WMI namespaces (`root\ccm`, `root\cimv2\sms`, `root\SmsDm`, `root\sms`).
4. Deletes leftover files and folders (`C:\Windows\CCM`, `ccmsetup`, `ccmcache`, `SMSCFG.ini`, SMS MIF files).
5. Purges SCCM registry keys from both `HKLM\SOFTWARE` and `HKLM\SYSTEM` hives, including Wow6432Node entries and the Control Panel applet entry.
6. Removes certificates from the `LocalMachine\SMS` certificate store.
7. Deletes the `\Microsoft\Configuration Manager` scheduled task folder and all tasks within it.

If `ccmsetup.exe` is not present, steps 2-7 run as a standalone manual cleanup.

---

## Requirements

| Requirement | Detail |
|---|---|
| Run as | SYSTEM or local Administrator |
| OS | Windows 10 / 11 |
| PowerShell | 5.1+ |

---

## Usage

```powershell
.\sccm_removal.ps1
```

No parameters required. The script is fully automated and logs all activity.

---

## Log File

`C:\Windows\Temp\Remove-SCCMClient.log`

Each entry is timestamped and tagged with a level:

| Level | Meaning |
|---|---|
| `INFO` | Normal operation (service stopped, key removed, etc.) |
| `WARN` | Non-fatal issue (timeout waiting for ccmsetup, namespace removal failed) |

Two verbosity tiers are written:
- **Console + log** -- key milestone messages per step
- **Log only** -- per-item detail (individual files, keys, tasks deleted)

---

## Deployment

Can be deployed as:

- An **Intune remediation script** (run as SYSTEM, 64-bit PowerShell)
- A **task scheduler** job triggered at startup
- A **manual one-shot run** by a local administrator

---

## After Running

**Reboot the machine** before re-enrolling or re-imaging. Some service and WMI changes require a restart to fully clear.

---

## Notes

- Safe to run on machines where the SCCM client is already partially or fully removed -- each step checks for existence before acting.
- Re-running on a clean machine is a no-op.
