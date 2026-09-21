# MSI Customizer

`MsiCustomizer.ps1` produces a pre-configured copy of the PowerSyncPro Migration
Agent MSI with the connection settings **baked in**, so the agent can be installed
by a double-click or a plain `msiexec /i` with no parameters. It is aimed at
manual / technician-assisted installs - war-room, lab, or small-batch work - where
having someone type or paste the PSK and server URL is impractical or error-prone.

Normally the agent MSI is installed with two public properties on the command line:

```
msiexec /i PSPMigrationAgentInstaller.msi /qn PSK="<psk>" URL="https://<server>/Agent"
```

This script writes those values (plus an optional polling interval) into the MSI's
own `Property` table as defaults. It uses the same Windows Installer COM / MSI-SQL
mechanism PowerSyncPro's own `PSP-CreateMST.ps1` uses to build its GPO transform -
the difference is that this keeps the customized **MSI** instead of emitting a
separate `.mst` transform file. The result is a single self-contained file you can
hand to a technician or drop on a device.

> [!WARNING]
> **The MSI this script produces is not validly signed.** Editing the package
> breaks PowerSyncPro's Authenticode signature, so Windows will show an
> "unknown / unverified publisher" or "invalid signature" warning when the file
> is run (SmartScreen and/or the UAC elevation prompt). This is expected - the
> install still works; approve the prompt to continue. See
> [Unsigned MSI and Windows warnings](#unsigned-msi-and-windows-warnings) before
> distributing.

---

## Quick start

```powershell
# Bake a customer MSI (PSK + URL, default polling interval of 60s)
.\MsiCustomizer.ps1 `
    -MSIPath  .\PSPMigrationAgentInstaller.msi `
    -PSKValue "<psk from PSP server>" `
    -URLValue "https://psp.contoso.com/Agent"

# -> PSPMigrationAgentInstaller-<version>-custom.msi, in the same folder.
#    Double-click it, or run: msiexec /i "<that file>"
```

Add `-Silent` to make the double-click install show only a progress bar with no
setup wizard:

```powershell
.\MsiCustomizer.ps1 `
    -MSIPath  .\PSPMigrationAgentInstaller.msi `
    -PSKValue "<psk>" `
    -URLValue "https://psp.contoso.com" `
    -PollingInterval 300 `
    -Silent
```

Check what is baked into any MSI (nothing is modified):

```powershell
.\MsiCustomizer.ps1 -MSIPath .\PSPMigrationAgentInstaller-3.3.26177.2-custom.msi -Verify
```

---

## Parameters

### Build mode

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-MSIPath` | yes | - | Path to the source PowerSyncPro MSI to customize. |
| `-PSKValue` | yes | - | The pre-shared key from the PSP server. Baked in as the `PSK` property. Treat it as a secret - see [Security](#security-the-psk-is-in-the-file). |
| `-URLValue` | yes | - | The PSP server agent endpoint. Baked in as the `URL` property exactly as supplied (never rewritten). Warns if it does not end in `/Agent` - see [URL handling](#url-handling). |
| `-PollingInterval` | no | `60` | Agent check-in interval in seconds, baked in as `POLLING_INTERVAL`. Range 1-86400. `60` matches the agent's own default. |
| `-Silent` | no | off | Remove the setup wizard so a double-click install shows only a progress bar. See [Silent install](#silent-install--silent). |
| `-OutputPath` | no | `<source>-<version>-custom.msi` | Where to write the customized MSI. Defaults to the source folder, named after the source plus the MSI's `ProductVersion`. |
| `-Force` | no | off | Overwrite `-OutputPath` if it already exists. |

### Verify mode

| Parameter | Required | Description |
|---|---|---|
| `-MSIPath` | yes | The MSI to inspect. |
| `-Verify` | yes | Switch into read-only inspection. Reports the MSI's ProductName / version / ProductCode, its Authenticode signature status, and any baked-in `PSK` / `URL` / `POLLING_INTERVAL`. Modifies nothing. |

`-Verify` is its own parameter set, so it cannot be combined with the build
parameters - PowerShell rejects the mix at parameter binding.

---

## URL handling

`-URLValue` is baked in **exactly as you supply it** - the script never rewrites
it. The agent normally registers against the server's `/Agent` endpoint, so if the
URL does not end in `/Agent` (matched case-insensitively) the script prints a
**warning** to catch an accidental omission. It does not change the value.

The value is left alone deliberately: a client with a customized reverse proxy may
expose the agent endpoint at a different path - even the site root (`/`) - and
silently appending `/Agent` would corrupt a URL that was already correct. If you
get the warning and your URL is right for your proxy, ignore it.

| You pass | Baked value | Note |
|---|---|---|
| `https://psp.contoso.com/Agent` | `https://psp.contoso.com/Agent` | no warning |
| `https://psp.contoso.com` | `https://psp.contoso.com` | warns - confirm the path is correct |
| `https://psp.contoso.com/` | `https://psp.contoso.com/` | warns - confirm the path is correct |

Whatever you pass is what the agent will use, so include the full path your server
expects.

---

## Silent install (`-Silent`)

By default the customized MSI behaves like the PowerSyncPro MSI: a double-click launches
the full setup wizard. `-Silent` removes that wizard so the install runs with just
a progress bar - the same experience as `msiexec /qb`, but built into the file so
no command line is needed.

It works by clearing the MSI's `InstallUISequence` table. Windows Installer's
documented behavior is that when a full UI is requested (a double-click) but that
table is empty, it skips the dialogs and runs the install with a reduced UI
(progress only). **The install itself is not weakened** - all of the real work
(services, registry, PSK/polling configuration, file copy) lives in the
`InstallExecuteSequence`, which is left completely untouched. Interactive PSK
validation, which only runs as a wizard dialog, is skipped - which is fine,
because the PSK is already baked in.

The UAC elevation prompt (and the unsigned-file warning) still appear; `-Silent`
only removes the setup wizard, not the OS security prompts.

---

## Unsigned MSI and Windows warnings

**Every MSI this script produces is unsigned as far as Windows is concerned.**

PowerSyncPro ships the agent MSI with an Authenticode signature. Baking properties
into the package changes its contents, which invalidates that signature - there is
no way to edit an MSI and keep the original signature valid. As a result:

* Running the file may trigger a **SmartScreen** "Windows protected your PC" /
  "unknown publisher" prompt. The user clicks **More info -> Run anyway**.
* The **UAC** elevation prompt shows an unverified/unknown publisher rather than
  PowerSyncPro's name.
* `Get-AuthenticodeSignature` on the file reports `HashMismatch` (the original
  signature no longer matches the modified content).

None of this blocks a manual install - it is a cosmetic trust warning that a
technician approves. It is called out here because it **will** be seen, and anyone
handed the file should be told to expect it.

Where it *does* matter:

* **Signed-installer enforcement.** Environments that require a valid publisher
  signature to install software - WDAC / AppLocker publisher rules, some MDM
  configurations - will reject the customized MSI. In those environments, use the
  **original PowerSyncPro MSI** and pass `PSK=` / `URL=` on the command line (or via a
  transform) instead of baking them in.
* **Re-signing.** If you have your own code-signing certificate, you can re-sign
  the customized MSI (`signtool sign ...`) to replace the broken signature with a
  valid one under your own publisher name. The script does not do this.

The script prints a reminder of this on every build, and `-Verify` reports the
signature status so you can confirm it.

---

## Security: the PSK is in the file

The `PSK` is stored in the MSI as a plain-text property. It is trivially
extractable from the file (for example with Orca, or this script's own `-Verify`).
This is the same exposure as passing `PSK=` on a command line or putting it in a
batch file - baking it in does not make it more secret, but it does mean the file
itself is now a credential.

Practical guidance:

* **Scope each customized MSI per customer / site**, matching how the PSK is
  scoped. Do not bake one broad PSK into a widely-shared file.
* Store and transfer the customized MSI like any other secret-bearing artifact.
* The script never echoes the PSK except in its own success/verify output; it does
  not log it elsewhere. Note that `msiexec` verbose logs (`/L*V`) written at
  install time **do** record property values, so treat those logs as sensitive too.

---

## Versioning

A customized MSI is tied to the exact agent version it was built from. When
PowerSyncPro ships a new agent MSI, **re-run this script against the new MSI** to
produce an updated customized copy - you cannot upgrade a baked MSI in place.

To make this easy to track, the default output filename includes the source MSI's
`ProductVersion` (for example `PSPMigrationAgentInstaller-3.3.26177.2-custom.msi`).
Consider adding the customer or site to `-OutputPath` as well, since each file is
effectively a per-customer credential.

The script also stamps a fresh **PackageCode** into every customized copy (per
Windows Installer rules for modified packages), so a customized MSI is never
confused with the PowerSyncPro original - or with another customer's copy - in the local
Windows Installer cache.

---

## How it works

1. Opens the source MSI read-only and reads its identity (ProductName, version,
   ProductCode).
2. Copies the source MSI to the output path.
3. Opens the copy read/write and writes the properties into the `Property` table:
   `PSK`, `URL`, and `POLLING_INTERVAL`. Values are written with
   parameterized MSI-SQL, so characters like `+` and `/` in a PSK are handled
   safely.
4. With `-Silent`, empties the `InstallUISequence` table.
5. Stamps a new PackageCode into the copy's Summary Information stream and commits.
6. Re-opens the finished MSI read-only and confirms the baked values match what
   was requested, failing the build if they do not.

Command-line properties still override baked-in defaults, so a customized MSI can
also be installed with an explicit `PSK=` / `URL=` if ever needed.

---

## Requirements

* **Windows PowerShell 5.1** or later. No third-party tools or modules - the
  script uses the built-in `WindowsInstaller.Installer` COM object.
* Read access to the source MSI and write access to the output location.
* Building the MSI does **not** require elevation. Installing the resulting agent
  MSI does (the MSI requests it via UAC as normal).

---

## Notes

* Baked property names (`PSK`, `URL`, `POLLING_INTERVAL`) are PowerSyncPro's, per the
  KB: <https://kb.powersyncpro.com/powersyncpro-migration-agent-installation-methods>
* For GPO deployment specifically, PowerSyncPro's `PSP-CreateMST.ps1` (which produces
  a transform rather than a modified MSI) is the supported path - GPO applies the
  MST via the package's **Modifications** tab.

Run `Get-Help .\MsiCustomizer.ps1 -Full` for complete parameter help.
