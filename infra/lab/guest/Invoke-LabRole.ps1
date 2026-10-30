#requires -Version 5.1
# Inline bootstrap: no companion is loaded until the archive has been verified.
# Dot-sourcing defines functions only, for offline synthetic tests.
[CmdletBinding()]
param(
    [ValidateSet('StageSource','InitializeDns','PrepareHyperV','BuildNested','CompleteNested','VerifyBuild','VerifyRestricted')][string]$Action,
    [ValidateSet('dns','hyperv','workload')][string]$Role,
    [string]$CommitSha,
    [string]$Repository = 'uedait/ampls-arcpls-handson',
    [string]$ArchiveUri,
    [string]$ArchiveSha256,
    [string]$L2Password,
    [string]$RunId
)

function Assert-LabRequest {
    param([string]$Action, [string]$Role, [string]$CommitSha, [string]$Repository, [string]$RunId)
    if ($CommitSha -notmatch '^[a-fA-F0-9]{40}$' -or
        $Repository -cne 'uedait/ampls-arcpls-handson' -or
        $RunId -notmatch '^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$') {
        throw 'Invalid public request identity.'
    }
    $actions = @{
        dns = @('StageSource','InitializeDns','VerifyBuild','VerifyRestricted')
        hyperv = @('StageSource','PrepareHyperV','BuildNested','CompleteNested','VerifyBuild','VerifyRestricted')
        workload = @('StageSource','VerifyBuild','VerifyRestricted')
    }
    if (-not $actions.ContainsKey($Role) -or $actions[$Role] -notcontains $Action) {
        throw 'Role/action conflict.'
    }
}

function Assert-LabArchiveUri {
    param([Parameter(Mandatory)][uri]$Uri)
    # Exact host allowlist, not suffix matching. Never include a URI in errors.
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or
        $Uri.UserInfo -or $Uri.Fragment -or
        @('codeload.github.com', 'api.github.com', 'github.com') -notcontains $Uri.DnsSafeHost.ToLowerInvariant()) {
        throw 'Archive transport rejected.'
    }
}

function Assert-LabPlainPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { throw 'Local path rejected.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Reparse path rejected.'
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Protect-LabDirectory {
    param([string]$Path)
    Assert-LabPlainPath $Path
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-LabRequiredFiles {
    @(
        'infra/lab/guest/Invoke-LabRole.ps1'
        'infra/lab/guest/Initialize-WindowsDns.ps1'
        'infra/lab/guest/Install-HyperV.ps1'
        'infra/lab/guest/NestedIso.Helpers.ps1'
        'infra/lab/guest/Initialize-NestedNetwork.ps1'
        'infra/lab/guest/Set-NestedGuest.ps1'
        'infra/lab/guest/Test-NestedImds.ps1'
        'infra/lab/guest/New-NestedParentDisk.ps1'
        'infra/lab/guest/New-NestedLabFromIso.ps1'
        'infra/lab/guest/Initialize-LabHandover.ps1'
        'infra/lab/guest/Test-LabNestedReadiness.ps1'
        'scripts/Install-ArcAgent.ps1'
        'scripts/Connect-ArcServer.ps1'
        'scripts/Write-HandsonEvent.ps1'
    )
}

function Test-LabSelectedPath {
    param([string]$Path)
    return ($Path -match '^infra/lab/guest/[A-Za-z0-9_.-]+\.ps1$' -or
        $Path -in @('scripts/Install-ArcAgent.ps1','scripts/Connect-ArcServer.ps1','scripts/Write-HandsonEvent.ps1'))
}

function Get-LabArchivePlan {
    param([Parameter(Mandatory)][object[]]$Entries)
    if ($Entries.Count -eq 0 -or $Entries.Count -gt 20000) { throw 'Archive entry count rejected.' }
    $seen = @{}
    $files = @{}
    $directories = @{}
    $top = $null
    $total = [long]0
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Entries) {
        $name = [string]$entry.FullName
        # Backslashes and Windows path aliases are rejected rather than normalized.
        if (-not $name -or $name.Length -gt 220 -or $name.Contains('\') -or
            $name.StartsWith('/') -or $name.EndsWith('//') -or $name.Contains(':') -or $name -match '[\x00-\x1f]') {
            throw 'Archive path rejected.'
        }
        $isDirectory = $name.EndsWith('/')
        $parts = @($name.TrimEnd('/').Split('/'))
        if ($parts.Count -eq 0) { throw 'Archive path rejected.' }
        foreach ($part in $parts) {
            if (-not $part -or $part -in @('.', '..') -or $part -match '[<>:"|?*]' -or
                $part -match '[ .]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                throw 'Archive component rejected.'
            }
        }
        if (-not $top) { $top = $parts[0] }
        if ($parts[0] -cne $top -or (-not $isDirectory -and $parts.Count -lt 2)) {
            throw 'Archive must have one top-level directory.'
        }
        $key = $name.TrimEnd('/')
        if ($seen.ContainsKey($key)) { throw 'Archive path collision.' }
        $seen[$key] = $true
        $attributes = [long]$entry.ExternalAttributes -band 4294967295L
        $kind = ($attributes -shr 16) -band 61440
        if (($attributes -band 1024) -ne 0 -or $kind -notin @(0, 16384, 32768) -or
            ($isDirectory -and $kind -eq 32768) -or (-not $isDirectory -and $kind -eq 16384)) {
            throw 'Archive link or special file rejected.'
        }
        if ($entry.Length -lt 0 -or $entry.Length -gt 268435456) { throw 'Archive file length rejected.' }
        $total += [long]$entry.Length
        if ($total -gt 1073741824) { throw 'Archive expanded size rejected.' }
        if ($isDirectory) { $directories[$key] = $true }
        else { $files[$key] = $true }
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $directories[($parts[0..($i - 1)] -join '/')] = $true
        }
        if (-not $isDirectory) {
            $relative = ($parts[1..($parts.Count - 1)] -join '/')
            if (Test-LabSelectedPath $relative) {
                if ($entry.Length -eq 0 -or $entry.Length -gt 4194304) { throw 'Selected script length rejected.' }
                $plan.Add([pscustomobject]@{ Relative = $relative; Entry = $entry })
            }
        }
    }
    foreach ($key in $files.Keys) {
        if ($directories.ContainsKey($key)) { throw 'Archive file/directory collision.' }
    }
    $selected = @($plan | ForEach-Object Relative)
    foreach ($required in Get-LabRequiredFiles) {
        if ($selected -cnotcontains $required) { throw 'Required package file missing.' }
    }
    return $plan.ToArray()
}

function Test-LabSourceCacheOnly {
    param([string]$Action)
    return ($Action -ne 'StageSource')
}

function Get-LabDownloadRemainingMilliseconds {
    param([long]$ElapsedMilliseconds)
    if ($ElapsedMilliseconds -lt 0 -or $ElapsedMilliseconds -ge 600000) {
        throw 'Archive download deadline exceeded.'
    }
    return [int](600000 - $ElapsedMilliseconds)
}

function Copy-LabBoundedStream {
    param([IO.Stream]$InputStream, [IO.Stream]$OutputStream,
        [long]$Limit, [long]$ExpectedLength = -1, [Diagnostics.Stopwatch]$DownloadWatch)
    $buffer = New-Object byte[] 65536
    $length = [long]0
    while ($true) {
        if ($DownloadWatch) {
            $remaining = Get-LabDownloadRemainingMilliseconds $DownloadWatch.ElapsedMilliseconds
            $readTask = $InputStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait([int][Math]::Min(120000, $remaining))) {
                throw 'Archive download read timed out.'
            }
            $read = $readTask.Result
            [void](Get-LabDownloadRemainingMilliseconds $DownloadWatch.ElapsedMilliseconds)
        }
        else { $read = $InputStream.Read($buffer, 0, $buffer.Length) }
        if ($read -eq 0) { break }
        $length += $read
        if ($length -gt $Limit -or ($ExpectedLength -ge 0 -and $length -gt $ExpectedLength)) {
            throw 'Stream expansion limit exceeded.'
        }
        $OutputStream.Write($buffer, 0, $read)
    }
    if ($ExpectedLength -ge 0 -and $length -ne $ExpectedLength) { throw 'Stream length mismatch.' }
}

function Receive-LabArchive {
    param([string]$Uri, [string]$Path, [string]$ExpectedHash)
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Archive hash is required.' }
    $current = [uri]$Uri
    $complete = $false
    # One 600-second budget across redirects, response waits and body reads.
    # No automatic retry of an expired URL or failed request.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($hop = 0; $hop -le 5; $hop++) {
        $remaining = Get-LabDownloadRemainingMilliseconds $watch.ElapsedMilliseconds
        Assert-LabArchiveUri $current
        $request = [Net.HttpWebRequest]::Create($current)
        $request.AllowAutoRedirect = $false
        $request.UseDefaultCredentials = $false
        $request.Credentials = $null
        $request.Timeout = [int][Math]::Min(120000, $remaining)
        $request.ReadWriteTimeout = [int][Math]::Min(120000, $remaining)
        $request.UserAgent = 'AmplsArcLabBootstrap'
        $response = $null
        try {
            $pending = $request.BeginGetResponse($null, $null)
            try {
                $remaining = Get-LabDownloadRemainingMilliseconds $watch.ElapsedMilliseconds
                if (-not $pending.AsyncWaitHandle.WaitOne([int][Math]::Min(120000, $remaining))) {
                    throw 'Archive response timed out.'
                }
                $response = $request.EndGetResponse($pending)
            }
            finally {
                if (-not $pending.IsCompleted) { $request.Abort() }
                $pending.AsyncWaitHandle.Close()
            }
            [void](Get-LabDownloadRemainingMilliseconds $watch.ElapsedMilliseconds)
            Assert-LabArchiveUri $response.ResponseUri
            $status = [int]$response.StatusCode
            if ($status -in @(301,302,303,307,308)) {
                $current = [uri]::new($current, $response.Headers['Location'])
                Assert-LabArchiveUri $current
                continue
            }
            if ($status -ne 200 -or $response.ContentLength -gt 67108864) { throw 'Archive response rejected.' }
            $output = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
            $input = $null
            try {
                $input = $response.GetResponseStream()
                Copy-LabBoundedStream $input $output 67108864 $response.ContentLength $watch
            }
            finally { if ($input) { $input.Dispose() }; $output.Dispose() }
            $complete = $true
            break
        }
        catch { throw 'Archive transport failed; controller may retry only the download stage.' }
        finally {
            try { if ($response) { $response.Dispose() } }
            finally { $request.Abort() }
        }
    }
    if (-not $complete) { throw 'Archive redirect limit exceeded.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) { throw 'Archive hash mismatch.' }
}

function Assert-LabPackageMarker {
    param([object]$Marker, [string]$CommitSha, [string]$Repository, [string]$ArchiveHash)
    if ($Marker.Schema -cne 'AmplsArcSource-v1' -or $Marker.CommitSha -cne $CommitSha -or
        $Marker.Repository -cne $Repository -or $Marker.ArchiveSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        ($ArchiveHash -and $Marker.ArchiveSha256 -ne $ArchiveHash)) {
        throw 'Source marker identity mismatch.'
    }
    $seen = @{}
    foreach ($file in @($Marker.Files)) {
        if (-not (Test-LabSelectedPath $file.Path) -or $seen.ContainsKey($file.Path) -or
            $file.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Source marker file list rejected.' }
        $seen[$file.Path] = $true
    }
    foreach ($required in Get-LabRequiredFiles) {
        if (-not $seen.ContainsKey($required)) { throw 'Source marker incomplete.' }
    }
}

function Assert-LabPackage {
    param([string]$Path, [string]$CommitSha, [string]$Repository, [string]$ArchiveHash)
    Assert-LabPlainPath $Path
    $markerPath = Join-Path $Path 'source-package.json'
    Assert-LabPlainPath $markerPath
    $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json
    Assert-LabPackageMarker $marker $CommitSha $Repository $ArchiveHash
    foreach ($file in $marker.Files) {
        $local = Join-Path $Path ($file.Path.Replace('/', '\'))
        Assert-LabPlainPath $local
        if (-not (Test-Path -LiteralPath $local -PathType Leaf) -or
            (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $file.Sha256) {
            throw 'Source package file hash mismatch.'
        }
    }
    return $marker
}

function Get-LabPackage {
    param([string]$Root, [string]$CommitSha, [string]$Repository, [string]$ArchiveUri,
        [string]$ArchiveHash, [bool]$CacheOnly)
    $target = Join-Path $Root $CommitSha
    Assert-LabPlainPath $target
    if (Test-Path -LiteralPath $target) {
        [void](Assert-LabPackage $target $CommitSha $Repository $ArchiveHash)
        return $target
    }
    if ($CacheOnly -or -not $ArchiveUri -or $ArchiveHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Verified source cache unavailable.'
    }
    $stage = Join-Path $Root ('stage-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $stage -ErrorAction Stop)
    Protect-LabDirectory $stage
    $zipPath = Join-Path $stage 'source.zip'
    $ownedFiles = New-Object 'System.Collections.Generic.List[string]'
    $ownedDirectories = New-Object 'System.Collections.Generic.List[string]'
    $ownedFiles.Add($zipPath)
    $archive = $null
    $moved = $false
    try {
        Receive-LabArchive $ArchiveUri $zipPath $ArchiveHash
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        $plan = @(Get-LabArchivePlan @($archive.Entries))
        $manifestFiles = @()
        foreach ($item in $plan) {
            $local = Join-Path $stage ($item.Relative.Replace('/', '\'))
            $directory = [IO.Path]::GetDirectoryName($local)
            $missing = New-Object 'System.Collections.Generic.List[string]'
            $cursor = $directory
            while (-not (Test-Path -LiteralPath $cursor)) {
                $missing.Add($cursor)
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
            for ($i = $missing.Count - 1; $i -ge 0; $i--) {
                [void](New-Item -ItemType Directory -Path $missing[$i] -ErrorAction Stop)
                $ownedDirectories.Add($missing[$i])
            }
            Assert-LabPlainPath $local
            $stream = [IO.File]::Open($local, 'CreateNew', 'Write', 'None')
            $ownedFiles.Add($local)
            $input = $null
            try {
                $input = $item.Entry.Open()
                Copy-LabBoundedStream $input $stream 4194304 $item.Entry.Length
            }
            finally { if ($input) { $input.Dispose() }; $stream.Dispose() }
            if ((Get-Item -LiteralPath $local).Length -ne $item.Entry.Length) { throw 'Extracted length mismatch.' }
            $manifestFiles += [ordered]@{
                Path = $item.Relative; Sha256 = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            }
        }
        $archive.Dispose()
        $archive = $null
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
        $markerPath = Join-Path $stage 'source-package.json'
        $ownedFiles.Add($markerPath)
        $marker = [ordered]@{
            Schema = 'AmplsArcSource-v1'; CommitSha = $CommitSha
            Repository = $Repository; ArchiveSha256 = $ArchiveHash.ToUpperInvariant()
            Files = $manifestFiles
        }
        [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        [void](Assert-LabPackage $stage $CommitSha $Repository $ArchiveHash)
        if (Test-Path -LiteralPath $target) { throw 'Source directory collision; no overwrite allowed.' }
        Move-Item -LiteralPath $stage -Destination $target -ErrorAction Stop
        $moved = $true
        return $target
    }
    finally {
        if ($archive) { $archive.Dispose() }
        if (-not $moved) {
            # Only exact files created by this invocation, and empty known dirs.
            # Unknown files are retained. Never recursively delete a source root.
            foreach ($file in $ownedFiles) {
                Assert-LabPlainPath $file
                if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
            }
            for ($i = $ownedDirectories.Count - 1; $i -ge 0; $i--) {
                Assert-LabPlainPath $ownedDirectories[$i]
                if ((Test-Path -LiteralPath $ownedDirectories[$i]) -and
                    @(Get-ChildItem -LiteralPath $ownedDirectories[$i] -Force).Count -eq 0) {
                    [IO.Directory]::Delete($ownedDirectories[$i], $false)
                }
            }
            Assert-LabPlainPath $stage
            if (@(Get-ChildItem -LiteralPath $stage -Force).Count -eq 0) { [IO.Directory]::Delete($stage, $false) }
        }
    }
}

function Assert-LabHostIdentity {
    param([string]$Role)
    $map = @{ dns = '10.30.1.5'; hyperv = '10.30.1.4'; workload = '10.10.1.4' }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' })
    if (@($ips | Where-Object IPAddress -eq $map[$Role]).Count -ne 1 -or
        @($ips | Where-Object { $map.Values -contains $_.IPAddress -and $_.IPAddress -ne $map[$Role] }).Count -gt 0) {
        throw 'Host role/IP identity mismatch.'
    }
}

function Assert-LabDns {
    param([string]$Role)
    $address = if ($Role -eq 'workload') { '10.20.2.4' } else { '10.30.1.5' }
    $ip = (@{ dns = '10.30.1.5'; hyperv = '10.30.1.4'; workload = '10.10.1.4' })[$Role]
    $adapter = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $ip)
    if ($adapter.Count -ne 1) { throw 'Host adapter mismatch.' }
    $servers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses)
    if ($servers.Count -ne 1 -or $servers[0] -ne $address) { throw 'Host DNS setting mismatch.' }
    if ($Role -eq 'dns') {
        if (-not (Get-WindowsFeature DNS).Installed -or (Get-Service DNS).Status -ne 'Running') {
            throw 'DNS role/service not ready.'
        }
        Import-Module DnsServer -ErrorAction Stop
        $forwarders = @((Get-DnsServerForwarder).IPAddress | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() })
        if ($forwarders.Count -ne 1 -or $forwarders[0] -ne '168.63.129.16') { throw 'DNS forwarder mismatch.' }
    }
    $answers = @(Resolve-DnsName 'www.microsoft.com' -Server $address -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -in @('A', 'AAAA') })
    if ($answers.Count -eq 0) { throw 'DNS query returned no addresses.' }
    $answers = @(Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -in @('A', 'AAAA') })
    if ($answers.Count -eq 0) { throw 'Default DNS query returned no addresses.' }
}

function Assert-LabRdp {
    if ((Get-Service TermService -ErrorAction Stop).Status -ne 'Running' -or
        (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections -ne 0) {
        throw 'Windows RDP service/settings not ready.'
    }
}

function Assert-LabPublicBlocked {
    foreach ($target in @('1.1.1.1', 'management.azure.com')) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($target, 443)
            try { [void]$task.Wait(4000) } catch [AggregateException] { }
            if ($client.Connected) { throw 'Fresh public TCP connection succeeded.' }
        }
        finally { $client.Dispose() }
    }
}

function Get-LabNestedChecks {
    param([string]$Package, [pscredential]$Credential, [bool]$Restricted)
    if (-not $Credential) { throw 'Protected L2 credential is required.' }
    Import-Module Hyper-V -ErrorAction Stop
    if (-not (Get-WindowsFeature Hyper-V).Installed -or (Get-Service vmms).Status -ne 'Running') {
        throw 'Hyper-V feature/service not ready.'
    }
    $vm = Get-VM -Name 'ArcOnpremL2' -ErrorAction Stop
    if ($vm.State -ne 'Running' -or $vm.Generation -ne 2) { throw 'L2 VM not ready.' }
    $biosGuid = Get-NestedVmBiosGuid -VmId $vm.Id
    $hashes = @{}
    foreach ($name in @('Install-ArcAgent.ps1','Connect-ArcServer.ps1','Write-HandsonEvent.ps1')) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $Package "scripts\$name") -Algorithm SHA256).Hash
    }
    $direct = $null
    $session = $null
    try {
        $direct = Wait-NestedDirect -VmName $vm.Name -Credential $Credential -TimeoutSeconds 120
        $session = $direct.Session
        $checks = @(Invoke-Command -Session $session -FilePath (Join-Path $Package 'infra\lab\guest\Test-LabNestedReadiness.ps1') `
            -ArgumentList "$biosGuid", $hashes, $Restricted -ErrorAction Stop)
        if ($checks.Count -ne 1 -or -not $checks[0].NestedReady) { throw 'Unexpected nested verification result.' }
        foreach ($key in @('NestedReady','IdentityReady','NetworkReady','DnsReady','ImdsBlocked','HandoverFilesReady','Licensed')) {
            if ($checks[0].$key -isnot [bool] -or -not $checks[0].$key) { throw 'Nested public check did not pass.' }
        }
        if ($Restricted -and ($checks[0].InternetBlocked -isnot [bool] -or -not $checks[0].InternetBlocked)) {
            throw 'Nested Internet block did not pass.'
        }
        return $checks[0]
    }
    finally {
        try { if ($session) { Remove-PSSession -Session $session -ErrorAction Stop } }
        finally { if ($direct) { $direct.Pipeline.Dispose() } }
    }
}

function ConvertTo-LabResult {
    param([string]$RunId, [string]$Role, [string]$Action, [string]$CommitSha,
        [bool]$RebootRequired, [hashtable]$Checks)
    Assert-LabRequest $Action $Role $CommitSha 'uedait/ampls-arcpls-handson' $RunId
    $allowed = @('RoleReady','DnsReady','HyperVReady','NestedReady','IdentityReady',
        'NetworkReady','ImdsBlocked','HandoverFilesReady','Licensed','RdpReady',
        'EventScriptReady','InternetBlocked','SourceVerified','L2Ready','HandoverReady','L2InternetBlocked')
    $result = [ordered]@{
        RunId = $RunId; Role = $Role; Action = $Action; CommitSha = $CommitSha
        Succeeded = $true; FilesReady = $true; RebootRequired = $RebootRequired
    }
    foreach ($key in $Checks.Keys) {
        if ($allowed -cnotcontains $key -or $Checks[$key] -isnot [bool]) { throw 'Unsafe public result rejected.' }
        $result[$key] = $Checks[$key]
    }
    if ($RebootRequired) {
        if ($Action -notin @('InitializeDns','PrepareHyperV')) { throw 'Unexpected reboot result.' }
        foreach ($key in @('RoleReady','DnsReady','HyperVReady','L2Ready')) {
            if ($Checks.ContainsKey($key) -and $Checks[$key]) { throw 'Reboot result cannot claim role readiness.' }
        }
    }
    else {
        $requiredChecks = switch ($Action) {
            'StageSource' { @('SourceVerified') }
            'InitializeDns' { @('DnsReady') }
            'PrepareHyperV' { @('HyperVReady') }
            { $_ -in @('BuildNested','CompleteNested') } { @('L2Ready','HandoverReady','ImdsBlocked','Licensed') }
            'VerifyBuild' {
                @('DnsReady','RdpReady')
                if ($Role -eq 'hyperv') { @('L2Ready','HandoverReady','ImdsBlocked','Licensed') }
            }
            'VerifyRestricted' {
                @('InternetBlocked','DnsReady','RdpReady')
                if ($Role -eq 'hyperv') { @('L2InternetBlocked','ImdsBlocked','HandoverReady') }
            }
        }
        foreach ($key in $requiredChecks) {
            if (-not $Checks.ContainsKey($key) -or -not $Checks[$key]) { throw 'Required public check did not pass.' }
        }
    }
    return ('LAB_RESULT:' + ($result | ConvertTo-Json -Compress -Depth 4))
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$stage = 'RequestValidation'
$lock = $null
$credential = $null
$safeResult = $null
try {
    Assert-LabRequest $Action $Role $CommitSha $Repository $RunId
    $CommitSha = $CommitSha.ToLowerInvariant()
    if ($ArchiveSha256 -and $ArchiveSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid archive hash.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        $PSVersionTable.PSVersion.Major -ne 5) { throw 'Requires administrator Windows PowerShell 5.1.' }
    $stage = 'HostIdentity'
    Assert-LabHostIdentity $Role
    $cacheOnly = Test-LabSourceCacheOnly $Action
    if ($cacheOnly -and $ArchiveUri) { throw 'ArchiveUri is accepted only for StageSource.' }
    $stage = if ($cacheOnly) { 'SourceValidation' } else { 'SourceDownload' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $base = 'C:\ProgramData\AmplsArcHandson'
    $root = Join-Path $base 'Source'
    foreach ($directory in @($base, $root)) {
        Assert-LabPlainPath $directory
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
        }
        Protect-LabDirectory $directory
    }
    $lockPath = Join-Path $root "$CommitSha.lock"
    Assert-LabPlainPath $lockPath
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $package = Get-LabPackage $root $CommitSha $Repository $ArchiveUri $ArchiveSha256 $cacheOnly
    $ArchiveUri = $null
    $stage = 'SourceValidation'
    [void](Assert-LabPackage $package $CommitSha $Repository $ArchiveSha256)
    Protect-LabDirectory $package
    $guest = Join-Path $package 'infra\lab\guest'
    if ($Action -ne 'StageSource') { . (Join-Path $guest 'NestedIso.Helpers.ps1') }
    if ($Role -eq 'hyperv' -and $Action -in @('BuildNested','CompleteNested','VerifyBuild','VerifyRestricted')) {
        if (-not $L2Password) { throw 'Protected L2 credential is required.' }
        $secure = ConvertTo-SecureString $L2Password -AsPlainText -Force
        $credential = [pscredential]::new('Administrator', $secure)
        $L2Password = $null
    }
    $checks = @{ SourceVerified = $true; RoleReady = $false }
    $reboot = $false
    $stage = $Action
    switch ($Action) {
        'StageSource' {
            # Only the verified package is staged. No role, DNS, VM, license
            # or nested guest configuration is performed by this action.
        }
        'InitializeDns' {
            $operation = & (Join-Path $guest 'Initialize-WindowsDns.ps1') -StructuredResult `
                -InformationAction SilentlyContinue -WarningAction SilentlyContinue
            if ($null -eq $operation -or $operation.RebootRequired -isnot [bool]) { throw 'Invalid DNS installation result.' }
            $reboot = $operation.RebootRequired
            $checks.DnsReady = $false
            if (-not $reboot) {
                Assert-LabDns $Role
                $checks.DnsReady = $true
                $checks.RoleReady = $true
            }
        }
        'PrepareHyperV' {
            $operation = & (Join-Path $guest 'Install-HyperV.ps1') -StructuredResult `
                -InformationAction SilentlyContinue -WarningAction SilentlyContinue
            if ($null -eq $operation -or $operation.RebootRequired -isnot [bool]) { throw 'Invalid Hyper-V installation result.' }
            $reboot = $operation.RebootRequired
            $checks.HyperVReady = $false
            # DNS is checked by Install-HyperV before installing the feature.
            if (-not $reboot) {
                Assert-LabDns $Role
                $checks.HyperVReady = $true
                $checks.RoleReady = $true
            }
        }
        { $_ -in @('BuildNested','CompleteNested') } {
            Assert-LabDns $Role
            $nestedArguments = @{UseDefaultMedia=$true; Credential=$credential}
            if ($Action -eq 'CompleteNested') { $nestedArguments.ContinueExistingVm=$true }
            & (Join-Path $guest 'New-NestedLabFromIso.ps1') @nestedArguments `
                -InformationAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            $nested = Get-LabNestedChecks $package $credential $false
            foreach ($key in @('NestedReady','IdentityReady','NetworkReady','ImdsBlocked','HandoverFilesReady','Licensed')) {
                $checks[$key] = [bool]$nested.$key
            }
            $checks.L2Ready = [bool]$nested.NestedReady
            $checks.HandoverReady = [bool]$nested.HandoverFilesReady
            $checks.DnsReady = $true
            $checks.RoleReady = $true
        }
        { $_ -in @('VerifyBuild','VerifyRestricted') } {
            Assert-LabDns $Role
            Assert-LabRdp
            $checks.DnsReady = $true
            $checks.RdpReady = $true
            # Source hash verification covers the three actual handover scripts
            # on every role, including workload's event script metadata.
            $event = Get-Item -LiteralPath (Join-Path $package 'scripts\Write-HandsonEvent.ps1')
            if ($event.Length -le 0 -or $event.Extension -ne '.ps1') { throw 'Event script metadata mismatch.' }
            $checks.EventScriptReady = $true
            if ($Role -eq 'hyperv') {
                $nested = Get-LabNestedChecks $package $credential ($Action -eq 'VerifyRestricted')
                foreach ($key in @('NestedReady','IdentityReady','NetworkReady','ImdsBlocked','HandoverFilesReady','Licensed')) {
                    $checks[$key] = [bool]$nested.$key
                }
                $checks.L2Ready = [bool]$nested.NestedReady
                $checks.HandoverReady = [bool]$nested.HandoverFilesReady
                if ($Action -eq 'VerifyRestricted') { $checks.L2InternetBlocked = [bool]$nested.InternetBlocked }
                $checks.HyperVReady = $true
            }
            if ($Action -eq 'VerifyRestricted') {
                Assert-LabPublicBlocked
                $checks.InternetBlocked = $true
            }
            $checks.RoleReady = $true
        }
        default { throw 'Unsupported action.' }
    }
    # Recheck source files even after the invoked scripts have finished.
    [void](Assert-LabPackage $package $CommitSha $Repository $ArchiveSha256)
    $safeResult = ConvertTo-LabResult $RunId $Role $Action $CommitSha $reboot $checks
    $stage = 'LockRelease'
    $lock.Dispose()
    $lock = $null
}
catch {
    # Do not emit underlying errors, URIs, XML, credentials or arbitrary messages.
    [Console]::Error.WriteLine("LAB_ERROR:Stage=$stage;Kind=GuestStageFailed")
    exit 1
}
finally {
    if ($lock) { $lock.Dispose() }
    $ArchiveUri = $null
    $L2Password = $null
    $credential = $null
    $secure = $null
}
Write-Output $safeResult
exit 0
