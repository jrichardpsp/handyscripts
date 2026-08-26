<#
    Remediate-MigrationAgentUrl.ps1
    Intune Remediation - REMEDIATION script

    Rewrites the Migration Agent URL value from the old HTTPS endpoint to the
    new HTTP endpoint on port 5000, then restarts the agent service so it
    picks up the change. Leaves any other value untouched.

    Exit 0 = success (or nothing to do)
    Exit 1 = remediation failed
#>

$RegPath  = 'HKLM:\SOFTWARE\Declaration Software\Migration Agent'
$RegName  = 'URL'
$OldValue = 'https://psp.company.com/Agent'
$NewValue = 'http://psp.company.com:5000/Agent'
$ServiceName = 'PowerSyncPro Migration Agent'

try {
    $Current = (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName
}
catch {
    Write-Output "Value '$RegName' not found under $RegPath - nothing to change"
    exit 0
}

if ($Current -ne $OldValue) {
    Write-Output "URL is '$Current' - not the target value, leaving unchanged"
    exit 0
}

try {
    Set-ItemProperty -Path $RegPath -Name $RegName -Value $NewValue -Type String -ErrorAction Stop
}
catch {
    Write-Output "Failed to set '$RegName': $($_.Exception.Message)"
    exit 1
}

$Verify = (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue).$RegName

if ($Verify -ne $NewValue) {
    Write-Output "Write-back verification failed - URL is now '$Verify'"
    exit 1
}

Write-Output "URL changed from '$OldValue' to '$Verify'"

# Restart the agent so it picks up the new endpoint
$Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $Service) {
    $Service = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $ServiceName } |
        Select-Object -First 1
}

if (-not $Service) {
    Write-Output "Service '$ServiceName' not found - registry change applied, restart skipped"
    exit 0
}

try {
    if ($Service.Status -eq 'Running') {
        Restart-Service -Name $Service.Name -Force -ErrorAction Stop
    }
    else {
        Start-Service -Name $Service.Name -ErrorAction Stop
    }
    $Service.WaitForStatus('Running', (New-TimeSpan -Seconds 60))
    Write-Output "Service '$($Service.Name)' is running"
    exit 0
}
catch {
    Write-Output "Registry change applied but service restart failed: $($_.Exception.Message)"
    exit 1
}
