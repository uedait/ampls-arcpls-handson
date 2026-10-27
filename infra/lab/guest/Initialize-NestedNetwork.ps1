#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SwitchName = 'OptionalLab-Internal',
    [string]$NatName = 'OptionalLab-NAT'
)
$ErrorActionPreference = 'Stop'
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4') -or
    (Get-Service vmms).Status -ne 'Running') { throw 'Requires the running L1 Hyper-V host at 10.30.1.4.' }
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch -and $switch.SwitchType -ne 'Internal') { throw 'Existing switch is not Internal. No changes made.' }
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne '192.168.100.0/24') {
    throw 'Existing NAT name has a different prefix.'
}
if (@(Get-NetNat | Where-Object Name -ne $NatName).Count -gt 0) {
    throw 'Another WinNAT configuration exists. Resolve it manually before continuing.'
}
if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -like '192.168.100.*' -and $_.InterfaceAlias -ne "vEthernet ($SwitchName)"
}).Count -gt 0) { throw '192.168.100.0/24 overlaps another host interface.' }
if (-not $switch) { $switch = New-VMSwitch -Name $SwitchName -SwitchType Internal }
$adapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction Stop
$static = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' })
if ($static.Count -gt 0 -and ($static.Count -ne 1 -or
    $static[0].IPAddress -ne '192.168.100.1' -or $static[0].PrefixLength -ne 24)) {
    throw 'Internal switch has conflicting IPv4 settings. No existing IP will be removed.'
}
if ($static.Count -eq 0) {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress '192.168.100.1' -PrefixLength 24 | Out-Null
}
if (-not $nat) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix '192.168.100.0/24' | Out-Null
}
