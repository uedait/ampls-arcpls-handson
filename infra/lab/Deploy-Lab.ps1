#requires -Version 7.0
<#
Uses the reader's interactive Azure CLI login. Never imports workspace credentials.
Azure CLI prompts for the missing secure adminPassword; do not use --no-prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$ParameterFile = (Join-Path $PSScriptRoot 'example.bicepparam')
)
$ErrorActionPreference = 'Stop'
function Invoke-AzJson {
    param([string[]]$Arguments)
    $result = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0])" }
    return ($result | ConvertFrom-Json -Depth 100)
}
Get-Command az -ErrorAction Stop | Out-Null
$account = Invoke-AzJson -Arguments @('account', 'show', '--subscription', "$SubscriptionId")
if ($account.tenantId -ne "$TenantId" -or $account.id -ne "$SubscriptionId" -or
    $account.state -ne 'Enabled' -or $account.user.type -ne 'user') {
    throw 'Expected an enabled subscription and the reader interactive user login. Check az login.'
}
Write-Host "Tenant: $TenantId / Subscription: $SubscriptionId / RG: $ResourceGroupName"
if ((Read-Host 'Type the subscription ID to confirm this target') -ne "$SubscriptionId") {
    throw 'Target not confirmed.'
}
$generatedDirectory = Join-Path $PSScriptRoot '.generated'
if (-not (Test-Path -LiteralPath $generatedDirectory)) {
    New-Item -ItemType Directory -Path $generatedDirectory | Out-Null
}
$publicParameterPath = Join-Path $generatedDirectory "lab-$([guid]::NewGuid().ToString('N')).parameters.json"
# --stdout may wrap parametersJson/templateJson. --outfile produces a plain parameter document.
& az bicep build-params --file $ParameterFile --outfile $publicParameterPath
if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed. Bicep 0.31+ is required.' }
$parameterObject = (Get-Content -LiteralPath $publicParameterPath -Raw | ConvertFrom-Json -Depth 100).parameters
$allowedParameters = @('prefix', 'location', 'workloadVmSize', 'dnsVmSize', 'hyperVVmSize')
if (-not $parameterObject -or @($parameterObject.PSObject.Properties.Name |
    Where-Object { $_ -notin $allowedParameters }).Count -gt 0) {
    throw 'Use the non-secret example parameter schema; do not store adminPassword.'
}
if ($parameterObject.prefix.value -notmatch '^[a-z][a-z0-9]{1,11}$') {
    throw 'prefix must start with a lowercase letter and contain 2-12 lowercase letters/digits.'
}
$region = $parameterObject.location.value
if (-not $region) { throw 'location is required in the parameter file.' }
foreach ($key in @('workloadVmSize', 'dnsVmSize', 'hyperVVmSize')) {
    $size = $parameterObject.$key.value
    if (-not $size) { throw "Missing $key." }
    $skus = @(Invoke-AzJson -Arguments @('vm', 'list-skus', '--location', $region,
        '--size', $size, '--all', '--subscription', "$SubscriptionId"))
    $sku = @($skus | Where-Object { $_.name -eq $size -and $_.resourceType -eq 'virtualMachines' })
    if ($sku.Count -ne 1 -or @($sku[0].restrictions).Count -gt 0) {
        throw "SKU unavailable/restricted or ambiguous: $size in $region. Check quota and availability."
    }
    $generation = $sku[0].capabilities | Where-Object name -eq 'HyperVGenerations'
    if (-not $generation -or $generation.value -notmatch 'V2') { throw "$size must support Gen2." }
}
Write-Host "Hyper-V host SKU: $($parameterObject.hyperVVmSize.value)"
Write-Host 'The hub includes Azure Bastion Standard (2 scale units) and its dedicated Standard Public IP. Include both in the approved budget.'
Write-Host 'SKU listing does not prove nested virtualization support, quota or deployable capacity.'
if ((Read-Host 'Confirm documented nested-virtualization support, quota, costs and region: type APPROVE') -ne 'APPROVE') {
    throw 'Deployment not approved.'
}
$exists = & az group exists --name $ResourceGroupName --subscription "$SubscriptionId" --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Resource group existence check failed.' }
if ("$exists".Trim() -ne 'true') {
    & az group create --name $ResourceGroupName --location $region --subscription "$SubscriptionId" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Resource group creation failed.' }
}
else {
    $resources = @(Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $ResourceGroupName,
        '--subscription', "$SubscriptionId"))
    if ($resources.Count -gt 0) { throw 'Use an empty resource group. Existing resources will not be overwritten.' }
}
# The generated parameter JSON contains only public configuration. The CLI prompts for adminPassword.
# Do not enable debug/input logging. Suppress the deployment response on stdout.
& az deployment group create --name 'optional-lab' --resource-group $ResourceGroupName `
    --subscription "$SubscriptionId" --template-file (Join-Path $PSScriptRoot 'main.bicep') `
    --parameters "@$publicParameterPath" --mode Incremental --output none
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. Inspect the resource group before retrying; no cleanup was run.' }
