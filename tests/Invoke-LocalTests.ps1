#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) {
    throw 'Synthetic CLI tests require Windows. Static checks can run with Test-Handson.ps1 -SkipMockTests.'
}
$root = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ampls-handson-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$previousPath = $env:PATH
$previousState = $env:HANDSON_TEST_STATE_DIR
$previousConfigDir = $env:AZURE_CONFIG_DIR
$tenant = '11111111-1111-1111-1111-111111111111'
$subscription = '22222222-2222-2222-2222-222222222222'
$target = "/subscriptions/$subscription/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test-vm"
$dce = "/subscriptions/$subscription/resourceGroups/test/providers/Microsoft.Insights/dataCollectionEndpoints/test-dce"
$handler = @'
$ErrorActionPreference = 'Stop'
$directory = $env:HANDSON_TEST_STATE_DIR
$statePath = Join-Path $directory 'state.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$arguments = @($args)
$arguments | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $directory 'calls.jsonl')
function Return-Json($value) {
    ConvertTo-Json -InputObject $value -Depth 30 -Compress
    exit 0
}
$line = $arguments -join ' '
if ($line.StartsWith('account show ')) {
    if ($state.mode -eq 'account-failure') { Write-Error 'Synthetic unauthenticated context'; exit 9 }
    $tenant = if ($state.mode -eq 'mismatch') { '33333333-3333-3333-3333-333333333333' } else { $state.tenant }
    $subscription = if ($state.mode -eq 'subscription-mismatch') { '99999999-9999-9999-9999-999999999999' } else { $state.subscription }
    $client = if ($state.mode -eq 'client-mismatch') { '99999999-9999-9999-9999-999999999999' } else { $state.client }
    $type = if ($state.mode -eq 'type-mismatch') { 'user' } else { $state.authenticationType }
    $status = if ($state.mode -eq 'disabled') { 'Disabled' } else { 'Enabled' }
    if ($state.mode -eq 'identity-changed') {
        $state.accountChecks++
        $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
        if ($state.accountChecks -gt 1) { $client='99999999-9999-9999-9999-999999999999' }
    }
    Return-Json @{ tenantId=$tenant; id=$subscription; state=$status; user=@{type=$type; name=$client} }
}
if ($line.StartsWith('account list ')) { Return-Json @(@{id=$state.subscription}) }
if ($line.StartsWith('account set ') -or $line.StartsWith('vm restart ')) { Return-Json @{} }
if ($line.StartsWith('login ')) { throw 'Unexpected login: synthetic tests must not authenticate.' }
if ($line -match '^(vm|connectedmachine) extension show ') {
    if ($state.mode -eq 'missing-extension') { Write-Error 'Synthetic missing extension'; exit 3 }
    Return-Json $state.extension
}
if ($line -match '^(vm extension set|connectedmachine extension update) ') {
    $index = [array]::IndexOf($arguments, '--settings')
    if ($index -lt 0) { throw 'Missing --settings' }
    $file = $arguments[$index + 1].TrimStart('@')
    $state.extension.settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    $state.extension.provisioningState = 'Succeeded'
    $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    Return-Json $state.extension
}
if ($line.StartsWith('resource show ')) {
    $index = [array]::IndexOf($arguments, '--ids')
    $id = $arguments[$index + 1]
    $location = if ($state.mode -eq 'region-mismatch' -and $id -match '/dataCollectionEndpoints/') { 'westus' } else { 'japaneast' }
    Return-Json @{ id=$id; location=$location }
}
if ($line.StartsWith('monitor data-collection rule association list ')) { Return-Json @($state.associations) }
if ($line.StartsWith('monitor data-collection rule association create ')) {
    $index = [array]::IndexOf($arguments, '--data-collection-endpoint-id')
    $association = @{ name='configurationAccessEndpoint'; dataCollectionEndpointId=$arguments[$index + 1] }
    $state.associations = @($association)
    $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    Return-Json $association
}
if ($line.StartsWith('network nsg show ')) {
    $name = $arguments[[array]::IndexOf($arguments, '--name') + 1]
    $rule = @{
        name='LabInternetOutbound'; access=$state.nsgAccess[$name]; priority=400
        direction='Outbound'; protocol='*'; sourceAddressPrefix='*'; sourcePortRange='*'
        destinationAddressPrefix='Internet'; destinationPortRange='*'
    }
    if ($state.mode -eq 'nsg-priority') { $rule.priority=200 }
    $rules = @($rule,
        @{ name='AllowPrivateEndpoints'; access='Allow'; priority=110; direction='Outbound'; protocol='Tcp'; destinationAddressPrefix='10.20.1.0/24'; destinationPortRange='443' },
        @{ name='AllowExplicitProxy'; access='Allow'; priority=120; direction='Outbound'; protocol='Tcp'; destinationAddressPrefix='10.20.0.4'; destinationPortRange='3128' })
    if ($state.mode -eq 'nsg-extra-rule') {
        $rules += @{ name='ExtraPublicAllow'; direction='Outbound'; access='Allow'; priority=300 }
    }
    if ($state.mode -eq 'nsg-imds-allow') {
        $rules += @{ name='AllowHostImds'; direction='Outbound'; access='Allow'; priority=140; destinationAddressPrefix='AzurePlatformIMDS' }
    }
    $purpose = if ($state.mode -eq 'nsg-owner') { 'someone-else' } else { 'optional-ampls-arcpls-lab' }
    Return-Json @{ id="/subscriptions/$($state.subscription)/resourceGroups/test/providers/Microsoft.Network/networkSecurityGroups/$name"; tags=@{purpose=$purpose}; securityRules=$rules }
}
if ($line.StartsWith('network nic show ')) {
    $name = $arguments[[array]::IndexOf($arguments, '--name') + 1]
    $vm = $name -replace '-nic$', ''
    $ip = switch ($vm) { 'arclab-workload' {'10.10.1.4'}; 'arclab-dns' {'10.30.1.5'}; 'arclab-hyperv' {'10.30.1.4'} }
    if ($state.mode -eq 'nsg-nic') { $ip='10.99.0.4' }
    Return-Json @{
        networkSecurityGroup=@{id="/subscriptions/$($state.subscription)/resourceGroups/test/providers/Microsoft.Network/networkSecurityGroups/$vm-nsg"}
        virtualMachine=@{id="/subscriptions/$($state.subscription)/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/$vm"}
        ipConfigurations=@(@{privateIPAddress=$ip})
    }
}
if ($line.StartsWith('network nsg rule update ')) {
    $name = $arguments[[array]::IndexOf($arguments, '--nsg-name') + 1]
    if ($state.mode -eq 'nsg-update-failure' -and $name -eq 'arclab-dns-nsg') {
        Write-Error 'Synthetic NSG update failure'; exit 7
    }
    $state.nsgAccess[$name] = $arguments[[array]::IndexOf($arguments, '--access') + 1]
    $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statePath
    Return-Json @{access=$state.nsgAccess[$name]}
}
if ($line.StartsWith('network nsg rule show ')) {
    $name = $arguments[[array]::IndexOf($arguments, '--nsg-name') + 1]
    Return-Json @{access=$state.nsgAccess[$name]; direction='Outbound'; destinationAddressPrefix='Internet'; priority=400}
}
throw "Unexpected synthetic CLI invocation: $line"
'@
function Reset-State([string]$Mode, [object[]]$Associations = @(), [string]$AuthenticationType = 'user') {
    @{
        mode = $Mode; tenant = $tenant; subscription = $subscription
        authenticationType=$AuthenticationType; client='44444444-4444-4444-4444-444444444444'; accountChecks=0
        associations = $Associations
        nsgAccess = @{ 'arclab-workload-nsg'='Allow'; 'arclab-dns-nsg'='Allow'; 'arclab-hyperv-nsg'='Allow' }
        extension = @{
            id = "$target/extensions/AzureMonitorWindowsAgent"
            publisher = 'Microsoft.Azure.Monitor'
            provisioningState = 'Succeeded'
            settings = @{ existingOption = 'preserve'; proxy = @{ mode='application'; address='http://old-proxy:3128' } }
        }
    } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $temporary 'state.json') -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Value '' -Encoding utf8NoBOM
}
function Assert-Failure([scriptblock]$Action, [string]$Message) {
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if (-not $caught -or $caught.Exception.Message -notlike "*$Message*") {
        throw "Expected error containing '$Message'; actual: $caught"
    }
}
function Get-TestState {
    Get-Content -LiteralPath (Join-Path $temporary 'state.json') -Raw | ConvertFrom-Json -AsHashtable
}
function Assert-NoWrites {
    $calls = Get-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Raw
    if ($calls -match '"(set|update|create|restart|invoke)"') { throw 'Unexpected write invocation.' }
}
try {
    Set-Content -LiteralPath (Join-Path $temporary 'fake-az.ps1') -Value $handler -Encoding utf8NoBOM
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $cmd = "@echo off`r`n`"$pwsh`" -NoLogo -NoProfile -NonInteractive -File `"$(Join-Path $temporary 'fake-az.ps1')`" %*`r`nexit /b %errorlevel%`r`n"
    Set-Content -LiteralPath (Join-Path $temporary 'az.cmd') -Value $cmd -Encoding ascii
    $env:PATH = "$temporary;$previousPath"
    $env:HANDSON_TEST_STATE_DIR = $temporary
    $env:AZURE_CONFIG_DIR = $temporary
    $common = @{ ExpectedTenantId=$tenant; ExpectedSubscriptionId=$subscription }
    $ama = Join-Path $root 'scripts\Set-AmaDirect.ps1'
    $association = Join-Path $root 'scripts\Set-DceAssociation.ps1'

    foreach ($kind in 'AzureVm', 'ArcServer') {
        Reset-State 'normal'
        $null = & $ama @common -ResourceType $kind -ResourceGroup test -MachineName test-vm
        $settings = (Get-TestState).extension.settings
        if ($settings.proxy.mode -ne 'none' -or $settings.existingOption -ne 'preserve' -or $settings.proxy.ContainsKey('address')) {
            throw "AMA proxy update failed or lost unrelated settings: $kind"
        }
        Write-Output "PASS: $kind AMA direct configuration and preservation."
    }
    Reset-State 'mismatch'
    Assert-Failure { & $ama @common -ResourceType AzureVm -ResourceGroup test -MachineName test-vm } 'context mismatch'
    Assert-NoWrites
    Write-Output 'PASS: context mismatch prevents writes.'

    Reset-State 'missing-extension'
    Assert-Failure { & $ama @common -ResourceType ArcServer -ResourceGroup test -MachineName test-vm } 'Azure CLI failed'
    Assert-NoWrites
    Write-Output 'PASS: missing extension fails explicitly.'

    Reset-State 'normal'
    $null = & $association @common -ResourceId $target -DceId $dce
    if ((Get-TestState).associations[0].dataCollectionEndpointId -ne $dce) { throw 'DCE association was not created.' }
    Write-Output 'PASS: configuration DCE association creation and verification.'

    Reset-State 'normal' @(@{ name='other'; dataCollectionEndpointId=($dce + '-other') })
    Assert-Failure { & $association @common -ResourceId $target -DceId $dce } 'different configuration DCE'
    Assert-NoWrites
    Write-Output 'PASS: conflicting DCE is not replaced.'

    Reset-State 'normal' @(@{ name='same'; dataCollectionEndpointId=$dce })
    $null = & $association @common -ResourceId $target -DceId $dce
    Assert-NoWrites
    Write-Output 'PASS: matching DCE association makes no write.'

    Reset-State 'region-mismatch'
    Assert-Failure { & $association @common -ResourceId $target -DceId $dce } 'regions must match'
    Assert-NoWrites
    Write-Output 'PASS: DCE region mismatch prevents writes.'

    Reset-State 'normal' @(@{ name='dcr-only'; dataCollectionRuleId='/synthetic/dcr' })
    $null = & $association @common -ResourceId $target -DceId $dce
    Write-Output 'PASS: an existing DCR association does not hide a missing configuration DCE.'

    Reset-State 'normal'
    $null = & $ama @common -ResourceType AzureVm -ResourceGroup test -MachineName test-vm -WhatIf
    Assert-NoWrites
    Write-Output 'PASS: WhatIf prevents AMA mutation.'

    $phase = Join-Path $root 'infra\lab\Set-LabInternetAccess.ps1'
    Reset-State 'normal'
    $null = & $phase @common -ResourceGroup test -Mode Restricted -Confirm:$false
    if (@((Get-TestState).nsgAccess.Values | Where-Object { $_ -ne 'Deny' }).Count -gt 0) { throw 'All three NSGs must deny direct Internet.' }
    Write-Output 'PASS: Restricted phase applies Internet deny to all three NIC NSGs.'
    $null = & $phase @common -ResourceGroup test -Mode Build -Confirm:$false
    if (@((Get-TestState).nsgAccess.Values | Where-Object { $_ -ne 'Allow' }).Count -gt 0) { throw 'Build recovery must restore all three NSGs.' }
    Write-Output 'PASS: approved Build phase restores Internet allowance.'

    foreach ($case in @(
        @{Mode='nsg-owner'; Error='owner tag'}
        @{Mode='nsg-nic'; Error='ownership mismatch'}
        @{Mode='nsg-priority'; Error='Unexpected LabInternetOutbound'}
        @{Mode='nsg-extra-rule'; Error='Additional outbound rules'}
        @{Mode='nsg-imds-allow'; Error='Additional outbound rules'}
        @{Mode='mismatch'; Error='context mismatch'}
    )) {
        Reset-State $case.Mode
        Assert-Failure { & $phase @common -ResourceGroup test -Mode Restricted -Confirm:$false } $case.Error
        Assert-NoWrites
        Write-Output "PASS: $($case.Mode) blocks NSG mutations during preflight."
    }
    Reset-State 'nsg-update-failure'
    Assert-Failure { & $phase @common -ResourceGroup test -Mode Restricted -Confirm:$false } 'Phase change stopped'
    $state = Get-TestState
    if ($state.nsgAccess['arclab-workload-nsg'] -ne 'Deny' -or
        $state.nsgAccess['arclab-dns-nsg'] -ne 'Allow' -or $state.nsgAccess['arclab-hyperv-nsg'] -ne 'Allow') {
        throw 'Partial NSG failure was not represented accurately.'
    }
    Write-Output 'PASS: partial NSG mutation fails explicitly and retains observed per-VM state.'

    Reset-State 'normal'
    $null = & $phase @common -ResourceGroup test -Mode Restricted -WhatIf
    Assert-NoWrites
    Write-Output 'PASS: phase WhatIf leaves NSGs unchanged.'

    $client = '44444444-4444-4444-4444-444444444444'
    $servicePrincipal = $common.Clone()
    $servicePrincipal.ExpectedClientId = $client
    Reset-State 'normal' -AuthenticationType servicePrincipal
    $null = & $phase @servicePrincipal -ResourceGroup test -Mode Restricted -Confirm:$false
    if (@((Get-TestState).nsgAccess.Values | Where-Object { $_ -ne 'Deny' }).Count -gt 0) { throw 'Service principal did not restrict every NSG.' }
    Write-Output 'PASS: service principal applies the same verified NSG changes.'

    foreach ($mode in 'mismatch', 'subscription-mismatch', 'client-mismatch', 'type-mismatch', 'disabled', 'identity-changed') {
        Reset-State $mode -AuthenticationType servicePrincipal
        Assert-Failure { & $phase @servicePrincipal -ResourceGroup test -Mode Restricted -Confirm:$false } 'context mismatch'
        Assert-NoWrites
    }
    Write-Output 'PASS: identity and subscription failures prevent NSG writes, including identity changes after startup.'

    . (Join-Path $root 'scripts\common\AzureCli.ps1')
    $pinned = $servicePrincipal.Clone()
    $pinned.ExpectedAzureConfigDir = $temporary
    Reset-State 'normal' -AuthenticationType servicePrincipal
    $env:AZURE_CONFIG_DIR = [IO.Path]::GetTempPath()
    Assert-Failure { Invoke-HandsonAz -ExpectedContext $pinned -Arguments @('network','nsg','rule','update') } 'cache changed'
    Assert-NoWrites
    $env:AZURE_CONFIG_DIR = $null
    Assert-Failure { & $phase @servicePrincipal -ResourceGroup test -Mode Restricted -Confirm:$false } 'AZURE_CONFIG_DIR'
    Assert-NoWrites
    $env:AZURE_CONFIG_DIR = $temporary
    Write-Output 'PASS: missing or changed authentication cache prevents writes.'

    $ghCmd = "@echo off`r`necho Synthetic GitHub authentication stop 1>&2`r`nexit /b 8`r`n"
    Set-Content -LiteralPath (Join-Path $temporary 'gh.cmd') -Value $ghCmd -Encoding ascii
    function Read-Host {
        param([string]$Prompt)
        if ($Prompt -like 'Type the full VM name*') { return 'arclab-hyperv' }
        return ''
    }
    $deploy = Join-Path $root 'infra\lab\Deploy-Lab.ps1'
    $deployArguments = @{TenantId=$tenant; SubscriptionId=$subscription; ResourceGroupName='rg-test'; ClientId=$client}
    Reset-State 'normal' -AuthenticationType servicePrincipal
    Assert-Failure { & $deploy @deployArguments } 'GitHub sign-in failed'
    Assert-NoWrites
    $calls = Get-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Raw
    if ($calls -match '"login"|"list"|"set"') { throw 'Service principal path must not log in or change the subscription.' }
    Write-Output 'PASS: deployment accepts the approved service principal without login or account selection.'

    Reset-State 'normal' -AuthenticationType servicePrincipal
    $env:AZURE_CONFIG_DIR = $null
    Assert-Failure { & $deploy @deployArguments } 'AZURE_CONFIG_DIR'
    Assert-NoWrites
    $env:AZURE_CONFIG_DIR = $temporary
    foreach ($mode in 'mismatch', 'subscription-mismatch', 'client-mismatch', 'type-mismatch', 'disabled', 'account-failure') {
        Reset-State $mode -AuthenticationType servicePrincipal
        $message = if ($mode -eq 'account-failure') { 'Azure CLI failed' } else { 'context mismatch' }
        Assert-Failure { & $deploy @deployArguments } $message
        Assert-NoWrites
        $calls = Get-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Raw
        if ($calls -match '"login"|"set"') { throw 'Failed service principal validation must not switch authentication.' }
    }
    foreach ($key in 'TenantId', 'SubscriptionId') {
        Reset-State 'normal' -AuthenticationType servicePrincipal
        $missing = $deployArguments.Clone()
        $missing.Remove($key)
        Assert-Failure { & $deploy @missing } 'explicit non-empty'
        Assert-NoWrites
    }
    $emptyClient = $deployArguments.Clone()
    $emptyClient.ClientId = [guid]::Empty
    Assert-Failure { & $deploy @emptyClient } 'explicit non-empty'
    Write-Output 'PASS: deployment rejects invalid identity, missing IDs and unauthenticated contexts without login or writes.'

    Reset-State 'normal'
    $userArguments = $deployArguments.Clone()
    $userArguments.Remove('ClientId')
    Assert-Failure { & $deploy @userArguments } 'GitHub sign-in failed'
    $calls = Get-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Raw
    if ($calls -notmatch '"set"') { throw 'Existing user path did not select the approved subscription.' }
    Reset-State 'normal' -AuthenticationType servicePrincipal
    Assert-Failure { & $deploy @userArguments } 'interactive Azure CLI login'
    Assert-NoWrites
    Write-Output 'PASS: existing user login remains available and does not implicitly accept a service principal.'

    $guest = Join-Path $root 'infra\lab\Invoke-LabGuest.ps1'
    Reset-State 'normal' -AuthenticationType servicePrincipal
    $null = & $guest -TenantId $tenant -SubscriptionId $subscription -ClientId $client -ResourceGroupName test -Action RestartHyperV
    $calls = Get-Content -LiteralPath (Join-Path $temporary 'calls.jsonl') -Raw
    if ($calls -notmatch '"restart"') { throw 'Approved service principal guest restart was not requested.' }
    Reset-State 'client-mismatch' -AuthenticationType servicePrincipal
    Assert-Failure { & $guest -TenantId $tenant -SubscriptionId $subscription -ClientId $client -ResourceGroupName test -Action RestartHyperV } 'context mismatch'
    Assert-NoWrites
    Reset-State 'identity-changed' -AuthenticationType servicePrincipal
    Assert-Failure { & $guest -TenantId $tenant -SubscriptionId $subscription -ClientId $client -ResourceGroupName test -Action RestartHyperV } 'context mismatch'
    Assert-NoWrites
    Write-Output 'PASS: guest operations accept the approved service principal and recheck identity after approval.'
} finally {
    $env:PATH = $previousPath
    $env:HANDSON_TEST_STATE_DIR = $previousState
    $env:AZURE_CONFIG_DIR = $previousConfigDir
    foreach ($name in 'az.cmd', 'gh.cmd', 'fake-az.ps1', 'state.json', 'calls.jsonl') {
        $file = Join-Path $temporary $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $temporary
}
