# Set-CorporateDeviceIdentifiers

Registers the local machine as a **Corporate Device Identifier** in Microsoft Intune using the Microsoft Graph API (`/beta/deviceManagement/importedDeviceIdentities`).

This is a **proof-of-concept** script intended for evaluation and testing. It uses the `manufacturerModelSerial` identifier type, which is the format required for **Windows Autopilot Device Preparation** (no hardware hash needed).

---

## How It Works

1. Reads `Manufacturer`, `Model`, and `SerialNumber` from the local machine via WMI (`Win32_ComputerSystem` / `Win32_BIOS`)
2. Authenticates to Microsoft Graph using an App Registration (client credentials / client secret flow)
3. Submits the device to Intune as a Corporate Device Identifier

The identifier string submitted to Intune takes the format: `MANUFACTURER,MODEL,SERIALNUMBER`

---

## Prerequisites

### App Registration (Entra ID)

Create an App Registration in Entra ID with the following **Application** permission (not Delegated) and admin consent granted:

| Permission | Type |
|---|---|
| `DeviceManagementServiceConfig.ReadWrite.All` | Application |

You will need the **Tenant ID**, **Client ID**, and a **Client Secret** from the app registration.

### Runtime Requirements

- PowerShell 5.1 or later
- Run as **local Administrator** (required for WMI BIOS serial number access)
- Internet access to `login.microsoftonline.com` and `graph.microsoft.com`

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | Yes* | *(hardcoded POC value)* | Your Entra ID Tenant ID (GUID) |
| `-ClientId` | Yes* | *(hardcoded POC value)* | App Registration Client ID (GUID) |
| `-ClientSecret` | Yes* | *(hardcoded POC value)* | Client secret value |
| `-OverwriteExisting` | No | `$false` | Overwrite an existing identifier for this device |
| `-Description` | No | `$env:COMPUTERNAME` | Description/note stored alongside the identifier in Intune |

> **Note:** The script ships with hardcoded default values for `TenantId`, `ClientId`, and `ClientSecret` for POC convenience. **Remove or replace these before any production or shared use.** Always pass credentials explicitly or source them from a secrets store.

---

## Usage

### Basic usage (pass credentials explicitly)

```powershell
.\Set-CorporateDeviceIdentifiers.ps1 `
    -TenantId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret "your-client-secret-here"
```

### Overwrite an existing identifier

```powershell
.\Set-CorporateDeviceIdentifiers.ps1 `
    -TenantId          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret      "your-client-secret-here" `
    -OverwriteExisting $true
```

### Dry run (WhatIf — no API call made)

```powershell
.\Set-CorporateDeviceIdentifiers.ps1 `
    -TenantId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret "your-client-secret-here" `
    -WhatIf
```

### Run via the included CMD launcher

The `cmdline.cmd` wrapper launches the script using the hardcoded POC defaults:

```cmd
cmdline.cmd
```

---

## Deployment via Intune Remediation

This script can be deployed as an Intune **Remediation** (detection + remediation script pair) or as a **Platform Script** targeting devices that need to be registered.

- Run as: **SYSTEM** (ensure the machine account or a service account has internet access)
- Run in 64-bit PowerShell: **Yes**
- Enforce script signature check: depends on your tenant policy

---

## Notes

- The `importedDeviceIdentities` endpoint is currently **beta-only** (`/beta/...`) and subject to change.
- The identifier type `manufacturerModelSerial` does **not** require a hardware hash — this is the key advantage over traditional Autopilot registration.
- If Intune reports a failure after submission, check `enrollmentState` in the output — common causes are duplicate identifiers (use `-OverwriteExisting $true`) or insufficient app permissions.

---

## Security Warning

> Do **not** commit real client secrets to source control. The hardcoded defaults in this POC script are for local testing convenience only. Rotate any secrets that have been exposed and store credentials using a secrets manager or environment variables for any production use.
