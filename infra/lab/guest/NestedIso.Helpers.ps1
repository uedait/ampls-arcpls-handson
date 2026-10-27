#requires -Version 5.1
# Pure helpers: loading this file performs no downloads or host/guest changes.
Set-StrictMode -Version 2.0

function Assert-NestedOfficialUri {
    param([Parameter(Mandatory)][uri]$Uri)
    $hosts = @('download.microsoft.com', 'software-download.microsoft.com',
        'software-static.download.prss.microsoft.com')
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or
        $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or
        $hosts -notcontains $Uri.DnsSafeHost.ToLowerInvariant()) {
        throw 'Only HTTPS port 443 on explicitly allowed Microsoft media hosts is accepted.'
    }
}

function Select-NestedImage {
    param([Parameter(Mandatory)][object[]]$Images, [string]$ImageName, [switch]$DefaultEvaluation)
    $matches = @($Images | Where-Object {
        ([version]$_.Version).Build -eq 20348 -and
        $_.EditionId -match '^Server(Standard|Datacenter)(Eval)?$' -and
        $_.InstallationType -eq 'Server' -and
        "$($_.Architecture)" -in @('9', 'x64', 'amd64') -and
        (-not $ImageName -or $_.ImageName -ceq $ImageName) -and
        (-not $DefaultEvaluation -or ($_.EditionId -eq 'ServerStandardEval' -and
            @($_.Languages | Where-Object { "$_" -match '^en-US(\s.*)?$' }).Count -gt 0))
    })
    if ($matches.Count -ne 1) {
        throw 'Select exactly one WS2022 x64 Standard/Datacenter Desktop Experience image with -ImageName. No fixed index is assumed.'
    }
    return $matches[0]
}

function Get-NestedMedia {
    param(
        [Parameter(Mandatory)][uri]$DownloadUri,
        [Parameter(Mandatory)][string]$Cache,
        [string]$Sha256,
        [switch]$DefaultEvaluation
    )
    # Caller owns and locks Cache. Never log the request or an underlying exception.
    Assert-NestedOfficialUri $DownloadUri
    $name = if ($DefaultEvaluation) { 'ws2022-eval-english' } else { $Sha256.ToLowerInvariant() }
    $path = Join-Path $Cache "$name.iso"
    $record = Join-Path $Cache "$name.media.json"
    [void](Assert-NestedLocalPath $path)
    [void](Assert-NestedLocalPath $record)
    $actual = $null
    if ($DefaultEvaluation -and (Test-Path -LiteralPath $path)) {
        if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { throw 'Media cache record missing.' }
        $saved = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        if ($saved.Schema -ne 'NestedOfficialMedia-v1' -or
            $saved.SourceUri -cne $DownloadUri.AbsoluteUri -or
            $saved.HashMeaning -ne 'CacheIntegrityOnly' -or
            $saved.Length -ne 5044094976 -or (Get-Item -LiteralPath $path).Length -ne $saved.Length) {
            throw 'Media cache record conflicts. No overwrite is allowed.'
        }
        $Sha256 = $saved.Sha256
    }
    if (-not (Test-Path -LiteralPath $path)) {
        if (Test-Path -LiteralPath $record) { throw 'Orphan media record. Inspect manually.' }
        $partial = "$path.partial"
        if (Test-Path -LiteralPath $partial) { throw 'Partial ISO exists. Inspect manually before retrying.' }
        $current = $DownloadUri
        $downloaded = $false
        for ($hop = 0; $hop -le 5; $hop++) {
            Assert-NestedOfficialUri $current
            $request = [Net.HttpWebRequest]::Create($current)
            $request.AllowAutoRedirect = $false
            $request.UseDefaultCredentials = $false
            $request.Credentials = $null
            $request.Timeout = 120000
            $request.ReadWriteTimeout = 120000
            $response = $null
            try {
                $response = $request.GetResponse()
                Assert-NestedOfficialUri $response.ResponseUri
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    $current = [uri]::new($current, $response.Headers['Location'])
                    Assert-NestedOfficialUri $current
                    continue
                }
                if ($status -ne 200 -or ($DefaultEvaluation -and $response.ContentLength -ne 5044094976)) {
                    throw 'Unexpected media response.'
                }
                $stream = [IO.File]::Open($partial, 'CreateNew', 'Write', 'None')
                try { $response.GetResponseStream().CopyTo($stream) }
                finally { $stream.Dispose() }
                if ($DefaultEvaluation -and (Get-Item -LiteralPath $partial).Length -ne 5044094976) {
                    throw 'Unexpected media length.'
                }
                $downloaded = $true
                break
            }
            catch { throw 'Official media download failed. Inspect retained partial media.' }
            finally {
                try { if ($response) { $response.Dispose() } }
                finally { $request.Abort() }
            }
        }
        if (-not $downloaded) { throw 'Media redirect limit exceeded.' }
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        if ($DefaultEvaluation) { $Sha256 = $actual }
        else { Assert-NestedSha256 -Actual $actual -Expected $Sha256 }
        Move-Item -LiteralPath $partial -Destination $path -ErrorAction Stop
        if ($DefaultEvaluation) {
            Save-NestedManifest $record ([ordered]@{
                Schema = 'NestedOfficialMedia-v1'; SourceUri = $DownloadUri.AbsoluteUri
                Sha256 = $Sha256; Length = 5044094976; HashMeaning = 'CacheIntegrityOnly'
            })
        }
    }
    [void](Assert-NestedLocalPath $path)
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Media reparse point rejected.'
    }
    if (-not $actual) { $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    Assert-NestedSha256 -Actual $actual -Expected $Sha256
    return [pscustomobject]@{ Path = $path; Sha256 = $Sha256 }
}

function New-NestedUnattendXml {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [string]$TimeZone = 'Tokyo Standard Time'
    )
    if ($ComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or
        $ComputerName -match '^[0-9]+$' -or $ComputerName.EndsWith('-')) {
        throw 'ComputerName must be a valid 1-15 character Windows computer name.'
    }
    if ($Credential.UserName -cne 'Administrator') {
        throw 'The credential username must be exactly Administrator (not a domain-qualified name).'
    }
    [void][TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
    $doc = New-Object System.Xml.XmlDocument
    $ns = 'urn:schemas-microsoft-com:unattend'
    $root = $doc.CreateElement('unattend', $ns)
    [void]$doc.AppendChild($root)
    foreach ($pass in @('specialize', 'oobeSystem')) {
        $settings = $doc.CreateElement('settings', $ns)
        $settings.SetAttribute('pass', $pass)
        [void]$root.AppendChild($settings)
        $component = $doc.CreateElement('component', $ns)
        foreach ($pair in @{
            name = 'Microsoft-Windows-Shell-Setup'; processorArchitecture = 'amd64'
            publicKeyToken = '31bf3856ad364e35'; language = 'neutral'; versionScope = 'nonSxS'
        }.GetEnumerator()) { $component.SetAttribute($pair.Key, $pair.Value) }
        [void]$settings.AppendChild($component)
        if ($pass -eq 'specialize') {
            foreach ($pair in @{ComputerName = $ComputerName; TimeZone = $TimeZone}.GetEnumerator()) {
                $node = $doc.CreateElement($pair.Key, $ns)
                $node.InnerText = $pair.Value
                [void]$component.AppendChild($node)
            }
        }
        else {
            $accounts = $doc.CreateElement('UserAccounts', $ns)
            $password = $doc.CreateElement('AdministratorPassword', $ns)
            $value = $doc.CreateElement('Value', $ns)
            # PlainText is intentional. Base64 would not encrypt an answer file.
            $value.InnerText = $Credential.GetNetworkCredential().Password
            [void]$password.AppendChild($value)
            $plain = $doc.CreateElement('PlainText', $ns)
            $plain.InnerText = 'true'
            [void]$password.AppendChild($plain)
            [void]$accounts.AppendChild($password)
            [void]$component.AppendChild($accounts)
            $oobe = $doc.CreateElement('OOBE', $ns)
            foreach ($name in @('HideEULAPage', 'HideLocalAccountScreen', 'HideOEMRegistrationScreen',
                'HideOnlineAccountScreens', 'HideWirelessSetupInOOBE')) {
                $node = $doc.CreateElement($name, $ns)
                $node.InnerText = 'true'
                [void]$oobe.AppendChild($node)
            }
            $protect = $doc.CreateElement('ProtectYourPC', $ns)
            $protect.InnerText = '3'
            [void]$oobe.AppendChild($protect)
            [void]$component.AppendChild($oobe)
        }
    }
    return ,$doc
}

function Save-NestedManifest {
    param([string]$Path, [object]$Value)
    # A truncated manifest is intentionally not accepted on the next invocation.
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
}

function Protect-NestedDirectory {
    param([string]$Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-NestedLocalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
        throw 'Use an absolute local drive path without alternate data streams.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -le 3) { throw 'A drive root cannot be used as lab storage.' }
    if ((Get-Volume -DriveLetter $full.Substring(0, 1)).FileSystem -ne 'NTFS') {
        throw 'Nested image and guest directories require NTFS.'
    }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Reparse points in storage paths are not supported.'
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full.TrimEnd('\')
}

function Assert-NestedSha256 {
    param([string]$Actual, [string]$Expected)
    if ($Expected -notmatch '^[A-Fa-f0-9]{64}$' -or
        $Actual -notmatch '^[A-Fa-f0-9]{64}$' -or $Actual -ne $Expected) {
        throw 'HashMismatch: media will not be used.'
    }
}

function Test-NestedBootTransportError {
    param([System.Management.Automation.ErrorRecord]$Failure)
    return ($Failure.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -and
        $Failure.Exception.Message -match 'A remote session might have ended\.' -and
        $Failure.Exception.Message -notmatch '(?i)credential|authentication|logon|access.*denied')
}

function Wait-NestedDirect {
    param([string]$VmName, [pscredential]$Credential, [int]$TimeoutSeconds = 1800)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining = $TimeoutSeconds - $watch.Elapsed.TotalSeconds
        if ($remaining -le 0) { throw 'PowerShell Direct readiness timed out; inspect the retained VM.' }
        $pipeline = [PowerShell]::Create()
        $keepPipeline = $false
        try {
            [void]$pipeline.AddCommand('New-PSSession')
            [void]$pipeline.AddParameter('VMName', $VmName)
            [void]$pipeline.AddParameter('Credential', $Credential)
            [void]$pipeline.AddParameter('ErrorAction', 'Stop')
            $async = $pipeline.BeginInvoke()
            if (-not $async.AsyncWaitHandle.WaitOne([int]($remaining * 1000))) {
                $pipeline.Stop()
                throw 'PowerShell Direct readiness timed out; inspect the retained VM.'
            }
            $result = $null
            try { $result = $pipeline.EndInvoke($async) }
            catch {
                if ($pipeline.Streams.Error.Count -eq 0) { throw }
            }
            if ($pipeline.Streams.Error.Count -eq 0) {
                if (@($result).Count -ne 1 -or $result[0].State -ne 'Opened') {
                    throw 'PowerShell Direct returned no open session.'
                }
                # Keep the creating runspace alive until the caller closes the
                # live session. Disposing it here could invalidate the session.
                $keepPipeline = $true
                return [pscustomobject]@{ Session = $result[0]; Pipeline = $pipeline }
            }
            $failure = $pipeline.Streams.Error[0]
            # Microsoft documents this specific English transport error as a boot/
            # service readiness failure. Other locales fail closed, not guessed.
            if (-not (Test-NestedBootTransportError $failure)) {
                throw $failure
            }
        }
        finally { if (-not $keepPipeline) { $pipeline.Dispose() } }
        Start-Sleep -Seconds ([int][Math]::Min(10, [Math]::Max(0, $TimeoutSeconds - $watch.Elapsed.TotalSeconds)))
    } while ($true)
}
