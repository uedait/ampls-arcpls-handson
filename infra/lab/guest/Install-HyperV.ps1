#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'Run only on the L1 Hyper-V host (10.30.1.4).'
}
$result = Install-WindowsFeature Hyper-V -IncludeManagementTools
if (-not $result.Success) { throw 'Hyper-V installation failed. Confirm nested virtualization support and Windows feature sources.' }
if ($result.RestartNeeded -eq 'Yes') {
    Write-Warning 'Restart required. Restart the L1 host through your approved management path, reconnect, then rerun this script.'
    return
}
if ((Get-Service vmms).Status -ne 'Running') {
    throw 'Hyper-V VMMS is not running. Reboot the L1 host and rerun before continuing.'
}
Write-Host 'Hyper-V is ready. This script does not change the L1 IMDS access or restart the host automatically.'
