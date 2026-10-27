#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+$')][string]$Location,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._-]+$')][string]$MachineName,
    [Parameter(Mandatory)][string]$PrivateLinkScopeId,
    [Parameter(Mandatory)][uri]$ProxyUri
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($TenantId -eq [guid]::Empty -or $SubscriptionId -eq [guid]::Empty) {
    throw 'Replace placeholder tenant/subscription IDs.'
}
$scopePattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId.ToString()) +
    '/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/privateLinkScopes/[^/]+$'
if ($PrivateLinkScopeId -notmatch $scopePattern) {
    throw 'The Arc PLS ID must belong to the expected subscription and resource type.'
}
if ($ProxyUri.Scheme -ne 'http' -or $ProxyUri.UserInfo -or
    $ProxyUri.AbsolutePath -ne '/' -or $ProxyUri.Query -or $ProxyUri.Fragment) {
    throw 'Use an unauthenticated HTTP explicit proxy URL without a path.'
}
$agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
if (-not (Test-Path -LiteralPath $agent)) {
    throw 'Install the Connected Machine Agent first.'
}
$rawState = & $agent show --json
if ($LASTEXITCODE -ne 0) { throw "azcmagent show failed (exit $LASTEXITCODE)." }
$state = ($rawState -join "`n") | ConvertFrom-Json
if (-not $state.PSObject.Properties['status'] -or $state.status -ne 'Disconnected') {
    throw 'This script only supports a disconnected, newly prepared agent. Review existing registration before changing it.'
}
if (-not $PSCmdlet.ShouldProcess("$TenantId / $SubscriptionId / $ResourceGroup / $MachineName", 'Configure Arc proxy and connect using the specified private link scope')) {
    return
}

& $agent config set proxy.url $ProxyUri.AbsoluteUri.TrimEnd('/')
if ($LASTEXITCODE -ne 0) { throw "Setting proxy.url failed (exit $LASTEXITCODE)." }
& $agent config set proxy.bypass Arc
if ($LASTEXITCODE -ne 0) { throw "Setting proxy.bypass failed (exit $LASTEXITCODE)." }
& $agent check --location $Location --enable-pls-check
if ($LASTEXITCODE -ne 0) { throw "Arc network check failed (exit $LASTEXITCODE). Registration was not attempted." }
& $agent connect --tenant-id $TenantId.ToString() --subscription-id $SubscriptionId.ToString() `
    --resource-group $ResourceGroup --location $Location --resource-name $MachineName `
    --private-link-scope $PrivateLinkScopeId --use-device-code `
    --tags 'ArcSQLServerExtensionDeployment=Disabled'
if ($LASTEXITCODE -ne 0) {
    throw "Arc connection failed (exit $LASTEXITCODE). Review registration and the agent-specific proxy settings; they were not automatically removed."
}
& $agent show
if ($LASTEXITCODE -ne 0) { throw "Post-connect status check failed (exit $LASTEXITCODE)." }
