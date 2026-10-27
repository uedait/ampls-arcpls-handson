#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$StructuredResult)
$ErrorActionPreference = 'Stop'
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.5')) {
    throw 'Run this script only on the lab DNS VM (10.30.1.5).'
}
$result = Install-WindowsFeature DNS -IncludeManagementTools
if (-not $result.Success) { throw 'DNS role installation failed.' }
if ($result.RestartNeeded -eq 'Yes') {
    if ($StructuredResult) {
        return [pscustomobject]@{ RebootRequired = $true; DnsReady = $false }
    }
    throw 'Restart the DNS VM, then run this script again.'
}
Import-Module DnsServer
$forwarders = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.ToString() })
if ($forwarders.Count -gt 0 -and
    ($forwarders.Count -ne 1 -or $forwarders[0] -ne '168.63.129.16')) {
    throw 'Unexpected existing forwarders. No forwarder configuration was changed.'
}
Set-DnsServerForwarder -IPAddress '168.63.129.16'
Start-Service DNS
if ((Get-Service DNS).Status -ne 'Running') { throw 'DNS service is not running.' }
# Allow only this simulated on-premises network. No conditional forwarders are created.
foreach ($protocol in @('UDP', 'TCP')) {
    $name = "OptionalLab-DNS-$protocol"
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($rule) {
        $port = $rule | Get-NetFirewallPortFilter
        $address = $rule | Get-NetFirewallAddressFilter
        if ($rule.Action -ne 'Allow' -or $rule.Enabled -ne 'True' -or
            $rule.Direction -ne 'Inbound' -or $port.LocalPort -ne '53' -or
            $port.Protocol -ne $protocol -or
            @($address.RemoteAddress).Count -ne 1 -or $address.RemoteAddress -ne '10.30.0.0/16') {
            throw "Existing firewall rule conflicts: $name"
        }
    }
    else {
        New-NetFirewallRule -Name $name -DisplayName $name -Direction Inbound `
            -Action Allow -Protocol $protocol -LocalPort 53 -RemoteAddress '10.30.0.0/16' `
            -Profile Any | Out-Null
    }
}
$adapter = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.5')
if ($adapter.Count -ne 1) { throw 'DNS NIC identity is ambiguous.' }
$effectiveForwarders = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.ToString() })
if ((Get-Service DNS).Status -ne 'Running' -or $effectiveForwarders.Count -ne 1 -or
    $effectiveForwarders[0] -ne '168.63.129.16') {
    throw 'DNS service/forwarder is not ready for self-reference.'
}
$answers = @(Resolve-DnsName 'www.microsoft.com' -Server '10.30.1.5' -DnsOnly -NoHostsFile `
    -ErrorAction Stop | Where-Object { $_.Type -in @('A','AAAA') })
if ($answers.Count -eq 0) { throw 'Explicit DNS self-query returned no addresses.' }
# Switch only after service, effective forwarder and explicit self-query pass.
# Failure never implicitly restores a former guest/NIC DNS configuration.
Set-DnsClientServerAddress -InterfaceIndex $adapter[0].InterfaceIndex -ServerAddresses '10.30.1.5'
Resolve-DnsName 'www.microsoft.com' -Server '10.30.1.5' -DnsOnly -ErrorAction Stop | Out-Null
Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction Stop | Out-Null
if ($StructuredResult) { return [pscustomobject]@{ RebootRequired = $false; DnsReady = $true } }
Write-Host 'DNS role ready. The seven conditional forwarders are configured manually in chapter 03.'
