#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$ExpectedBiosGuid)
$ErrorActionPreference = 'Stop'
if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedBiosGuid -or
    -not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '192.168.100.10')) {
    throw 'L2 identity/IP check failed. Do not run IMDS configuration or tests on L1.'
}
if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -gt 0) {
    throw 'Windows Firewall must be enabled on every profile.'
}
foreach ($address in @('169.254.169.254', '169.254.169.253')) {
    $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name "OptionalLab-Block-IMDS-$address" -ErrorAction Stop
    $port = $rule | Get-NetFirewallPortFilter
    $filter = $rule | Get-NetFirewallAddressFilter
    if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or
        $rule.Profile -ne 'Any' -or $port.Protocol -ne 'TCP' -or $port.RemotePort -ne '80' -or
        @($filter.RemoteAddress).Count -ne 1 -or $filter.RemoteAddress -ne $address) {
        throw "IMDS block rule is not effective as expected: $address"
    }
    $client = New-Object System.Net.Sockets.TcpClient
    $connected = $false
    try {
        $task = $client.ConnectAsync($address, 80)
        if ($task.Wait(3000)) { $connected = $client.Connected }
    }
    catch [System.AggregateException] {
        # A refused/blocked TCP connection is expected.
    }
    finally { $client.Dispose() }
    if ($connected) { throw "FAIL: L2 can connect to ${address}:80." }
    Write-Output "PASS: active outbound block rule present; TCP connection to ${address}:80 failed."
}
Write-Output 'Connection failure alone does not establish a firewall drop; the active rules above are also verified.'
