#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\common\AzureCli.ps1')
. (Join-Path $root 'infra\lab\common\LabAutomation.ps1')
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('lab-automation-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$checks = 0
function Assert-Test([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $errorRecord = $null
    try { & $Action | Out-Null } catch { $errorRecord = $_ }
    Assert-Test ($null -ne $errorRecord -and $errorRecord.Exception.Message -like "*$Pattern*") $Pattern
}
$password = ConvertTo-SecureString ('OnlySynthetic-' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
$context = @{
    RunId=('a' * 32); TenantId='11111111-1111-1111-1111-111111111111'
    SubscriptionId='22222222-2222-2222-2222-222222222222'; ResourceGroup='rg-test'; Prefix='labtest'
    AzureContext=@{ExpectedTenantId='11111111-1111-1111-1111-111111111111'; ExpectedSubscriptionId='22222222-2222-2222-2222-222222222222'}
    Location='japaneast'; WorkloadVmSize='Standard_D2s_v5'; DnsVmSize='Standard_D2s_v5'; HyperVVmSize='Standard_D8s_v5'
    Repository='uedait/ampls-arcpls-handson'; RunDirectory=$temporary
    Source=@{Root=$root; CommitSha=('b' * 40); ArchiveSha256=('c' * 64)}
    VmCredential=[pscredential]::new('labadmin', $password); L2Password=$password; GitHubToken=$password
}
$valid = @{
    RunId=$context.RunId; Role='hyperv'; Action='VerifyBuild'; CommitSha=$context.Source.CommitSha
    Succeeded=$true; FilesReady=$true; DnsReady=$true; RdpReady=$true
    L2Ready=$true; HandoverReady=$true; ImdsBlocked=$true; Licensed=$true
}
try {
    $copyStatement = ${function:Get-LabSource}.Ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text -match '^\$null\s*=\s*\$response\.Content\.CopyToAsync'
    }, $true)
    Assert-Test ($null -ne $copyStatement) 'Archive download suppresses the internal asynchronous completion result.'
    $response = [pscustomobject]@{Content=[Net.Http.StringContent]::new('synthetic archive bytes')}
    $stream = [IO.MemoryStream]::new()
    try {
        $copyResult = @(& ([scriptblock]::Create($copyStatement.Extent.Text)))
        Assert-Test ($copyResult.Count -eq 0 -and $stream.Length -gt 0) 'The actual archive copy statement writes bytes without returning VoidTaskResult.'
    } finally { $stream.Dispose(); $response.Content.Dispose() }

    $instance = @{output='LAB_RESULT:' + ($valid | ConvertTo-Json -Compress)}
    $result = Assert-LabRoleResult $context hyperv VerifyBuild $instance
    Assert-Test ($result.Licensed -eq $true) 'Valid structured readiness result.'
    $completeResult = $valid.Clone()
    $completeResult.Action = 'CompleteNested'
    $completeResult.Licensed = $false
    Assert-Throws { Assert-LabRoleResult $context hyperv CompleteNested @{output='LAB_RESULT:' + ($completeResult | ConvertTo-Json -Compress)} } 'Licensed'
    foreach ($key in 'RunId', 'CommitSha', 'Role', 'FilesReady', 'Licensed', 'HandoverReady') {
        $changed = $valid.Clone()
        $changed[$key] = if ($changed[$key] -is [bool]) { $false } else { 'wrong' }
        Assert-Throws { Assert-LabRoleResult $context hyperv VerifyBuild @{output='LAB_RESULT:' + ($changed | ConvertTo-Json -Compress)} } ''
    }
    foreach ($key in 'Succeeded', 'FilesReady', 'Licensed') {
        $changed = $valid.Clone()
        $changed[$key] = 'true'
        Assert-Throws { Assert-LabRoleResult $context hyperv VerifyBuild @{output='LAB_RESULT:' + ($changed | ConvertTo-Json -Compress)} } ''
    }
    Assert-Throws { Assert-LabRoleResult $context hyperv VerifyBuild @{output='HTTP succeeded but no guest result'} } 'no unique'
    Assert-Throws { Assert-LabRoleResult $context hyperv VerifyBuild @{output="$($instance.output)`n$($instance.output)"} } 'no unique'
    $restartResult = @{
        RunId=$context.RunId; Role='hyperv'; Action='PrepareHyperV'; CommitSha=$context.Source.CommitSha
        Succeeded=$true; FilesReady=$true; RebootRequired=$true
    }
    $restart = Assert-LabRoleResult $context hyperv PrepareHyperV @{output='LAB_RESULT:' + ($restartResult | ConvertTo-Json -Compress)}
    Assert-Test ($restart.RebootRequired -eq $true) 'Explicit reboot request is accepted before feature readiness.'
    $stagedResult = @{
        RunId=$context.RunId; Role='dns'; Action='StageSource'; CommitSha=$context.Source.CommitSha
        Succeeded=$true; FilesReady=$true
    }
    $staged = Assert-LabRoleResult $context dns StageSource @{output='LAB_RESULT:' + ($stagedResult | ConvertTo-Json -Compress)}
    Assert-Test ($staged.FilesReady -eq $true) 'Source-only staging has an explicit result contract.'

    $savedState = Join-Path $temporary 'state.json'
    Save-LabRunState $context 'Test' 'Running'
    $stateJson = Get-Content -LiteralPath $savedState -Raw
    Assert-Test ($stateJson -notmatch 'GitHubToken|VmCredential|L2Password|ArchiveUri') 'Public state excludes secret inputs.'
    $secretText = [Net.NetworkCredential]::new('', $password).Password
    Assert-Test (-not $stateJson.Contains($secretText)) 'Public state excludes secret content.'
    $secretText = $null

    $zip = Join-Path $temporary 'fixture.zip'
    foreach ($entryName in @('root/readme.txt', '../escape.txt', 'root/../../escape.txt', '/absolute.txt', 'root/C:/drive.txt')) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry($entryName)
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('synthetic') } finally { $writer.Dispose() }
        } finally { $archive.Dispose() }
        if ($entryName -eq 'root/readme.txt') {
            $destination = Join-Path $temporary 'good'
            $extracted = Expand-LabSourceArchive $zip $destination
            Assert-Test (Test-Path -LiteralPath (Join-Path $extracted 'readme.txt')) 'Single-root source archive extracted.'
        } else {
            Assert-Throws { Expand-LabSourceArchive $zip (Join-Path $temporary 'blocked') } 'unsafe'
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $temporary 'blocked'))) 'Unsafe archive was not extracted.'
        }
    }

    $originalManaged = ${function:Invoke-LabManagedCommand}
    $originalRestricted = ${function:Set-LabRestrictedMode}
    function Invoke-LabArm {
        param($Context, $Method, $Path, $Body)
        if ($Method -eq 'PUT') {
            $script:lastBody = $Body
            return @{}
        }
        return @{
            properties=@{
                provisioningState='Succeeded'
                instanceView=@{executionState=$script:execution; exitCode=$script:exitCode; output='synthetic'}
            }
        }
    }
    $script:execution = 'Failed'
    $script:exitCode = 0
    Assert-Throws { & $originalManaged -Context $context -Role dns -Action Test -Script 'synthetic' } 'failed in Managed'
    $script:execution = 'Succeeded'
    $script:exitCode = 9
    Assert-Throws { & $originalManaged -Context $context -Role dns -Action Test -Script 'synthetic' } 'non-zero'
    $script:exitCode = 0
    $result = & $originalManaged -Context $context -Role dns -Action Test -Script 'synthetic' `
        -Parameters @{Role='dns'} -ProtectedParameters @{ArchiveUri='synthetic-private-url'}
    Assert-Test ($result.exitCode -eq 0) 'Managed execution success requires exit code zero.'
    Assert-Test (@($script:lastBody.properties.protectedParameters | Where-Object name -eq 'ArchiveUri').Count -eq 1) 'Short-lived URL uses protectedParameters.'
    Assert-Test (@($script:lastBody.properties.parameters | Where-Object name -eq 'ArchiveUri').Count -eq 0) 'Short-lived URL is absent from public parameters.'
    Assert-Test ($script:lastBody.properties.asyncExecution -eq $true -and $script:lastBody.properties.timeoutInSeconds -eq 14400) 'Long-running command uses asynchronous execution and a bounded deadline.'

    $script:events = [Collections.Generic.List[string]]::new()
    $script:failure = ''
    $script:prepareCalls = 0
    $script:clientId = '33333333-3333-3333-3333-333333333333'
    $script:authenticationType = 'user'
    $script:skuRestrictions = @()
    $script:skuGen2 = $true
    $script:groupExists = $false
    $script:existingResources = @()
    $script:deploymentState = 'Failed'
    function Save-LabRunState {
        param($Context, $Stage, $Status, $Detail=@{})
        $script:events.Add("$Stage/$Status")
    }
    function Invoke-HandsonAz {
        param($Arguments, $ExpectedContext)
        if ($ExpectedContext) { Assert-HandsonAzContext @ExpectedContext }
        $line = $Arguments -join ' '
        if ($line -like 'account show*') {
            return @{tenantId=$context.TenantId; id=$context.SubscriptionId; state='Enabled'; user=@{type=$script:authenticationType; name=$script:clientId}}
        }
        if ($line -like 'vm list-skus*') {
            $size = $Arguments[[array]::IndexOf($Arguments, '--size') + 1]
            $generations = if ($script:skuGen2) { 'V1,V2' } else { 'V1' }
            return @(@{name=$size; resourceType='virtualMachines'; restrictions=$script:skuRestrictions; capabilities=@(@{name='HyperVGenerations';value=$generations})})
        }
        if ($line -like 'group list*') {
            if ($script:groupExists) { return @(@{name='rg-test'}) }
            return @()
        }
        if ($line -like 'resource list*') { return @($script:existingResources) }
        if ($line -like 'deployment group list*') { return @(@{properties=@{provisioningState=$script:deploymentState}}) }
        if ($line -like 'group create*') { $script:events.Add('GroupCreated'); return @{name='rg-test'} }
        if ($line -like 'bicep build*') { return @{resources=@()} }
        if ($line -like 'network nic update*') { $script:events.Add('NicDns'); return @{name='nic'} }
        throw "Unexpected synthetic CLI request: $line"
    }
    function Invoke-LabArm {
        param($Context, $Method, $Path, $Body)
        if ($Method -eq 'PUT' -and $Path -like '*deployments/optional-lab*') {
            $script:events.Add('ResourceDeploymentRequested')
            $script:deploymentBody = $Body
            return @{}
        }
        throw 'Unexpected synthetic ARM request.'
    }
    function Wait-LabDeployment { param($Context,$Path) $script:events.Add('DeploymentSucceeded') }
    function Get-LabDeploymentTemplate { param($Context) return @{resources=@()} }
    function Wait-LabVmReady { param($Context,$VmName) $script:events.Add("VmReady:$VmName") }
    function Invoke-LabManagedCommand { param($Context,$Role,$Action,$Script,$TimeoutSeconds) return @{output='LAB_WARMUP_READY';exitCode=0} }
    function Invoke-LabRoleAction {
        param($Context,$Role,$Action,[switch]$Download)
        $script:events.Add("$Role/$Action")
        if ($script:failure -eq "$Role/$Action") { throw 'Synthetic guest failure.' }
        $reboot = $false
        if ($Action -eq 'PrepareHyperV') { $script:prepareCalls++; $reboot = $script:prepareCalls -eq 1 }
        return @{RebootRequired=$reboot}
    }
    function Restart-LabVm { param($Context,$Role) $script:events.Add("Restart:$Role") }
    function Set-LabRestrictedMode { param($Context) $script:events.Add('RestrictionApplied') }

    $result = Invoke-LabAutomation $context
    Assert-Test ($result.Status -eq 'Succeeded' -and $result.InternetPhase -eq 'Restricted') 'Controller completes only after all phases.'
    Assert-Test ($script:events.IndexOf('dns/InitializeDns') -lt $script:events.IndexOf('NicDns')) 'DNS service precedes NIC DNS change.'
    Assert-Test ($script:events.IndexOf('hyperv/StageSource') -lt $script:events.IndexOf('dns/InitializeDns')) 'All three source packages are staged before role configuration.'
    Assert-Test ($script:events.IndexOf('NicDns') -lt $script:events.IndexOf('hyperv/PrepareHyperV')) 'NIC DNS is prepared before Hyper-V.'
    Assert-Test ($script:events.Contains('Restart:hyperv') -and $script:prepareCalls -eq 2) 'Hyper-V restart is automated and followed by a readiness recheck.'
    $lastBuild = $script:events.IndexOf('hyperv/VerifyBuild')
    Assert-Test ($lastBuild -lt $script:events.IndexOf('RestrictionApplied')) 'All build verification precedes restriction.'
    Assert-Test ($script:events.IndexOf('RestrictionApplied') -lt $script:events.IndexOf('dns/VerifyRestricted')) 'Restriction precedes fresh connection checks.'
    Assert-Test ($script:events[$script:events.Count-1] -eq 'Complete/Succeeded') 'Completion is the final state.'
    Assert-Test ($script:deploymentBody.properties.parameters.adminPassword.value -eq $context.VmCredential.GetNetworkCredential().Password) 'VM password is handed to the in-memory secure ARM parameter.'

    foreach ($zones in @(@('1'), @('1', '3'))) {
        $script:skuRestrictions = @(@{type='Zone'; reasonCode='NotAvailableForSubscription'; restrictionInfo=@{locations=@('japaneast'); zones=$zones}})
        $result = Invoke-LabAutomation $context
        Assert-Test ($result.Status -eq 'Succeeded') 'Zone-only restrictions allow a deployment without a pinned zone.'
    }
    foreach ($restrictions in @(
        @(@{type='Location'}),
        @(@{type='Zone'}, @{type='Location'}),
        @(@{type='Unknown'}),
        @(@{type='Zone'}, @{type='Unknown'})
    )) {
        $script:skuRestrictions = $restrictions
        $script:events.Clear()
        Assert-Throws { Invoke-LabAutomation $context } 'Lab deployment stopped at ValidateInputs'
        Assert-Test (-not $script:events.Contains('GroupCreated') -and -not $script:events.Contains('DeployResources/Running')) 'Location, mixed and unknown restrictions prevent resource creation.'
    }
    $script:skuRestrictions = @()
    $script:skuGen2 = $false
    $script:events.Clear()
    Assert-Throws { Invoke-LabAutomation $context } 'Lab deployment stopped at ValidateInputs'
    Assert-Test (-not $script:events.Contains('GroupCreated')) 'Gen2 remains mandatory before resource creation.'
    $script:skuGen2 = $true

    $previousDirectory = Join-Path $temporary 'failed-run'
    $null = New-Item -ItemType Directory -Path $previousDirectory
    $previousRecord = @{
        RunId=('d' * 32); Stage='DeployResources'; Status='Failed'; CommitSha=('e' * 40)
        TenantId=$context.TenantId; SubscriptionId=$context.SubscriptionId
        ResourceGroup=$context.ResourceGroup; Prefix=$context.Prefix
    }
    $previousApproval = @{
        RunId=$previousRecord.RunId; SourceCommit=$previousRecord.CommitSha
        ResourceGroup=$context.ResourceGroup; Prefix=$context.Prefix
        Location=$context.Location; Repository=$context.Repository
    }
    $previousStatePath = Join-Path $previousDirectory 'state.json'
    $previousRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
    $previousApproval | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $previousDirectory 'approval.json')
    $approvedId = "/subscriptions/$($context.SubscriptionId)/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/labtest-hub"
    $recovery = @{PreviousRunDirectory=$previousDirectory; ApprovedResourceIds=@($approvedId)}
    $script:groupExists = $true
    $script:existingResources = @(@{id=$approvedId})
    $script:events.Clear()
    Assert-Throws { Invoke-LabAutomation $context } 'Lab deployment stopped at ValidateInputs'
    Assert-Test (-not $script:events.Contains('DeployResources/Running')) 'Default execution still rejects a non-empty resource group.'
    $script:events.Clear()
    $result = Invoke-LabAutomation -Context $context -Recovery $recovery
    Assert-Test ($result.Status -eq 'Succeeded' -and -not $script:events.Contains('GroupCreated')) 'Explicit recovery reuses only the approved existing resource group.'
    foreach ($case in @(
        @{Resources=@()},
        @{Resources=@(@{id=$approvedId}, @{id=($approvedId + '-extra')})},
        @{Resources=@(@{id=($approvedId + '-other')})}
    )) {
        $script:existingResources = $case.Resources
        $script:events.Clear()
        Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'Lab deployment stopped at ValidateInputs'
        Assert-Test (-not $script:events.Contains('DeployResources/Running')) 'Missing, additional and different resources prevent recovery writes.'
    }
    $script:existingResources = @(@{id=$approvedId})
    $script:deploymentState = 'Running'
    $script:events.Clear()
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'Lab deployment stopped at ValidateInputs'
    Assert-Test (-not $script:events.Contains('DeployResources/Running')) 'Active deployments prevent recovery writes.'
    $script:deploymentState = 'Failed'
    $invalidRecovery = $recovery.Clone()
    $invalidRecovery.ApprovedResourceIds = @($approvedId, $approvedId)
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $invalidRecovery } 'unique approved resource IDs'
    $invalidRecovery.ApprovedResourceIds = @($approvedId.Replace('/rg-test/', '/other/'))
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $invalidRecovery } 'outside the target resource group'
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery @{} } 'Recovery requires'
    $invalidRecord = $previousRecord.Clone()
    $invalidRecord.Status = 'Succeeded'
    $invalidRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'matching failed run record'
    $invalidRecord = $previousRecord.Clone()
    $invalidRecord.ResourceGroup = 'other'
    $invalidRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'Previous run context'
    $previousRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
    $originalRunDirectory = $context.RunDirectory
    $context.RunDirectory = $previousDirectory
    $originalRecordText = Get-Content -LiteralPath $previousStatePath -Raw
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'must not overwrite'
    Assert-Test ((Get-Content -LiteralPath $previousStatePath -Raw) -eq $originalRecordText) 'Invalid recovery cannot overwrite the previous state record.'
    $context.RunDirectory = $originalRunDirectory
    $script:groupExists = $false
    $script:events.Clear()
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $recovery } 'Lab deployment stopped at ValidateInputs'
    Assert-Test (-not $script:events.Contains('GroupCreated')) 'Recovery never creates a missing resource group.'
    $dnsRecord = $previousRecord.Clone()
    $dnsRecord.Stage = 'InitializeDns'
    $dnsRecord.Detail = @{CurrentRole='dns'; LastRunCommand='lab-dddddddd-initializedns-123abc'}
    $dnsRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    $dnsRecovery = $recovery.Clone()
    $dnsRecovery.ResumeFrom = 'InitializeDns'
    $vmIds = @('dns','workload','hyperv' | ForEach-Object {
        "/subscriptions/$($context.SubscriptionId)/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/labtest-$_"
    })
    $dnsRecovery.ApprovedResourceIds = @($approvedId) + $vmIds
    $script:groupExists = $true
    $script:existingResources = @($dnsRecovery.ApprovedResourceIds | ForEach-Object { @{id=$_} })
    $script:skuRestrictions = @(@{type='Location'})
    $script:events.Clear()
    $result = Invoke-LabAutomation -Context $context -Recovery $dnsRecovery
    Assert-Test ($result.Status -eq 'Succeeded' -and $script:events.Contains('hyperv/BuildNested') -and
        $script:events.Contains('RestrictionApplied')) 'DNS recovery completes the remaining guest configuration and restriction stages.'
    Assert-Test (-not $script:events.Contains('ResourceDeploymentRequested') -and
        -not $script:events.Contains('DeployResources/Running')) 'DNS recovery never redeploys VM or network resources and does not require new VM capacity.'
    $script:skuRestrictions = @()
    $invalidDnsRecord = $dnsRecord.Clone()
    $invalidDnsRecord.Detail = @{CurrentRole='workload'; LastRunCommand='lab-dddddddd-initializedns-123abc'}
    $invalidDnsRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $dnsRecovery } 'matching failed DNS role'
    $invalidDnsRecord.Detail = @{CurrentRole='dns'; LastRunCommand='lab-aaaaaaaa-initializedns-123abc'}
    $invalidDnsRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $dnsRecovery } 'matching failed DNS role'
    $dnsRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    $missingVmRecovery = $dnsRecovery.Clone()
    $missingVmRecovery.ApprovedResourceIds = @($approvedId) + $vmIds[0,1]
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $missingVmRecovery } 'all three approved lab VM IDs'
    $unknownStageRecovery = $dnsRecovery.Clone()
    $unknownStageRecovery.ResumeFrom = 'PrepareHyperV'
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $unknownStageRecovery } 'stage is not supported'
    $script:existingResources = @(@{id=$approvedId})
    $script:events.Clear()
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $dnsRecovery } 'Lab deployment stopped at ValidateInputs'
    Assert-Test (-not $script:events.Contains('StageSource/Running')) 'DNS recovery rejects changed resource inventories before guest operations.'
    $nestedRecord = $dnsRecord.Clone()
    $nestedRecord.Stage = 'BuildNested'
    $nestedRecord.Detail = @{CurrentRole='hyperv'; LastRunCommand='lab-dddddddd-buildnested-123abc'}
    $nestedRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    $nestedRecovery = $dnsRecovery.Clone()
    $nestedRecovery.ResumeFrom = 'BuildNested'
    $script:existingResources = @($nestedRecovery.ApprovedResourceIds | ForEach-Object { @{id=$_} })
    $script:events.Clear()
    $result = Invoke-LabAutomation -Context $context -Recovery $nestedRecovery
    Assert-Test ($result.Status -eq 'Succeeded' -and $script:events.Contains('hyperv/BuildNested') -and
        $script:events.Contains('RestrictionApplied')) 'Nested recovery completes L2 creation and final restriction.'
    Assert-Test (-not $script:events.Contains('ResourceDeploymentRequested') -and
        -not $script:events.Contains('dns/InitializeDns') -and
        -not $script:events.Contains('NicDns') -and
        -not $script:events.Contains('hyperv/PrepareHyperV') -and
        -not $script:events.Contains('Restart:hyperv')) 'Nested recovery never repeats VM, network, DNS or Hyper-V deployment.'
    $invalidNestedRecord = $nestedRecord.Clone()
    $invalidNestedRecord.Detail = @{CurrentRole='dns'; LastRunCommand='lab-dddddddd-buildnested-123abc'}
    $invalidNestedRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $nestedRecovery } 'matching failed hyperv role'
    $invalidNestedRecord.Detail = @{CurrentRole='hyperv'; LastRunCommand='lab-dddddddd-initializedns-123abc'}
    $invalidNestedRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $nestedRecovery } 'matching failed hyperv role'
    $nestedRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    $missingNestedVm = $nestedRecovery.Clone()
    $missingNestedVm.ApprovedResourceIds = @($approvedId) + $vmIds[0,1]
    Assert-Throws { Invoke-LabAutomation -Context $context -Recovery $missingNestedVm } 'all three approved lab VM IDs'
    $completionRecovery = $nestedRecovery.Clone()
    $completionRecovery.ResumeFrom = 'CompleteNested'
    $script:events.Clear()
    $result = Invoke-LabAutomation -Context $context -Recovery $completionRecovery
    Assert-Test ($result.Status -eq 'Succeeded' -and $script:events.Contains('hyperv/CompleteNested') -and
        $script:events.Contains('RestrictionApplied')) 'Explicit completion continues an existing L2 through final verification.'
    Assert-Test (-not $script:events.Contains('hyperv/BuildNested') -and
        -not $script:events.Contains('ResourceDeploymentRequested') -and
        -not $script:events.Contains('dns/InitializeDns') -and
        -not $script:events.Contains('hyperv/PrepareHyperV')) 'Existing L2 completion never falls back to fresh creation or completed foundation stages.'
    $priorCompletion = $nestedRecord.Clone()
    $priorCompletion.Detail = @{CurrentRole='hyperv'; LastRunCommand='lab-dddddddd-completenested-123abc'}
    $priorCompletion | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
    $result = Invoke-LabAutomation -Context $context -Recovery $completionRecovery
    Assert-Test ($result.Status -eq 'Succeeded') 'A recorded failed completion can retry only through the explicit completion mode.'
    $previousRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
    $script:groupExists = $false
    $script:existingResources = @()

    $previousConfigDir = $env:AZURE_CONFIG_DIR
    try {
        $env:AZURE_CONFIG_DIR = $temporary
        $context.AzureContext.ExpectedClientId = $script:clientId
        $context.AzureContext.ExpectedAzureConfigDir = $temporary
        $script:authenticationType = 'servicePrincipal'
        $result = Invoke-LabAutomation $context
        Assert-Test ($result.Status -eq 'Succeeded') 'Service principal context completes the same controller phases.'
        $script:groupExists = $true
        $script:existingResources = @(@{id=$approvedId})
        $result = Invoke-LabAutomation -Context $context -Recovery $recovery
        Assert-Test ($result.Status -eq 'Succeeded') 'Service principal recovery uses the approved identity and exact existing resource list.'
        $dnsRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
        $script:existingResources = @($dnsRecovery.ApprovedResourceIds | ForEach-Object { @{id=$_} })
        $script:events.Clear()
        $result = Invoke-LabAutomation -Context $context -Recovery $dnsRecovery
        Assert-Test ($result.Status -eq 'Succeeded' -and -not $script:events.Contains('ResourceDeploymentRequested')) 'Service principal DNS recovery skips resource deployment and completes all guest stages.'
        $nestedRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousStatePath
        $script:existingResources = @($nestedRecovery.ApprovedResourceIds | ForEach-Object { @{id=$_} })
        $script:events.Clear()
        $result = Invoke-LabAutomation -Context $context -Recovery $nestedRecovery
        Assert-Test ($result.Status -eq 'Succeeded' -and -not $script:events.Contains('ResourceDeploymentRequested') -and
            -not $script:events.Contains('dns/InitializeDns')) 'Service principal nested recovery retains the identity guard without repeating completed deployment.'
        $script:events.Clear()
        $result = Invoke-LabAutomation -Context $context -Recovery $completionRecovery
        Assert-Test ($result.Status -eq 'Succeeded' -and $script:events.Contains('hyperv/CompleteNested') -and
            -not $script:events.Contains('hyperv/BuildNested')) 'Service principal completion selects the existing-VM action only.'
        $previousRecord | ConvertTo-Json | Set-Content -LiteralPath $previousStatePath
        $script:groupExists = $false
        $script:existingResources = @()

        $legacy = Join-Path $temporary 'legacy'
        $null = New-Item -ItemType Directory -Path (Join-Path $legacy 'infra\lab') -Force
        Set-Content -LiteralPath (Join-Path $legacy 'infra\lab\Set-LabInternetAccess.ps1') -Value 'param()' -Encoding ascii
        $sourceRoot = $context.Source.Root
        $context.Source.Root = $legacy
        $script:events.Clear()
        Assert-Throws { Invoke-LabAutomation $context } 'Lab deployment stopped at ValidateInputs'
        Assert-Test (-not $script:events.Contains('DeployResources/Running')) 'Legacy source is rejected before resource deployment.'
        Assert-Test (-not $script:events.Contains('GroupCreated')) 'Legacy source is rejected before resource group creation.'
        $phaseFixture = @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [guid]$ExpectedTenantId, [guid]$ExpectedSubscriptionId, [guid]$ExpectedClientId,
    [string]$ResourceGroup, [string]$Prefix, [string]$Mode
)
@{
    Tenant=$ExpectedTenantId.ToString(); Subscription=$ExpectedSubscriptionId.ToString()
    Client=$ExpectedClientId.ToString(); Mode=$Mode
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'observed.json')
'@
        Set-Content -LiteralPath (Join-Path $legacy 'infra\lab\Set-LabInternetAccess.ps1') -Value $phaseFixture -Encoding ascii
        & $originalRestricted -Context $context
        $observedPath = Join-Path $legacy 'infra\lab\observed.json'
        $observed = Get-Content -LiteralPath $observedPath -Raw | ConvertFrom-Json
        Assert-Test ($observed.Client -eq $script:clientId -and $observed.Tenant -eq $context.TenantId -and
            $observed.Subscription -eq $context.SubscriptionId -and $observed.Mode -eq 'Restricted') 'NSG script receives the approved service principal and resource context.'
        Remove-Item -LiteralPath $observedPath
        $env:AZURE_CONFIG_DIR = [IO.Path]::GetTempPath()
        Assert-Throws { & $originalRestricted -Context $context } 'cache changed'
        Assert-Test (-not (Test-Path -LiteralPath $observedPath)) 'Changed cache blocks NSG script execution.'
        $env:AZURE_CONFIG_DIR = $temporary
        $context.Source.Root = $sourceRoot
    } finally {
        $env:AZURE_CONFIG_DIR = $previousConfigDir
        $context.AzureContext.Remove('ExpectedClientId')
        $context.AzureContext.Remove('ExpectedAzureConfigDir')
        $script:authenticationType = 'user'
    }

    foreach ($failure in 'hyperv/StageSource', 'dns/InitializeDns', 'hyperv/BuildNested', 'workload/VerifyBuild', 'hyperv/VerifyRestricted') {
        $script:events.Clear()
        $script:failure = $failure
        $script:prepareCalls = 0
        Assert-Throws { Invoke-LabAutomation $context } 'Lab deployment stopped'
        Assert-Test (-not $script:events.Contains('Complete/Succeeded')) 'Failure never emits completion.'
        if ($failure -notlike '*VerifyRestricted') {
            Assert-Test (-not $script:events.Contains('RestrictionApplied')) 'Failed build does not restrict unfinished guests.'
        } else {
            Assert-Test ($script:events.Contains('RestrictionApplied')) 'Post-restriction failure retains the applied phase.'
        }
    }
    Write-Output "PASS: $checks controller, result-contract, archive and failure-order assertions."
} finally {
    $password.Dispose()
    foreach ($file in @('state.json','fixture.zip','good\root\readme.txt','legacy\infra\lab\Set-LabInternetAccess.ps1','legacy\infra\lab\observed.json','failed-run\state.json','failed-run\approval.json')) {
        $path = Join-Path $temporary $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($directory in @('good\root','good','legacy\infra\lab','legacy\infra','legacy','failed-run')) {
        $path = Join-Path $temporary $directory
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $temporary
}
