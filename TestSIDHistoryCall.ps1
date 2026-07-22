#requires -version 5.1
 
<#
    Calls:
      DsMakePasswordCredentials - source
      DsMakePasswordCredentials - target
      DsBindWithCred             - target PDC
      DsAddSidHistory            - source -> target account
 
    Run from an elevated 64-bit PowerShell session.
 
#>
 
# -----------------------------
# Inputs
# -----------------------------
 
$SourceUsername = "source-admin"             # just the user name of the service account per PSP config (e.g. psp.svc)
$SourceDomainForCreds = "SOURCE"             # the domain part of the service account per PSP config - netbios or fqdn (e.g. CONTOSO or contoso.com)
$SourcePassword = "SourcePasswordHere"       # Password for the source domain service account.
 
$TargetUsername = "target-admin"             # just the user name of the service account per PSP config (e.g. psp.svc)
$TargetDomainForCreds = "TARGET"             # the domain part of the service account per PSP config - netbios or fqdn (e.g. FABRIKAM or fabrikam.com)
$TargetPassword = "TargetPasswordHere"       # Password for the target domain service account.
 
$TargetPdcController = "target-pdc.target.local" # FQDN / IP of the Primary DC in the Target Domain (e.g. dc1.fabrikam.com)
$TargetDirectoryName = "target.local"            # FQDN of the Target Directory (e.g. fabrikam.com)
 
$SourceDomainName = "source.local"            # FQDN of the Source Directory (e.g. contoso.com)
$SourceSamAccountName = "sourceuser"          # SAM Account Name of the Source Account for a SID History Migration (e.g. john.smith)
 
$SourcePdcController = "source-pdc.source.local" # FQDN / IP of the Primary DC in the Source (e.g. dc1.contoso.com)
 
$TargetDomainName = "target.local"            # FQDN of the Target Directory (e.g. fabrikam.com)
$TargetSamAccountName = "targetuser"          # SAM Account Name of the Target account for a SID History Migration (e.g. john.smith)
 
# -----------------------------
# Native API declarations
# -----------------------------
 
$ntdsApiCode = @"
using System;
using System.Runtime.InteropServices;
 
public static class Ntdsapi
{
    [DllImport("ntdsapi.dll", CharSet = CharSet.Unicode)]
    public static extern int DsMakePasswordCredentials(
        string User,
        string Domain,
        string Password,
        out IntPtr AuthIdentity
    );
 
    [DllImport("ntdsapi.dll")]
    public static extern void DsFreePasswordCredentials(
        IntPtr AuthIdentity
    );
 
    [DllImport("ntdsapi.dll", CharSet = CharSet.Unicode)]
    public static extern int DsBindWithCred(
        string DomainControllerName,
        string DnsDomainName,
        IntPtr AuthIdentity,
        out IntPtr BindHandle
    );
 
    [DllImport("ntdsapi.dll")]
    public static extern int DsUnBind(
        ref IntPtr BindHandle
    );
 
    [DllImport("ntdsapi.dll", CharSet = CharSet.Unicode)]
    public static extern int DsAddSidHistory(
        IntPtr DestinationDomainHandle,
        int Flags,
        string SrcDomain,
        string SrcPrincipal,
        string SrcDomainController,
        IntPtr SrcDomainCreds,
        string DstDomain,
        string DstPrincipal
    );
}
"@
 
Add-Type -TypeDefinition $ntdsApiCode -ErrorAction Stop
 
function Throw-IfWin32Error {
    param(
        [Parameter(Mandatory)]
        [int] $ReturnCode,
 
        [Parameter(Mandatory)]
        [string] $Operation
    )
 
    if ($ReturnCode -ne 0) {
        $ex = New-Object ComponentModel.Win32Exception($ReturnCode)
        throw "$Operation failed. Return code: $ReturnCode. Message: $($ex.Message)"
    }
}
 
# -----------------------------
# Execute
# -----------------------------
 
$sourceCreds = [IntPtr]::Zero
$targetCreds = [IntPtr]::Zero
$targetBinding = [IntPtr]::Zero
 
try {
    Write-Host "Creating source credential handle..."
    $rc = [Ntdsapi]::DsMakePasswordCredentials(
        $SourceUsername,
        $SourceDomainForCreds,
        $SourcePassword,
        [ref] $sourceCreds
    )
    Throw-IfWin32Error $rc "DsMakePasswordCredentials source"
 
    Write-Host "Creating target credential handle..."
    $rc = [Ntdsapi]::DsMakePasswordCredentials(
        $TargetUsername,
        $TargetDomainForCreds,
        $TargetPassword,
        [ref] $targetCreds
    )
    Throw-IfWin32Error $rc "DsMakePasswordCredentials target"
 
    Write-Host "Binding to target domain..."
    $rc = [Ntdsapi]::DsBindWithCred(
        $TargetPdcController,
        $TargetDirectoryName,
        $targetCreds,
        [ref] $targetBinding
    )
    Throw-IfWin32Error $rc "DsBindWithCred target"
 
    Write-Host "Calling DsAddSidHistory..."
    $rc = [Ntdsapi]::DsAddSidHistory(
        $targetBinding,
        0,
        $SourceDomainName,
        $SourceSamAccountName,
        $SourcePdcController,
        $sourceCreds,
        $TargetDomainName,
        $TargetSamAccountName
    )
    Throw-IfWin32Error $rc "DsAddSidHistory"
 
    Write-Host "DsAddSidHistory completed successfully."
}
finally {
    if ($targetBinding -ne [IntPtr]::Zero) {
        Write-Host "Unbinding target handle..."
        [void] [Ntdsapi]::DsUnBind([ref] $targetBinding)
    }
 
    if ($sourceCreds -ne [IntPtr]::Zero) {
        Write-Host "Freeing source credential handle..."
        [Ntdsapi]::DsFreePasswordCredentials($sourceCreds)
    }
 
    if ($targetCreds -ne [IntPtr]::Zero) {
        Write-Host "Freeing target credential handle..."
        [Ntdsapi]::DsFreePasswordCredentials($targetCreds)
    }
}
