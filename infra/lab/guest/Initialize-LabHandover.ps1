#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$ExpectedBiosGuid)
$ErrorActionPreference = 'Stop'
if ([guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedBiosGuid -or
    (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '10.30.1.4')) {
    throw 'L2 identity mismatch.'
}
$path = 'C:\Handson'
$marker = Join-Path $path 'lab-handover.marker'
if (Test-Path -LiteralPath $path) {
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
        -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Item -LiteralPath $marker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
        (Get-Content -LiteralPath $marker -Raw) -cne 'LabHandover-v1') {
        throw 'Existing handover directory is not owned. No files were overwritten.'
    }
}
else {
    [void](New-Item -ItemType Directory -Path $path)
    [IO.File]::WriteAllText($marker, 'LabHandover-v1')
}
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
Set-Acl -LiteralPath $path -AclObject $acl
