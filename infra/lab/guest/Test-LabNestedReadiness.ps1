#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$ExpectedBiosGuid,
    [Parameter(Mandatory)][hashtable]$ExpectedHashes,
    [bool]$Restricted = $false
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Test-NestedBlockedConnectError -CommandType Function -ErrorAction SilentlyContinue)) {
    if (-not $PSScriptRoot) { throw 'The verified TCP failure classifier must be supplied to the remote check.' }
    . (Join-Path $PSScriptRoot 'NestedIso.Helpers.ps1')
}
if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedBiosGuid -or
    (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'L2 identity mismatch.'
}
if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) { throw 'L2 has an Azure guest agent.' }
$os = Get-CimInstance Win32_OperatingSystem
if (([version]$os.Version).Build -ne 20348 -or $os.ProductType -ne 3) { throw 'L2 OS version/type mismatch.' }
$adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up')
if ($adapters.Count -ne 1) { throw 'L2 adapter mismatch.' }
$index = $adapters[0].ifIndex
$ips = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' })
if ($ips.Count -ne 1 -or $ips[0].IPAddress -ne '192.168.100.10' -or
    $ips[0].PrefixLength -ne 24 -or $ips[0].PrefixOrigin -ne 'Manual') { throw 'L2 IP mismatch.' }
$routes = @(Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0')
if ($routes.Count -ne 1 -or $routes[0].NextHop -ne '192.168.100.1') { throw 'L2 gateway mismatch.' }
$dns = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4).ServerAddresses)
if ($dns.Count -ne 1 -or $dns[0] -ne '10.30.1.5') { throw 'L2 DNS configuration mismatch.' }
$answers = @(Resolve-DnsName 'www.microsoft.com' -Server '10.30.1.5' -DnsOnly -ErrorAction Stop |
    Where-Object { $_.Type -in @('A', 'AAAA') })
if ($answers.Count -eq 0) { throw 'L2 DNS query returned no addresses.' }
foreach ($path in @(
    "$env:SystemRoot\Panther\unattend.xml",
    "$env:SystemRoot\Panther\Unattend\unattend.xml",
    "$env:SystemRoot\System32\Sysprep\unattend.xml"
)) {
    if (Test-Path -LiteralPath $path) { throw 'Known answer file remains.' }
}
if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -gt 0) {
    throw 'L2 firewall is disabled.'
}
foreach ($address in @('169.254.169.254', '169.254.169.253')) {
    $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name "OptionalLab-Block-IMDS-$address"
    $port = $rule | Get-NetFirewallPortFilter
    $filter = $rule | Get-NetFirewallAddressFilter
    if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or
        $rule.Profile -ne 'Any' -or $port.Protocol -ne 'TCP' -or $port.RemotePort -ne '80' -or
        @($filter.RemoteAddress).Count -ne 1 -or $filter.RemoteAddress -ne $address) {
        throw 'L2 active IMDS rule mismatch.'
    }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($address, 80)
        [void]$task.Wait(3000)
        if ($client.Connected) { throw 'L2 IMDS connection succeeded.' }
    }
    catch { if (-not (Test-NestedBlockedConnectError $_)) { throw } }
    finally { $client.Dispose() }
}
$names = @('Install-ArcAgent.ps1', 'Connect-ArcServer.ps1', 'Write-HandsonEvent.ps1')
if ($ExpectedHashes.Count -ne 3) { throw 'Unexpected handover hash count.' }
foreach ($path in @('C:\Handson', 'C:\Handson\lab-handover.marker')) {
    if (-not (Test-Path -LiteralPath $path) -or
        (Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Handover path missing or redirected.'
    }
}
if ((Get-Content -LiteralPath 'C:\Handson\lab-handover.marker' -Raw) -cne 'LabHandover-v1') {
    throw 'Handover marker mismatch.'
}
foreach ($name in $names) {
    $path = Join-Path 'C:\Handson' $name
    if (-not $ExpectedHashes.ContainsKey($name) -or $ExpectedHashes[$name] -notmatch '^[a-fA-F0-9]{64}$' -or
        -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHashes[$name]) {
        throw 'Handover file hash mismatch.'
    }
}
$licenses = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL AND LicenseIsAddon=FALSE")
if (@($licenses | Where-Object LicenseStatus -eq 1).Count -eq 0) { throw 'L2 Windows is not Licensed.' }
if ($Restricted) {
    # Two independent fresh direct TCP sockets, no HTTP proxy or existing session.
    foreach ($target in @('1.1.1.1', 'management.azure.com')) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($target, 443)
            [void]$task.Wait(4000)
            if ($client.Connected) { throw 'L2 public TCP connection succeeded.' }
        }
        catch { if (-not (Test-NestedBlockedConnectError $_)) { throw } }
        finally { $client.Dispose() }
    }
}
[pscustomobject]@{
    NestedReady = $true; IdentityReady = $true; NetworkReady = $true
    DnsReady = $true; ImdsBlocked = $true; HandoverFilesReady = $true
    Licensed = $true; InternetBlocked = [bool]$Restricted
    UpdatesBaseline = 'StandardImageOnly'
}
