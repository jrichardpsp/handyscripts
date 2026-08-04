#Requires -RunAsAdministrator

<#
.SYNOPSIS
    PowerSyncPro Workgroup Kickoff Script - parameter driven, no CSV. Supports N:N user mappings.

.DESCRIPTION
    Argument-driven variant of WorkgroupMigrator.ps1.

    - Designed for WORKGROUP machines only (not domain-joined).
    - Supports one OR MANY source-to-target user mappings on a single machine.
    - Creates a SID translation table file and places it in the Runbook folder.
    - Stamps required registry values and restarts the Migration Agent service
      to force a refresh of runbook data.
    - Downloads the Migration Agent MSI from the PowerSyncPro CDN by default,
      or uses a locally staged MSI with -UseLocalMsi.

    Differences from WorkgroupMigrator.ps1
    - No mig_db.csv is read. All per-device values are supplied as parameters,
      which suits RMM platforms that can template variables per endpoint.
    - computer_name is no longer needed: the row lookup is gone and the local
      hostname is used directly (override with -ComputerName if required).
    - target_upn is no longer required. It is accepted as an optional value and
      is only echoed to the transcript for operator traceability.
    - Environment-specific values (domain, server URL, PSK, runbook GUID) have no
      defaults and MUST be supplied. There are no placeholder values to forget.

    ------------------------------------------------------------------
    SUPPLYING USER MAPPINGS
    ------------------------------------------------------------------
    There are three mutually exclusive ways to define the migration mapping.
    PowerShell enforces that exactly one is used.

    1) Single pair by local username (-LocalUsername + -TargetIdentity)

         -LocalUsername "Peter" -TargetIdentity "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    2) Single pair by source SID (-LocalUserSid + -TargetIdentity)

         -LocalUserSid "S-1-5-21-111-222-333-1001" -TargetIdentity "3f2504e0-..."

       Use this when the local account has been renamed or deleted but the
       profile SID is known.

    3) Many pairs (-Mapping)

         -Mapping "Peter=3f2504e0-4f89-11d3-9a0c-0305e82c3301",
                  "Miles=7c9e6679-7425-40de-944b-e07fc1f90ae7",
                  "S-1-5-21-111-222-333-1005=9b2a1f3c-1111-2222-3333-444455556666"

       Each entry is "<source>=<target>":
         <source>  Local username OR a source SID. Anything starting with "S-1-"
                   is treated as a SID and used as-is; anything else is looked up
                   as a local account name via Win32_UserAccount.
         <target>  Entra ObjectId GUID or AD SID, per -TargetIdentityType.

       Whitespace around the "=" is trimmed. Blank entries are skipped.
       Duplicate source identities are a hard error (they would collide as
       duplicate keys in the translation table). Duplicate targets produce a
       warning only, since fan-in is occasionally intentional.

       The resulting translation table contains every pair:
         {"S-1-5-21-...-1001":"S-1-12-1-a-b-c-d","S-1-5-21-...-1002":"S-1-12-1-e-f-g-h"}

    ------------------------------------------------------------------
    MSI ACQUISITION
    ------------------------------------------------------------------
    The MSI is only needed when the Migration Agent service is absent, so it is
    acquired lazily - machines that already have the agent never download it.

      Default          Download the self-contained MSI from -MsiUrl (PSP CDN)
                       into -BasePath.
      -UseLocalMsi     Skip the download and use -LocalMsiPath, which defaults to
                       <BasePath>\PSPMigrationAgentInstallerSelfContained.msi
                       (the file an RMM would have staged alongside this script).

.PARAMETER LocalUsername
    Single-pair mode. Local workgroup account name to migrate FROM (example: "Peter").
    Resolved to a SID via Win32_UserAccount.

.PARAMETER LocalUserSid
    Single-pair mode. Source SID to migrate FROM, supplied directly. Use when the
    local account has been renamed/removed but the profile SID is known.

.PARAMETER TargetIdentity
    Single-pair mode. Entra ObjectId GUID (-TargetIdentityType Entra) or an AD SID
    string (-TargetIdentityType AD) to migrate TO.

.PARAMETER Mapping
    Multi-pair mode. One or more "<source>=<target>" strings. See the description
    above for the full format.

.PARAMETER TargetIdentityType
    Entra (default) or AD. Controls how every target value is interpreted.

.PARAMETER RunbookGuid
    Required. The runbook GUID. The translation table is copied into
    C:\ProgramData\Declaration Software\Migration Agent\<GUID>\.

.PARAMETER DomainName
    Required. Written to the agent registry key as part of kickoff. For workgroup
    migrations this is typically the dummy domain holding the AD object for the
    workstation.

.PARAMETER PspServerUrl
    Required. PSP server agent endpoint, including /Agent.

.PARAMETER PspPsk
    Required. Pre-shared key from the PSP server.

.PARAMETER UseLocalMsi
    Use a locally staged MSI instead of downloading from the CDN.

.PARAMETER LocalMsiPath
    Path to the staged MSI when -UseLocalMsi is set.
    Defaults to <BasePath>\PSPMigrationAgentInstallerSelfContained.msi.

.PARAMETER MsiUrl
    Download source for the MSI. Defaults to the PowerSyncPro CDN current build.

.PARAMETER TargetUpn
    Optional. Not used for the migration itself; logged for traceability.
    Only meaningful in single-pair mode.

.EXAMPLE
    .\WorkgroupMigrator_Args.ps1 -LocalUsername "Peter" `
        -TargetIdentity "3f2504e0-4f89-11d3-9a0c-0305e82c3301" `
        -RunbookGuid "d73976d7-d004-425f-8163-08de576995ae" `
        -DomainName "dummy.local" `
        -PspServerUrl "https://psp.contoso.com/Agent" -PspPsk "<psk>"

    Single user, MSI downloaded from the CDN if the agent is missing.

.EXAMPLE
    .\WorkgroupMigrator_Args.ps1 `
        -Mapping "Peter=3f2504e0-4f89-11d3-9a0c-0305e82c3301","Miles=7c9e6679-7425-40de-944b-e07fc1f90ae7" `
        -RunbookGuid "d73976d7-d004-425f-8163-08de576995ae" `
        -DomainName "dummy.local" `
        -PspServerUrl "https://psp.contoso.com/Agent" -PspPsk "<psk>"

    Shared machine with two local users migrating to two Entra identities.

.EXAMPLE
    .\WorkgroupMigrator_Args.ps1 `
        -Mapping "S-1-5-21-111-222-333-1001=S-1-5-21-999-888-777-1105" `
        -TargetIdentityType AD `
        -RunbookGuid "d73976d7-d004-425f-8163-08de576995ae" `
        -DomainName "dummy.local" `
        -PspServerUrl "https://psp.contoso.com/Agent" -PspPsk "<psk>" `
        -UseLocalMsi

    AD target SIDs, orphaned source profile, MSI staged locally by the RMM.

.NOTES
    Date        January/2026
    Disclaimer  This script is provided 'AS IS'. No warranty is provided either expressed or implied.
                Declaration Software Ltd cannot be held responsible for any misuse of the script.
    Version     0.2
    Updated     Argument-driven variant of WorkgroupMigrator.ps1, multi-pair + CDN download - JRR
    Copyright   (c) 2026 Declaration Software

    Layout warning: keep exactly one blank line between the #Requires statement and
    this help block, with no # comment lines in between. If #Requires is immediately
    followed by the help block - or separated from it only by comments - Get-Help
    silently discards this help and displays generated syntax instead.
#>

[CmdletBinding(DefaultParameterSetName = "SinglePairByName")]
param(
    # ---- Source identity: single pair by local account name ----

    [Parameter(Mandatory = $true, ParameterSetName = "SinglePairByName")]
    [ValidateNotNullOrEmpty()]
    [string]$LocalUsername,

    # ---- Source identity: single pair by SID ----

    [Parameter(Mandatory = $true, ParameterSetName = "SinglePairBySid")]
    [ValidateNotNullOrEmpty()]
    [string]$LocalUserSid,

    # Target for the single-pair sets. Entra: GUID ObjectId. AD: SID string.
    [Parameter(Mandatory = $true, ParameterSetName = "SinglePairByName")]
    [Parameter(Mandatory = $true, ParameterSetName = "SinglePairBySid")]
    [ValidateNotNullOrEmpty()]
    [string]$TargetIdentity,

    # ---- Source + target: many pairs ----

    # "<source>=<target>" entries. Source may be a local username or a source SID.
    [Parameter(Mandatory = $true, ParameterSetName = "MultiPair")]
    [ValidateNotNullOrEmpty()]
    [string[]]$Mapping,

    # ---- Target interpretation ----

    [Parameter(Mandatory = $false)]
    [ValidateSet("Entra","AD")]
    [string]$TargetIdentityType = "Entra",

    # Not used by the migration. Logged only, for operator traceability.
    [Parameter(Mandatory = $false, ParameterSetName = "SinglePairByName")]
    [Parameter(Mandatory = $false, ParameterSetName = "SinglePairBySid")]
    [string]$TargetUpn,

    # ---- Environment configuration (no defaults - must be supplied) ----

    # Runbook folder under C:\ProgramData\Declaration Software\Migration Agent\<GUID>\
    # See the PSP KB for how to retrieve this from the web interface.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RunbookGuid,

    # Written to the agent registry key as part of kickoff.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    # PSP server agent endpoint, including /Agent.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PspServerUrl,

    # Pre-shared key from the PSP server.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PspPsk,

    # ---- MSI acquisition ----

    # By default the MSI is pulled from the PowerSyncPro CDN when the agent is missing.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$MsiUrl = "https://downloads.powersyncpro.com/current/PSPMigrationAgentInstallerSelfContained.msi",

    # Set to use a locally staged MSI instead of downloading.
    [Parameter(Mandatory = $false)]
    [switch]$UseLocalMsi,

    # Staged MSI path for -UseLocalMsi. Empty means <BasePath>\<CDN filename>.
    [Parameter(Mandatory = $false)]
    [string]$LocalMsiPath,

    # ---- Paths / service ----

    # Registry ComputerName stamp. Defaults to this machine's hostname.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName = $env:COMPUTERNAME,

    # Working directory for the transcript, translation table and downloaded MSI.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$BasePath = "C:\Temp",

    # Windows service name (not display name) for the PowerSyncPro Migration Agent.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceName = "PowerSyncPro Migration Agent"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------
# INPUT NORMALIZATION
# -----------------------
# These two helpers are defined here, ahead of the main helper block, because
# parameter normalization has to run before DERIVED CONFIGURATION builds paths
# out of -BasePath.
#
# Stray whitespace is the motivating case. Copying a GUID out of the PSP web
# interface or an RMM variable field very easily picks up a leading space, and
# -RunbookGuid is used directly as a folder name: " <guid>" would create a
# folder the agent never reads, while this script still reported success.

function ConvertTo-CanonicalGuid {
<#
.SYNOPSIS
    Validates a GUID string and returns it in canonical dashed (D) form.

.DESCRIPTION
    Trims surrounding whitespace, then accepts any format Guid.TryParse
    understands:
      D  d73976d7-d004-425f-8163-08de576995ae
      N  d73976d7d004425f816308de576995ae
      B  {d73976d7-d004-425f-8163-08de576995ae}
      P  (d73976d7-d004-425f-8163-08de576995ae)

    Always returns the D form, which is the shape the Migration Agent uses for
    its runbook folder names. Normalizing means "{GUID}" or the no-dash form
    still lands in the correct folder rather than creating a new bogus one.

.PARAMETER Value
    The candidate GUID string.

.PARAMETER Label
    Used verbatim in error and warning text. Callers pass either a parameter name
    ("-RunbookGuid") or a description ("Target identity for 'Peter'"), because in
    -Mapping mode the value did not come from a parameter of its own.

.OUTPUTS
    String GUID in D form.

.NOTES
    - Throws with the offending value quoted, so a stray space is visible in the log.
    - The normalization warning uses a case-insensitive comparison, so an uppercase
      GUID is accepted quietly; only whitespace or a format change is reported.
#>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw ($Label + " is blank. A GUID is required.")
    }

    $trimmed = $Value.Trim()

    # PS 5.1 requires the [ref] target to be a Guid, not $null.
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($trimmed, [ref]$guid)) {
        throw ($Label + " is not a valid GUID: '" + $Value + "'")
    }

    $canonical = $guid.ToString("D")

    # -ne is case-insensitive in PowerShell, so "3F25..." vs "3f25..." does not warn.
    if ($canonical -ne $Value) {
        Write-Warning ($Label + " '" + $Value + "' normalized to '" + $canonical + "'.")
    }

    return $canonical
}

function ConvertTo-TrimmedValue {
<#
.SYNOPSIS
    Trims surrounding whitespace from a parameter value and reports if it changed.

.DESCRIPTION
    Accidental leading/trailing whitespace in a pasted value is silent and can be
    very hard to spot in a log. This trims it and emits a warning so the change is
    visible in the transcript.

.PARAMETER Value
    The value to trim.

.PARAMETER Name
    Parameter name used in the warning message.

.PARAMETER DoNotEcho
    Suppress the value in the warning text. Used for secrets such as the PSK.

.OUTPUTS
    Trimmed string.
#>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$false)][switch]$DoNotEcho
    )

    if ($null -eq $Value) { return $Value }

    $trimmed = $Value.Trim()

    if ($trimmed -ne $Value) {
        if ($DoNotEcho) {
            Write-Warning ("-" + $Name + " had leading/trailing whitespace, which was removed.")
        } else {
            Write-Warning ("-" + $Name + " had leading/trailing whitespace, which was removed. Using '" + $trimmed + "'.")
        }
    }

    return $trimmed
}

# -RunbookGuid is used verbatim as a directory name, so it gets full GUID
# validation rather than a trim. A typo here otherwise fails silently.
$RunbookGuid = ConvertTo-CanonicalGuid -Value $RunbookGuid -Label "-RunbookGuid"

# The remaining values are free-form, so whitespace is all that can be safely
# corrected. PSK is trimmed without echoing its value.
$DomainName   = ConvertTo-TrimmedValue -Value $DomainName   -Name "DomainName"
$PspServerUrl = ConvertTo-TrimmedValue -Value $PspServerUrl -Name "PspServerUrl"
$PspPsk       = ConvertTo-TrimmedValue -Value $PspPsk       -Name "PspPsk" -DoNotEcho
$ComputerName = ConvertTo-TrimmedValue -Value $ComputerName -Name "ComputerName"
$BasePath     = ConvertTo-TrimmedValue -Value $BasePath     -Name "BasePath"
$ServiceName  = ConvertTo-TrimmedValue -Value $ServiceName  -Name "ServiceName"
$MsiUrl       = ConvertTo-TrimmedValue -Value $MsiUrl       -Name "MsiUrl"

if (-not [string]::IsNullOrWhiteSpace($LocalMsiPath)) {
    $LocalMsiPath = ConvertTo-TrimmedValue -Value $LocalMsiPath -Name "LocalMsiPath"
}

# -----------------------
# DERIVED CONFIGURATION
# -----------------------

# Transcript logging output location.
$TranscriptName = "Migration_Kickoff_Log"
$TranscriptPath = Join-Path -Path $BasePath -ChildPath ($TranscriptName + ".log")

# Fixed locations used by the agent.
$RegKey           = "HKLM:\SOFTWARE\Declaration Software\Migration Agent"
$MaDataDirectory  = "C:\ProgramData\Declaration Software\Migration Agent"
$RunbooksFileName = "Runbooks.json"

# Translation table file created by this script.
$TranslationFileName = "TranslationTable.json"
$TranslationJsonPath = Join-Path -Path $BasePath -ChildPath $TranslationFileName

# MSI install log (only written if installation occurs).
$MsiInstallLogPath = Join-Path -Path $BasePath -ChildPath "PSPAgent_Install.log"

# ASCII logo shown at runtime for quick operator confirmation.
$asciiLogo=@"
 ____                        ____                   ____
|  _ \ _____      _____ _ __/ ___| _   _ _ __   ___|  _ \ _ __ ___
| |_) / _ \ \ /\ / / _ \ '__\___ \| | | | '_ \ / __| |_) | '__/ _ \
|  __/ (_) \ V  V /  __/ |   ___) | |_| | | | | (__|  __/| | | (_) |
|_|   \___/ \_/\_/ \___|_|  |____/ \__, |_| |_|\___|_|   |_|  \___/
                                   |___/
"@

# -----------------------
# HELPER FUNCTIONS
# -----------------------

function Write-Info {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ("[INFO] " + $Message)
}

function Write-Warn {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Warning $Message
}

function Assert-FileExists {
<#
.SYNOPSIS
    Validates that a file exists at a given path.

.DESCRIPTION
    Throws a terminating error if the path does not exist.
    This is used as a "fail fast" check before operations that require the file.

.PARAMETER Path
    The full file path to validate.

.PARAMETER FriendlyName
    Friendly description of the file for error messages (example: "PSP MSI").

.EXAMPLE
    Assert-FileExists -Path "C:\Temp\PSPMigrationAgentInstaller.msi" -FriendlyName "PSP MSI"
#>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$FriendlyName
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ($FriendlyName + " was not found: " + $Path)
    }
}

function Assert-WorkgroupOnly {
<#
.SYNOPSIS
    Hard guardrail: ensures the machine is not domain joined.

.DESCRIPTION
    This script is intended exclusively for workgroup machines. If the machine is
    domain-joined, the script throws and stops immediately.

    Uses Win32_ComputerSystem.PartOfDomain for determination.

.NOTES
    - This is a business/process requirement (not a technical limitation).
    - If you ever need to support domain-joined, remove/modify this function.
#>
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        throw ("This script is for WORKGROUP machines only. This machine is domain-joined (Domain: " + $cs.Domain + "). Aborting.")
    }
}

function Get-LocalUserSid {
<#
.SYNOPSIS
    Returns the SID for a local (workgroup) user account by username.

.DESCRIPTION
    Uses Win32_UserAccount with a filter:
      LocalAccount=True AND Name='<username>'

    This avoids partial matches and avoids returning domain accounts.

.PARAMETER LocalUserName
    The local username to look up (example: "bob").

.OUTPUTS
    String SID (example: "S-1-5-21-...").

.NOTES
    - Throws if the local account is not found.
    - Warns and returns the first result if multiple results are found (unexpected).
#>
    param([Parameter(Mandatory=$true)][string]$LocalUserName)

    # Escape single quotes so the WMI filter string remains valid.
    $escaped = $LocalUserName.Replace("'", "''")
    $acct = Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + $escaped + "'")

    if ($null -eq $acct) {
        throw ("Local workgroup account '" + $LocalUserName + "' not found (LocalAccount=True). Aborting.")
    }

    if (@($acct).Count -gt 1) {
        Write-Warn ("Multiple local accounts matched '" + $LocalUserName + "'. Using the first.")
        $acct = @($acct)[0]
    }

    return $acct.SID
}

function Assert-SidFormat {
<#
.SYNOPSIS
    Validates that a string is a valid Windows SID.

.DESCRIPTION
    Attempts to construct a System.Security.Principal.SecurityIdentifier.
    If construction fails, the SID string is invalid and the function throws.

.PARAMETER Sid
    SID string to validate (example: "S-1-5-21-...").

.NOTES
    - This validates format and basic SID correctness.
    - It does not validate that the SID exists on the system.
#>
    param([Parameter(Mandatory=$true)][string]$Sid)
    try {
        $null = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    } catch {
        throw ("Invalid SID format: '" + $Sid + "'")
    }
}

function Convert-EntraObjectIdToSid {
<#
.SYNOPSIS
    Converts an Entra ID objectId (GUID) into its corresponding SID format.

.DESCRIPTION
    Entra object IDs are GUIDs. Windows represents these cloud identities as
    SIDs in the form:

      S-1-12-1-<UInt32>-<UInt32>-<UInt32>-<UInt32>

    This function:
      - Validates the input is a GUID
      - Converts GUID -> byte array
      - Interprets bytes as four UInt32 values
      - Constructs the S-1-12-1-* SID string

.PARAMETER ObjectId
    Entra user objectId as a GUID string.

.OUTPUTS
    String SID in the S-1-12-1-* form.

.NOTES
    - Throws if ObjectId is not a valid GUID.
#>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$ObjectId,
        [Parameter(Mandatory=$false)][string]$Label = "Target identity"
    )

    # Shared validation: trims, accepts D/N/B/P forms, throws on anything else.
    $canonical = ConvertTo-CanonicalGuid -Value $ObjectId -Label $Label

    $guid = [Guid]$canonical

    $guidBytes = $guid.ToByteArray()
    $uintArray = New-Object 'UInt32[]' 4
    [Buffer]::BlockCopy($guidBytes, 0, $uintArray, 0, 16)

    return ("S-1-12-1-" + $uintArray[0] + "-" + $uintArray[1] + "-" + $uintArray[2] + "-" + $uintArray[3])
}

function Resolve-SourceSid {
<#
.SYNOPSIS
    Resolves a source identity string to a SID.

.DESCRIPTION
    Accepts either a source SID or a local account name and returns a validated SID.

    Detection rule: anything starting with "S-1-" is treated as a SID and used
    directly (after format validation). Anything else is looked up as a local
    account name through Win32_UserAccount.

    A local Windows account name cannot start with "S-1-", so this is unambiguous.

.PARAMETER Source
    Source SID or local username.

.OUTPUTS
    String SID.
#>
    param([Parameter(Mandatory=$true)][string]$Source)

    $s = $Source.Trim()

    if ($s -match '^[Ss]-1-') {
        Assert-SidFormat -Sid $s
        Write-Info ("Source SID supplied directly: " + $s)
        return $s
    }

    $sid = Get-LocalUserSid -LocalUserName $s
    Assert-SidFormat -Sid $sid
    Write-Info ("Local user '" + $s + "' SID: " + $sid)
    return $sid
}

function Resolve-TargetSid {
<#
.SYNOPSIS
    Resolves a target identity string to a SID according to the identity type.

.DESCRIPTION
    Entra: the value is a GUID ObjectId and is converted to an S-1-12-1-* SID.
    AD:    the value is already a SID string; it is validated and used directly.

.PARAMETER Target
    Entra ObjectId GUID or AD SID string.

.PARAMETER IdentityType
    "Entra" or "AD".

.PARAMETER Label
    Description of where this value came from, used in error text. In -Mapping mode
    this identifies which entry failed.

.OUTPUTS
    String SID.
#>
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][ValidateSet("Entra","AD")][string]$IdentityType,
        [Parameter(Mandatory=$false)][string]$Label = "Target identity"
    )

    $t = $Target.Trim()

    if ($IdentityType -eq "Entra") {
        $sid = Convert-EntraObjectIdToSid -ObjectId $t -Label $Label
        Assert-SidFormat -Sid $sid
        Write-Info ("Entra ObjectId '" + $t + "' converted to target SID: " + $sid)
        return $sid
    }

    Assert-SidFormat -Sid $t
    Write-Info ("AD target SID: " + $t)
    return $t
}

function ConvertFrom-MappingEntry {
<#
.SYNOPSIS
    Parses a single "<source>=<target>" mapping string.

.DESCRIPTION
    Splits on the first "=" only, so the target value is preserved verbatim even
    if it somehow contained a further "=". Both halves are trimmed and must be
    non-empty.

    Local Windows account names, SIDs and GUIDs never contain "=", so a single
    delimiter is unambiguous.

.PARAMETER Entry
    The raw mapping string (example: "Peter=3f2504e0-4f89-11d3-9a0c-0305e82c3301").

.OUTPUTS
    PSCustomObject with Source and Target string properties.
#>
    param([Parameter(Mandatory=$true)][string]$Entry)

    $idx = $Entry.IndexOf("=")
    if ($idx -lt 1) {
        throw ("Invalid -Mapping entry '" + $Entry + "'. Expected format: '<localUsernameOrSid>=<targetGuidOrSid>'.")
    }

    $source = $Entry.Substring(0, $idx).Trim()
    $target = $Entry.Substring($idx + 1).Trim()

    if ([string]::IsNullOrWhiteSpace($source)) {
        throw ("Invalid -Mapping entry '" + $Entry + "'. Source side is blank.")
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw ("Invalid -Mapping entry '" + $Entry + "'. Target side is blank.")
    }

    return [PSCustomObject]@{
        Source = $source
        Target = $target
    }
}

function New-TranslationJson {
<#
.SYNOPSIS
    Builds the translation table JSON from a list of SID pairs.

.DESCRIPTION
    Produces the flat object the Migration Agent expects:

      {"<sourceSid1>":"<targetSid1>","<sourceSid2>":"<targetSid2>"}

    The JSON is assembled by hand rather than with ConvertTo-Json so the output
    is deterministic, single-line and ordering-stable across PowerShell versions.
    SIDs are a constrained character set (S, digits, hyphens) so no escaping is
    required; they are validated by Assert-SidFormat before reaching this point.

.PARAMETER Pairs
    Array of objects with SourceSid and TargetSid properties.

.OUTPUTS
    Single-line JSON string.
#>
    param([Parameter(Mandatory=$true)][object[]]$Pairs)

    $parts = @()
    foreach ($p in $Pairs) {
        $parts += ('"' + $p.SourceSid + '":"' + $p.TargetSid + '"')
    }

    return ("{" + ($parts -join ",") + "}")
}

function Write-Utf8NoBomFile {
<#
.SYNOPSIS
    Writes text content to disk using UTF-8 encoding without a BOM.

.DESCRIPTION
    Uses .NET APIs to write the file as UTF-8 without a Byte Order Mark (BOM).
    This is often more compatible with parsers that treat a BOM as file content.

.PARAMETER Path
    Destination file path.

.PARAMETER Content
    Text content to write.

.NOTES
    - Overwrites the file if it exists.
    - UTF-8 without BOM is used intentionally.
#>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-PspMsi {
<#
.SYNOPSIS
    Returns a path to the Migration Agent MSI, downloading it if required.

.DESCRIPTION
    Two acquisition modes:

      Download (default) - fetches the self-contained MSI from the PSP CDN into
                           the destination folder. TLS 1.2 is force-enabled
                           because PS 5.1 on older builds still defaults to
                           TLS 1.0, which the CDN rejects.
      Local              - validates and returns an already-staged MSI path.

    A download writes to a .partial file first and only moves it into place on
    success, so an interrupted transfer can never leave a truncated MSI that a
    later run would try to install.

.PARAMETER UseLocal
    When set, use LocalPath instead of downloading.

.PARAMETER LocalPath
    Path to the staged MSI (used when UseLocal is set).

.PARAMETER Url
    Download source URL.

.PARAMETER DestinationFolder
    Folder to download into.

.OUTPUTS
    Full path to the MSI on disk.
#>
    param(
        [Parameter(Mandatory=$true)][bool]$UseLocal,
        [Parameter(Mandatory=$false)][string]$LocalPath,
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$DestinationFolder
    )

    if ($UseLocal) {
        Write-Info ("Using local MSI: " + $LocalPath)
        Assert-FileExists -Path $LocalPath -FriendlyName "PSP MSI (local)"
        return $LocalPath
    }

    # Name the download after the file in the URL so the on-disk name matches the CDN build.
    $fileName = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = "PSPMigrationAgentInstallerSelfContained.msi"
    }

    $destination = Join-Path -Path $DestinationFolder -ChildPath $fileName
    $partial     = $destination + ".partial"

    Write-Info ("Downloading MSI from: " + $Url)
    Write-Info ("Download destination: " + $destination)

    # PS 5.1 can default to TLS 1.0; enable TLS 1.2 explicitly for the CDN.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Warn ("Could not adjust TLS settings: " + $_.Exception.Message)
    }

    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    # Invoke-WebRequest progress rendering is extremely slow in PS 5.1 for large files.
    $previousProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    } catch {
        throw ("Failed to download MSI from '" + $Url + "': " + $_.Exception.Message)
    } finally {
        $ProgressPreference = $previousProgress
    }

    if (-not (Test-Path -LiteralPath $partial)) {
        throw ("Download reported success but no file was written: " + $partial)
    }

    $size = (Get-Item -LiteralPath $partial).Length
    if ($size -le 0) {
        Remove-Item -LiteralPath $partial -Force
        throw ("Downloaded MSI is empty: " + $Url)
    }

    # Only publish the final name once the transfer completed.
    Move-Item -LiteralPath $partial -Destination $destination -Force
    Write-Info ("Downloaded MSI (" + [math]::Round($size / 1MB, 1) + " MB): " + $destination)

    return $destination
}

function Ensure-PspAgentInstalled {
<#
.SYNOPSIS
    Ensures the PowerSyncPro Migration Agent service exists, installing if necessary.

.DESCRIPTION
    - Checks for the existence of the service by name.
    - If missing:
        * Acquires the MSI (CDN download or local staged file)
        * Runs msiexec with PSK and URL parameters
        * Logs install output to a file
        * Treats exit code 0 as success and 3010 as success (reboot required)
        * Waits up to 60 seconds for the service to appear after install

    MSI acquisition is deliberately inside this function: a machine that already
    has the agent never downloads anything.

.PARAMETER ServiceName
    The Windows service name to check.

.PARAMETER UseLocalMsi
    Use a staged MSI instead of downloading.

.PARAMETER LocalMsiPath
    Staged MSI path (used when UseLocalMsi is set).

.PARAMETER MsiUrl
    CDN/download URL for the MSI.

.PARAMETER DownloadFolder
    Folder to download the MSI into.

.PARAMETER PspServerUrl
    Agent endpoint URL passed to MSI.

.PARAMETER PspPsk
    PSK passed to MSI.

.PARAMETER InstallLogPath
    MSI log file path.

.NOTES
    - This function does not verify the service is "Running"; only that it exists.
    - Throwing here indicates install failure or missing service after install.
#>
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][bool]$UseLocalMsi,
        [Parameter(Mandatory=$false)][string]$LocalMsiPath,
        [Parameter(Mandatory=$true)][string]$MsiUrl,
        [Parameter(Mandatory=$true)][string]$DownloadFolder,
        [Parameter(Mandatory=$true)][string]$PspServerUrl,
        [Parameter(Mandatory=$true)][string]$PspPsk,
        [Parameter(Mandatory=$true)][string]$InstallLogPath
    )

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        Write-Info ("Service '" + $ServiceName + "' exists. Status: " + $svc.Status)
        return
    }

    Write-Info ("Service '" + $ServiceName + "' not found. Installing PSP Migration Agent...")

    $msiPath = Get-PspMsi `
        -UseLocal $UseLocalMsi `
        -LocalPath $LocalMsiPath `
        -Url $MsiUrl `
        -DestinationFolder $DownloadFolder

    $msiArgs = @(
        "/i", ('"' + $msiPath + '"'),
        ("PSK=" + $PspPsk),
        ("URL=" + $PspServerUrl),
        "/qn",
        "/l*v", ('"' + $InstallLogPath + '"')
    )

    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    Write-Info ("MSI install exit code: " + $p.ExitCode)

    # 3010 is a common MSI success code indicating a reboot is required to complete.
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw ("PSP Migration Agent install failed (msiexec exit code " + $p.ExitCode + "). See " + $InstallLogPath)
    }

    # MSI completion does not always mean the service is registered instantly.
    # Poll for the service for up to 60 seconds to avoid race conditions.
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    } while ($null -eq $svc -and (Get-Date) -lt $deadline)

    if ($null -eq $svc) {
        throw ("Service '" + $ServiceName + "' still not present after installation. Verify MSI install.")
    }

    Write-Info ("Service '" + $ServiceName + "' is present. Status: " + $svc.Status)
}

function Apply-TranslationAndRestartAgent {
<#
.SYNOPSIS
    Applies translation/registry settings and restarts the agent to force a refresh.

.DESCRIPTION
    This function performs the "kickoff" steps expected by the Migration Agent:

    1) Validate translation file exists.
    2) Stop the Migration Agent service.
    3) Ensure the agent registry key exists.
    4) Write DomainName and ComputerName into the agent registry key.
    5) Copy TranslationTable.json into the runbook GUID folder.
    6) Remove Runbooks.json to force the agent to rebuild/refresh on next start.
    7) Start the service and wait until it is Running.

.PARAMETER ServiceName
    Migration Agent Windows service name.

.PARAMETER RegKey
    Registry key path where agent settings are stored.

.PARAMETER DomainName
    Value written to the agent registry key.

.PARAMETER ComputerName
    Value written to the agent registry key.

.PARAMETER MaDataDirectory
    Agent data directory (ProgramData path).

.PARAMETER RunbookGuid
    Runbook GUID whose folder receives the translation table.

.PARAMETER TranslationJsonPath
    Full path to TranslationTable.json.

.PARAMETER RunbooksFileName
    Filename under MaDataDirectory to remove (Runbooks.json).

.NOTES
    - Stopping the service avoids races where the agent reads files while they are being updated.
    - Removing Runbooks.json is an intentional "force refresh" behavior.
#>
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$RegKey,
        [Parameter(Mandatory=$true)][string]$DomainName,
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][string]$MaDataDirectory,
        [Parameter(Mandatory=$true)][string]$RunbookGuid,
        [Parameter(Mandatory=$true)][string]$TranslationJsonPath,
        [Parameter(Mandatory=$true)][string]$RunbooksFileName
    )

    Assert-FileExists -Path $TranslationJsonPath -FriendlyName "Translation table JSON"

    Write-Info ("Stopping service '" + $ServiceName + "'...")
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { throw ("Service '" + $ServiceName + "' not found.") }

    if ($svc.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus("Stopped","00:00:30")
    }

    # Ensure registry key exists before writing values.
    if (-not (Test-Path -LiteralPath $RegKey)) {
        Write-Info ("Registry key not found, creating: " + $RegKey)
        New-Item -Path $RegKey -Force | Out-Null
    }

    # Stamp values used by the agent to understand current device context.
    Write-Info ("Setting registry values DomainName='" + $DomainName + "', ComputerName='" + $ComputerName + "'")
    Set-ItemProperty -Path $RegKey -Name "DomainName"   -Value $DomainName
    Set-ItemProperty -Path $RegKey -Name "ComputerName" -Value $ComputerName

    # Copy translation table into the Runbook GUID folder.
    # The agent reads this file when processing the runbook.
    $targetFolder = Join-Path -Path $MaDataDirectory -ChildPath $RunbookGuid

    if (-not (Test-Path -LiteralPath $targetFolder)) {
        Write-Info ("Creating runbook folder: " + $targetFolder)
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
    }

    $dest = Join-Path -Path $targetFolder -ChildPath ([IO.Path]::GetFileName($TranslationJsonPath))
    Write-Info ("Copying translation table to: " + $dest)
    Copy-Item -LiteralPath $TranslationJsonPath -Destination $dest -Force

    # Removing Runbooks.json forces the agent to refresh runbook state on startup.
    $runbookFilePath = Join-Path -Path $MaDataDirectory -ChildPath $RunbooksFileName
    if (Test-Path -LiteralPath $runbookFilePath) {
        Write-Info ("Removing: " + $runbookFilePath)
        Remove-Item -LiteralPath $runbookFilePath -Force
    } else {
        Write-Info ("Runbooks file not present (ok): " + $runbookFilePath)
    }

    # Restart the service and confirm it transitions to Running.
    Write-Info ("Starting service '" + $ServiceName + "'...")
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running","00:00:30")
    Write-Info "Service is running."
}

# -----------------------
# MAIN
# -----------------------
# Main execution is intentionally linear and "fail-fast":
#   1) Ensure required folders exist.
#   2) Confirm this is a workgroup machine.
#   3) Normalise the supplied mapping(s) into raw source/target pairs.
#   4) Resolve every pair to source SID + target SID, and check for collisions.
#   5) Write translation table JSON to BasePath.
#   6) Ensure agent is installed (download or local MSI if missing).
#   7) Apply translation file + registry settings and restart agent.

try {
    # Ensure BasePath exists.
    # Some RMM tools create it automatically, but do not rely on that.
    if (-not (Test-Path -LiteralPath $BasePath)) {
        New-Item -Path $BasePath -ItemType Directory -Force | Out-Null
    }

    # Start transcript early so any failures are captured in the log file.
    Start-Transcript -Append -LiteralPath $TranscriptPath | Out-Null
    Write-Info ("Transcript: " + $TranscriptPath)

    # Guardrail: do not allow execution on domain-joined machines.
    # This is a strict requirement for this workflow.
    Assert-WorkgroupOnly

    # Display the ASCII logo so it is obvious in RMM output what script ran.
    Write-Host $asciiLogo

    Write-Info ("ComputerName: " + $ComputerName)
    Write-Info ("TargetIdentityType: " + $TargetIdentityType)
    Write-Info ("Mode: " + $PSCmdlet.ParameterSetName)

    # Parameter normalization runs before the transcript is open, so any warning it
    # raised is console-only. Echo the effective runbook GUID here so the value that
    # actually gets used is always recorded in the log.
    Write-Info ("RunbookGuid: " + $RunbookGuid)

    # Default the local MSI path to the CDN filename staged in BasePath.
    if ([string]::IsNullOrWhiteSpace($LocalMsiPath)) {
        $LocalMsiPath = Join-Path -Path $BasePath -ChildPath "PSPMigrationAgentInstallerSelfContained.msi"
    }

    # ----- Step 3: normalise input into raw source/target pairs -----
    # Both single-pair sets and the multi-pair set converge on the same shape here,
    # so everything downstream only deals with a list of pairs.
    $rawPairs = @()

    if ($PSCmdlet.ParameterSetName -eq "MultiPair") {
        foreach ($entry in $Mapping) {
            # Tolerate blank array elements, which RMM variable templating can produce.
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $rawPairs += (ConvertFrom-MappingEntry -Entry $entry)
        }

        if ($rawPairs.Count -eq 0) {
            throw "-Mapping contained no usable entries."
        }
    }
    else {
        # Optional traceability value, single-pair mode only. Not used to build the translation.
        if (-not [string]::IsNullOrWhiteSpace($TargetUpn)) {
            Write-Info ("Target UPN: " + $TargetUpn)
        }

        $singleSource = $LocalUsername
        if ($PSCmdlet.ParameterSetName -eq "SinglePairBySid") {
            $singleSource = $LocalUserSid
        }

        $rawPairs += [PSCustomObject]@{
            Source = $singleSource
            Target = $TargetIdentity
        }
    }

    Write-Info ("Mappings supplied: " + $rawPairs.Count)

    # ----- Step 4: resolve each pair to SIDs and validate the set -----
    $pairs      = @()
    $seenSource = @{}
    $seenTarget = @{}

    foreach ($raw in $rawPairs) {
        $sourceSid = Resolve-SourceSid -Source $raw.Source
        $targetSid = Resolve-TargetSid -Target $raw.Target -IdentityType $TargetIdentityType `
                                       -Label ("Target identity for source '" + $raw.Source + "'")

        # A source mapped to itself is a no-op and almost always a parameter mistake.
        if ($sourceSid -ieq $targetSid) {
            throw ("Source and target SID are identical for '" + $raw.Source + "' ('" + $sourceSid + "'). Check the supplied parameters.")
        }

        # Duplicate source SIDs would collide as duplicate JSON keys: hard error.
        $sourceKey = $sourceSid.ToUpperInvariant()
        if ($seenSource.ContainsKey($sourceKey)) {
            throw ("Source identity '" + $raw.Source + "' resolves to SID '" + $sourceSid + "', which is already mapped. Each source may appear only once.")
        }
        $seenSource[$sourceKey] = $true

        # Two sources mapped to one target is unusual but occasionally intentional.
        $targetKey = $targetSid.ToUpperInvariant()
        if ($seenTarget.ContainsKey($targetKey)) {
            Write-Warn ("Target SID '" + $targetSid + "' is used by more than one source mapping.")
        }
        $seenTarget[$targetKey] = $true

        $pairs += [PSCustomObject]@{
            Source    = $raw.Source
            SourceSid = $sourceSid
            TargetSid = $targetSid
        }
    }

    # ----- Step 5: build and write the translation table -----
    # Format: {"<sourceSid>":"<targetSid>", ...}
    $translationJson = New-TranslationJson -Pairs $pairs

    # Write the translation table to a deterministic location (BasePath).
    # This avoids working-directory differences under various RMM execution contexts.
    Write-Utf8NoBomFile -Path $TranslationJsonPath -Content $translationJson
    Write-Info ("Translation table written (" + $pairs.Count + " mapping(s)): " + $TranslationJsonPath)
    Write-Info ("Translation JSON: " + $translationJson)

    # ----- Step 6: ensure the agent exists -----
    # If the service does not exist, acquire the MSI and install it.
    Ensure-PspAgentInstalled `
        -ServiceName $ServiceName `
        -UseLocalMsi ([bool]$UseLocalMsi) `
        -LocalMsiPath $LocalMsiPath `
        -MsiUrl $MsiUrl `
        -DownloadFolder $BasePath `
        -PspServerUrl $PspServerUrl `
        -PspPsk $PspPsk `
        -InstallLogPath $MsiInstallLogPath

    # ----- Step 7: apply translation/registry values and restart the agent -----
    # This forces the agent to refresh runbook state and pick up the new translation file.
    Apply-TranslationAndRestartAgent `
        -ServiceName $ServiceName `
        -RegKey $RegKey `
        -DomainName $DomainName `
        -ComputerName $ComputerName `
        -MaDataDirectory $MaDataDirectory `
        -RunbookGuid $RunbookGuid `
        -TranslationJsonPath $TranslationJsonPath `
        -RunbooksFileName $RunbooksFileName

    Write-Info "Migration kickoff completed successfully."
    exit 0
}
catch {
    # Any uncaught error results in a non-zero exit code for the RMM.
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    # Stop transcript if it was started. Ignore errors to avoid masking root causes.
    try { Stop-Transcript | Out-Null } catch { }
}
