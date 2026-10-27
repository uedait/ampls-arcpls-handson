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
    $instance = @{output='LAB_RESULT:' + ($valid | ConvertTo-Json -Compress)}
    $result = Assert-LabRoleResult $context hyperv VerifyBuild $instance
    Assert-Test ($result.Licensed -eq $true) 'Valid structured readiness result.'
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
    function Save-LabRunState {
        param($Context, $Stage, $Status, $Detail=@{})
        $script:events.Add("$Stage/$Status")
    }
    function Invoke-HandsonAz {
        param($Arguments)
        $line = $Arguments -join ' '
        if ($line -like 'vm list-skus*') {
            $size = $Arguments[[array]::IndexOf($Arguments, '--size') + 1]
            return @(@{name=$size; resourceType='virtualMachines'; restrictions=@(); capabilities=@(@{name='HyperVGenerations';value='V1,V2'})})
        }
        if ($line -like 'group list*') { return @() }
        if ($line -like 'group create*') { return @{name='rg-test'} }
        if ($line -like 'bicep build*') { return @{resources=@()} }
        if ($line -like 'network nic update*') { $script:events.Add('NicDns'); return @{name='nic'} }
        throw "Unexpected synthetic CLI request: $line"
    }
    function Invoke-LabArm {
        param($Context, $Method, $Path, $Body)
        if ($Method -eq 'PUT' -and $Path -like '*deployments/optional-lab*') {
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
    foreach ($file in @('state.json','fixture.zip','good\root\readme.txt')) {
        $path = Join-Path $temporary $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($directory in @('good\root','good')) {
        $path = Join-Path $temporary $directory
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $temporary
}
