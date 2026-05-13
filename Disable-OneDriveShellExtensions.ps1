# Disable-OneDriveShellExtensions.ps1
# PowerShell 5.1 compatible

$ErrorActionPreference = "Stop"

$blockedKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"

if (-not (Test-Path $blockedKey)) {
    New-Item -Path $blockedKey -Force | Out-Null
}

# Find OneDrive shell overlay CLSIDs
$overlayRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"

$items = Get-ChildItem $overlayRoot -ErrorAction SilentlyContinue |
    Where-Object {
        $_.PSChildName -like "*OneDrive*" -or
        ((Get-ItemProperty $_.PSPath)."(default)" -like "*OneDrive*")
    }

foreach ($item in $items) {
    $clsid = (Get-ItemProperty $item.PSPath)."(default)"

    if ($clsid -match "^\{[0-9A-Fa-f\-]+\}$") {
        Write-Host "Blocking $($item.PSChildName) $clsid"
        New-ItemProperty `
            -Path $blockedKey `
            -Name $clsid `
            -Value "Blocked OneDrive shell extension" `
            -PropertyType String `
            -Force | Out-Null
    }
}

Write-Host "Restarting Explorer..."
Stop-Process -Name explorer -Force
Start-Process explorer.exe