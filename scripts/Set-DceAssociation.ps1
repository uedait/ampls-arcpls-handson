#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$ExpectedTenantId,
    [Parameter(Mandatory)][guid]$ExpectedSubscriptionId,
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)][string]$DceId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common\AzureCli.ps1')
Assert-HandsonAzContext -ExpectedTenantId $ExpectedTenantId -ExpectedSubscriptionId $ExpectedSubscriptionId
$prefix = '^/subscriptions/' + [regex]::Escape($ExpectedSubscriptionId.ToString()) + '/resourceGroups/[^/]+/providers/'
if ($ResourceId -notmatch ($prefix + '(Microsoft\.Compute/virtualMachines|Microsoft\.HybridCompute/machines)/[^/]+$') -or
    $DceId -notmatch ($prefix + 'Microsoft\.Insights/dataCollectionEndpoints/[^/]+$')) {
    throw 'Use VM/Arc and DCE IDs from the approved subscription.'
}
$subscription = @('--subscription', $ExpectedSubscriptionId.ToString())
$target = Invoke-HandsonAz -Arguments (@('resource', 'show', '--ids', $ResourceId) + $subscription)
$dce = Invoke-HandsonAz -Arguments (@('resource', 'show', '--ids', $DceId) + $subscription)
if ($target.location -ne $dce.location) {
    throw 'Target and configuration DCE regions must match.'
}
$associations = @(Invoke-HandsonAz -Arguments (@('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', $ResourceId) + $subscription))
$existingDce = @($associations | Where-Object { $_['dataCollectionEndpointId'] })
if (@($existingDce | Where-Object { $_['dataCollectionEndpointId'] -ne $DceId }).Count -gt 0) {
    throw 'A different configuration DCE is associated. Review its owner before replacing it.'
}
if ($existingDce.Count -gt 0) {
    Write-Output 'The expected DCE is already associated; no change was made.'
    return
}
if (-not $PSCmdlet.ShouldProcess($ResourceId, "Associate configuration DCE $DceId")) { return }
$null = Invoke-HandsonAz -Arguments (@(
    'monitor', 'data-collection', 'rule', 'association', 'create',
    '--association-name', 'configurationAccessEndpoint',
    '--resource-uri', $ResourceId, '--data-collection-endpoint-id', $DceId
) + $subscription)
$after = @(Invoke-HandsonAz -Arguments (@('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', $ResourceId) + $subscription))
if (@($after | Where-Object { $_['dataCollectionEndpointId'] -eq $DceId }).Count -ne 1) {
    throw 'DCE association verification failed.'
}
Write-Output 'Configuration DCE association verified.'
