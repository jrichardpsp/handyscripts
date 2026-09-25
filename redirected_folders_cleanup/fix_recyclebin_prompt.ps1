#Requires -Version 5.1
<#
.SYNOPSIS
    Removes stale per-known-folder Recycle Bin registrations for the current user.

.DESCRIPTION
    Fixes the 'The Recycle Bin on \\server\share\... is corrupted' prompt that
    appears at every logon after Folder Redirection has been reversed.

    Folder Redirection gives each redirected known folder (Documents, Pictures,
    etc.) its own Recycle Bin on the file server, registered per-folder under:

        HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\KnownFolder

    After migration those registrations still point at the old UNC paths, and
    Explorer complains at each logon when it cannot reach them. Deleting the
    KnownFolder subtree is safe - Explorer rebuilds registrations automatically,
    and local folders are covered by the normal per-volume Recycle Bin.

    Run as the affected user (no admin rights required). Changes take effect
    after signing out and back in, or after Explorer is restarted.

.PARAMETER RestartExplorer
    Restart Explorer immediately so the fix applies without signing out.
    Open File Explorer windows will close; running apps are not affected.

.EXAMPLE
    .\fix_recyclebin_prompt.ps1

.EXAMPLE
    .\fix_recyclebin_prompt.ps1 -RestartExplorer

.NOTES
    Exit codes:
      0 = Success (state cleared, or nothing to clear)
      1 = Could not delete the registry key

    Compatibility: PowerShell 5.1, Windows 10/11
    Encoding: ASCII-safe (no Unicode characters)
#>
param(
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Stop'

$bbKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\KnownFolder'

Write-Host ''
Write-Host 'Recycle Bin cleanup - removing stale redirected-folder registrations'
Write-Host '--------------------------------------------------------------------'

if (-not (Test-Path $bbKey)) {
    Write-Host 'No KnownFolder Recycle Bin registrations found - nothing to clean up.'
    Write-Host 'If you are still seeing the corrupted Recycle Bin prompt, it is not'
    Write-Host 'coming from this user profile.'
    exit 0
}

# Show what is registered before deleting, for the record
$subKeys = @(Get-ChildItem -Path $bbKey -ErrorAction SilentlyContinue)
Write-Host "Found $($subKeys.Count) per-folder Recycle Bin registration(s):"
foreach ($k in $subKeys) {
    Write-Host "  $($k.PSChildName)"
}

try {
    Remove-Item -Path $bbKey -Recurse -Force -ErrorAction Stop
    Write-Host 'Registrations removed successfully.'
} catch {
    Write-Host "ERROR: Could not remove the registry key: $_"
    exit 1
}

if ($RestartExplorer) {
    Write-Host 'Restarting Explorer to apply the change now...'
    try {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        # Explorer normally restarts itself; start it if it does not within 5 seconds
        Start-Sleep -Seconds 5
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Host 'Explorer restarted. The prompt should not appear again.'
    } catch {
        Write-Host "WARNING: Could not restart Explorer: $_"
        Write-Host 'Sign out and back in to complete the fix.'
    }
} else {
    Write-Host ''
    Write-Host 'Done. Sign out and back in (or restart the computer) to complete the fix.'
}

exit 0
