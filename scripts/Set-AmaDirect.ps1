#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$ExpectedTenantId,
    [Parameter(Mandatory)][guid]$ExpectedSubscriptionId,
    [Parameter(Mandatory)][ValidateSet('AzureVm', 'ArcServer')][string]$ResourceType,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MachineName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common\AzureCli.ps1')
Assert-HandsonAzContext -ExpectedTenantId $ExpectedTenantId -ExpectedSubscriptionId $ExpectedSubscriptionId
$scope = @('--resource-group', $ResourceGroup, '--subscription', $ExpectedSubscriptionId.ToString())
if ($ResourceType -eq 'AzureVm') {
    $show = @('vm', 'extension', 'show', '--vm-name', $MachineName, '--name', 'AzureMonitorWindowsAgent') + $scope
} else {
    $show = @('connectedmachine', 'extension', 'show', '--machine-name', $MachineName, '--name', 'AzureMonitorWindowsAgent') + $scope
}
$extension = Invoke-HandsonAz -Arguments $show
if ($extension.publisher -ne 'Microsoft.Azure.Monitor') {
    throw 'The existing extension is not the expected Azure Monitor Windows Agent.'
}
$settings = $extension.settings
if ($null -eq $settings) { $settings = @{} }
$settings['proxy'] = @{ mode = 'none' }
if (-not $PSCmdlet.ShouldProcess("$ResourceType / $ResourceGroup / $MachineName", 'Update only the AMA proxy setting to mode=none')) {
    return
}
$temp = New-TemporaryFile
try {
    $settings | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp.FullName -Encoding utf8NoBOM
    if ($ResourceType -eq 'AzureVm') {
        $set = @('vm', 'extension', 'set', '--vm-name', $MachineName,
            '--name', 'AzureMonitorWindowsAgent', '--publisher', 'Microsoft.Azure.Monitor')
    } else {
        $set = @('connectedmachine', 'extension', 'update', '--machine-name', $MachineName, '--name', 'AzureMonitorWindowsAgent')
    }
    $null = Invoke-HandsonAz -Arguments ($set + $scope + @('--settings', ('@' + $temp.FullName)))
    $verified = Invoke-HandsonAz -Arguments $show
    if ($verified.settings.proxy.mode -ne 'none' -or $verified.provisioningState -ne 'Succeeded') {
        throw 'AMA proxy setting verification failed.'
    }
    [pscustomobject]@{ ResourceId = $verified.id; ProxyMode = $verified.settings.proxy.mode; ProvisioningState = $verified.provisioningState }
} finally {
    Remove-Item -LiteralPath $temp.FullName -Force
}
