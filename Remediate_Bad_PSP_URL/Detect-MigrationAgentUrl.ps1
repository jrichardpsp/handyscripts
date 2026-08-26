<#
    Detect-MigrationAgentUrl.ps1
    Intune Remediation - DETECTION script

    Flags a device for remediation only when the Migration Agent URL value
    exactly matches the old HTTPS endpoint.

    Exit 0 = compliant / no action
    Exit 1 = non-compliant, run remediation
#>

$RegPath  = 'HKLM:\SOFTWARE\Declaration Software\Migration Agent'
$RegName  = 'URL'
$OldValue = 'https://psp.company.com/Agent'

try {
    $Current = (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName
}
catch {
    Write-Output "Value '$RegName' not found under $RegPath - no action"
    exit 0
}

if ($Current -eq $OldValue) {
    Write-Output "URL is '$Current' - remediation required"
    exit 1
}

Write-Output "URL is '$Current' - no action"
exit 0
