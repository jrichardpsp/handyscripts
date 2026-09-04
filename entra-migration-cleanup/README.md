# Entra Migration Cleanup

`Remove-MigrationShells.ps1` finds and removes the directory debris that a
PowerSyncPro workstation migration (Hybrid AD -> Entra) leaves behind in Entra ID
and Intune: placeholder "shell" device objects and the stale Intune enrollment
records that spawn them. It is an **admin tool run from a workstation against the
tenant** — it is not part of any migration package and never touches the endpoints
themselves.

It always starts safe: without `-Execute` nothing is deleted, you just get a
report (console + CSV) of what would happen.

---

## Background: why the debris exists

After a migration, one machine can show two or three device entries in the Entra
portal. The migration itself succeeded — the extras are leftovers from two
Microsoft-side changes (~June 2026):

- **Entra device recycle bin (soft delete).** The migration's leave step deletes
  the old hybrid device object exactly as it always did, but the delete is now
  *soft*. Entra Connect's next sync cycle **restores** the old object wholesale
  instead of re-creating a harmless empty pending object. Whether the restored
  "zombie" survives depends on a timing race with the new join object's hostname
  registration (hostnames are now uniqueness-enforced).
- **Intune placeholder objects.** When an Intune enrollment's linked Entra device
  disappears, Intune mints a near-empty placeholder device ("shell") so its
  compliance/targeting machinery has something to reference. Orphaned shells
  never clean themselves up.

## What the script classifies

For each hostname it inventories every Entra device object and Intune managed
device record, then classifies:

| Class | Fingerprint | Action |
|---|---|---|
| **REAL** (Entra) | `trustType AzureAd` — the live join | Kept, always |
| **SHELL** (Entra) | `trustType` null AND its altSecId key base64-decodes to the ASCII GUID equal to its own `deviceId` | Deleted (order-aware, see below) |
| **ZOMBIE** (Entra) | `trustType ServerAd` coexisting with a REAL object — the restored old hybrid identity; no machine holds its key | **Reported only.** Cloud-side deletes get re-restored by Entra Connect; the fix is in the source AD — see "Removing zombies" below |
| **HYBRID** (Entra) | `trustType ServerAd` with **no** REAL sibling — possibly a live hybrid machine | Whole hostname left alone |
| **HEALTHY** (Intune) | `azureADDeviceId` matches a REAL object's `deviceId` | Kept, always |
| **STALE** (Intune) | Anything else — points at a shell, all-zeros, or nothing | Deleted (age-gated, see below) |

## Removing zombies (manual, AD-side)

A zombie cannot be deleted cloud-side: as long as its AD computer object is in
Entra Connect's sync scope, the next sync cycle restores or re-provisions it. Fix
it in the source AD:

1. **Delete the computer object from AD.** This is the normal choice — the
   machine has migrated, so the AD account's only remaining purpose is rollback.
   Once rollback is off the table, delete it.
   - Alternative, if the AD account must be kept (rollback still possible):
     clear its `userCertificate` attribute instead. That drops the object out of
     the "In from AD - Computer Join" sync rule's scope without touching the
     account.
2. Run (or wait for) an Entra Connect delta sync — it deletes the cloud zombie.
3. Purge the zombie from the Entra recycle bin
   (`Entra portal > Devices > Deleted devices`, or
   `DELETE /directory/deletedItems/{objectId}` in Graph) so nothing can restore
   it later.
4. Nothing else is needed: the real device object picks up its hostname
   automatically on its next background retry, and this script (re-run) removes
   any shell that Intune minted when the zombie disappeared.

Do the script's cleanup pass (stale record deletion) **before** the AD-side step
when possible — with the stale record already gone, the zombie's deletion cannot
trigger a new placeholder.

## Safety rails

- **Report-only by default.** `-Execute` is required to delete anything;
  deletions prompt per object unless `-Force` is also given.
- **`-Execute` requires `-TenantId`** so deletions cannot land in whatever tenant
  happens to be cached.
- **Order matters and is enforced:** stale Intune records are deleted before
  their shells. Deleting a shell while its record lives makes Intune re-mint a
  new one within minutes (observed behavior).
- **Mis-link window guard:** a freshly created Intune record can transiently
  point at the *old* (deleted) hybrid deviceId before self-correcting, which
  makes it look stale. A stale record younger than `-StaleAfterDays` (default 7)
  with no HEALTHY sibling is HELD, along with its shell — re-run later.
- **Decommissioned machines** (only shells remain, no real object) are skipped
  unless `-IncludeOrphans` is given.
- **Unknown hostnames** report "not found" instead of failing; running with no
  parameters prints a quick-start guide instead of a parameter error.

## Timing: wait ~24 hours after a migration

The directory keeps churning for a while after a migration, and running the
cleanup too soon gives misleading results:

- **First ~30 minutes:** the restore race is still being decided. A zombie only
  appears when Entra Connect's next delta cycle runs, so a machine that looks
  clean now can grow a zombie minutes later. Intune is also still minting and
  (sometimes) purging placeholder shells in this window.
- **First ~24 hours:** the new Intune enrollment typically reports the OLD
  (deleted) hybrid deviceId before self-correcting to the real object. During
  this mis-link window the live enrollment classifies as STALE, no record
  classifies as HEALTHY, and the script HOLDs everything for that hostname
  (the `-StaleAfterDays` guard) - correct, but the run accomplishes nothing.
- **After ~24 hours:** the picture is stable. The new record has linked to the
  real object, transient objects have settled, and a single pass classifies and
  cleans everything accurately.

Practical rule: report mode is safe at any time, but treat results for machines
migrated in the last day as provisional. Schedule `-Execute` runs at least a day
behind the migration wave they clean up after. The safety rails make an early
run harmless - just not useful.

## Usage

```powershell
# 1. Survey the whole tenant (read-only), including decommissioned machines
.\Remove-MigrationShells.ps1 -ScanTenant -IncludeOrphans -TenantId <tenant>

# 2. Review the report_<timestamp>.csv it writes

# 3. Clean up, no prompts, and hard-delete removed shells from the recycle bin
.\Remove-MigrationShells.ps1 -ScanTenant -IncludeOrphans -TenantId <tenant> -Execute -Force -PurgeRecycleBin

# Or target specific machines
.\Remove-MigrationShells.ps1 -Hostname PC-001,PC-002 -TenantId <tenant> -Execute
```

| Parameter | Purpose |
|---|---|
| `-Hostname <name>[,...]` | Specific machine(s) to assess |
| `-ScanTenant` | Discover every hostname in the tenant that has a shell object |
| `-TenantId` | Tenant to connect to. Required with `-Execute` |
| `-Execute` | Actually delete (prompts per object unless `-Force`) |
| `-Force` | With `-Execute`: skip the per-deletion prompts |
| `-PurgeRecycleBin` | Also permanently delete removed shells from `directory/deletedItems` (recommended — every device delete is soft and restorable for 30 days otherwise) |
| `-IncludeOrphans` | Include machines where only shells remain (decommissioned) |
| `-StaleAfterDays` | Age gate for deleting a stale record with no healthy sibling (default 7) |
| `-ReportPath` / `-LogPath` | CSV report and log locations (default: timestamped files next to the script) |

## Output

- Console: per-hostname inventory with classifications, then every action
  (`[REPORT]` / `[DELETED]` / `[PURGED]` / `HOLD` / `SKIP`) and a summary table.
- CSV (`-ReportPath`): one row per object/record seen — `Hostname, RecordType,
  Class, Id, LinkedId, Detail, Hostnames, Timestamp, Action`. Actions include
  `kept`, `would-delete`, `deleted`, `deleted+purged`, `held - ...`,
  `skipped: ...`, and `zombie - manual AD-side cleanup required`.
- Log (`-LogPath`): timestamped copy of everything.

## Requirements

- PowerShell 5.1 or 7+, with the `Microsoft.Graph.Authentication` module
  (`Install-Module Microsoft.Graph.Authentication`).
- Delegated Graph sign-in with scopes `Device.ReadWrite.All`,
  `DeviceManagementManagedDevices.ReadWrite.All`, `Directory.ReadWrite.All`
  (the script requests them on connect). Practically: Cloud Device Administrator
  + Intune Administrator, or Global Administrator.

## What it deliberately does NOT do

- Delete zombies (restored hybrid objects) — those must be fixed at the AD
  source or Entra Connect brings them back. See "Removing zombies" above; the
  script points there when it finds one.
- Touch hostnames that still look hybrid-only, or any REAL object or HEALTHY
  record, under any flag combination.
- Fix Intune primary user / Entra owner on PPKG-migrated devices (bulk
  enrollments leave the package account as owner and no primary user) — that is
  a separate remediation.
