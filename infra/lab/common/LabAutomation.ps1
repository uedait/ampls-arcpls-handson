#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-LabArm {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body
    )
    if (-not $Path.StartsWith("/subscriptions/$($Context.SubscriptionId)/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ARM request does not match the approved subscription.'
    }
    $token = Invoke-HandsonAz -Arguments @('account', 'get-access-token',
        '--resource', 'https://management.azure.com/', '--subscription', $Context.SubscriptionId) -ExpectedContext $Context.AzureContext
    if ($token.tenant -ne $Context.TenantId -or $token.subscription -ne $Context.SubscriptionId -or -not $token.accessToken) {
        throw 'ARM token context mismatch.'
    }
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [timespan]::FromMinutes(5)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "https://management.azure.com$Path")
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token.accessToken)
    try {
        if ($Body) {
            $json = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
            $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw 'ARM transport failed. Inspect the resource state before retrying a write request.' }
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "ARM request failed (HTTP $([int]$response.StatusCode)); the response body is suppressed."
            }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
            return (ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100)
        } finally { $response.Dispose() }
    } finally {
        $json = $null
        $token = $null
        $request.Dispose()
        $client.Dispose()
    }
}

function Invoke-LabGitHub {
    param([Security.SecureString]$Token, [string]$Path, [switch]$ArchiveLocation)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "https://api.github.com$Path")
    $request.Headers.UserAgent.ParseAdd('ampls-arcpls-handson')
    $request.Headers.Accept.ParseAdd('application/vnd.github+json')
    $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
        'Bearer', [Net.NetworkCredential]::new('', $Token).Password)
    try {
        try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw 'GitHub request transport failed; credential and URL details are suppressed.' }
        try {
            if ($ArchiveLocation) {
                if ([int]$response.StatusCode -notin 301, 302, 303, 307, 308) {
                    throw "GitHub archive request failed (HTTP $([int]$response.StatusCode))."
                }
                $uri = $response.Headers.Location
                if (-not $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
                    $uri.DnsSafeHost -ne 'codeload.github.com' -or $uri.UserInfo -or $uri.Port -ne 443) {
                    throw 'GitHub returned an unexpected archive host.'
                }
                return $uri.AbsoluteUri
            }
            if (-not $response.IsSuccessStatusCode) {
                throw "GitHub request failed (HTTP $([int]$response.StatusCode)). Check repository read permission."
            }
            return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 100)
        } finally { $response.Dispose() }
    } finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Get-LabArchiveUri {
    param([string]$Repository, [string]$CommitSha, [Security.SecureString]$Token)
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $CommitSha -notmatch '^[a-f0-9]{40}$') {
        throw 'Use an owner/repository and a complete commit SHA.'
    }
    return (Invoke-LabGitHub -Token $Token -Path "/repos/$Repository/zipball/$CommitSha" -ArchiveLocation)
}

function Expand-LabSourceArchive {
    param([string]$ArchivePath, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Source destination already exists.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        foreach ($entry in $archive.Entries) {
            $parts = $entry.FullName.Replace('\', '/').Split('/')
            if ($entry.FullName.StartsWith('/') -or $entry.FullName.Contains(':') -or
                $parts -contains '..' -or $parts -contains '.' -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Archive contains an unsafe path or symbolic link.'
            }
            if ($parts[0]) { [void]$roots.Add($parts[0]) }
            $total += $entry.Length
        }
        if ($roots.Count -ne 1 -or $archive.Entries.Count -gt 3000 -or $total -gt 128MB) {
            throw 'Unexpected source archive layout or size.'
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
        return (Join-Path $Destination @($roots)[0])
    } finally { $archive.Dispose() }
}

function Get-LabSource {
    param([string]$Repository, [string]$Ref, [Security.SecureString]$Token, [string]$RunDirectory)
    $commit = Invoke-LabGitHub -Token $Token -Path "/repos/$Repository/commits/$([uri]::EscapeDataString($Ref))"
    if ($commit.sha -notmatch '^[a-f0-9]{40}$') { throw 'GitHub returned no complete commit SHA.' }
    $url = Get-LabArchiveUri -Repository $Repository -CommitSha $commit.sha -Token $Token
    $zip = Join-Path $RunDirectory 'source.zip'
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromMinutes(10)
    try {
        try { $response = $client.GetAsync($url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
        catch { throw 'Source archive download failed; short-lived URL details are suppressed.' }
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "Source archive download failed (HTTP $([int]$response.StatusCode))."
            }
            $stream = [IO.File]::Create($zip)
            try { $null = $response.Content.CopyToAsync($stream).GetAwaiter().GetResult() }
            finally { $stream.Dispose() }
        } finally { $response.Dispose() }
    } finally { $client.Dispose(); $url = $null }
    $sourceRoot = Expand-LabSourceArchive -ArchivePath $zip -Destination (Join-Path $RunDirectory 'source')
    foreach ($relative in @('infra\lab\main.bicep', 'infra\lab\guest\Invoke-LabRole.ps1',
        'infra\lab\Set-LabInternetAccess.ps1', 'scripts\Write-HandsonEvent.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
            throw "Published commit is missing $relative. Publish the automation revision before deploying."
        }
    }
    return @{
        CommitSha = $commit.sha
        ArchiveSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Root = $sourceRoot
    }
}

function Save-LabRunState {
    param([hashtable]$Context, [string]$Stage, [string]$Status, [hashtable]$Detail = @{})
    $state = @{
        RunId=$Context.RunId; Stage=$Stage; Status=$Status; TenantId=$Context.TenantId
        SubscriptionId=$Context.SubscriptionId; ResourceGroup=$Context.ResourceGroup
        Prefix=$Context.Prefix; CommitSha=$Context.Source.CommitSha
        UpdatedUtc=[datetime]::UtcNow.ToString('o'); Detail=$Detail
    }
    $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Context.RunDirectory 'state.json') -Encoding utf8NoBOM
    Write-Host "[$Status] $Stage"
}

function Get-LabResourcePath {
    param([hashtable]$Context, [string]$Suffix)
    return "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$([uri]::EscapeDataString($Context.ResourceGroup))/$Suffix"
}

function Wait-LabDeployment {
    param([hashtable]$Context, [string]$Path, [int]$TimeoutSeconds = 7200)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $deployment = Invoke-LabArm -Context $Context -Method GET -Path $Path
        $status = $deployment.properties.provisioningState
        if ($status -eq 'Succeeded') { return }
        if ($status -in 'Failed', 'Canceled') { throw "Resource deployment ended in $status. Inspect the named deployment in Azure." }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Resource deployment timed out; inspect Azure before retrying.' }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Wait-LabVmReady {
    param([hashtable]$Context, [string]$VmName, [int]$TimeoutSeconds = 1800)
    $path = Get-LabResourcePath $Context "providers/Microsoft.Compute/virtualMachines/$VmName/instanceView?api-version=2024-07-01"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $view = Invoke-LabArm -Context $Context -Method GET -Path $path
        $running = @($view['statuses'] | Where-Object { $_.code -eq 'PowerState/running' }).Count -eq 1
        $agentStatus = if ($view['vmAgent']) { @($view.vmAgent['statuses']) } else { @() }
        $ready = @($agentStatus | Where-Object { $_.code -eq 'ProvisioningState/succeeded' }).Count -gt 0
        if ($running -and $ready) { return }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "VM Agent readiness timed out for $VmName." }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Invoke-LabManagedCommand {
    param(
        [hashtable]$Context, [string]$Role, [string]$Action, [string]$Script,
        [hashtable]$Parameters = @{}, [hashtable]$ProtectedParameters = @{},
        [int]$TimeoutSeconds = 14400
    )
    $vm = "$($Context.Prefix)-$Role"
    $name = "lab-$($Context.RunId.Substring(0, 8))-$($Action.ToLowerInvariant())-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $resource = Get-LabResourcePath $Context "providers/Microsoft.Compute/virtualMachines/$vm/runCommands/$name"
    $Context.LastRunCommand = $name
    $Context.CurrentRole = $Role
    $path = "${resource}?api-version=2024-07-01"
    $body = @{
        location=$Context.Location
        properties=@{
            source=@{script=$Script}
            parameters=@($Parameters.GetEnumerator() | ForEach-Object { @{name=$_.Key; value=[string]$_.Value} })
            protectedParameters=@($ProtectedParameters.GetEnumerator() | ForEach-Object { @{name=$_.Key; value=[string]$_.Value} })
            timeoutInSeconds=$TimeoutSeconds; asyncExecution=$true; treatFailureAsDeploymentFailure=$true
        }
    }
    $null = Invoke-LabArm -Context $Context -Method PUT -Path $path -Body $body
    $body = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $run = Invoke-LabArm -Context $Context -Method GET -Path "${resource}?api-version=2024-07-01&`$expand=instanceView"
        $instance = $run.properties['instanceView']
        $execution = if ($instance) { $instance.executionState } else { $null }
        if ($execution -eq 'Succeeded') {
            if ($instance.exitCode -ne 0) { throw "$Role / $Action returned a non-zero guest exit code." }
            return $instance
        }
        if ($execution -in 'Failed', 'Canceled', 'TimedOut' -or $run.properties.provisioningState -in 'Failed', 'Canceled') {
            throw "$Role / $Action failed in Managed Run Command. Raw output is suppressed; inspect the safe guest stage."
        }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds + 300) {
            throw "$Role / $Action exceeded its managed execution deadline."
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Assert-LabRoleResult {
    param([hashtable]$Context, [string]$Role, [string]$Action, [hashtable]$Instance)
    $matches = [regex]::Matches([string]$Instance.output, '(?m)^LAB_RESULT:(\{[^\r\n]*\})\s*$')
    if ($matches.Count -ne 1) { throw "$Role / $Action returned no unique structured result." }
    try { $result = $matches[0].Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 20 }
    catch { throw "$Role / $Action returned an invalid structured result." }
    if ($result.RunId -ne $Context.RunId -or $result.Role -ne $Role -or $result.Action -ne $Action -or
        $result.CommitSha -ne $Context.Source.CommitSha -or
        $result.Succeeded -isnot [bool] -or $result.Succeeded -ne $true -or
        $result.FilesReady -isnot [bool] -or $result.FilesReady -ne $true) {
        throw "$Role / $Action result identity or file verification mismatch."
    }
    if ($Action -in 'InitializeDns', 'PrepareHyperV') {
        if ($result['RebootRequired'] -isnot [bool]) { throw "$Role / $Action omitted the boolean restart status." }
        if ($result.RebootRequired) { return $result }
    }
    $required = switch ($Action) {
        'StageSource' { @() }
        'InitializeDns' { @('DnsReady') }
        'PrepareHyperV' { @('HyperVReady') }
        { $_ -in @('BuildNested','CompleteNested') } { @('L2Ready', 'HandoverReady', 'ImdsBlocked', 'Licensed') }
        'VerifyBuild' { @('DnsReady', 'RdpReady') }
        'VerifyRestricted' { @('InternetBlocked', 'DnsReady', 'RdpReady') }
        default { throw 'Unknown guest action.' }
    }
    if ($Role -eq 'hyperv' -and $Action -eq 'VerifyBuild') { $required += @('L2Ready', 'HandoverReady', 'ImdsBlocked', 'Licensed') }
    if ($Role -eq 'hyperv' -and $Action -eq 'VerifyRestricted') { $required += @('L2InternetBlocked', 'ImdsBlocked', 'HandoverReady') }
    foreach ($key in $required) {
        if ($result[$key] -isnot [bool] -or $result[$key] -ne $true) { throw "$Role / $Action did not verify $key." }
    }
    return $result
}

function Invoke-LabRoleAction {
    param([hashtable]$Context, [string]$Role, [string]$Action, [switch]$Download)
    $parameters = @{
        Role=$Role; Action=$Action; RunId=$Context.RunId; Repository=$Context.Repository
        CommitSha=$Context.Source.CommitSha; ArchiveSha256=$Context.Source.ArchiveSha256
    }
    $protected = @{}
    if ($Download) {
        $protected.ArchiveUri = Get-LabArchiveUri -Repository $Context.Repository -CommitSha $Context.Source.CommitSha -Token $Context.GitHubToken
    }
    if ($Role -eq 'hyperv' -and $Action -in 'BuildNested', 'CompleteNested', 'VerifyBuild', 'VerifyRestricted') {
        $protected.L2Password = [Net.NetworkCredential]::new('', $Context.L2Password).Password
    }
    try {
        $script = Get-Content -LiteralPath (Join-Path $Context.Source.Root 'infra\lab\guest\Invoke-LabRole.ps1') -Raw
        $timeout = if ($Action -eq 'StageSource') { 600 } else { 14400 }
        $instance = Invoke-LabManagedCommand -Context $Context -Role $Role -Action $Action -Script $script `
            -Parameters $parameters -ProtectedParameters $protected -TimeoutSeconds $timeout
        return (Assert-LabRoleResult -Context $Context -Role $Role -Action $Action -Instance $instance)
    } finally { $protected.Clear() }
}

function Restart-LabVm {
    param([hashtable]$Context, [string]$Role)
    $vm = "$($Context.Prefix)-$Role"
    $azContext = $Context.AzureContext
    Assert-HandsonAzContext @azContext
    & az vm restart --resource-group $Context.ResourceGroup --name $vm `
        --subscription $Context.SubscriptionId --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "VM restart failed for $vm." }
    Wait-LabVmReady -Context $Context -VmName $vm
}

function Set-LabRestrictedMode {
    param([hashtable]$Context)
    $azContext = $Context.AzureContext
    Assert-HandsonAzContext @azContext
    $authentication = @{}
    if ($Context.AzureContext.ContainsKey('ExpectedClientId')) {
        $authentication.ExpectedClientId = $Context.AzureContext.ExpectedClientId
    }
    & (Join-Path $Context.Source.Root 'infra\lab\Set-LabInternetAccess.ps1') `
        -ExpectedTenantId $Context.TenantId -ExpectedSubscriptionId $Context.SubscriptionId `
        -ResourceGroup $Context.ResourceGroup -Prefix $Context.Prefix -Mode Restricted -Confirm:$false @authentication | Out-Host
}

function Get-LabDeploymentTemplate {
    param([hashtable]$Context)
    $path = Join-Path $Context.RunDirectory 'compiled-template.json'
    if (Test-Path -LiteralPath $path) { throw 'Compiled template destination already exists.' }
    try {
        & az bicep build --file (Join-Path $Context.Source.Root 'infra\lab\main.bicep') `
            --outfile $path --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Bicep template compilation failed.' }
        return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100)
    } finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Assert-LabRecoveryContext {
    param([hashtable]$Context, [hashtable]$Recovery)
    if (-not $Recovery.ContainsKey('PreviousRunDirectory') -or
        -not [IO.Path]::IsPathFullyQualified($Recovery.PreviousRunDirectory) -or
        -not $Recovery.ContainsKey('ApprovedResourceIds')) {
        throw 'Recovery requires an absolute previous run directory and approved resource IDs.'
    }
    if ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Recovery.PreviousRunDirectory)) -eq
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Context.RunDirectory))) {
        throw 'Recovery must not overwrite the previous run directory.'
    }
    $previous = Get-Content -LiteralPath (Join-Path $Recovery.PreviousRunDirectory 'state.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $approval = Get-Content -LiteralPath (Join-Path $Recovery.PreviousRunDirectory 'approval.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $resumeFrom = if ($Recovery.ContainsKey('ResumeFrom')) { $Recovery.ResumeFrom } else { 'DeployResources' }
    if ($resumeFrom -notin 'DeployResources','InitializeDns','BuildNested','CompleteNested') { throw 'The requested recovery stage is not supported.' }
    $previousStage = if ($resumeFrom -eq 'CompleteNested') { 'BuildNested' } else { $resumeFrom }
    if ($previous['Stage'] -ne $previousStage -or $previous['Status'] -ne 'Failed' -or
        $previous['RunId'] -notmatch '^[a-f0-9]{32}$' -or $previous.RunId -eq $Context.RunId -or
        $approval['RunId'] -ne $previous.RunId -or $approval['SourceCommit'] -ne $previous['CommitSha'] -or
        $previous['CommitSha'] -notmatch '^[a-f0-9]{40}$') {
        throw 'Recovery requires a matching failed run record for the requested stage from a different run.'
    }
    foreach ($key in 'TenantId','SubscriptionId','ResourceGroup','Prefix') {
        if ($previous[$key] -ne $Context[$key]) { throw 'Previous run context does not match the approved recovery target.' }
    }
    foreach ($key in 'ResourceGroup','Prefix','Location','Repository') {
        if ($approval[$key] -ne $Context[$key]) { throw 'Previous approval does not match the approved recovery target.' }
    }
    $approvedIds = @($Recovery.ApprovedResourceIds)
    $scope = "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroup)/providers/"
    if ($approvedIds.Count -eq 0 -or @($approvedIds | Sort-Object -Unique).Count -ne $approvedIds.Count) {
        throw 'Recovery requires a non-empty list of unique approved resource IDs.'
    }
    foreach ($id in $approvedIds) {
        if ($id -isnot [string] -or -not $id.StartsWith($scope, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'An approved recovery resource ID is outside the target resource group.'
        }
    }
    if ($resumeFrom -in 'InitializeDns','BuildNested','CompleteNested') {
        $expectedRole = if ($resumeFrom -eq 'InitializeDns') { 'dns' } else { 'hyperv' }
        $actionPattern = if ($resumeFrom -eq 'CompleteNested') { '(?:buildnested|completenested)' } else { $resumeFrom.ToLowerInvariant() }
        $commandPattern = '^lab-' + $previous.RunId.Substring(0, 8) + '-' + $actionPattern + '-[a-f0-9]{6}$'
        if ($previous['Detail'] -isnot [Collections.IDictionary] -or
            $previous.Detail['CurrentRole'] -ne $expectedRole -or $previous.Detail['LastRunCommand'] -notmatch $commandPattern) {
            throw "Guest recovery requires the matching failed $expectedRole role and Run Command record."
        }
        foreach ($role in 'dns','workload','hyperv') {
            $vmId = $scope + "Microsoft.Compute/virtualMachines/$($Context.Prefix)-$role"
            if ($approvedIds -notcontains $vmId) { throw 'Guest recovery requires all three approved lab VM IDs.' }
        }
    }
}

function Invoke-LabAutomation {
    param([hashtable]$Context, [hashtable]$Recovery)
    $recovering = $PSBoundParameters.ContainsKey('Recovery') -and $null -ne $Recovery
    if ($recovering) { Assert-LabRecoveryContext -Context $Context -Recovery $Recovery }
    $guestOnly = $recovering -and ($Recovery['ResumeFrom'] -in 'InitializeDns','BuildNested','CompleteNested')
    $nestedOnly = $recovering -and ($Recovery['ResumeFrom'] -in 'BuildNested','CompleteNested')
    $stage = 'ValidateInputs'
    try {
        Save-LabRunState $Context $stage 'Running'
        $azContext = $Context.AzureContext
        Assert-HandsonAzContext @azContext
        if ($Context.AzureContext.ContainsKey('ExpectedClientId')) {
            $phaseScript = Get-Command -Name (Join-Path $Context.Source.Root 'infra\lab\Set-LabInternetAccess.ps1') -ErrorAction Stop
            if (-not $phaseScript.Parameters.ContainsKey('ExpectedClientId')) {
                throw 'Published commit does not support service principal authentication. Publish the authentication revision before deploying.'
            }
        }
        $subscription = @('--subscription', $Context.SubscriptionId)
        if (-not $guestOnly) {
            foreach ($size in @($Context.WorkloadVmSize, $Context.DnsVmSize, $Context.HyperVVmSize) | Select-Object -Unique) {
                $skus = @(Invoke-HandsonAz -Arguments (@('vm', 'list-skus', '--location', $Context.Location,
                    '--size', $size, '--all') + $subscription) -ExpectedContext $Context.AzureContext)
                $sku = @($skus | Where-Object { $_.name -eq $size -and $_.resourceType -eq 'virtualMachines' })
                if ($sku.Count -ne 1 -or @($sku[0].restrictions | Where-Object { $_.type -ne 'Zone' }).Count -gt 0) {
                    throw "VM size is unavailable or restricted: $size."
                }
                if (@($sku[0].capabilities | Where-Object { $_.name -eq 'HyperVGenerations' -and $_.value -match 'V2' }).Count -ne 1) {
                    throw "Gen2 is unavailable for $size."
                }
            }
        }
        $groups = @(Invoke-HandsonAz -Arguments (@('group', 'list') + $subscription) -ExpectedContext $Context.AzureContext)
        if (@($groups | Where-Object { $_.name -eq $Context.ResourceGroup }).Count -gt 0) {
            $existing = @(Invoke-HandsonAz -Arguments (@('resource', 'list', '--resource-group', $Context.ResourceGroup) + $subscription) -ExpectedContext $Context.AzureContext)
            if ($recovering) {
                $deployments = @(Invoke-HandsonAz -Arguments (@('deployment', 'group', 'list',
                    '--resource-group', $Context.ResourceGroup) + $subscription) -ExpectedContext $Context.AzureContext)
                if (@($deployments | Where-Object { $_.properties.provisioningState -notin 'Succeeded','Failed','Canceled' }).Count -gt 0) {
                    throw 'A deployment is still active. Recovery did not change any resources.'
                }
                $actualIds = @($existing | ForEach-Object { $_.id } | Sort-Object)
                $approvedIds = @($Recovery.ApprovedResourceIds | Sort-Object)
                if ($actualIds.Count -ne $approvedIds.Count -or
                    @(Compare-Object $actualIds $approvedIds).Count -gt 0) {
                    throw 'Existing resources do not exactly match the approved recovery resource IDs.'
                }
            } elseif ($existing.Count -gt 0) {
                throw 'Use a new or empty lab resource group; automatic resume over resources is not supported.'
            }
        } else {
            if ($recovering) { throw 'The approved recovery resource group is missing. No resource group was created.' }
            $null = Invoke-HandsonAz -Arguments (@('group', 'create', '--name', $Context.ResourceGroup, '--location', $Context.Location) + $subscription) -ExpectedContext $Context.AzureContext
        }
        if (-not $guestOnly) {
            $stage = 'DeployResources'
            Save-LabRunState $Context $stage 'Running'
            $compiled = Get-LabDeploymentTemplate -Context $Context
            $body = @{
                properties=@{
                    mode='Incremental'; template=$compiled
                    parameters=@{
                        prefix=@{value=$Context.Prefix}; location=@{value=$Context.Location}
                        workloadVmSize=@{value=$Context.WorkloadVmSize}; dnsVmSize=@{value=$Context.DnsVmSize}
                        hyperVVmSize=@{value=$Context.HyperVVmSize}; adminUsername=@{value=$Context.VmCredential.UserName}
                        adminPassword=@{value=$Context.VmCredential.GetNetworkCredential().Password}
                    }
                }
            }
            $deploymentPath = Get-LabResourcePath $Context 'providers/Microsoft.Resources/deployments/optional-lab?api-version=2022-09-01'
            try { $null = Invoke-LabArm -Context $Context -Method PUT -Path $deploymentPath -Body $body }
            finally { $body = $null }
            Wait-LabDeployment -Context $Context -Path $deploymentPath
        }
        $stage = 'StageSource'
        Save-LabRunState $Context $stage 'Running'
        foreach ($role in 'dns', 'workload', 'hyperv') {
            Wait-LabVmReady -Context $Context -VmName "$($Context.Prefix)-$role"
            $probe = Invoke-LabManagedCommand -Context $Context -Role $role -Action Warmup `
                -Script "Write-Output 'LAB_WARMUP_READY'" -TimeoutSeconds 600
            if ([string]$probe.output -notmatch 'LAB_WARMUP_READY') { throw "Managed Run Command warmup failed for $role." }
            $null = Invoke-LabRoleAction -Context $Context -Role $role -Action StageSource -Download
        }
        if (-not $nestedOnly) {
            $stage = 'InitializeDns'
            Save-LabRunState $Context $stage 'Running'
            $dns = Invoke-LabRoleAction -Context $Context -Role dns -Action InitializeDns
            if ($dns.RebootRequired -eq $true) {
                Restart-LabVm -Context $Context -Role dns
                $dns = Invoke-LabRoleAction -Context $Context -Role dns -Action InitializeDns
                if ($dns.RebootRequired -eq $true) { throw 'DNS VM requested a second restart; inspect its feature state.' }
            }
            foreach ($role in 'dns', 'hyperv') {
                $null = Invoke-HandsonAz -Arguments (@('network', 'nic', 'update',
                    '--resource-group', $Context.ResourceGroup, '--name', "$($Context.Prefix)-$role-nic",
                    '--dns-servers', '10.30.1.5') + $subscription) -ExpectedContext $Context.AzureContext
            }
            $stage = 'PrepareHyperV'
            Save-LabRunState $Context $stage 'Running'
            $hyperv = Invoke-LabRoleAction -Context $Context -Role hyperv -Action PrepareHyperV
            if ($hyperv.RebootRequired -eq $true) {
                Restart-LabVm -Context $Context -Role hyperv
                $hyperv = Invoke-LabRoleAction -Context $Context -Role hyperv -Action PrepareHyperV
                if ($hyperv.RebootRequired -eq $true) { throw 'L1 requested a second restart; inspect Hyper-V state.' }
            }
        }
        $stage = 'BuildNested'
        Save-LabRunState $Context $stage 'Running'
        $nestedAction = if ($recovering -and $Recovery['ResumeFrom'] -eq 'CompleteNested') { 'CompleteNested' } else { 'BuildNested' }
        $null = Invoke-LabRoleAction -Context $Context -Role hyperv -Action $nestedAction
        $stage = 'VerifyBuild'
        Save-LabRunState $Context $stage 'Running'
        foreach ($role in 'dns', 'workload', 'hyperv') {
            $null = Invoke-LabRoleAction -Context $Context -Role $role -Action VerifyBuild
        }
        $stage = 'RestrictInternet'
        Save-LabRunState $Context $stage 'Running'
        Set-LabRestrictedMode -Context $Context
        $stage = 'VerifyRestricted'
        Save-LabRunState $Context $stage 'Running'
        foreach ($role in 'dns', 'workload', 'hyperv') {
            $null = Invoke-LabRoleAction -Context $Context -Role $role -Action VerifyRestricted
        }
        Save-LabRunState $Context 'Complete' 'Succeeded'
        return @{
            Status='Succeeded'; ResourceGroup=$Context.ResourceGroup; CommitSha=$Context.Source.CommitSha
            BastionName="$($Context.Prefix)-bastion"; InternetPhase='Restricted'
            VmNames=@('dns', 'workload', 'hyperv' | ForEach-Object { "$($Context.Prefix)-$_" })
        }
    } catch {
        $detail = @{ FailureKind=$_.Exception.GetType().Name }
        foreach ($key in 'CurrentRole', 'LastRunCommand') {
            if ($Context.ContainsKey($key)) { $detail[$key] = $Context[$key] }
        }
        Save-LabRunState $Context $stage 'Failed' $detail
        throw "Lab deployment stopped at $stage. Inspect $($Context.RunDirectory) and the resource group; the state identifies the last VM/Run Command. Resources and current Internet phase were retained. No completion was reported."
    }
}
