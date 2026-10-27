#requires -Version 7.0
# Optional Run Command helper; not a guaranteed management path.
# Use an approved private management connection as the primary guest access path.
# Agent/handler public download connectivity must be confirmed separately.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [ValidatePattern('^[a-z][a-z0-9]{1,11}$')][string]$Prefix = 'arclab',
    [Parameter(Mandatory)]
    [ValidateSet('InitializeDns', 'InstallHyperV', 'RestartHyperV')][string]$Action
)
$ErrorActionPreference = 'Stop'
$accountJson = & az account show --subscription "$SubscriptionId" --output json
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI account lookup failed.' }
$account = $accountJson | ConvertFrom-Json
if ($account.tenantId -ne "$TenantId" -or $account.id -ne "$SubscriptionId" -or
    $account.state -ne 'Enabled' -or $account.user.type -ne 'user') {
    throw 'Tenant, subscription or interactive user authentication mismatch.'
}
$role = if ($Action -eq 'InitializeDns') { 'dns' } else { 'hyperv' }
$vmName = "$Prefix-$role"
Write-Host "Tenant: $TenantId / Subscription: $SubscriptionId / RG: $ResourceGroupName / VM: $vmName / Action: $Action"
if ((Read-Host 'Type the full VM name to approve this operation') -ne $vmName) { throw 'Not approved.' }
if ($Action -eq 'RestartHyperV') {
    & az vm restart --resource-group $ResourceGroupName --name $vmName --subscription "$SubscriptionId"
}
else {
    Write-Warning 'Run Command requires working agent/handler delivery connectivity; default outbound is not guaranteed. If unavailable, use your approved private management connection or stop.'
    $scriptName = if ($Action -eq 'InitializeDns') { 'Initialize-WindowsDns.ps1' } else { 'Install-HyperV.ps1' }
    & az vm run-command invoke --resource-group $ResourceGroupName --name $vmName `
        --subscription "$SubscriptionId" --command-id RunPowerShellScript `
        --scripts "@$(Join-Path $PSScriptRoot "guest\$scriptName")"
}
if ($LASTEXITCODE -ne 0) { throw 'Guest operation request failed. Review the VM and Run Command output.' }
# Run Command can return a successful HTTP response even when the guest script fails.
Write-Host 'Inspect Run Command stdout/stderr and the reported guest exit status before continuing.'
