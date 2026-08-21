# Suppress user-phase ESP on PPKG-enrolled devices. Run as SYSTEM.
# ASCII only, PS 5.1, no external modules.

$Root      = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$TimeoutS  = 900
$Deadline  = (Get-Date).AddSeconds($TimeoutS)
$GuidRegex = '^\{?[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}?$'

function Get-MdmEnrollmentKey {
    Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match $GuidRegex } |
        Where-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            $p.ProviderID -eq 'MS DM Server' -and $p.EnrollmentState -eq 1
        } |
        Select-Object -First 1
}

$Enrollment = $null
while ((Get-Date) -lt $Deadline) {
    $Enrollment = Get-MdmEnrollmentKey
    if ($Enrollment) { break }
    Start-Sleep -Seconds 10
}

if (-not $Enrollment) {
    Write-Output 'No MS DM Server enrollment found before timeout.'
    exit 1
}

$FirstSync = Join-Path $Enrollment.PSPath 'FirstSync'
if (-not (Test-Path $FirstSync)) {
    New-Item -Path $FirstSync -Force | Out-Null
}

# -1 as an Int32 is stored as 0xFFFFFFFF in a REG_DWORD.
Set-ItemProperty -Path $FirstSync -Name 'SkipUserStatusPage'   -Value ([int]-1) -Type DWord -Force
Set-ItemProperty -Path $FirstSync -Name 'SkipDeviceStatusPage' -Value ([int]-1) -Type DWord -Force

$Check = Get-ItemProperty -Path $FirstSync
Write-Output ("Enrollment: {0}" -f $Enrollment.PSChildName)
Write-Output ("SkipUserStatusPage   = 0x{0:X8}" -f $Check.SkipUserStatusPage)
Write-Output ("SkipDeviceStatusPage = 0x{0:X8}" -f $Check.SkipDeviceStatusPage)