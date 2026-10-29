#Requires -Version 7.0
[CmdletBinding()]
param(
    [guid]$TenantId,
    [guid]$SubscriptionId,
    [guid]$ClientId,
    [string]$ResourceGroupName,
    [ValidatePattern('^[a-z][a-z0-9]{1,11}$')][string]$Prefix = 'arclab',
    [string]$Location = 'japaneast',
    [string]$WorkloadVmSize = 'Standard_D2s_v5',
    [string]$DnsVmSize = 'Standard_D2s_v5',
    [string]$HyperVVmSize = 'Standard_D8s_v5',
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository = 'uedait/ampls-arcpls-handson',
    [string]$SourceRef = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'scripts\common\AzureCli.ps1')
. (Join-Path $PSScriptRoot 'common\LabAutomation.ps1')
Get-Command az, gh -ErrorAction Stop | Out-Null

function Read-LabDefault {
    param([string]$Prompt, [string]$Default)
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

if ($PSBoundParameters.ContainsKey('ClientId')) {
    if (-not $TenantId -or $TenantId -eq [guid]::Empty -or
        -not $SubscriptionId -or $SubscriptionId -eq [guid]::Empty -or $ClientId -eq [guid]::Empty) {
        throw 'Service principal execution requires explicit non-empty TenantId, SubscriptionId and ClientId.'
    }
    $azContext = @{
        ExpectedTenantId=$TenantId; ExpectedSubscriptionId=$SubscriptionId
        ExpectedClientId=$ClientId; ExpectedAzureConfigDir=$env:AZURE_CONFIG_DIR
    }
    Assert-HandsonAzContext @azContext
} else {
    $accounts = @(Invoke-HandsonAz -Arguments @('account', 'list', '--all'))
    if ($accounts.Count -eq 0) {
        Write-Host 'Azure CLI sign-in is required. Complete the interactive sign-in.'
        $login = @('login', '--output', 'none')
        if ($TenantId -and $TenantId -ne [guid]::Empty) { $login += @('--tenant', $TenantId.ToString()) }
        & az @login
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed.' }
    }
    $account = Invoke-HandsonAz -Arguments @('account', 'show')
    if (-not $SubscriptionId -or $SubscriptionId -eq [guid]::Empty) {
        $SubscriptionId = [guid](Read-LabDefault 'Subscription ID' $account.id)
    }
    if (-not $TenantId -or $TenantId -eq [guid]::Empty) { $TenantId = [guid]$account.tenantId }
    $selected = Invoke-HandsonAz -Arguments @('account', 'show', '--subscription', $SubscriptionId.ToString())
    if ($selected.tenantId -ne $TenantId.ToString() -or $selected.state -ne 'Enabled' -or $selected.user.type -ne 'user') {
        throw 'Select an enabled subscription in the expected tenant using your interactive Azure CLI login.'
    }
    & az account set --subscription $SubscriptionId.ToString()
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI subscription selection failed.' }
    Assert-HandsonAzContext -ExpectedTenantId $TenantId -ExpectedSubscriptionId $SubscriptionId
    $azContext = @{ExpectedTenantId=$TenantId; ExpectedSubscriptionId=$SubscriptionId}
}
if (-not $ResourceGroupName) { $ResourceGroupName = Read-LabDefault 'New lab resource group' "rg-$Prefix-lab" }
if ($ResourceGroupName -notmatch '^[A-Za-z0-9_().-]{1,90}$' -or $ResourceGroupName.EndsWith('.')) { throw 'Invalid lab resource group name.' }
$Prefix = Read-LabDefault 'VM/resource alias prefix (2-12 lowercase letters/digits)' $Prefix
if ($Prefix -notmatch '^[a-z][a-z0-9]{1,11}$') { throw 'Invalid prefix.' }

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    & gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in failed.' }
}
$tokenText = & gh auth token --hostname github.com
if ($LASTEXITCODE -ne 0 -or -not $tokenText) { throw 'GitHub token lookup failed.' }
$githubToken = ConvertTo-SecureString ($tokenText -join '').Trim() -AsPlainText -Force
$tokenText = $null
$runId = [guid]::NewGuid().ToString('N')
$directory = Join-Path $root ".local\runs\$runId"
$null = New-Item -ItemType Directory -Path $directory -Force
$context = $null
$vmCredential = $null
$l2Credential = $null
try {
    $source = Get-LabSource -Repository $Repository -Ref $SourceRef -Token $githubToken -RunDirectory $directory
    $vmCredential = Get-Credential -UserName 'labadmin' -Message 'Administrator for the three Azure VMs'
    $l2Credential = Get-Credential -UserName 'Administrator' -Message 'Built-in Administrator for the nested Windows server'
    if (-not $vmCredential -or -not $l2Credential -or $l2Credential.UserName -ne 'Administrator') {
        throw 'Azure VM credentials and the L2 built-in Administrator credential are required.'
    }
    if ($vmCredential.UserName -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,19}$' -or
        $vmCredential.UserName -in 'Administrator', 'Admin', 'Guest') { throw 'Choose a supported Azure VM administrator name, for example labadmin.' }
    if ($vmCredential.Password.Length -lt 12 -or $l2Credential.Password.Length -lt 12) { throw 'Use administrator passwords of at least 12 characters with Windows/Azure complexity requirements.' }
    Write-Host "Tenant: $TenantId / Subscription: $SubscriptionId"
    if ($azContext.ContainsKey('ExpectedClientId')) { Write-Host "Service principal: $ClientId" }
    Write-Host "RG: $ResourceGroupName / Location: $Location / Alias: $Prefix"
    Write-Host "Source: $Repository / $($source.CommitSha)"
    Write-Host "VMs: $WorkloadVmSize, $DnsVmSize, $HyperVVmSize / Nested: Windows Server 2022 Evaluation"
    Write-Host 'Billable resources: Firewall Standard, Bastion Standard, Resolver, 3 VMs/disks and 5 Public IPs.'
    Write-Host 'Guest setup, L1 restart and final Internet restriction will run automatically. No resources are deleted on failure.'
    if ((Read-Host 'Confirm nested SKU support, quota, budget/currency/expiry and the full plan: type APPROVE') -ne 'APPROVE') {
        throw 'Deployment was not approved.'
    }
    $context = @{
        TenantId=$TenantId.ToString(); SubscriptionId=$SubscriptionId.ToString()
        AzureContext=$azContext
        ResourceGroup=$ResourceGroupName; Prefix=$Prefix; Location=$Location
        WorkloadVmSize=$WorkloadVmSize; DnsVmSize=$DnsVmSize; HyperVVmSize=$HyperVVmSize
        Repository=$Repository; Source=$source; GitHubToken=$githubToken
        VmCredential=$vmCredential; L2Password=$l2Credential.Password
        RunId=$runId; RunDirectory=$directory
    }
    $result = Invoke-LabAutomation -Context $context
    Write-Host 'Deployment complete: all guest checks passed and Internet access is Restricted.'
    Write-Host "Bastion: $($result.BastionName) / RG: $ResourceGroupName"
    Write-Host "Commit: $($result.CommitSha)"
    Write-Host 'Open each VM in Azure Portal > Connect > Bastion. Open the L2 console from the L1 Hyper-V Manager.'
    Write-Host "Safe run state: $(Join-Path $directory 'state.json')"
} finally {
    if ($context) { $context.Remove('GitHubToken'); $context.Remove('VmCredential'); $context.Remove('L2Password') }
    $vmCredential = $null
    $l2Credential = $null
    if ($githubToken) { $githubToken.Dispose() }
}
