#Requires -Version 5.1
<#
.SYNOPSIS
    Removes stale Folder Redirection Recycle Bin state for the current user.

.DESCRIPTION
    Fixes the 'The Recycle Bin on \\server\share\... is corrupted' prompt that
    appears at every logon after Folder Redirection has been reversed.

    Two things must be cleaned, in order:

    1. Stale GUID alias values in User Shell Folders / Shell Folders.
       The Folder Redirection CSE writes GUID-named alias values (the ThisPC*
       known-folder GUIDs) alongside the legacy named values (Desktop,
       Personal, My Pictures...). Migration tooling typically rewrites only
       the named values, leaving the aliases pointing at the UNC share.
       As long as those aliases remain, Explorer re-registers per-folder
       Recycle Bins at every logon and the prompt keeps coming back.

    2. Per-known-folder Recycle Bin registrations under:
       HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\KnownFolder

    Only the known alias GUIDs for user data folders (Desktop, Documents,
    Pictures, Music, Videos, Downloads) are removed, and only when they still
    point at a UNC path. Named values (Desktop, Personal, etc.) are NEVER
    deleted by this script - if one of those still points at a UNC path, this
    machine has not been migrated and the script reports it instead.

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
      1 = One or more registry deletions failed

    Compatibility: PowerShell 5.1, Windows 10/11
    Encoding: ASCII-safe (no Unicode characters)
#>
param(
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Stop'

$usfKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$sfKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$bbKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\KnownFolder'

# ThisPC* known-folder alias GUIDs written by the Folder Redirection CSE.
# Safe to delete when stale - Explorer rebuilds them from the named values.
$aliasGuids = @{
    '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}' = 'Desktop'
    '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' = 'Documents'
    '{0DDD015D-B06C-45D5-8C4C-F59713854639}' = 'Pictures'
    '{A0C69A99-21C8-4671-8703-7934162FCF1D}' = 'Music'
    '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}' = 'Videos'
    '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}' = 'Downloads'
}

$hadErrors    = $false
$removedCount = 0

Write-Host ''
Write-Host 'Recycle Bin cleanup - removing stale redirected-folder state'
Write-Host '------------------------------------------------------------'

# ---------------------------------------------------------------------------
# Step 1: Remove stale UNC alias values from User Shell Folders / Shell Folders
# ---------------------------------------------------------------------------
foreach ($regInfo in @(
    @{ Path = $usfKey; Label = 'User Shell Folders' },
    @{ Path = $sfKey;  Label = 'Shell Folders'      }
)) {
    $regPath = $regInfo.Path
    $label   = $regInfo.Label

    if (-not (Test-Path $regPath)) { continue }

    $key = Get-Item -Path $regPath
    foreach ($name in @($key.GetValueNames())) {
        if ($name -eq '') { continue }

        $raw = [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (-not $raw) { continue }
        if ($raw -notlike '\\*') { continue }

        if ($aliasGuids.ContainsKey($name)) {
            $friendly = $aliasGuids[$name]
            try {
                Remove-ItemProperty -Path $regPath -Name $name -ErrorAction Stop
                Write-Host "Removed stale $friendly alias from $label ($name -> $raw)"
                $removedCount++
            } catch {
                Write-Host "ERROR: Could not remove $friendly alias '$name' from ${label}: $_"
                $hadErrors = $true
            }
        } else {
            Write-Host "WARNING: '$name' in $label still points to $raw"
            Write-Host '         This folder does not appear to have been migrated - leaving it'
            Write-Host '         in place. Contact IT if you believe this is an error.'
        }
    }
}

if ($removedCount -eq 0) {
    Write-Host 'No stale UNC alias values found in the shell folder keys.'
}

# ---------------------------------------------------------------------------
# Step 2: Remove per-known-folder Recycle Bin registrations
# ---------------------------------------------------------------------------
if (Test-Path $bbKey) {
    $subKeys = @(Get-ChildItem -Path $bbKey -ErrorAction SilentlyContinue)
    Write-Host "Found $($subKeys.Count) per-folder Recycle Bin registration(s):"
    foreach ($k in $subKeys) {
        Write-Host "  $($k.PSChildName)"
    }
    try {
        Remove-Item -Path $bbKey -Recurse -Force -ErrorAction Stop
        Write-Host 'Recycle Bin registrations removed successfully.'
    } catch {
        Write-Host "ERROR: Could not remove the BitBucket registry key: $_"
        $hadErrors = $true
    }
} else {
    Write-Host 'No KnownFolder Recycle Bin registrations found - nothing to remove there.'
}

if ($hadErrors) {
    Write-Host ''
    Write-Host 'Completed with errors - see messages above.'
    exit 1
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
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
