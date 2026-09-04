<#
.SYNOPSIS
    Finds and removes Entra "shell" placeholder device objects and the stale Intune
    records that spawn them, left behind by Hybrid-to-Entra workstation migrations.

.DESCRIPTION
    For each hostname (given explicitly, or discovered with -ScanTenant), the script:
      1. Classifies every Entra device object:
           REAL   - trustType AzureAd (the live join)
           SHELL  - trustType null AND alternativeSecurityIds key decodes to the ASCII
                    GUID equal to its own deviceId (Intune-minted placeholder)
           ZOMBIE - trustType ServerAd coexisting with a REAL object (restored hybrid)
           OTHER  - anything else (left alone)
      2. Classifies every Intune managed device record:
           HEALTHY - azureADDeviceId matches a REAL object's deviceId
           STALE   - anything else (points at a shell, all-zeros, or nothing)
      3. Safety rails before any delete:
           - a REAL object must exist (or, with -IncludeOrphans, ONLY shells remain)
           - a STALE record is deleted only if a HEALTHY record exists or the stale
             record is older than -StaleAfterDays (default 7) - protects records still
             inside their post-enrollment mis-link window
           - a shell tied to a held record is also held (deleting it would re-mint)
           - hostnames with a HYBRID (ServerAd, no REAL) object are left alone entirely
           - ZOMBIE objects are reported, never deleted (they need the source-AD step
             or Entra Connect will just restore them again)
      4. Deletes in the order that avoids re-mints: STALE Intune records first, then
         SHELL objects, then (optionally) purges the shells from the recycle bin.

    Report-only by default. Add -Execute to act; add -Force to skip per-delete prompts.
    Every run writes a CSV report (see -ReportPath) with one row per object/record seen:
    its classification and the action taken (kept / would-delete / deleted /
    deleted+purged / held / skipped / zombie).

.EXAMPLE
    .\Remove-MigrationShells.ps1 -Hostname DEMO-PLUM11,DEMO-OTTER26 -TenantId <tenant>
    Report only.

.EXAMPLE
    .\Remove-MigrationShells.ps1 -Hostname DEMO-PLUM11 -TenantId <tenant> -Execute -PurgeRecycleBin

.EXAMPLE
    .\Remove-MigrationShells.ps1 -ScanTenant -TenantId <tenant>
    Discover every hostname in the tenant that has a shell object, report only.

.NOTES
    TIMING: wait ~24 hours after a migration before cleaning its machines. Earlier,
    the directory is still churning (restore race undecided, Intune enrollment
    mis-linked to the old deviceId) and everything gets held. Report mode is safe
    at any time; treat results for machines migrated today as provisional.
    Running with no parameters prints a quick-start guide instead of an error.
    -Execute requires -TenantId (prevents deleting in whatever tenant happens to be
    cached). -Force and -PurgeRecycleBin are ignored with a notice in report mode.
    Background on the debris this cleans: FINDINGS-BPRT.md / FINDINGS-PPKG.md in this
    folder, or the team writeup "The Restore Race".
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Help')]
param(
    [Parameter(ParameterSetName = 'ByHost', Mandatory = $true, Position = 0)]
    [string[]]$Hostname,

    [Parameter(ParameterSetName = 'Scan', Mandatory = $true)]
    [switch]$ScanTenant,

    [string]$TenantId,

    # Actually delete. Without this the script only reports.
    [switch]$Execute,

    # With -Execute: skip the per-deletion confirmation prompts.
    [switch]$Force,

    # After deleting shells, permanently remove them from the Entra recycle bin.
    [switch]$PurgeRecycleBin,

    # Also clean hostnames where ONLY shells and shell-linked stale records remain
    # (decommissioned machines). Hostnames with any REAL, HYBRID or ZOMBIE object are
    # never treated as orphans.
    [switch]$IncludeOrphans,

    # A stale Intune record is only deleted if a HEALTHY record exists for the hostname
    # OR its lastSyncDateTime is older than this many days (i.e. it cannot be a record
    # still inside its post-enrollment mis-link window).
    [int]$StaleAfterDays = 7,

    [string]$LogPath = (Join-Path $PSScriptRoot ('cleanup_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    # CSV report of every object/record seen, its classification and the action taken.
    [string]$ReportPath = (Join-Path $PSScriptRoot ('report_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

$ErrorActionPreference = 'Stop'
$ZeroGuid = '00000000-0000-0000-0000-000000000000'

# ---------------------------------------------------------------------------
# Guardrails: friendly guidance instead of parameter errors
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Help') {
    Write-Host ''
    Write-Host 'Remove-MigrationShells - cleans up Entra/Intune debris left by PSP migrations' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Tell it WHAT to look at (pick one):'
    Write-Host '  -Hostname <name>[,<name>...]   specific machine(s)'
    Write-Host '  -ScanTenant                    every hostname in the tenant with a shell object'
    Write-Host ''
    Write-Host 'It always starts safe: without -Execute nothing is deleted, you just get a'
    Write-Host 'report (console + CSV) of what WOULD happen.'
    Write-Host ''
    Write-Host 'Typical workflow:' -ForegroundColor Yellow
    Write-Host '  1. .\Remove-MigrationShells.ps1 -ScanTenant -IncludeOrphans -TenantId <tenant>'
    Write-Host '  2. Review the report_<timestamp>.csv it writes'
    Write-Host '  3. .\Remove-MigrationShells.ps1 -ScanTenant -IncludeOrphans -TenantId <tenant> -Execute -Force -PurgeRecycleBin'
    Write-Host ''
    Write-Host 'Other switches:'
    Write-Host '  -Execute          actually delete (prompts per object unless -Force)'
    Write-Host '  -Force            with -Execute: no per-delete prompts'
    Write-Host '  -PurgeRecycleBin  also hard-delete removed shells from the Entra recycle bin'
    Write-Host '  -IncludeOrphans   include decommissioned machines (only shells remain)'
    Write-Host '  -StaleAfterDays   age gate for deleting a stale record with no healthy sibling (default 7)'
    Write-Host '  -TenantId         tenant to connect to (REQUIRED with -Execute)'
    Write-Host ''
    Write-Host 'Full help: Get-Help .\Remove-MigrationShells.ps1 -Detailed'
    Write-Host ''
    return
}
if ($Execute -and -not $TenantId) {
    Write-Host ''
    Write-Host 'STOP: -Execute requires -TenantId so deletions cannot land in the wrong tenant.' -ForegroundColor Red
    Write-Host 'Re-run with -TenantId <your tenant id or domain>. Report mode works without it.' -ForegroundColor Red
    Write-Host ''
    return
}
if ($Force -and -not $Execute) {
    Write-Host 'NOTE: -Force only matters with -Execute; continuing in report-only mode.' -ForegroundColor Yellow
}
if ($PurgeRecycleBin -and -not $Execute) {
    Write-Host 'NOTE: -PurgeRecycleBin only matters with -Execute; continuing in report-only mode.' -ForegroundColor Yellow
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '{0:u}  {1}' -f (Get-Date), $Message
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogPath -Value $line
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
$requiredScopes = @(
    'Device.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'Directory.ReadWrite.All'
)
$ctx = Get-MgContext
$needConnect = ($null -eq $ctx)
if (-not $needConnect -and $TenantId -and $ctx.TenantId -ne $TenantId) { $needConnect = $true }
if (-not $needConnect) {
    $missing = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
    if ($missing) { $needConnect = $true }
}
if ($needConnect) {
    $p = @{ Scopes = $requiredScopes; NoWelcome = $true }
    if ($TenantId) { $p.TenantId = $TenantId }
    Connect-MgGraph @p
    $ctx = Get-MgContext
}
$modeText = 'REPORT ONLY'
if ($Execute) { $modeText = 'EXECUTE' }
if ($Execute -and $Force) { $ConfirmPreference = 'None'; $modeText = 'EXECUTE (FORCE - no prompts)' }
Write-Log ("Tenant {0} as {1}  Mode: {2}" -f $ctx.TenantId, $ctx.Account, $modeText) 'Cyan'
$script:reportRows = @()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-GraphCollection {
    param([string]$Uri)
    $items = @()
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($resp.value) { $items += $resp.value }
        $next = $resp.'@odata.nextLink'
    }
    return $items
}

function Test-ShellFingerprint {
    # A shell's altSecId key is base64 of the ASCII GUID string that equals its deviceId.
    param($Device)
    if ($null -ne $Device.trustType) { return $false }
    if (-not $Device.alternativeSecurityIds) { return $false }
    foreach ($asid in $Device.alternativeSecurityIds) {
        try {
            $bytes = [Convert]::FromBase64String($asid.key)
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            if ($text -match '^[0-9a-fA-F\-]{36}$' -and $text -eq $Device.deviceId) { return $true }
        } catch { }
    }
    return $false
}

function Get-HostnameAssessment {
    param([string]$Name)
    $escaped = $Name.Replace("'", "''")
    $entra  = Get-GraphCollection -Uri ("beta/devices?`$filter=displayName eq '$escaped'&`$select=id,deviceId,displayName,trustType,alternativeSecurityIds,onPremisesSyncEnabled,hostnames,createdDateTime")
    $intune = Get-GraphCollection -Uri ("beta/deviceManagement/managedDevices?`$filter=deviceName eq '$escaped'&`$select=id,deviceName,azureADDeviceId,deviceEnrollmentType,enrolledDateTime,lastSyncDateTime,complianceState")

    $classified = @()
    foreach ($d in $entra) {
        $class = 'OTHER'
        if ($d.trustType -eq 'AzureAd') { $class = 'REAL' }
        elseif (Test-ShellFingerprint $d) { $class = 'SHELL' }
        elseif ($d.trustType -eq 'ServerAd') { $class = 'ZOMBIE-CANDIDATE' }
        $classified += [pscustomobject]@{
            Class = $class; Id = $d.id; DeviceId = $d.deviceId; TrustType = $d.trustType
            Hostnames = ($d.hostnames -join ','); Created = $d.createdDateTime
        }
    }
    $realIds = @($classified | Where-Object { $_.Class -eq 'REAL' } | ForEach-Object { $_.DeviceId })
    # A ServerAd object only counts as a zombie if a REAL object also exists
    foreach ($c in $classified) {
        if ($c.Class -eq 'ZOMBIE-CANDIDATE') {
            if ($realIds.Count -gt 0) { $c.Class = 'ZOMBIE' } else { $c.Class = 'HYBRID' }
        }
    }

    $records = @()
    foreach ($m in $intune) {
        $class = 'STALE'
        if ($m.azureADDeviceId -and $m.azureADDeviceId -ne $ZeroGuid -and $realIds -contains $m.azureADDeviceId) { $class = 'HEALTHY' }
        $records += [pscustomobject]@{
            Class = $class; Id = $m.id; AzureADDeviceId = $m.azureADDeviceId
            EnrollmentType = $m.deviceEnrollmentType; Enrolled = $m.enrolledDateTime
            LastSync = $m.lastSyncDateTime; Compliance = $m.complianceState
        }
    }

    [pscustomobject]@{ Hostname = $Name; Entra = $classified; Intune = $records }
}

function Remove-GraphObject {
    # Intentionally uses the script-level $PSCmdlet.ShouldProcess so all deletes share
    # the script's ConfirmImpact/-Force behavior.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '')]
    param([string]$Uri, [string]$Description)
    if (-not $Execute) {
        Write-Log ("  [REPORT] would delete {0}" -f $Description) 'Yellow'
        return 'would-delete'
    }
    if ($PSCmdlet.ShouldProcess($Description, 'DELETE')) {
        Invoke-MgGraphRequest -Method DELETE -Uri $Uri | Out-Null
        Write-Log ("  [DELETED] {0}" -f $Description) 'Green'
        return 'deleted'
    }
    return 'declined'
}

function Add-HostRows {
    # Appends one CSV row per Entra object and Intune record for a processed hostname.
    param($Assessment, [hashtable]$Actions, [string]$DefaultAction = 'kept')
    foreach ($e in $Assessment.Entra) {
        $act = $DefaultAction
        if ($Actions.ContainsKey($e.Id)) { $act = $Actions[$e.Id] }
        $script:reportRows += [pscustomobject]@{
            Hostname = $Assessment.Hostname; RecordType = 'EntraDevice'; Class = $e.Class
            Id = $e.Id; LinkedId = $e.DeviceId; Detail = $e.TrustType
            Hostnames = $e.Hostnames; Timestamp = $e.Created; Action = $act
        }
    }
    foreach ($i in $Assessment.Intune) {
        $act = $DefaultAction
        if ($Actions.ContainsKey($i.Id)) { $act = $Actions[$i.Id] }
        $script:reportRows += [pscustomobject]@{
            Hostname = $Assessment.Hostname; RecordType = 'IntuneRecord'; Class = $i.Class
            Id = $i.Id; LinkedId = $i.AzureADDeviceId; Detail = $i.EnrollmentType
            Hostnames = ''; Timestamp = $i.LastSync; Action = $act
        }
    }
}

# ---------------------------------------------------------------------------
# Discover hostnames
# ---------------------------------------------------------------------------
if ($ScanTenant) {
    Write-Log 'Scanning tenant for shell objects (this pages through every device)...' 'Cyan'
    $all = Get-GraphCollection -Uri "beta/devices?`$select=id,deviceId,displayName,trustType,alternativeSecurityIds&`$top=999"
    $Hostname = @($all | Where-Object { Test-ShellFingerprint $_ } | ForEach-Object { $_.displayName } | Sort-Object -Unique)
    Write-Log ("  {0} device(s) scanned, {1} hostname(s) with shell objects" -f $all.Count, $Hostname.Count) 'Cyan'
    if ($Hostname.Count -eq 0) { return }
}

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------
$summary = @()
foreach ($name in $Hostname) {
    Write-Log ("`n=== {0} ===" -f $name) 'White'
    $a = Get-HostnameAssessment -Name $name
    $actions = @{}

    foreach ($e in $a.Entra)  { Write-Log ("  Entra  {0,-8} {1}  deviceId={2}  trustType={3}  hostnames=[{4}]" -f $e.Class, $e.Id, $e.DeviceId, $e.TrustType, $e.Hostnames) }
    foreach ($i in $a.Intune) { Write-Log ("  Intune {0,-8} {1}  aadDeviceId={2}  {3}  lastSync={4:u}" -f $i.Class, $i.Id, $i.AzureADDeviceId, $i.EnrollmentType, $i.LastSync) }

    $real    = @($a.Entra  | Where-Object { $_.Class -eq 'REAL' })
    $shells  = @($a.Entra  | Where-Object { $_.Class -eq 'SHELL' })
    $zombies = @($a.Entra  | Where-Object { $_.Class -eq 'ZOMBIE' })
    $healthy = @($a.Intune | Where-Object { $_.Class -eq 'HEALTHY' })
    $stale   = @($a.Intune | Where-Object { $_.Class -eq 'STALE' })

    $hybrids = @($a.Entra  | Where-Object { $_.Class -eq 'HYBRID' })
    $others  = @($a.Entra  | Where-Object { $_.Class -eq 'OTHER' })
    $staleCutoff = (Get-Date).AddDays(-$StaleAfterDays)

    $result = [pscustomobject]@{ Hostname = $name; Shells = $shells.Count; Stale = $stale.Count; Zombies = $zombies.Count; Deleted = 0; Note = '' }

    # --- Safety rails ---
    if ($a.Entra.Count -eq 0 -and $a.Intune.Count -eq 0) {
        Write-Log '  Nothing found for this hostname (no Entra objects, no Intune records) - check the spelling.' 'Gray'
        $result.Note = 'not found'; $summary += $result; continue
    }
    $isOrphanSet = ($real.Count -eq 0 -and $hybrids.Count -eq 0 -and $zombies.Count -eq 0 -and $others.Count -eq 0 -and $shells.Count -gt 0)
    if ($real.Count -eq 0) {
        if ($isOrphanSet -and $IncludeOrphans) {
            Write-Log '  ORPHAN SET: only shells and shell-linked records remain (machine decommissioned).' 'DarkYellow'
            $result.Note = 'orphan set'
        }
        elseif ($isOrphanSet) {
            Write-Log '  SKIP: only shells remain (decommissioned machine). Re-run with -IncludeOrphans to clean these.' 'Red'
            $result.Note = 'orphan set (use -IncludeOrphans)'
            Add-HostRows -Assessment $a -Actions $actions -DefaultAction 'skipped: orphan set (use -IncludeOrphans)'
            $summary += $result; continue
        }
        else {
            Write-Log '  SKIP: no REAL (AzureAd) object but a HYBRID/other object exists - machine may be live in hybrid state. Leaving alone.' 'Red'
            $result.Note = 'no real object; hybrid present'
            Add-HostRows -Assessment $a -Actions $actions -DefaultAction 'skipped: hybrid present'
            $summary += $result; continue
        }
    }
    foreach ($z in $zombies) {
        Write-Log ("  ZOMBIE present: {0} (deviceId {1}) owns hostnames [{2}]. NOT deleting - fix in the source AD: delete the computer object from AD (or, if it must be kept for rollback, clear its userCertificate attribute), let Entra Connect remove the cloud object, then purge it from the Entra recycle bin. See README, 'Removing zombies'." -f $z.Id, $z.DeviceId, $z.Hostnames) 'Magenta'
        $actions[$z.Id] = 'zombie - manual AD-side cleanup required'
    }
    if ($shells.Count -eq 0 -and $stale.Count -eq 0) {
        Write-Log '  Clean - nothing to do.' 'Green'
        Add-HostRows -Assessment $a -Actions $actions
        $summary += $result; continue
    }

    # --- 1. Stale Intune records first (prevents shell re-mint) ---
    #   Safe when a HEALTHY record exists (the live enrollment is accounted for) OR the
    #   record is older than the threshold (cannot be inside a mis-link window).
    $blockedShellIds = @()
    foreach ($s in $stale) {
        $isOld = ($s.LastSync -and ([datetime]$s.LastSync) -lt $staleCutoff)
        if ($healthy.Count -eq 0 -and -not $isOld) {
            Write-Log ("  HOLD: Intune record {0} last synced {1:u} - this machine was likely migrated within the last {2} day(s) and its new enrollment has not yet linked itself to the real device object (normally resolves within a day). Nothing deleted for safety. Re-run tomorrow, or adjust the wait window with -StaleAfterDays." -f $s.Id, $s.LastSync, $StaleAfterDays) 'Yellow'
            $blockedShellIds += $s.AzureADDeviceId
            $result.Note = 'recent stale record held'
            $actions[$s.Id] = 'held - possible mis-link window'
            continue
        }
        $desc = "Intune record {0} ({1}, lastSync {2:u})" -f $s.Id, $s.EnrollmentType, $s.LastSync
        $status = Remove-GraphObject -Uri "beta/deviceManagement/managedDevices/$($s.Id)" -Description $desc
        $actions[$s.Id] = $status
        if ($status -eq 'deleted') { $result.Deleted++ }
    }

    # --- 2. Shells (HEALTHY already implies the record points at the REAL object,
    #        so a shell orphaned by the healthy record's mis-link window is safe) ---
    $healthyIds = @($healthy | ForEach-Object { $_.Id })
    foreach ($sh in $shells) {
        if ($blockedShellIds -contains $sh.DeviceId) {
            Write-Log ("  HOLD: shell {0} stays for now - it belongs to a held Intune record above, and deleting the shell while that record exists makes Intune re-create it within minutes. It will be removed on the re-run." -f $sh.Id) 'Yellow'
            $actions[$sh.Id] = 'held - linked record held'
            continue
        }
        $desc = "Entra shell {0} (deviceId {1}, created {2:u})" -f $sh.Id, $sh.DeviceId, $sh.Created
        if ($healthyIds -contains $sh.DeviceId) { $desc += ' [orphan of the healthy record]' }
        $status = Remove-GraphObject -Uri "beta/devices/$($sh.Id)" -Description $desc
        $actions[$sh.Id] = $status
        if ($status -eq 'deleted') {
            $result.Deleted++
            if ($PurgeRecycleBin) {
                try {
                    Invoke-MgGraphRequest -Method DELETE -Uri "beta/directory/deletedItems/$($sh.Id)" | Out-Null
                    Write-Log ("  [PURGED] {0} from recycle bin" -f $sh.Id) 'Green'
                    $actions[$sh.Id] = 'deleted+purged'
                } catch {
                    Write-Log ("  [WARN] purge failed for {0}: {1}" -f $sh.Id, $_.Exception.Message) 'Yellow'
                    $actions[$sh.Id] = 'deleted (purge failed)'
                }
            }
        }
    }
    Add-HostRows -Assessment $a -Actions $actions
    $summary += $result
}

Write-Log "`n=== Summary ===" 'White'
$summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
if ($script:reportRows.Count -gt 0) {
    $script:reportRows | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Log ("Report CSV: {0} ({1} rows)" -f $ReportPath, $script:reportRows.Count) 'Cyan'
}
if (-not $Execute) { Write-Log 'Report only. Re-run with -Execute to delete (add -PurgeRecycleBin to also empty them from the recycle bin, -Force to skip prompts).' 'Yellow' }
Write-Log ("Log: {0}" -f $LogPath) 'Cyan'
