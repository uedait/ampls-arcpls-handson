#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$StructuredResult)
$ErrorActionPreference = 'Stop'
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'Run only on the L1 Hyper-V host (10.30.1.4).'
}
$adapter = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')
if ($adapter.Count -ne 1) { throw 'Hyper-V NIC identity is ambiguous.' }
Set-DnsClientServerAddress -InterfaceIndex $adapter[0].InterfaceIndex -ServerAddresses '10.30.1.5'
Resolve-DnsName 'www.microsoft.com' -Server '10.30.1.5' -DnsOnly -ErrorAction Stop | Out-Null
Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction Stop | Out-Null
$result = Install-WindowsFeature Hyper-V -IncludeManagementTools
if (-not $result.Success) { throw 'Hyper-V installation failed. Confirm nested virtualization support and Windows feature sources.' }
if ($result.RestartNeeded -eq 'Yes') {
    if ($StructuredResult) {
        return [pscustomobject]@{ RebootRequired = $true; HyperVReady = $false }
    }
    Write-Warning 'Restart required. Restart the L1 host through your approved management path, reconnect, then rerun this script.'
    return
}
if ((Get-Service vmms).Status -ne 'Running') {
    throw 'Hyper-V VMMS is not running. Reboot the L1 host and rerun before continuing.'
}
if ($StructuredResult) { return [pscustomobject]@{ RebootRequired = $false; HyperVReady = $true } }
Write-Host 'Hyper-V is ready. This script does not change the L1 IMDS access or restart the host automatically.'
