#requires -Version 7.0
# Local-only checks. Does not authenticate to Azure, install tools, or deploy resources.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($errorItem in $parseErrors) { $failures.Add("$($file.Name): $errorItem") }
}
$bicep = Get-Command bicep -ErrorAction SilentlyContinue
if (-not $bicep) {
    $failures.Add('Bicep CLI not found on PATH. Bicep build and build-params were not executed.')
}
else {
    $bastionFailureCount = $failures.Count
    $compiled = & $bicep.Source build (Join-Path $PSScriptRoot 'main.bicep') --stdout
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('main.bicep compilation failed.')
    }
    else {
        $template = ($compiled -join "`n") | ConvertFrom-Json -Depth 100
        $bastions = @($template.resources | Where-Object type -eq 'Microsoft.Network/bastionHosts')
        $hub = @($template.resources | Where-Object {
            $_.type -eq 'Microsoft.Network/virtualNetworks' -and $_.properties.addressSpace.addressPrefixes -contains '10.20.0.0/16'
        })
        if ($bastions.Count -ne 1 -or $bastions[0].sku.name -ne 'Standard' -or
            $bastions[0].properties.scaleUnits -ne 2 -or $bastions[0].properties.enableTunneling -ne $true) {
            $failures.Add('Expected one Standard Bastion with two scale units and native client support.')
        }
        if ($hub.Count -ne 1 -or @($hub[0].properties.subnets | Where-Object {
            $_.name -eq 'AzureBastionSubnet' -and $_.properties.addressPrefix -eq '10.20.3.0/26'
        }).Count -ne 1) {
            $failures.Add('Expected AzureBastionSubnet 10.20.3.0/26 in the hub.')
        }
        $publicIps = @($template.resources | Where-Object type -eq 'Microsoft.Network/publicIPAddresses')
        if ($publicIps.Count -ne 2 -or @($publicIps | Where-Object {
            $_.sku.name -ne 'Standard' -or $_.properties.publicIPAllocationMethod -ne 'Static'
        }).Count -gt 0) {
            $failures.Add('Expected separate Standard static Public IPs for Firewall and Bastion.')
        }
        foreach ($deployment in @($template.resources | Where-Object type -eq 'Microsoft.Resources/deployments')) {
            $guestResources = $deployment.properties.template.resources
            $vmPips = @($guestResources | Where-Object type -eq 'Microsoft.Network/publicIPAddresses')
            $vmNsgs = @($guestResources | Where-Object type -eq 'Microsoft.Network/networkSecurityGroups')
            if ($vmPips.Count -ne 1 -or $vmPips[0].sku.name -ne 'Standard' -or
                $vmPips[0].properties.publicIPAllocationMethod -ne 'Static' -or $vmNsgs.Count -ne 1) {
                $failures.Add('Each VM module must create a dedicated Standard static Public IP and NSG.')
                continue
            }
            $rules = @($vmNsgs[0].properties.securityRules)
            $expected = @{
                AllowBastionRdp = @{ priority=100; direction='Inbound'; access='Allow'; protocol='Tcp'; sourceAddressPrefix='10.20.3.0/26'; destinationPortRange='3389' }
                DenyOtherRdp = @{ priority=150; direction='Inbound'; access='Deny'; sourceAddressPrefix='*'; destinationPortRange='3389' }
                DenyInternetInbound = @{ priority=200; direction='Inbound'; access='Deny'; sourceAddressPrefix='Internet'; destinationPortRange='*' }
                AllowPrivateEndpoints = @{ priority=110; direction='Outbound'; access='Allow'; destinationAddressPrefix='10.20.1.0/24'; destinationPortRange='443' }
                AllowExplicitProxy = @{ priority=120; direction='Outbound'; access='Allow'; destinationAddressPrefix='10.20.0.4'; destinationPortRange='3128' }
                LabInternetOutbound = @{ priority=400; direction='Outbound'; access='Allow'; destinationAddressPrefix='Internet'; destinationPortRange='*' }
            }
            foreach ($name in $expected.Keys) {
                $found = @($rules | Where-Object name -eq $name)
                foreach ($key in $expected[$name].Keys) {
                    if ($found.Count -ne 1 -or $found[0].properties.$key -ne $expected[$name][$key]) {
                        $failures.Add("Unexpected $key on NSG rule $name.")
                    }
                }
            }
            foreach ($nic in @($guestResources | Where-Object type -eq 'Microsoft.Network/networkInterfaces')) {
                if (-not $nic.properties.networkSecurityGroup.id) {
                    $failures.Add('VM NIC must reference its dedicated NSG.')
                }
                foreach ($configuration in $nic.properties.ipConfigurations) {
                    if (-not $configuration.properties.publicIPAddress.id) {
                        $failures.Add('VM NIC must reference its dedicated Public IP for build-time outbound.')
                    }
                }
            }
        }
        if ($failures.Count -eq $bastionFailureCount) {
            Write-Output 'PASS: hub Bastion Standard, native client support, each VM Public IP/NSG, Bastion-only RDP and explicit outbound phase rule.'
        }
    }
    & $bicep.Source build-params (Join-Path $PSScriptRoot 'example.bicepparam') --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add('example.bicepparam compilation failed; Bicep 0.31+ is required.') }
}
if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Output 'PASS: PowerShell syntax (current PS7 parser), Bicep template and standalone parameters compiled.'
Write-Output 'Not tested: PS5.1 runtime, Azure availability/quota/cost, deployment, guest boot, DNS, WinNAT, PowerShell Direct and IMDS isolation.'
