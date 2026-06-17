#requires -version 5.1
<#
.SYNOPSIS
    Registers (or re-registers) the PSP SIEM Log Exporter as a Windows Scheduled Task.

.DESCRIPTION
    Creates a repeating scheduled task with MultipleInstances = IgnoreNew, so a slow export
    run is never interrupted by the next trigger. Interval defaults to 5 minutes; use
    -IntervalMinutes to change it.

    Works for both SQL Server Express (named instances, relies on SQL Browser for port
    resolution) and full SQL Server.  On full SQL Server a SQL Agent job is also an option --
    see the commented block at the bottom of psp-siem-export-permissions.sql.

    Run this script once as a local administrator to set up or update the task.
    The exporter itself runs as a gMSA or dedicated service account; see
    psp-siem-export-permissions.sql for the least-privilege DB setup.

.NOTES
    SQL Browser requirement (Express / named instances):
        Named instances use a dynamic TCP port assigned at service startup.
        The SQL Server Browser service must be running and its UDP port 1434 must be
        reachable from the machine running this exporter, unless you hard-code the port
        in the instance string (e.g. "HOST\SQLEXPRESS,52317").

    gMSA vs. domain service account:
        For a gMSA (DOMAIN\account$) set -LogonType to 'ServiceAccount' -- no password needed.
        For a regular domain account set -LogonType to 'Password' and supply -RunAsPassword.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ScriptPath     = 'C:\PSPLogExport\psp-agentlogs-to-siem.ps1',
    [string]$ConfigFile     = 'C:\PSPLogExport\psp-siem-export.json',
    [string]$TaskName       = 'PSPLogExport_Tenant1',
    [string]$TaskPath       = '\PSP\',

    # gMSA: 'DOMAIN\account$'   domain service account: 'DOMAIN\account'
    [string]$RunAsAccount   = 'DOMAIN\psp_siem_export$',

    # 'ServiceAccount' for gMSA / SYSTEM; 'Password' for a domain service account
    [ValidateSet('ServiceAccount','Password')]
    [string]$LogonType      = 'ServiceAccount',

    # Required only when LogonType = 'Password'. Pass as SecureString or omit to be prompted.
    [SecureString]$RunAsPassword  = $null,

    [int]   $TenantId         = 1,

    # How often the task fires, in minutes (default 5; minimum 1)
    [ValidateRange(1,1440)]
    [int]   $IntervalMinutes  = 5

)

$ErrorActionPreference = 'Stop'

$psExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigFile `"$ConfigFile`" -TenantId $TenantId"

$action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$trigger.Repetition.StopAtDurationEnd = $false

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances   IgnoreNew `
    -ExecutionTimeLimit  (New-TimeSpan -Hours 1) `
    -StartWhenAvailable `
    -RestartCount        0

# ServiceAccount logon type only works for gMSAs (account ends in $), SYSTEM, LOCAL SERVICE,
# and NETWORK SERVICE. A regular domain account (no trailing $) must use Password logon type.
if ($LogonType -eq 'ServiceAccount' -and
    $RunAsAccount -match '\\' -and
    $RunAsAccount -notmatch '\$$') {
    throw ("'{0}' looks like a regular domain account. ServiceAccount logon type only works for " +
           "gMSAs (name must end with '$') and built-in accounts. Use -LogonType Password instead.") -f $RunAsAccount
}

if ($LogonType -eq 'ServiceAccount') {
    $principal = New-ScheduledTaskPrincipal `
        -UserId    $RunAsAccount `
        -LogonType ServiceAccount `
        -RunLevel  Highest
} else {
    if (-not $RunAsPassword) {
        $RunAsPassword = Read-Host -AsSecureString "Password for $RunAsAccount"
    }
}

$description = "PSP SIEM Log Exporter -- tenant $TenantId. Exports RunbookLogEntries to NDJSON. READ-ONLY DB access."

if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Register Scheduled Task")) {
    $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Removing existing task: $TaskPath$TaskName"
        Unregister-ScheduledTask -InputObject $existing -Confirm:$false
    }

    # Register-ScheduledTask has two incompatible parameter sets: one takes -Principal,
    # the other takes -User/-Password/-RunLevel. Mixing them causes AmbiguousParameterSet.
    if ($LogonType -eq 'ServiceAccount') {
        $regParams = @{
            TaskName    = $TaskName
            TaskPath    = $TaskPath
            Action      = $action
            Trigger     = $trigger
            Settings    = $settings
            Principal   = $principal
            Description = $description
        }
    } else {
        $regParams = @{
            TaskName    = $TaskName
            TaskPath    = $TaskPath
            Action      = $action
            Trigger     = $trigger
            Settings    = $settings
            User        = $RunAsAccount
            Password    = [System.Net.NetworkCredential]::new('', $RunAsPassword).Password
            RunLevel    = 'Highest'
            Description = $description
        }
    }

    $task = Register-ScheduledTask @regParams

    Write-Host "Registered : $($task.TaskPath)$($task.TaskName)"
    $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName
    Write-Host ("Next run   : {0}" -f $info.NextRunTime)
    Write-Host ("Run as     : $RunAsAccount ($LogonType)")
}
