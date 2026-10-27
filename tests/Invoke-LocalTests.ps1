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
    $tenant = if ($state.mode -eq 'mismatch') { '33333333-3333-3333-3333-333333333333' } else { $state.tenant }
    Return-Json @{ tenantId=$tenant; id=$state.subscription; state='Enabled' }
}
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
function Reset-State([string]$Mode, [object[]]$Associations = @()) {
    @{
        mode = $Mode; tenant = $tenant; subscription = $subscription
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
    if ($calls -match '"(set|update|create)"') { throw 'Unexpected write invocation.' }
}
try {
    Set-Content -LiteralPath (Join-Path $temporary 'fake-az.ps1') -Value $handler -Encoding utf8NoBOM
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $cmd = "@echo off`r`n`"$pwsh`" -NoLogo -NoProfile -NonInteractive -File `"$(Join-Path $temporary 'fake-az.ps1')`" %*`r`nexit /b %errorlevel%`r`n"
    Set-Content -LiteralPath (Join-Path $temporary 'az.cmd') -Value $cmd -Encoding ascii
    $env:PATH = "$temporary;$previousPath"
    $env:HANDSON_TEST_STATE_DIR = $temporary
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
} finally {
    $env:PATH = $previousPath
    $env:HANDSON_TEST_STATE_DIR = $previousState
    foreach ($name in 'az.cmd', 'fake-az.ps1', 'state.json', 'calls.jsonl') {
        $file = Join-Path $temporary $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $temporary
}
