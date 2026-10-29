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
    [Parameter(Mandatory)][string]$CacheDirectory,
    [string]$ImageName,
    [ValidateRange(60, 2048)][int]$DiskSizeGB = 60,
    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [Parameter(Mandatory, ParameterSetName = 'Download')][switch]$AcceptedMediaTerms
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NestedIso.Helpers.ps1')
Import-Module Hyper-V -ErrorAction Stop
Import-Module Dism -ErrorAction Stop
if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4') -or
    (Get-Service vmms).Status -ne 'Running') { throw 'Requires the running L1 Hyper-V host at 10.30.1.4.' }
if (([version](Get-CimInstance Win32_OperatingSystem).Version).Build -ne 20348) {
    throw 'Only Windows Server 2022 L1 (build 20348) is supported by this workflow.'
}
if ($UseDefaultMedia) {
    $DownloadUri = [uri]'https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso'
}
elseif (-not $AcceptedMediaTerms) { throw 'Review the Microsoft media terms before continuing.' }
if (-not $UseDefaultMedia -and (-not $HashSourceUri.IsAbsoluteUri -or $HashSourceUri.Scheme -ne 'https' -or
    $HashSourceUri.UserInfo -or $HashSourceUri.Fragment -or $HashSourceUri.Query -or
    $HashSourceUri.Port -ne 443 -or
    ($HashSourceUri.DnsSafeHost -ne 'microsoft.com' -and
        -not $HashSourceUri.DnsSafeHost.EndsWith('.microsoft.com')))) {
    throw 'HashSourceUri must identify the Microsoft HTTPS publication of the expected SHA256.'
}
$cache = Assert-NestedLocalPath $CacheDirectory
if (Test-Path -LiteralPath $cache) {
    # Do not silently take ownership of an unrelated pre-existing directory.
    $ownerMarker = Join-Path $cache 'nested-cache.marker'
    [void](Assert-NestedLocalPath $ownerMarker)
    if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf) -or
        (Get-Content -LiteralPath $ownerMarker -Raw) -cne 'NestedIsoCache-v1') {
        throw 'Existing directory is not an owned nested image cache.'
    }
    if ((Get-Item -LiteralPath $cache).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Cache reparse points are not supported.'
    }
}
else {
    [void](New-Item -ItemType Directory -Path $cache)
    Protect-NestedDirectory $cache
    [IO.File]::WriteAllText((Join-Path $cache 'nested-cache.marker'), 'NestedIsoCache-v1')
}
Protect-NestedDirectory $cache
$lockPath = Join-Path $cache 'cache.lock'
[void](Assert-NestedLocalPath $lockPath)
$lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$isoMounted = $false
$vhdMounted = $false
$manifest = $null
$manifestPath = $null
try {
    if ($PSCmdlet.ParameterSetName -in @('Download', 'Default')) {
        $media = Get-NestedMedia -DownloadUri $DownloadUri -Cache $cache -Sha256 $Sha256 -DefaultEvaluation:$UseDefaultMedia
        $IsoPath = $media.Path
        $Sha256 = $media.Sha256
    }
    $iso = Get-Item -LiteralPath $IsoPath
    [void](Assert-NestedLocalPath $iso.FullName)
    if ($iso.Extension -ne '.iso') { throw 'Invalid ISO input. No image will be applied.' }
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        Assert-NestedSha256 -Actual (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash -Expected $Sha256
    }
    $IsoPath = $iso.FullName
    if ((Get-DiskImage -ImagePath $IsoPath).Attached) { throw 'ISO is already mounted; no existing mount will be reused.' }
    [void](Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru)
    $isoMounted = $true
    $volumes = @(Get-DiskImage -ImagePath $IsoPath | Get-Volume | Where-Object DriveLetter)
    if ($volumes.Count -ne 1) { throw 'Expected exactly one mounted ISO volume.' }
    $wim = "$($volumes[0].DriveLetter):\sources\install.wim"
    if (-not (Test-Path -LiteralPath $wim)) { throw 'Media must contain sources\install.wim (ESD is not supported).' }
    $images = @(Get-WindowsImage -ImagePath $wim | ForEach-Object {
        Get-WindowsImage -ImagePath $wim -Index $_.ImageIndex
    })
    $selected = Select-NestedImage -Images $images -ImageName $ImageName -DefaultEvaluation:$UseDefaultMedia
    $key = '{0}-{1}-{2}GB' -f $Sha256.ToLowerInvariant(), $selected.ImageIndex, $DiskSizeGB
    $parentPath = Join-Path $cache "$key.vhdx"
    $manifestPath = Join-Path $cache "$key.json"
    [void](Assert-NestedLocalPath $parentPath)
    [void](Assert-NestedLocalPath $manifestPath)
    if (Test-Path -LiteralPath $manifestPath) {
        $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($existing.Status -ne 'Ready' -or $existing.IsoSha256 -ne $Sha256 -or
            $existing.ImageIndex -ne $selected.ImageIndex -or $existing.ParentPath -ne $parentPath -or
            $existing.ImageName -cne $selected.ImageName -or
            -not (Test-Path -LiteralPath $parentPath) -or
            (Get-FileHash -LiteralPath $parentPath -Algorithm SHA256).Hash -ne $existing.ParentSha256) {
            throw 'Parent manifest/cache is incomplete or inconsistent. Inspect manually; no overwrite is allowed.'
        }
        return $parentPath
    }
    if (Test-Path -LiteralPath $parentPath) { throw 'Parent disk exists without a manifest. Refusing overwrite.' }
    $manifest = [ordered]@{
        Status = 'Building'; IsoSha256 = $Sha256.ToUpperInvariant()
        SourceUri = $(if ($UseDefaultMedia) { $DownloadUri.AbsoluteUri } else { $null })
        HashSourceUri = $(if ($UseDefaultMedia) { $null } else { $HashSourceUri.AbsoluteUri })
        HashMeaning = $(if ($UseDefaultMedia) { 'CacheIntegrityOnly' } else { 'OperatorSuppliedExpectedHash' })
        ImageIndex = $selected.ImageIndex
        ImageName = $selected.ImageName; Version = "$($selected.Version)"
        EditionId = $selected.EditionId; InstallationType = $selected.InstallationType
        ParentPath = $parentPath; ParentSha256 = $null; DiskSizeGB = $DiskSizeGB
    }
    Save-NestedManifest $manifestPath $manifest
    [void](New-VHD -Path $parentPath -Dynamic -SizeBytes ($DiskSizeGB * 1GB))
    $mounted = Mount-VHD -Path $parentPath -Passthru
    $vhdMounted = $true
    # The only disk number ever initialized is returned from this newly-created VHD.
    $disk = $mounted | Get-Disk
    if (@($disk).Count -ne 1 -or $disk.Number -ne $mounted.DiskNumber -or
        $mounted.Path -ne $parentPath -or $disk.PartitionStyle -ne 'RAW' -or -not $mounted.Attached) {
        throw 'New VHD is not the expected single attached RAW disk.'
    }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
    $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    [void](New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
    $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $windows | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $windowsRoot = "$($windows.DriveLetter):\"
    & "$env:SystemRoot\System32\dism.exe" /Apply-Image "/ImageFile:$wim" "/Index:$($selected.ImageIndex)" "/ApplyDir:$windowsRoot" /CheckIntegrity | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'DISM Apply-Image failed.' }
    & "${windowsRoot}Windows\System32\bcdboot.exe" "${windowsRoot}Windows" /s "$($efi.DriveLetter):" /f UEFI | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'BCDBoot failed.' }
    $null = Dismount-VHD -Path $parentPath
    $vhdMounted = $false
    (Get-Item -LiteralPath $parentPath).IsReadOnly = $true
    $manifest.ParentSha256 = (Get-FileHash -LiteralPath $parentPath -Algorithm SHA256).Hash
    # Ready is written only after all owned mounts have been released.
    $null = Dismount-DiskImage -ImagePath $IsoPath
    $isoMounted = $false
    $manifest.Status = 'Ready'
    Save-NestedManifest $manifestPath $manifest
    return $parentPath
}
catch {
    if ($manifest) {
        $manifest.Status = 'Failed'
        Save-NestedManifest $manifestPath $manifest
    }
    throw
}
finally {
    try { if ($vhdMounted) { $null = Dismount-VHD -Path $parentPath -ErrorAction Stop } }
    finally {
        try { if ($isoMounted) { $null = Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop } }
        finally { $lock.Dispose() }
    }
}
