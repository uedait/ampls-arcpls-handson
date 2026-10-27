#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$ExpectedBiosGuid)
$ErrorActionPreference = 'Stop'
$actualGuid = [guid](Get-CimInstance Win32_ComputerSystemProduct).UUID
if ($actualGuid -ne $ExpectedBiosGuid -or
    (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'L2 identity check failed. Refusing to modify network or IMDS settings.'
}
if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) {
    throw 'The L2 image must not contain the Azure VM guest agent. Use a clean on-premises Windows image.'
}
# Block IMDS before network configuration so the L2 cannot register as an Azure VM.
foreach ($address in @('169.254.169.254', '169.254.169.253')) {
    $name = "OptionalLab-Block-IMDS-$address"
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($rule) {
        $port = $rule | Get-NetFirewallPortFilter
        $filter = $rule | Get-NetFirewallAddressFilter
        if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or
            $port.Protocol -ne 'TCP' -or $port.RemotePort -ne '80' -or
            @($filter.RemoteAddress).Count -ne 1 -or $filter.RemoteAddress -ne $address -or
            $rule.Profile -ne 'Any') {
            throw "Existing IMDS rule conflicts: $name"
        }
    }
    else {
        New-NetFirewallRule -Name $name -DisplayName $name -Direction Outbound -Action Block `
            -Protocol TCP -RemoteAddress $address -RemotePort 80 -Profile Any | Out-Null
    }
}
if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -gt 0) {
    throw 'All Windows Firewall profiles must be enabled for IMDS blocking.'
}
$adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up')
if ($adapters.Count -ne 1) { throw 'Expected exactly one connected L2 network adapter.' }
$index = $adapters[0].ifIndex
$ips = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 |
    Where-Object { $_.PrefixOrigin -ne 'Dhcp' -and $_.IPAddress -notlike '169.254.*' })
if ($ips.Count -gt 0 -and ($ips.Count -ne 1 -or
    $ips[0].IPAddress -ne '192.168.100.10' -or $ips[0].PrefixLength -ne 24)) {
    throw 'Conflicting static IPv4 configuration. Existing addresses will not be overwritten.'
}
$routes = @(Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
if (@($routes | Where-Object NextHop -ne '192.168.100.1').Count -gt 0) {
    throw 'Conflicting default route. Existing routes will not be removed.'
}
if ($ips.Count -eq 0) {
    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
    New-NetIPAddress -InterfaceIndex $index -IPAddress '192.168.100.10' -PrefixLength 24 | Out-Null
}
if ($routes.Count -eq 0) {
    New-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -NextHop '192.168.100.1' | Out-Null
}
Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses '10.30.1.5'
Resolve-DnsName 'www.microsoft.com' -Server '10.30.1.5' -DnsOnly -ErrorAction Stop
Get-NetIPConfiguration -InterfaceIndex $index
