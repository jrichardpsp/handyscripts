#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Removes the SCCM (Configuration Manager) client from a system.

.DESCRIPTION
    Performs a complete removal of the SCCM/ConfigMgr client using the official
    ccmsetup.exe uninstaller, with fallback manual cleanup if the uninstaller is
    absent or incomplete. Designed to run as SYSTEM via task scheduler or RMM tool.

    This script:
      1. Runs ccmsetup.exe /uninstall and waits for the child process to finish.
      2. Stops and deletes all SCCM-related Windows services.
      3. Removes SCCM WMI namespaces (root\ccm, root\sms, etc.).
      4. Deletes leftover files and folders under C:\Windows (CCM, ccmsetup, ccmcache).
      5. Purges SCCM registry keys from HKLM SOFTWARE and SYSTEM hives.
      6. Removes SCCM certificates from the LocalMachine\SMS certificate store.
      7. Deletes the Configuration Manager scheduled task folder under \Microsoft.

    Manual cleanup checklist sourced from:
    https://learn.microsoft.com/en-us/archive/blogs/michaelgriswold/manual-removal-of-the-sccm-client

.NOTES
    Run as:    SYSTEM or local Administrator.
    Log file:  C:\Windows\Temp\Remove-SCCMClient.log (created automatically).
    Tested on: Windows 10 / 11, SCCM Client / ConfigMgr Client (all modern versions).
    Use-case:  Pre-migration cleanup before Entra ID join or OS re-imaging.

.EXAMPLE
    .\sccm_removal.ps1

    Runs silently as SYSTEM; all output is mirrored to the log file and the host console.
#>

# ---------------------------------------------
# CONFIGURATION
# ---------------------------------------------
$LogFile  = "C:\Windows\Temp\Remove-SCCMClient.log"
$CCMSetup = "C:\Windows\ccmsetup\ccmsetup.exe"

# ---------------------------------------------
# LOGGING HELPERS
# ---------------------------------------------

# Key milestones -> console + log
function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# Verbose detail -> log file only
function Write-Detail {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
}

# ---------------------------------------------
# STEP 1 - Official uninstall via ccmsetup.exe
# ---------------------------------------------
function Invoke-CCMSetupUninstall {
    if (Test-Path $CCMSetup) {
        Write-Status "STEP 1: Running ccmsetup.exe /uninstall..."
        $proc = Start-Process -FilePath $CCMSetup `
                              -ArgumentList "/uninstall" `
                              -Wait -PassThru -NoNewWindow
        Write-Detail "ccmsetup.exe initial process exited with code: $($proc.ExitCode)"

        # ccmsetup spawns a child process; wait for it to fully finish
        $timeout = 300  # seconds
        $elapsed = 0
        Write-Detail "Waiting for ccmsetup child process (max ${timeout}s)..."
        while ((Get-Process -Name "ccmsetup" -ErrorAction SilentlyContinue) -and ($elapsed -lt $timeout)) {
            Start-Sleep -Seconds 5
            $elapsed += 5
        }
        if ($elapsed -ge $timeout) {
            Write-Status "STEP 1: ccmsetup timed out after ${timeout}s -- continuing with manual cleanup." "WARN"
        } else {
            Write-Status "STEP 1: ccmsetup uninstall finished."
        }
    } else {
        Write-Status "STEP 1: ccmsetup.exe not found -- skipping official uninstall, running manual cleanup only." "WARN"
    }
}

# ---------------------------------------------
# STEP 2 - Stop & remove SCCM services
# ---------------------------------------------
function Remove-SCCMServices {
    Write-Status "STEP 2: Stopping and removing SCCM services..."
    $services = @("CcmExec", "smstsmgr", "CmRcService", "ccmsetup")
    $removed  = @()
    foreach ($svc in $services) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Write-Detail "Stopping service: $svc"
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Write-Detail "Deleting service: $svc"
            & sc.exe delete $svc | Out-Null
            $removed += $svc
        } else {
            Write-Detail "Service not found (already removed?): $svc"
        }
    }
    if ($removed.Count -gt 0) {
        Write-Status "STEP 2: Removed services: $($removed -join ', ')"
    } else {
        Write-Status "STEP 2: No SCCM services found."
    }
}

# ---------------------------------------------
# STEP 3 - Remove SCCM WMI namespaces
# ---------------------------------------------
function Remove-SCCMWmi {
    Write-Status "STEP 3: Cleaning up SCCM WMI namespaces..."
    $namespaces = @(
        "root\ccm",
        "root\cimv2\sms",
        "root\SmsDm",
        "root\sms"
    )
    $removed = @()
    foreach ($ns in $namespaces) {
        try {
            $parts  = $ns -split "\\"
            $parent = $parts[0..($parts.Count - 2)] -join "\"
            $child  = $parts[-1]
            $nsObj  = Get-WmiObject -Namespace $parent -Class __Namespace `
                                    -Filter "Name='$child'" -ErrorAction SilentlyContinue
            if ($nsObj) {
                Write-Detail "Removing WMI namespace: $ns"
                $nsObj.Delete()
                $removed += $ns
            } else {
                Write-Detail "WMI namespace not found (already removed?): $ns"
            }
        } catch {
            Write-Status "STEP 3: Failed to remove WMI namespace ${ns}: $_" "WARN"
        }
    }
    if ($removed.Count -gt 0) {
        Write-Status "STEP 3: Removed $($removed.Count) WMI namespace(s)."
    } else {
        Write-Status "STEP 3: No SCCM WMI namespaces found."
    }
}

# ---------------------------------------------
# STEP 4 - Delete leftover files & folders
# ---------------------------------------------
function Remove-SCCMFiles {
    Write-Status "STEP 4: Removing SCCM files and folders..."
    $paths = @(
        "C:\Windows\CCM",
        "C:\Windows\ccmsetup",
        "C:\Windows\ccmcache",
        "C:\Windows\SMSCFG.ini",
        "C:\Windows\SMS*.mif",
        "C:\Windows\SysWOW64\CCM"
    )
    $removed = 0
    foreach ($path in $paths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        if ($resolved) {
            foreach ($item in $resolved) {
                Write-Detail "Removing: $($item.Path)"
                Remove-Item -Path $item.Path -Recurse -Force -ErrorAction SilentlyContinue
                $removed++
            }
        } else {
            Write-Detail "Path not found (already removed?): $path"
        }
    }
    Write-Status "STEP 4: Removed $removed file/folder item(s)."
}

# ---------------------------------------------
# STEP 5 - Clean up registry keys
# ---------------------------------------------
function Remove-SCCMRegistry {
    Write-Status "STEP 5: Cleaning up SCCM registry keys..."
    $regKeys = @(
        "HKLM:\SOFTWARE\Microsoft\CCM",
        "HKLM:\SOFTWARE\Microsoft\CCMSetup",
        "HKLM:\SOFTWARE\Microsoft\SMS",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCM",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\CCMSetup",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS",
        "HKLM:\SYSTEM\CurrentControlSet\Services\CcmExec",
        "HKLM:\SYSTEM\CurrentControlSet\Services\smstsmgr",
        "HKLM:\SYSTEM\CurrentControlSet\Services\CmRcService"
    )
    $removed = 0
    foreach ($key in $regKeys) {
        if (Test-Path $key) {
            Write-Detail "Removing registry key: $key"
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        } else {
            Write-Detail "Registry key not found (already removed?): $key"
        }
    }

    # Remove the SCCM Control Panel applet entry (SMSCFGRC)
    $cplPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Cpls",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Control Panel\Cpls"
    )
    foreach ($cplPath in $cplPaths) {
        if (Test-Path $cplPath) {
            $val = Get-ItemProperty -Path $cplPath -Name "SMSCFGRC" -ErrorAction SilentlyContinue
            if ($val) {
                Write-Detail "Removing Control Panel applet entry: SMSCFGRC from $cplPath"
                Remove-ItemProperty -Path $cplPath -Name "SMSCFGRC" -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }

    Write-Status "STEP 5: Removed $removed registry key(s)/value(s)."
}

# ---------------------------------------------
# STEP 6 - Remove SCCM certificates from store
# ---------------------------------------------
function Remove-SCCMCertificates {
    Write-Status "STEP 6: Checking for SCCM certificates..."
    try {
        $certs = Get-ChildItem "Cert:\LocalMachine\SMS" -ErrorAction Stop
        if ($certs) {
            foreach ($cert in $certs) {
                Write-Detail "Removing certificate: $($cert.Thumbprint)"
                Remove-Item $cert.PSPath -Force -ErrorAction SilentlyContinue
            }
            Write-Status "STEP 6: Removed $($certs.Count) certificate(s)."
        } else {
            Write-Status "STEP 6: No SCCM certificates found."
        }
    } catch {
        Write-Status "STEP 6: No SMS certificate store found -- nothing to remove."
    }
}

# ---------------------------------------------
# STEP 7 - Remove Task Scheduler entries
# ---------------------------------------------
function Remove-SCCMScheduledTasks {
    Write-Status "STEP 7: Removing SCCM scheduled tasks..."
    try {
        $scheduler = New-Object -ComObject "Schedule.Service"
        $scheduler.Connect()
        $root = $scheduler.GetFolder("\Microsoft")

        # Check for the Configuration Manager folder
        try {
            $cmFolder = $root.GetFolder("Configuration Manager")
            $tasks = $cmFolder.GetTasks(0)
            $taskCount = $tasks.Count

            # Delete all tasks in the folder first
            foreach ($task in $tasks) {
                Write-Detail "Deleting scheduled task: $($task.Name)"
                $cmFolder.DeleteTask($task.Name, 0)
            }

            # Now delete the folder itself
            $root.DeleteFolder("Configuration Manager", 0)
            Write-Status "STEP 7: Removed Configuration Manager task folder ($taskCount task(s))."
        } catch {
            Write-Status "STEP 7: No 'Configuration Manager' task folder found -- nothing to remove."
        }
    } catch {
        Write-Status "STEP 7: Could not access Task Scheduler: $_" "WARN"
    }
}

# ---------------------------------------------
# MAIN
# ---------------------------------------------
Write-Status "===== SCCM Client Removal Started ====="
Write-Status "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Detail "Log file: $LogFile"

Invoke-CCMSetupUninstall
Remove-SCCMServices
Remove-SCCMWmi
Remove-SCCMFiles
Remove-SCCMRegistry
Remove-SCCMCertificates
Remove-SCCMScheduledTasks

Write-Status "===== SCCM Client Removal Complete -- Reboot recommended ====="