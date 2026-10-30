#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Local')][string]$IsoPath,
    [Parameter(Mandatory, ParameterSetName = 'Download')][Alias('IsoUri')][uri]$DownloadUri,
    [Parameter(Mandatory, ParameterSetName = 'Default')][switch]$UseDefaultMedia,
    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [Parameter(Mandatory, ParameterSetName = 'Download')]
    [Alias('ExpectedSha256')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256,
    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [Parameter(Mandatory, ParameterSetName = 'Download')][uri]$HashSourceUri,
    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [Parameter(Mandatory, ParameterSetName = 'Download')][switch]$AcceptedMediaTerms,
    [pscredential]$Credential,
    [string]$ImageName,
    [string]$CacheDirectory = 'C:\NestedIsoCache',
    [string]$VmDirectory = 'C:\NestedIsoGuests',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')][string]$VmName = 'ArcOnpremL2',
    [string]$TimeZone = 'Tokyo Standard Time',
    [ValidateRange(60, 7200)][int]$ReadinessTimeoutSeconds = 1800,
    [ValidateRange(60, 2048)][int]$DiskSizeGB = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NestedIso.Helpers.ps1')
Import-Module Hyper-V -ErrorAction Stop
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4') -or
    (Get-Service vmms).Status -ne 'Running') { throw 'Requires the running L1 Hyper-V host at 10.30.1.4.' }
foreach ($file in @('New-NestedParentDisk.ps1', 'Initialize-NestedNetwork.ps1',
    'Set-NestedGuest.ps1', 'Test-NestedImds.ps1', 'Initialize-LabHandover.ps1', 'Test-LabNestedReadiness.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing companion: $file" }
}
$root = Assert-NestedLocalPath $VmDirectory
$cache = Assert-NestedLocalPath $CacheDirectory
if ($root.Equals($cache, [StringComparison]::OrdinalIgnoreCase) -or
    $root.StartsWith("$cache\", [StringComparison]::OrdinalIgnoreCase) -or
    $cache.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Guest and parent directories must be separate, non-nested trees.'
}
$guestDirectory = Join-Path $root $VmName
$childPath = Join-Path $guestDirectory "$VmName.vhdx"
$statePath = Join-Path $guestDirectory 'deployment.json'
if ((Get-VM -Name $VmName -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath $guestDirectory)) {
    throw "VM or guest directory already exists. Inspect $statePath manually. No resume, overwrite, or automatic deletion is supported."
}
if (Test-Path -LiteralPath $root) {
    $ownerMarker = Join-Path $root 'nested-guests.marker'
    [void](Assert-NestedLocalPath $ownerMarker)
    if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf) -or
        (Get-Content -LiteralPath $ownerMarker -Raw) -cne 'NestedIsoGuests-v1' -or
        ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Existing guest root is not an owned, non-reparse nested guest directory.'
    }
}
else {
    [void](New-Item -ItemType Directory -Path $root)
    Protect-NestedDirectory $root
    [IO.File]::WriteAllText((Join-Path $root 'nested-guests.marker'), 'NestedIsoGuests-v1')
}
Protect-NestedDirectory $root
if (-not $Credential) {
    $Credential = Get-Credential -UserName 'Administrator' -Message 'L2 built-in Administrator password; never enter it on a command line'
}
if (-not $credential) { throw 'Credential input was cancelled.' }
$answer = New-NestedUnattendXml -ComputerName $VmName -TimeZone $TimeZone -Credential $credential
$parentArgs = @{ CacheDirectory = $CacheDirectory; DiskSizeGB = $DiskSizeGB }
if ($UseDefaultMedia) { $parentArgs.UseDefaultMedia = $true }
else {
    $parentArgs.Sha256 = $Sha256
    $parentArgs.HashSourceUri = $HashSourceUri
    $parentArgs.AcceptedMediaTerms = $AcceptedMediaTerms
}
if ($ImageName) { $parentArgs.ImageName = $ImageName }
if ($PSCmdlet.ParameterSetName -eq 'Download') { $parentArgs.DownloadUri = $DownloadUri }
elseif (-not $UseDefaultMedia) { $parentArgs.IsoPath = $IsoPath }
$session = $null
$direct = $null
$mounted = $false
$state = $null
$stage = 'ParentBuild'
try {
    $parentPath = & (Join-Path $PSScriptRoot 'New-NestedParentDisk.ps1') @parentArgs
    if ($parentPath -isnot [string] -or -not $parentPath.EndsWith('.vhdx')) {
        throw 'Parent builder did not return exactly one VHDX path.'
    }
    [void](New-Item -ItemType Directory -Path $guestDirectory -ErrorAction Stop)
    Protect-NestedDirectory $guestDirectory
    $state = [ordered]@{
        Status = 'Preparing'; VmName = $VmName; ParentPath = $parentPath
        ChildPath = $childPath; SecretMayRemain = $true; AnswerFilesRemoved = $false
        ActivationChecked = $false; InternetDenyReady = $false
        FailureStage = $null; FailureKind = $null
    }
    Save-NestedManifest $statePath $state
    $stage = 'ChildPreparation'
    [void](New-VHD -Path $childPath -ParentPath $parentPath -Differencing)
    $childMount = Mount-VHD -Path $childPath -Passthru
    $mounted = $true
    $disk = $childMount | Get-Disk
    $partitions = @($disk | Get-Partition | Where-Object {
        $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    })
    if ($partitions.Count -ne 1) { throw 'Expected one Windows basic data partition in the child.' }
    if (-not $partitions[0].DriveLetter) {
        $partitions[0] | Add-PartitionAccessPath -AssignDriveLetter
    }
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partitions[0].PartitionNumber
    $windows = "$($partition.DriveLetter):\Windows"
    if (-not (Test-Path -LiteralPath "$windows\System32\Config\SYSTEM")) { throw 'Child Windows partition was not found.' }
    [void](New-Item -ItemType Directory -Path "$windows\Panther" -Force)
    $answer.Save("$windows\Panther\unattend.xml")
    $answer = $null
    Dismount-VHD -Path $childPath
    $mounted = $false
    $stage = 'NetworkInitialization'
    & (Join-Path $PSScriptRoot 'Initialize-NestedNetwork.ps1')
    $stage = 'VmCreation'
    $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 4GB `
        -VHDPath $childPath -SwitchName 'OptionalLab-Internal' -Path $guestDirectory
    Set-VMProcessor -VMName $VmName -Count 2
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
    Set-VM -VMName $VmName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    $biosGuid = Get-NestedVmBiosGuid -VmId $vm.Id
    $state['VmId'] = "$($vm.Id)"
    $state['BiosGuid'] = "$biosGuid"
    $state.Status = 'Booting'
    Save-NestedManifest $statePath $state
    Start-VM -Name $VmName | Out-Null
    $stage = 'PowerShellDirectReadiness'
    $direct = Wait-NestedDirect -VmName $VmName -Credential $credential -TimeoutSeconds $ReadinessTimeoutSeconds
    $session = $direct.Session
    # Check guest identity before removing only known answer-file cache paths.
    $stage = 'AnswerFileCleanup'
    Invoke-Command -Session $session -ArgumentList "$biosGuid" -ScriptBlock {
        param([guid]$Expected)
        $ErrorActionPreference = 'Stop'
        if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $Expected -or
            (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
            throw 'L2 identity check failed before answer-file cleanup.'
        }
        $paths = @(
            "$env:SystemRoot\Panther\unattend.xml",
            "$env:SystemRoot\Panther\Unattend\unattend.xml",
            "$env:SystemRoot\System32\Sysprep\unattend.xml"
        )
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $path) { throw 'Known answer-file cleanup failed.' }
        }
    } -ErrorAction Stop
    $state.AnswerFilesRemoved = $true
    # Removal is logical, not secure erasure of child VHDX blocks/checkpoints.
    $state.SecretMayRemain = $true
    $state.Status = 'Configuring'
    Save-NestedManifest $statePath $state
    $stage = 'GuestNetworkAndImds'
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'Set-NestedGuest.ps1') `
        -ArgumentList "$biosGuid" -ErrorAction Stop
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'Test-NestedImds.ps1') `
        -ArgumentList "$biosGuid" -ErrorAction Stop
    $stage = 'HandoverScripts'
    $scriptsDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts'))
    $hashes = @{}
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'Initialize-LabHandover.ps1') `
        -ArgumentList "$biosGuid" -ErrorAction Stop | Out-Null
    foreach ($name in @('Install-ArcAgent.ps1', 'Connect-ArcServer.ps1', 'Write-HandsonEvent.ps1')) {
        $source = Join-Path $scriptsDirectory $name
        $hashes[$name] = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $exists = Invoke-Command -Session $session -ArgumentList $name, $hashes[$name] -ScriptBlock {
            param($Name, $Expected)
            $ErrorActionPreference = 'Stop'
            $path = Join-Path 'C:\Handson' $Name
            if (-not (Test-Path -LiteralPath $path)) { return $false }
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Expected) {
                throw 'Existing handover file conflicts. No overwrite is allowed.'
            }
            return $true
        } -ErrorAction Stop
        if (-not $exists) { Copy-Item -LiteralPath $source -Destination "C:\Handson\$name" -ToSession $session -ErrorAction Stop }
    }
    $stage = 'Activation'
    # Legitimate evaluation activation only. No product key changes or rearm.
    Invoke-Command -Session $session -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        & "$env:SystemRoot\System32\cscript.exe" //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Windows activation command failed.' }
    } -ErrorAction Stop | Out-Null
    $stage = 'ActivationStatusRead'
    $activation = @(Invoke-Command -Session $session -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL AND LicenseIsAddon=FALSE" |
            Select-Object Name, Description, LicenseStatus, GracePeriodRemaining
    } -ErrorAction Stop)
    if ($activation.Count -eq 0) { throw 'No Windows licensing status was returned.' }
    $state.ActivationChecked = $true
    if (@($activation | Where-Object LicenseStatus -eq 1).Count -eq 0) {
        throw 'Windows is not Licensed (LicenseStatus=1). Internet deny is not permitted.'
    }
    $stage = 'BuildReadiness'
    $readiness = Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'Test-LabNestedReadiness.ps1') `
        -ArgumentList "$biosGuid", $hashes, $false -ErrorAction Stop
    if (-not $readiness.NestedReady) { throw 'L2 readiness failed.' }
    $state.BiosGuid = "$biosGuid"
    $state.HandoverHashes = $hashes
    $state.UpdatesBaseline = 'StandardImageOnly'
    $stage = 'SessionCleanup'
    Remove-PSSession -Session $session -ErrorAction Stop
    $session = $null
    $direct.Pipeline.Dispose()
    $direct = $null
    $state.InternetDenyReady = $true
    $state.Status = 'Configured'
    Save-NestedManifest $statePath $state
    Write-Host 'L2 configured, Licensed and readiness checked. Updates baseline is the standard image; no full Windows Update completion is claimed.'
    Write-Host "Child VHDX remains sensitive (deleted answer-file blocks may persist): $childPath"
}
catch {
    $kind = $_.Exception.GetType().FullName
    if ($_.Exception.Message -match 'HashMismatch') { $kind = 'HashMismatch' }
    elseif ($_.Exception.Message -match '(?i)credential.*invalid|authentication|logon|access.*denied') {
        $kind = 'AuthenticationOrAccessRejected'
    }
    elseif ($_.Exception.Message -match '(?i)timed out') { $kind = 'ReadinessTimeout' }
    elseif ($_.Exception.Message -match 'Select exactly one WS2022') { $kind = 'ImageSelectionRequired' }
    if ($state) {
        $state.Status = 'Failed'
        $state.InternetDenyReady = $false
        $state.FailureStage = $stage
        $state.FailureKind = $kind
        Save-NestedManifest $statePath $state
    }
    # Never include the XML, credentials or arbitrary underlying error text here.
    Write-Warning "Deployment did not complete. Sensitive child/state may remain at: $guestDirectory"
    throw "Nested ISO deployment failed at $stage ($kind). No success or retry over partial state is allowed. Inspect the VM and manifest; no resources were deleted."
}
finally {
    try { if ($mounted) { Dismount-VHD -Path $childPath -ErrorAction Stop } }
    finally {
        try { if ($session) { Remove-PSSession -Session $session -ErrorAction Stop } }
        finally {
            if ($direct) { $direct.Pipeline.Dispose() }
            $answer = $null
            $credential = $null
        }
    }
}
