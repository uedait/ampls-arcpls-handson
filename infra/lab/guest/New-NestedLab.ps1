#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceVhdx,
    [string]$VmName = 'ArcOnpremL2',
    [string]$VmDirectory = 'C:\NestedLab',
    [string]$SwitchName = 'OptionalLab-Internal',
    [string]$NatName = 'OptionalLab-NAT'
)
$ErrorActionPreference = 'Stop'
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'Run only on the L1 Hyper-V host (10.30.1.4). L1 IMDS settings must not be changed.'
}
Import-Module Hyper-V -ErrorAction Stop
if ((Get-Service vmms).Status -ne 'Running') { throw 'Install Hyper-V, reboot the host, then retry.' }
foreach ($file in @('Set-NestedGuest.ps1', 'Test-NestedImds.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) {
        throw "Missing companion script: $file"
    }
}
$source = Get-Item -LiteralPath $SourceVhdx -ErrorAction Stop
if ($source.Extension -ne '.vhdx') { throw 'A legally prepared, generalized Gen2 Windows Server VHDX is required.' }
if ((Get-VHD -Path $source.FullName).Attached) { throw 'Source VHDX is attached. Use an offline source disk.' }
if ($VmName -notmatch '^[a-zA-Z0-9-]{1,40}$') { throw 'Use an alphanumeric VM name (hyphen allowed).' }
$diskPath = Join-Path $VmDirectory "$VmName.vhdx"
$existingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existingVm) {
    $disks = @(Get-VMHardDiskDrive -VMName $VmName)
    $adapters = @(Get-VMNetworkAdapter -VMName $VmName)
    if ($existingVm.Generation -ne 2 -or $disks.Count -ne 1 -or
        $disks[0].Path -ne $diskPath -or $adapters.Count -ne 1 -or
        $adapters[0].SwitchName -ne $SwitchName) {
        throw 'Existing VM conflicts with the expected lab layout. No VM will be overwritten or deleted.'
    }
}
elseif (Test-Path -LiteralPath $diskPath) {
    throw 'Destination disk exists without the expected VM. Resolve the conflict manually; nothing is overwritten.'
}
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch -and $switch.SwitchType -ne 'Internal') { throw 'Existing switch is not Internal. No changes made.' }
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne '192.168.100.0/24') {
    throw 'Existing NAT name has a different prefix.'
}
# Multiple WinNAT internal prefixes are not supported by this lab.
$otherNats = @(Get-NetNat | Where-Object Name -ne $NatName)
if ($otherNats.Count -gt 0) { throw 'Another WinNAT configuration exists. Resolve it manually before continuing.' }
$conflictingIps = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -like '192.168.100.*' -and $_.InterfaceAlias -ne "vEthernet ($SwitchName)"
})
if ($conflictingIps.Count -gt 0) { throw '192.168.100.0/24 overlaps another host interface.' }
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
if (-not $existingVm) {
    if (-not (Test-Path -LiteralPath $VmDirectory)) {
        New-Item -ItemType Directory -Path $VmDirectory | Out-Null
    }
    # Never download OS media or modify the source disk.
    Copy-Item -LiteralPath $source.FullName -Destination $diskPath -ErrorAction Stop
    $existingVm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 4GB `
        -VHDPath $diskPath -SwitchName $SwitchName -Path $VmDirectory
    Set-VMProcessor -VMName $VmName -Count 2
    Set-VM -VMName $VmName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
}
if ($existingVm.State -eq 'Off') { Start-VM -Name $VmName | Out-Null }
elseif ($existingVm.State -ne 'Running') { throw 'VM must be Off or Running. Resolve its state manually.' }
$vm = Get-VM -Name $VmName
if (-not $vm.BiosGuid) { throw 'Cannot obtain the nested VM BIOS GUID; refusing guest configuration.' }
$credential = Get-Credential -Message 'Enter the L2 local administrator credentials (never stored by this script)'
if (-not $credential) { throw 'Guest credentials are required.' }
try {
    # PowerShell Direct never falls back to a host session or network remoting.
    Invoke-Command -VMName $VmName -Credential $credential -FilePath `
        (Join-Path $PSScriptRoot 'Set-NestedGuest.ps1') -ArgumentList "$($vm.BiosGuid)" -ErrorAction Stop
    Invoke-Command -VMName $VmName -Credential $credential -FilePath `
        (Join-Path $PSScriptRoot 'Test-NestedImds.ps1') -ArgumentList "$($vm.BiosGuid)" -ErrorAction Stop
}
catch {
    throw "Nested guest configuration/verification failed; resources were retained. Complete OOBE, confirm credentials and PowerShell Direct readiness, then rerun. $($_.Exception.Message)"
}
finally { $credential = $null }
Write-Host 'L2 configured: 192.168.100.10/24, gateway 192.168.100.1, DNS 10.30.1.5. Register only this L2 with Arc.'
