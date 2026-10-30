#requires -Version 5.1
# Offline only: no Pester, administrator, downloads, disk writes or guest calls.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-LabRole.ps1')
$script:LabRoleOfflineAssertionCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw "FAIL: $Description" }
    $script:LabRoleOfflineAssertionCount++
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Description)
    $failed = $false
    try { & $Body | Out-Null } catch { $failed = $true }
    Assert-True $failed $Description
}
# The entry's dot-source guard must return before runtime initialization.
# This second load is isolated; it does not call any bootstrap/role function.
$functionsOnlyProbe = & {
    $stage = 'FunctionsOnlySentinel'
    $lock = 'FunctionsOnlySentinel'
    $credential = 'FunctionsOnlySentinel'
    $safeResult = 'FunctionsOnlySentinel'
    $protocolBefore = [Net.ServicePointManager]::SecurityProtocol
    $loadOutput = @(. (Join-Path $PSScriptRoot 'Invoke-LabRole.ps1'))
    [pscustomobject]@{
        OutputCount = $loadOutput.Count
        RuntimeUntouched = ($stage -ceq 'FunctionsOnlySentinel' -and
            $lock -ceq 'FunctionsOnlySentinel' -and
            $credential -ceq 'FunctionsOnlySentinel' -and
            $safeResult -ceq 'FunctionsOnlySentinel')
        ProtocolUnchanged = ([Net.ServicePointManager]::SecurityProtocol -eq $protocolBefore)
        FunctionLoaded = ($null -ne (Get-Command Assert-LabRequest -CommandType Function -ErrorAction Stop))
    }
}
Assert-True ($functionsOnlyProbe.OutputCount -eq 0) 'Functions-only entry load emits no runtime result'
Assert-True $functionsOnlyProbe.RuntimeUntouched 'Functions-only entry load skips runtime initialization'
Assert-True $functionsOnlyProbe.ProtocolUnchanged 'Functions-only entry load leaves process TLS settings unchanged'
Assert-True $functionsOnlyProbe.FunctionLoaded 'Functions-only entry load exposes helpers'
$commit = 'a' * 40
$hash = 'b' * 64
$run = 'c' * 32
$repo = 'uedait/ampls-arcpls-handson'
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    Assert-True (@([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count -eq 0) "ASCII: $($file.Name)"
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PS parsing: $($file.Name)"
}
foreach ($role in @('dns','hyperv','workload')) {
    foreach ($action in @('StageSource','VerifyBuild','VerifyRestricted')) {
        Assert-LabRequest $action $role $commit $repo $run
        $script:LabRoleOfflineAssertionCount++
    }
}
Assert-True (-not (Test-LabSourceCacheOnly StageSource)) 'Only StageSource may acquire the archive'
foreach ($action in @('InitializeDns','PrepareHyperV','BuildNested','CompleteNested','VerifyBuild','VerifyRestricted')) {
    Assert-True (Test-LabSourceCacheOnly $action) 'Role actions require an owned cache, never a download fallback'
}
Assert-True ((Get-LabDownloadRemainingMilliseconds 0) -eq 600000) 'Source download budget is 600 seconds'
Assert-True ((Get-LabDownloadRemainingMilliseconds 599999) -eq 1) 'Redirect/read budgets share the remaining deadline'
Assert-Throws { Get-LabDownloadRemainingMilliseconds 600000 } 'Reject elapsed download deadline'
Assert-Throws { Get-LabDownloadRemainingMilliseconds 600001 } 'No unlimited retry after deadline'
$dnsText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Initialize-WindowsDns.ps1'))
$dnsSwitch = $dnsText.IndexOf('Set-DnsClientServerAddress')
$dnsProbe = $dnsText.IndexOf('$answers = @(Resolve-DnsName')
$dnsEffective = $dnsText.IndexOf('$effectiveForwarders =')
Assert-True ($dnsEffective -ge 0 -and $dnsProbe -gt $dnsEffective -and $dnsSwitch -gt $dnsProbe) 'DNS switch follows effective-forwarder check and explicit self-query'
$dnsTokens = $null
$dnsErrors = $null
$dnsAst = [Management.Automation.Language.Parser]::ParseInput($dnsText, [ref]$dnsTokens, [ref]$dnsErrors)
$findForwarderAssignment = {
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -in @('forwarders','effectiveForwarders') -and
    $node.Right.Extent.Text.Contains('Get-DnsServerForwarder')
}
$forwarderAssignments = @($dnsAst.FindAll($findForwarderAssignment, $true)) +
    @(${function:Assert-LabDns}.Ast.FindAll($findForwarderAssignment, $true))
Assert-True ($forwarderAssignments.Count -eq 3) 'All DNS forwarder conversions are exercised'
foreach ($statement in $forwarderAssignments) {
    foreach ($case in @(
        @{ Addresses=$null; Expected=@() },
        @{ Addresses=@([ipaddress]'168.63.129.16'); Expected=@('168.63.129.16') },
        @{ Addresses=@($null,[ipaddress]'168.63.129.16'); Expected=@('168.63.129.16') },
        @{ Addresses=@([ipaddress]'1.1.1.1'); Expected=@('1.1.1.1') }
    )) {
        $converted = @(& {
            param($Statement,$Addresses)
            function Get-DnsServerForwarder { [pscustomobject]@{IPAddress=$Addresses} }
            . ([scriptblock]::Create($Statement.Extent.Text))
            foreach ($address in (Get-Variable -Name $Statement.Left.VariablePath.UserPath -ValueOnly)) { $address }
        } $statement $case.Addresses)
        Assert-True ($converted.Count -eq $case.Expected.Count) 'Null forwarders produce no address entries'
        Assert-True (($converted -join ',') -ceq ($case.Expected -join ',')) 'Non-null forwarders preserve their actual address values'
    }
}
$initialGuard = $dnsAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($forwarders.Count -gt 0')
}, $true)
$effectiveGuard = $dnsAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains('$effectiveForwarders.Count -ne 1')
}, $true)
$roleGuard = ${function:Assert-LabDns}.Ast.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($forwarders.Count -ne 1')
}, $true)
Assert-True ($null -ne $initialGuard -and $null -ne $effectiveGuard -and $null -ne $roleGuard) 'Initial and configured DNS guards are present'
function Invoke-TestDnsForwarderGuard {
    param($Guard,[object[]]$Addresses)
    & {
        param($Guard,$Addresses)
        function Get-Service { [pscustomobject]@{Status='Running'} }
        $forwarders = @($Addresses | Where-Object { $null -ne $_ })
        $effectiveForwarders = $forwarders
        . ([scriptblock]::Create($Guard.Extent.Text))
    } $Guard $Addresses
}
Invoke-TestDnsForwarderGuard $initialGuard @()
Invoke-TestDnsForwarderGuard $initialGuard @('168.63.129.16')
Assert-True $true 'Initial DNS setup permits empty or already-correct forwarders'
Assert-Throws { Invoke-TestDnsForwarderGuard $initialGuard @('1.1.1.1') } 'Initial DNS setup refuses an unexpected existing forwarder'
Assert-Throws { Invoke-TestDnsForwarderGuard $initialGuard @('168.63.129.16','1.1.1.1') } 'Initial DNS setup refuses multiple existing forwarders'
foreach ($guard in @($effectiveGuard,$roleGuard)) {
    Invoke-TestDnsForwarderGuard $guard @('168.63.129.16')
    Assert-True $true 'Configured DNS requires the approved Azure DNS forwarder'
    Assert-Throws { Invoke-TestDnsForwarderGuard $guard @() } 'Configured DNS rejects an empty effective forwarder list'
    Assert-Throws { Invoke-TestDnsForwarderGuard $guard @('1.1.1.1') } 'Configured DNS rejects an unexpected forwarder'
}
Assert-LabRequest InitializeDns dns $commit $repo ([guid]::NewGuid().ToString())
Assert-LabRequest PrepareHyperV hyperv $commit $repo $run
Assert-LabRequest BuildNested hyperv $commit $repo $run
Assert-LabRequest CompleteNested hyperv $commit $repo $run
foreach ($pair in @(@('InitializeDns','hyperv'), @('InitializeDns','workload'),
    @('PrepareHyperV','dns'), @('BuildNested','workload'), @('BuildNested','dns'),
    @('CompleteNested','dns'), @('CompleteNested','workload'), @('Other','hyperv'))) {
    Assert-Throws { Assert-LabRequest $pair[0] $pair[1] $commit $repo $run } 'Reject role/action conflict'
}
Assert-Throws { Assert-LabRequest VerifyBuild dns 'bad' $repo $run } 'Commit must be full SHA'
Assert-Throws { Assert-LabRequest VerifyBuild dns $commit 'other/repo' $run } 'Reject repository mismatch'
Assert-Throws { Assert-LabRequest VerifyBuild dns $commit $repo '../bad' } 'RunId must not become a path'
foreach ($hostName in @('codeload.github.com','api.github.com','github.com')) {
    Assert-LabArchiveUri ([uri]"https://$hostName/example")
    $script:LabRoleOfflineAssertionCount++
}
# Signed query accepted but not included in any result/marker or diagnostic.
Assert-LabArchiveUri ([uri]'https://codeload.github.com/example?synthetic=sensitive')
foreach ($bad in @('http://codeload.github.com/a', 'https://codeload.github.com.evil.example/a',
    'https://evil.example/a', 'https://codeload.github.com:444/a',
    'https://user:pass@codeload.github.com/a', 'https://codeload.github.com/a#x',
    'file:///C:/test.zip')) {
    Assert-Throws { Assert-LabArchiveUri ([uri]$bad) } 'Reject unsafe archive request or redirect'
}
Assert-Throws {
    Assert-LabArchiveUri ([uri]::new([uri]'https://codeload.github.com/a', '//evil.example/b'))
} 'Reject cross-host redirect before request'

function New-Entry {
    param([string]$Name, [long]$Attributes = 0, [long]$Length = 100)
    [pscustomobject]@{ FullName = $Name; ExternalAttributes = $Attributes; Length = $Length }
}
$entries = @(Get-LabRequiredFiles | ForEach-Object { New-Entry "repo-commit/$_" })
$plan = @(Get-LabArchivePlan -Entries $entries)
Assert-True ($plan.Count -eq (Get-LabRequiredFiles).Count) 'Required archive plan'
Assert-True (@($plan | Where-Object Relative -like 'scripts/*').Count -eq 3) 'Three handover files'
foreach ($bad in @(
    '/root/file', 'C:/root/file', 'repo-commit/../escape.ps1',
    'repo-commit/a/../../escape.ps1', 'repo-commit\infra\file',
    'repo-commit//file', 'repo-commit/AUX.txt', 'repo-commit/file.',
    'repo-commit/file ', 'repo-commit/a:stream', 'other-root/file',
    'repo-commit/dir//', 'root-file'
)) {
    Assert-Throws { Get-LabArchivePlan -Entries ($entries + @(New-Entry $bad)) } 'Reject ZipSlip/path alias/multiple roots'
}
Assert-Throws { Get-LabArchivePlan -Entries ($entries + @($entries[0])) } 'Reject duplicate path'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry ($entries[0].FullName.ToUpperInvariant())))
} 'Reject case-insensitive collision'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry 'repo-commit/scripts'))
} 'Reject file/directory conflict independent of entry order'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry 'repo-commit/link' 2684354560))
} 'Reject Unix symlink'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry 'repo-commit/link' 1024))
} 'Reject DOS reparse attribute'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry 'repo-commit/device' 536870912))
} 'Reject Unix device'
Assert-Throws {
    Get-LabArchivePlan -Entries ($entries + @(New-Entry 'repo-commit/huge' 0 268435457))
} 'Reject oversized expansion'
Assert-Throws { Get-LabArchivePlan -Entries $entries[1..($entries.Count - 1)] } 'Reject missing required entry'

$inputStream = [IO.MemoryStream]::new([byte[]]@(1,2,3,4))
$outputStream = [IO.MemoryStream]::new()
try {
    Copy-LabBoundedStream $inputStream $outputStream 4 4
    Assert-True ($outputStream.Length -eq 4) 'Bounded stream exact length'
    $inputStream.Position = 0
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Copy-LabBoundedStream $inputStream $outputStream 4 4 $watch
    $watch.Stop()
    Assert-True ($outputStream.Length -eq 8) 'Deadline-aware async read uses the same bounded stream checks'
    $inputStream.Position = 0
    Assert-Throws { Copy-LabBoundedStream $inputStream $outputStream 3 } 'Reject false central-directory size/expansion bomb'
    $inputStream.Position = 0
    Assert-Throws { Copy-LabBoundedStream $inputStream $outputStream 8 5 } 'Reject truncated stream'
}
finally { $inputStream.Dispose(); $outputStream.Dispose() }

function New-Marker {
    [pscustomobject]@{
        Schema = 'AmplsArcSource-v1'; CommitSha = $commit; Repository = $repo; ArchiveSha256 = $hash
        Files = @(Get-LabRequiredFiles | ForEach-Object { [pscustomobject]@{ Path = $_; Sha256 = $hash } })
    }
}
$marker = New-Marker
Assert-LabPackageMarker $marker $commit $repo $hash
Assert-LabPackageMarker $marker $commit $repo ''
$script:LabRoleOfflineAssertionCount += 2
Assert-Throws { Assert-LabPackageMarker $marker ('d' * 40) $repo $hash } 'Reject cached different commit'
Assert-Throws { Assert-LabPackageMarker $marker $commit $repo ('d' * 64) } 'Reject cached different ZIP'
$marker = New-Marker
$marker.Files[0].Path = '../outside.ps1'
Assert-Throws { Assert-LabPackageMarker $marker $commit $repo $hash } 'Reject marker traversal'
$marker = New-Marker
$marker.Files[0].Sha256 = 'invalid'
Assert-Throws { Assert-LabPackageMarker $marker $commit $repo $hash } 'Reject incomplete marker hash'
$marker = New-Marker
$marker.Files = @($marker.Files[0])
Assert-Throws { Assert-LabPackageMarker $marker $commit $repo $hash } 'Existence is not a complete manifest'
$marker = New-Marker
$marker.Files += $marker.Files[0]
Assert-Throws { Assert-LabPackageMarker $marker $commit $repo $hash } 'Reject duplicate manifest record'

foreach ($role in @('dns','hyperv','workload')) {
    $staged = ConvertTo-LabResult $run $role StageSource $commit $false @{ SourceVerified = $true; RoleReady = $false }
    $stageJson = $staged.Substring(11) | ConvertFrom-Json
    Assert-True ($stageJson.Action -ceq 'StageSource' -and $stageJson.Role -ceq $role -and
        $stageJson.RunId -ceq $run -and $stageJson.CommitSha -ceq $commit -and
        $stageJson.Succeeded -eq $true -and $stageJson.FilesReady -eq $true -and
        -not $stageJson.RebootRequired -and -not $stageJson.RoleReady) 'StageSource result does not claim role readiness'
    # Top-level variables share script scope. Never reuse the counter's name
    # for the public-check dictionary (the original $checks did exactly that).
    $publicResultChecks = @{ DnsReady = $true; RdpReady = $true; RoleReady = $true; InternetBlocked = $true }
    Assert-True ($script:LabRoleOfflineAssertionCount -is [int]) 'Public result dictionary cannot replace the assertion counter'
    if ($role -eq 'hyperv') {
        foreach ($key in @('L2Ready','HandoverReady','ImdsBlocked','Licensed','L2InternetBlocked')) { $publicResultChecks[$key] = $true }
    }
    foreach ($action in @('VerifyBuild','VerifyRestricted')) {
        $line = ConvertTo-LabResult $run $role $action $commit $false $publicResultChecks
        Assert-True ($line.StartsWith('LAB_RESULT:') -and -not $line.Contains("`n")) 'Single compact result line'
        $json = $line.Substring('LAB_RESULT:'.Length) | ConvertFrom-Json
        Assert-True ($json.RunId -ceq $run -and $json.CommitSha -ceq $commit -and
            $json.Succeeded -eq $true -and $json.FilesReady -eq $true -and
            $json.Role -ceq $role -and $json.Action -ceq $action) 'Controller identity/result contract'
    }
}
$line = ConvertTo-LabResult $run hyperv PrepareHyperV $commit $true @{ HyperVReady = $false; RoleReady = $false }
Assert-True (($line.Substring(11) | ConvertFrom-Json).RebootRequired -is [bool]) 'Reboot boolean, not VM restart'
$line = ConvertTo-LabResult $run dns InitializeDns $commit $true @{ DnsReady = $false; RoleReady = $false }
Assert-True (-not ($line.Substring(11) | ConvertFrom-Json).DnsReady) 'Reboot DNS not configured yet'
Assert-Throws {
    ConvertTo-LabResult $run dns StageSource $commit $false @{ SourceVerified = $false }
} 'StageSource cannot succeed with an invalid cache'
Assert-Throws {
    ConvertTo-LabResult $run hyperv StageSource $commit $true @{ SourceVerified = $true }
} 'Source staging cannot request a role reboot'
Assert-Throws {
    ConvertTo-LabResult $run dns InitializeDns $commit $true @{ DnsReady = $true }
} 'Reject success-looking DNS result before reboot'
Assert-Throws {
    ConvertTo-LabResult $run dns InitializeDns $commit $false @{ DnsReady = $false }
} 'Reject incomplete DNS result'
Assert-Throws {
    ConvertTo-LabResult $run hyperv BuildNested $commit $false @{ L2Ready = $true; HandoverReady = $true; ImdsBlocked = $true }
} 'License cannot be omitted'
Assert-Throws {
    ConvertTo-LabResult $run hyperv CompleteNested $commit $false @{ L2Ready=$true; HandoverReady=$true; ImdsBlocked=$true }
} 'Existing VM completion cannot omit license validation'
Assert-Throws {
    ConvertTo-LabResult $run workload VerifyBuild $commit $false @{ DnsReady = $true; RdpReady = $true; ArchiveUri = $true }
} 'Reject unapproved result keys'
Assert-Throws {
    ConvertTo-LabResult $run workload VerifyBuild $commit $false @{ DnsReady = 'true'; RdpReady = $true }
} 'Reject stringified check booleans'
Assert-Throws {
    ConvertTo-LabResult $run hyperv VerifyRestricted $commit $false @{
        InternetBlocked = $true; DnsReady = $true; RdpReady = $true; ImdsBlocked = $true; HandoverReady = $true
    }
} 'L1 deny does not prove L2 deny'
Write-Output "PASS: $script:LabRoleOfflineAssertionCount offline bootstrap assertions. No network, ISO, guest, ACL, or platform readiness was exercised."
