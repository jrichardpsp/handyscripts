<#
.SYNOPSIS
  Packer-safe: Wait for SQL to be running, then stop it, start in single-user (-m),
  grant BUILTIN\Administrators sysadmin via sqlcmd -E -C, restore startup params,
  and start normally.

.KEY IMPROVEMENTS FOR PACKER/PIPELINES
  - Waits for SQL service to reach Running before first stop attempt
  - Stop-Service with retry + fallback to sc.exe stop
  - Handles transient StartPending/StopPending states
  - Keeps safe parameter handling: backup + restore, append-only -m, remove duplicates

.REQUIREMENTS
  - Run as Administrator
  - sqlcmd installed
#>

[CmdletBinding()]
param(
  [string]$ServiceName = "MSSQLSERVER",
  [string]$BackupPath  = "C:\Temp\SqlStartupParamsBackup.json",

  [int]$WaitForRunningTimeoutSeconds = 300,
  [int]$ServiceTimeoutSeconds = 180,

  [int]$StopRetries = 12,
  [int]$StopRetryDelaySeconds = 5,

  [int]$SqlcmdRetries = 15,
  [int]$SqlcmdRetryDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$m) { Write-Host ("[INFO ] " + $m) }
function Write-Warn([string]$m) { Write-Warning $m }
function Write-Fail([string]$m) { throw $m }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceState([string]$Name) {
  # Using Get-Service gives basic state; WMI provides state transitions detail too
  $svc = Get-Service -Name $Name -ErrorAction Stop
  return $svc.Status.ToString()
}

function Wait-ServiceStatus {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet("Running","Stopped")] [string]$Desired,
    [int]$TimeoutSeconds = 120
  )
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status.ToString() -eq $Desired) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Wait-UntilServiceRunning {
  param([string]$Name, [int]$TimeoutSeconds)

  Write-Info "Waiting up to $TimeoutSeconds seconds for service '$Name' to be Running..."
  $ok = Wait-ServiceStatus -Name $Name -Desired "Running" -TimeoutSeconds $TimeoutSeconds
  if (-not $ok) {
    $state = Get-ServiceState -Name $Name
    Write-Fail "Service '$Name' did not reach Running within timeout. Current state: $state"
  }
}

function Stop-ServiceRobust {
  param(
    [string]$Name,
    [int]$Retries = 10,
    [int]$DelaySeconds = 3,
    [int]$StopTimeoutSeconds = 180
  )

  # If already stopped, done
  $state = Get-ServiceState -Name $Name
  if ($state -eq "Stopped") {
    Write-Info "Service '$Name' is already Stopped."
    return
  }

  for ($i=1; $i -le $Retries; $i++) {
    try {
      $state = Get-ServiceState -Name $Name
      Write-Info "Stop attempt $i/$Retries (current: $state) ..."

      # If it's StartPending/StopPending, give it a moment
      if ($state -in @("StartPending","StopPending","ContinuePending","PausePending")) {
        Start-Sleep -Seconds $DelaySeconds
        continue
      }

      Stop-Service -Name $Name -Force -ErrorAction Stop

      if (Wait-ServiceStatus -Name $Name -Desired "Stopped" -TimeoutSeconds $StopTimeoutSeconds) {
        Write-Info "Service '$Name' is Stopped."
        return
      }

      Write-Warn "Stop-Service issued but service still not Stopped; retrying..."
    }
    catch {
      Write-Warn ("Stop-Service failed: {0}" -f $_.Exception.Message)

      # Fallback to sc.exe stop (often works when Stop-Service errors)
      try {
        Write-Warn "Attempting fallback: sc.exe stop $Name"
        & sc.exe stop $Name | Out-Null
        if (Wait-ServiceStatus -Name $Name -Desired "Stopped" -TimeoutSeconds $StopTimeoutSeconds) {
          Write-Info "Service '$Name' is Stopped."
          return
        }
      } catch {
        # ignore and continue retries
      }
    }

    Start-Sleep -Seconds $DelaySeconds
  }

  $final = Get-ServiceState -Name $Name
  Write-Fail "Unable to stop service '$Name' after $Retries attempts. Final state: $final"
}

function Start-ServiceRobust {
  param([string]$Name, [int]$TimeoutSeconds = 180)

  $state = Get-ServiceState -Name $Name
  if ($state -eq "Running") {
    Write-Info "Service '$Name' is already Running."
    return
  }

  Start-Service -Name $Name -ErrorAction Stop
  if (-not (Wait-ServiceStatus -Name $Name -Desired "Running" -TimeoutSeconds $TimeoutSeconds)) {
    $final = Get-ServiceState -Name $Name
    Write-Fail "Service '$Name' failed to reach Running. Final state: $final"
  }

  Write-Info "Service '$Name' is Running."
}

function Get-InstanceIdFromService([string]$SvcName) {
  $svcKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Services\$SvcName"
  if (Test-Path $svcKey) {
    $p = Get-ItemProperty $svcKey -ErrorAction Stop
    if ($p.PSObject.Properties.Name -contains "InstanceID") { return [string]$p.InstanceID }
  }

  $instNamesKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
  if (Test-Path $instNamesKey) {
    $map = Get-ItemProperty $instNamesKey -ErrorAction Stop
    $inst = if ($SvcName -eq "MSSQLSERVER") { "MSSQLSERVER" } elseif ($SvcName -like "MSSQL$*") { $SvcName.Substring(6) } else { $null }
    if ($inst -and ($map.PSObject.Properties.Name -contains $inst)) { return [string]$map.$inst }
  }

  return $null
}

function Get-ParametersKey([string]$SvcName) {
  $instanceId = Get-InstanceIdFromService -SvcName $SvcName
  if (-not $instanceId) { Write-Fail "Could not resolve InstanceID for service '$SvcName'." }

  $key = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\Parameters"
  if (-not (Test-Path $key)) { Write-Fail "SQL Parameters key not found: $key" }

  [pscustomobject]@{
    InstanceID    = $instanceId
    ParametersKey = $key
  }
}

function Get-SqlArgPairs([string]$ParametersKey) {
  $p = Get-ItemProperty -Path $ParametersKey -ErrorAction Stop
  $pairs = @()
  foreach ($prop in $p.PSObject.Properties) {
    if ($prop.Name -match '^SQLArg(\d+)$') {
      $pairs += [pscustomobject]@{
        Index = [int]$Matches[1]
        Name  = $prop.Name
        Value = [string]$prop.Value
      }
    }
  }
  $pairs | Sort-Object Index
}

function Backup-Args([string]$Path, [object]$Pairs) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $Pairs | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Restore-ExactlyFromBackup([string]$ParametersKey, [string]$BackupPath) {
  if (-not (Test-Path $BackupPath)) { Write-Fail "Backup not found: $BackupPath" }
  $backup = Get-Content -LiteralPath $BackupPath -Encoding UTF8 | ConvertFrom-Json

  $cur = Get-ItemProperty -Path $ParametersKey -ErrorAction Stop
  foreach ($prop in $cur.PSObject.Properties) {
    if ($prop.Name -match '^SQLArg\d+$') {
      Remove-ItemProperty -Path $ParametersKey -Name $prop.Name -ErrorAction SilentlyContinue
    }
  }

  foreach ($b in ($backup | Sort-Object Index)) {
    New-ItemProperty -Path $ParametersKey -Name $b.Name -Value ([string]$b.Value) -PropertyType String -Force | Out-Null
  }

  Write-Info "Restored SQLArg list exactly from backup."
}

function Append-SqlArg([string]$ParametersKey, [string]$Value) {
  $pairs = Get-SqlArgPairs -ParametersKey $ParametersKey
  if ($pairs.Value -contains $Value) {
    Write-Info "Startup arg already present: $Value"
    return
  }

  $max  = if ($pairs.Count -gt 0) { ($pairs | Measure-Object Index -Maximum).Maximum } else { -1 }
  $next = [int]$max + 1
  $name = "SQLArg$next"

  New-ItemProperty -Path $ParametersKey -Name $name -Value $Value -PropertyType String -Force | Out-Null
  Write-Info "Appended $name = $Value"
}

function Remove-SqlArgsMatching([string]$ParametersKey, [string]$Regex) {
  $pairs = Get-SqlArgPairs -ParametersKey $ParametersKey
  $toRemove = $pairs | Where-Object { $_.Value -match $Regex }
  foreach ($r in $toRemove) {
    Remove-ItemProperty -Path $ParametersKey -Name $r.Name -ErrorAction SilentlyContinue
    Write-Info "Removed $($r.Name) = $($r.Value)"
  }
}

function Get-SqlcmdTargetFromService([string]$SvcName) {
  if ($SvcName -eq "MSSQLSERVER") { return "localhost" }
  if ($SvcName -like "MSSQL$*") { return ("localhost\" + $SvcName.Substring(6)) }
  return "localhost"
}

function Invoke-GrantAdminsSysadmin {
  param(
    [Parameter(Mandatory)][string]$Target,
    [int]$Retries = 10,
    [int]$DelaySeconds = 1
  )

  $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
  if (-not $sqlcmd) { Write-Fail "sqlcmd not found. Install SQL command-line utilities (or SSMS tools)." }

  $tsql = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'BUILTIN\Administrators')
BEGIN
  CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;
END;
IF NOT EXISTS (
  SELECT 1
  FROM sys.server_role_members rm
  JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
  JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
  WHERE r.name = N'sysadmin' AND m.name = N'BUILTIN\Administrators'
)
BEGIN
  ALTER SERVER ROLE [sysadmin] ADD MEMBER [BUILTIN\Administrators];
END;
"@

  $tmpSql = Join-Path $env:TEMP ("psp_grant_admins_{0}.sql" -f ([guid]::NewGuid().ToString("N")))
  Set-Content -LiteralPath $tmpSql -Value $tsql -Encoding ASCII

  try {
    for ($i=1; $i -le $Retries; $i++) {
      $args = @("-S", $Target, "-E", "-C", "-b", "-i", $tmpSql)
      $p = Start-Process -FilePath $sqlcmd.Source -ArgumentList $args -Wait -PassThru -NoNewWindow
      if ($p.ExitCode -eq 0) {
        Write-Info "BUILTIN\Administrators is now sysadmin (or already was)."
        return
      }
      Write-Warn "sqlcmd attempt $i/$Retries failed (exit $($p.ExitCode)); retrying in $DelaySeconds sec..."
      Start-Sleep -Seconds $DelaySeconds
    }
    Write-Fail "sqlcmd failed after $Retries attempts."
  }
  finally {
    Remove-Item -LiteralPath $tmpSql -Force -ErrorAction SilentlyContinue
  }
}

# ----------------------------
# MAIN
# ----------------------------
if (-not (Test-IsAdmin)) { Write-Fail "Run PowerShell elevated (Run as Administrator)." }

$pk = Get-ParametersKey -SvcName $ServiceName
$parametersKey = $pk.ParametersKey

Write-Info "Service       : $ServiceName"
Write-Info "InstanceID    : $($pk.InstanceID)"
Write-Info "ParametersKey : $parametersKey"

# Backup
$orig = Get-SqlArgPairs -ParametersKey $parametersKey
if (-not $orig -or $orig.Count -eq 0) { Write-Fail "No SQLArg* values found; aborting." }
Backup-Args -Path $BackupPath -Pairs $orig
Write-Info "Backed up SQLArg list to: $BackupPath"

# Packer safety: ensure SQL is fully Running before we attempt to stop it
Wait-UntilServiceRunning -Name $ServiceName -TimeoutSeconds $WaitForRunningTimeoutSeconds

# Stop SQL service robustly
Write-Info "Stopping SQL service..."
Stop-ServiceRobust -Name $ServiceName -Retries $StopRetries -DelaySeconds $StopRetryDelaySeconds -StopTimeoutSeconds $ServiceTimeoutSeconds

# Ensure no -m variants, then add plain -m
Remove-SqlArgsMatching -ParametersKey $parametersKey -Regex '^-m($|")'
Append-SqlArg -ParametersKey $parametersKey -Value "-m"

# Start in single-user mode
Write-Info "Starting SQL service (single-user mode -m)..."
Start-ServiceRobust -Name $ServiceName -TimeoutSeconds $ServiceTimeoutSeconds

# Grant sysadmin
$target = Get-SqlcmdTargetFromService -SvcName $ServiceName
Write-Info "sqlcmd target : $target"
Invoke-GrantAdminsSysadmin -Target $target -Retries $SqlcmdRetries -DelaySeconds $SqlcmdRetryDelaySeconds

# Stop again
Write-Info "Stopping SQL service..."
Stop-ServiceRobust -Name $ServiceName -Retries $StopRetries -DelaySeconds $StopRetryDelaySeconds -StopTimeoutSeconds $ServiceTimeoutSeconds

# Restore original startup params exactly (safest)
Restore-ExactlyFromBackup -ParametersKey $parametersKey -BackupPath $BackupPath

# Start normal
Write-Info "Starting SQL service (normal mode)..."
Start-ServiceRobust -Name $ServiceName -TimeoutSeconds $ServiceTimeoutSeconds

Write-Info "Done."
