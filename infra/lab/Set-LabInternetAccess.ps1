#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$ExpectedTenantId,
    [Parameter(Mandatory)][guid]$ExpectedSubscriptionId,
    [guid]$ExpectedClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [ValidatePattern('^[a-z][a-z0-9]{1,11}$')][string]$Prefix = 'arclab',
    [Parameter(Mandatory)][ValidateSet('Build', 'Restricted')][string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'scripts\common\AzureCli.ps1')
$azContext = @{ExpectedTenantId=$ExpectedTenantId; ExpectedSubscriptionId=$ExpectedSubscriptionId}
if ($PSBoundParameters.ContainsKey('ExpectedClientId')) {
    $azContext.ExpectedClientId = $ExpectedClientId
    $azContext.ExpectedAzureConfigDir = $env:AZURE_CONFIG_DIR
}
Assert-HandsonAzContext @azContext
$scope = @('--resource-group', $ResourceGroup, '--subscription', $ExpectedSubscriptionId.ToString())
$access = if ($Mode -eq 'Restricted') { 'Deny' } else { 'Allow' }
$roles = @(
    @{ Name = 'workload'; Ip = '10.10.1.4' }
    @{ Name = 'dns'; Ip = '10.30.1.5' }
    @{ Name = 'hyperv'; Ip = '10.30.1.4' }
)
$targets = foreach ($role in $roles) {
    $name = "$Prefix-$($role.Name)"
    $group = Invoke-HandsonAz -ExpectedContext $azContext -Arguments (@('network', 'nsg', 'show', '--name', "$name-nsg") + $scope)
    if ($group.tags.purpose -ne 'optional-ampls-arcpls-lab') {
        throw "Unexpected owner tag on $name-nsg. No NSGs were changed."
    }
    $nic = Invoke-HandsonAz -ExpectedContext $azContext -Arguments (@('network', 'nic', 'show', '--name', "$name-nic") + $scope)
    if ($nic.networkSecurityGroup.id -ne $group.id -or
        $nic.virtualMachine.id -ne "/subscriptions/$ExpectedSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$name" -or
        @($nic.ipConfigurations | Where-Object { $_.privateIPAddress -eq $role.Ip }).Count -ne 1) {
        throw "NIC/NSG/VM ownership mismatch for $name. No NSGs were changed."
    }
    $rule = @($group.securityRules | Where-Object { $_.name -eq 'LabInternetOutbound' })
    if ($rule.Count -ne 1 -or $rule[0].priority -ne 400 -or
        $rule[0].direction -ne 'Outbound' -or $rule[0].protocol -ne '*' -or
        $rule[0].sourceAddressPrefix -ne '*' -or $rule[0].sourcePortRange -ne '*' -or
        $rule[0].destinationAddressPrefix -ne 'Internet' -or $rule[0].destinationPortRange -ne '*' -or
        $rule[0].access -notin 'Allow', 'Deny') {
        throw "Unexpected LabInternetOutbound rule on $name-nsg. No NSGs were changed."
    }
    $expectedOutbound = @('AllowDnsTcp', 'AllowDnsUdp', 'AllowPrivateEndpoints',
        'AllowExplicitProxy', 'AllowAzureWireServer', 'LabInternetOutbound')
    if (@($group.securityRules | Where-Object {
        $_.direction -eq 'Outbound' -and $_.name -notin $expectedOutbound
    }).Count -gt 0) {
        throw "Additional outbound rules found on $name-nsg. Review their effect before switching phases."
    }
    $allowDefinitions = @(
        @{ Name='AllowPrivateEndpoints'; Priority=110; Destination='10.20.1.0/24'; Port='443' }
        @{ Name='AllowExplicitProxy'; Priority=120; Destination='10.20.0.4'; Port='3128' }
    )
    foreach ($definition in $allowDefinitions) {
        $allow = @($group.securityRules | Where-Object { $_.name -eq $definition.Name })
        if ($allow.Count -ne 1 -or $allow[0].access -ne 'Allow' -or
            $allow[0].direction -ne 'Outbound' -or $allow[0].protocol -ne 'Tcp' -or
            $allow[0].priority -ne $definition.Priority -or
            $allow[0].destinationAddressPrefix -ne $definition.Destination -or
            $allow[0].destinationPortRange -ne $definition.Port) {
            throw "Unexpected private-path rule $($definition.Name) on $name-nsg. No NSGs were changed."
        }
    }
    [pscustomobject]@{ Name = "$name-nsg"; Before = $rule[0].access }
}

if (-not $PSCmdlet.ShouldProcess(
    "$ResourceGroup / $($targets.Name -join ', ')",
    "Set LabInternetOutbound to $access; existing flows can remain until closed. Verify new connections afterward."
)) { return }

$completed = [Collections.Generic.List[string]]::new()
foreach ($target in $targets) {
    if ($target.Before -eq $access) {
        Write-Output "$($target.Name): already $access."
        continue
    }
    try {
        $null = Invoke-HandsonAz -ExpectedContext $azContext -Arguments (@('network', 'nsg', 'rule', 'update',
            '--nsg-name', $target.Name, '--name', 'LabInternetOutbound', '--access', $access) + $scope)
        $after = Invoke-HandsonAz -ExpectedContext $azContext -Arguments (@('network', 'nsg', 'rule', 'show',
            '--nsg-name', $target.Name, '--name', 'LabInternetOutbound') + $scope)
        if ($after.access -ne $access -or $after.direction -ne 'Outbound' -or
            $after.destinationAddressPrefix -ne 'Internet' -or $after.priority -ne 400) {
            throw 'Post-change rule verification failed.'
        }
        $completed.Add($target.Name)
        Write-Output "$($target.Name): $($target.Before) -> $access verified."
    } catch {
        throw "Phase change stopped at $($target.Name). Verified changes: $($completed -join ', '). Inspect this NSG and complete or restore the approved phase. $($_.Exception.Message)"
    }
}
Write-Output "Rule state is $Mode. Verify fresh TCP connections, DNS and Bastion before accepting the phase."
