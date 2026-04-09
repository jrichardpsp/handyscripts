#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the local machine's Manufacturer, Model, and Serial Number via WMI
    and registers it as a Corporate Device Identifier in Microsoft Intune
    using the Microsoft Graph API.

.DESCRIPTION
    This script is intended to run locally on a device (e.g. via Intune
    remediation, a startup script, or a deployment tool). It:

      1. Collects hardware info from the local machine using WMI
      2. Authenticates to Microsoft Graph using an App Registration
         (client credentials / client secret flow)
      3. Submits the device as a Corporate Device Identifier to:
         POST /beta/deviceManagement/importedDeviceIdentities/importDeviceIdentityList

    The identifier type used is "manufacturerModelSerial", which is the format
    required for Windows Autopilot Device Preparation (no hardware hash needed).

.PARAMETER TenantId
    Your Azure AD / Entra ID Tenant ID (GUID).

.PARAMETER ClientId
    The App Registration (Client) ID. The app must have the following
    Application permission (not Delegated) with admin consent granted:
      - DeviceManagementServiceConfig.ReadWrite.All

.PARAMETER ClientSecret
    The client secret value for the App Registration.

.PARAMETER OverwriteExisting
    If $true, an existing identifier record for this device will be
    overwritten. Defaults to $false.

.PARAMETER Description
    Optional description/note stored alongside the identifier in Intune.
    Defaults to the local computer name.

.EXAMPLE
    .\Set-CorporateDeviceIdentifiers.ps1 `
        -TenantId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-client-secret-here"

.EXAMPLE
    # Dry run — shows what would be submitted without calling the API
    .\Set-CorporateDeviceIdentifiers.ps1 `
        -TenantId "..." -ClientId "..." -ClientSecret "..." -WhatIf

.NOTES
    REQUIRED APP REGISTRATION API PERMISSIONS (Application, not Delegated):
      - DeviceManagementServiceConfig.ReadWrite.All

    The importedDeviceIdentities endpoint is currently beta-only.
    Run as local Administrator (required for WMI BIOS serial number access).
    Requires internet access to login.microsoftonline.com and graph.microsoft.com.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret = "your-client-secret-here",

    [Parameter(Mandatory = $false)]
    [bool]$OverwriteExisting = $false,

    [Parameter(Mandatory = $false)]
    [string]$Description = $env:COMPUTERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region ──────────────────────────────────────────────────────────────
#  FUNCTIONS
#endregion ──────────────────────────────────────────────────────────

function Get-LocalHardwareInfo {
    <#
    .SYNOPSIS
        Collects Manufacturer, Model, and Serial Number from the local machine via WMI.
    #>

    Write-Verbose "Querying Win32_ComputerSystem for Manufacturer and Model..."
    $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop

    Write-Verbose "Querying Win32_BIOS for SerialNumber..."
    $bios = Get-WmiObject -Class Win32_BIOS -ErrorAction Stop

    $info = [PSCustomObject]@{
        Manufacturer = $cs.Manufacturer.Trim()
        Model        = $cs.Model.Trim()
        SerialNumber = $bios.SerialNumber.Trim()
    }

    if (-not $info.Manufacturer) { throw "WMI returned an empty Manufacturer from Win32_ComputerSystem." }
    if (-not $info.Model)        { throw "WMI returned an empty Model from Win32_ComputerSystem." }
    if (-not $info.SerialNumber) { throw "WMI returned an empty SerialNumber from Win32_BIOS." }

    return $info
}

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
        Obtains an OAuth 2.0 access token from Azure AD using client credentials.
    #>
    param (
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }

    Write-Verbose "Requesting access token from $tokenUri"

    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Method POST -Body $body `
                        -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        return $response.access_token
    }
    catch {
        throw "Failed to obtain access token. Verify TenantId, ClientId, and ClientSecret.`nError: $_"
    }
}

function Submit-CorporateDeviceIdentifier {
    <#
    .SYNOPSIS
        Posts the local device's corporate identifier to Intune via Graph API.
    #>
    param (
        [hashtable]$Headers,
        [string]$IdentifierString,
        [string]$Description,
        [bool]$Overwrite
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/importedDeviceIdentities/importDeviceIdentityList"

    $bodyObject = @{
        overwriteImportedDeviceIdentities = $Overwrite
        importedDeviceIdentities          = @(
            @{
                "@odata.type"              = "#microsoft.graph.importedDeviceIdentity"
                importedDeviceIdentifier   = $IdentifierString
                importedDeviceIdentityType = "manufacturerModelSerial"
                platform                   = "windows"
                description                = $Description
            }
        )
    }

    $bodyJson = $bodyObject | ConvertTo-Json -Depth 5

    Write-Verbose "POST $uri"
    Write-Verbose "Body: $bodyJson"

    $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $Headers `
                    -Body $bodyJson -ContentType "application/json" -ErrorAction Stop

    return $response.value
}

#endregion

#region ──────────────────────────────────────────────────────────────
#  MAIN
#endregion ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Intune Corporate Device Identifier Tool  " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Collect local hardware info via WMI ───────────────────
Write-Host "[1/3] Reading hardware info from local machine via WMI..." -ForegroundColor Yellow

try {
    $hw = Get-LocalHardwareInfo
}
catch {
    Write-Error "Could not retrieve hardware information: $_"
    exit 1
}

# Identifier string format required by the API: MANUFACTURER,MODEL,SERIALNUMBER
$identifierString = "$($hw.Manufacturer),$($hw.Model),$($hw.SerialNumber)"

Write-Host "      Manufacturer : $($hw.Manufacturer)" -ForegroundColor Gray
Write-Host "      Model        : $($hw.Model)"        -ForegroundColor Gray
Write-Host "      Serial Number: $($hw.SerialNumber)" -ForegroundColor Gray
Write-Host "      Identifier   : $identifierString"   -ForegroundColor White

# ── Step 2: Authenticate to Microsoft Graph ───────────────────────
Write-Host "[2/3] Authenticating with Microsoft Graph..." -ForegroundColor Yellow

try {
    $accessToken = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
}
catch {
    Write-Error $_
    exit 1
}

$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

Write-Host "      Authentication successful." -ForegroundColor Green

# ── Step 3: Submit identifier to Intune ───────────────────────────
Write-Host "[3/3] Submitting Corporate Device Identifier to Intune..." -ForegroundColor Yellow

if ($PSCmdlet.ShouldProcess($identifierString, "Submit to Intune importDeviceIdentityList")) {
    try {
        $results = Submit-CorporateDeviceIdentifier `
                        -Headers          $headers `
                        -IdentifierString $identifierString `
                        -Description      $Description `
                        -Overwrite        $OverwriteExisting

        $result = $results | Select-Object -First 1

        if ($result.status -eq $true) {
            Write-Host "      Successfully registered." -ForegroundColor Green
        }
        else {
            Write-Warning "Identifier submitted but Intune reported a failure."
            Write-Warning "Enrollment state returned: $($result.enrollmentState)"
        }
    }
    catch {
        Write-Error "Failed to submit identifier to Intune: $_"
        exit 1
    }
}
else {
    # -WhatIf path
    Write-Host "      WhatIf: Would submit '$identifierString' to Intune." -ForegroundColor DarkYellow
}

# ── Summary ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Computer Name : $env:COMPUTERNAME"
Write-Host "  Manufacturer  : $($hw.Manufacturer)"
Write-Host "  Model         : $($hw.Model)"
Write-Host "  Serial Number : $($hw.SerialNumber)"
Write-Host "  Identifier    : $identifierString"
Write-Host ""
Write-Host "Done." -ForegroundColor Green
