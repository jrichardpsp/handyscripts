<#
.SYNOPSIS
    Replaces the invalid FileSystemRights ACE (value 270467583) with FullControl
    on all user profile folders.

.NOTES
    Must be run as SYSTEM or Administrator.
    Logs to C:\Temp\ACE-Cleanup.log
#>

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
$LogFile = "C:\Temp\ACE-Cleanup.log"
$BadRightsValue = 270467583

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry
}

function Repair-BadAce {
    param([string]$Path)

    try {
        $acl = Get-Acl -Path $Path -ErrorAction Stop
        $badRules = $acl.Access | Where-Object { [int]$_.FileSystemRights -eq $BadRightsValue }

        if ($badRules) {
            foreach ($rule in $badRules) {
                # Remove the invalid ACE
                $removed = $acl.RemoveAccessRule($rule)
                if ($removed) {
                    Write-Log "Removed bad ACE from: $Path (Identity: $($rule.IdentityReference))"

                    # Replace with FullControl, preserving the original identity and inheritance
                    $newRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $rule.IdentityReference,
                        [System.Security.AccessControl.FileSystemRights]::FullControl,
                        $rule.InheritanceFlags,
                        $rule.PropagationFlags,
                        $rule.AccessControlType
                    )
                    $acl.AddAccessRule($newRule)
                    Write-Log "Added FullControl ACE for: $($rule.IdentityReference) on $Path"
                } else {
                    Write-Log "RemoveAccessRule returned false for: $Path" "WARN"
                }
            }
            Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
        }
    }
    catch {
        Write-Log "ERROR processing '$Path': $_" "ERROR"
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Log "===== ACE Cleanup Started ====="

# Get all user profile paths from the registry (more reliable than scanning C:\Users)
$profileList = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
    Where-Object { $_.ProfileImagePath -and $_.ProfileImagePath -match "^C:\\Users\\" } |
    Select-Object -ExpandProperty ProfileImagePath

if (-not $profileList) {
    Write-Log "No user profiles found. Exiting." "WARN"
    exit 1
}

Write-Log "Found $($profileList.Count) profile(s) to check."

foreach ($profilePath in $profileList) {

    if (-not (Test-Path $profilePath)) {
        Write-Log "Profile path not found, skipping: $profilePath" "WARN"
        continue
    }

    Write-Log "--- Scanning profile: $profilePath"

    # Check root of profile first
    Repair-BadAce -Path $profilePath

    # Recurse into all subdirectories
    try {
        $subDirs = Get-ChildItem -Path $profilePath -Recurse -Directory -Force -ErrorAction SilentlyContinue
        foreach ($dir in $subDirs) {
            Repair-BadAce -Path $dir.FullName
        }
    }
    catch {
        Write-Log "ERROR enumerating subdirectories under '$profilePath': $_" "ERROR"
    }

    Write-Log "--- Completed profile: $profilePath"
}

Write-Log "===== ACE Cleanup Finished ====="