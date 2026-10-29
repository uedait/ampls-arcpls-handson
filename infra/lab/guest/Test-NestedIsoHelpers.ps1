#requires -Version 5.1
# No Pester, administrator rights, network, Hyper-V, or disk writes required.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NestedIso.Helpers.ps1')
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw "FAIL: $Description" }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Description)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Description
}

foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "ASCII: $($file.Name)"
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parsing: $($file.Name)"
}
$parentTokens = $null
$parentErrors = $null
$parentAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'New-NestedParentDisk.ps1'), [ref]$parentTokens, [ref]$parentErrors)
$cleanupCommands = @($parentAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -in @('Dismount-VHD','Dismount-DiskImage')
}, $true))
$cleanupStatements = @($parentAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'null' -and
    $node.Right.Extent.Text -match '\bDismount-(?:VHD|DiskImage)\b'
}, $true))
Assert-True ($cleanupCommands.Count -eq 4 -and $cleanupStatements.Count -eq $cleanupCommands.Count) 'All normal and finally unmount results are suppressed'
function Invoke-TestParentCleanup {
    param($Statement,[switch]$FailCleanup)
    & {
        param($Statement,$FailCleanup)
        $parentPath = 'C:\SyntheticParent.vhdx'
        $IsoPath = 'C:\SyntheticMedia.iso'
        function Dismount-VHD {
            [CmdletBinding()]
            param([string]$Path)
            if ($FailCleanup) { throw 'Synthetic unmount failure' }
            [pscustomobject]@{NoisyCompletion=$true}
        }
        function Dismount-DiskImage {
            [CmdletBinding()]
            param([string]$ImagePath)
            if ($FailCleanup) { throw 'Synthetic unmount failure' }
            [pscustomobject]@{NoisyCompletion=$true}
        }
        . ([scriptblock]::Create($Statement.Extent.Text))
    } $Statement $FailCleanup
}
foreach ($statement in $cleanupStatements) {
    $output = @(Invoke-TestParentCleanup $statement)
    Assert-True ($output.Count -eq 0) 'Noisy unmount cmdlets cannot add a second parent return value'
    Assert-Throws { Invoke-TestParentCleanup $statement -FailCleanup } 'Suppressing completion output does not suppress unmount failures'
}
$cachedReturn = @(& {
    param($Statements)
    try { return 'C:\SyntheticParent.vhdx' }
    finally { foreach ($statement in $Statements) { Invoke-TestParentCleanup $statement } }
} $cleanupStatements)
Assert-True ($cachedReturn.Count -eq 1 -and $cachedReturn[0] -is [string] -and
    $cachedReturn[0] -ceq 'C:\SyntheticParent.vhdx') 'A cached parent return remains exactly one VHDX string after finally cleanup'
Assert-NestedOfficialUri ([uri]'https://download.microsoft.com/media.iso')
foreach ($bad in @(
    'http://download.microsoft.com/media.iso',
    'https://download.microsoft.com.evil.example/media.iso',
    'https://evil.example/media.iso',
    'https://user:password@download.microsoft.com/media.iso',
    'https://download.microsoft.com:8443/media.iso',
    'https://download.microsoft.com/media.iso#fragment',
    'file:///C:/media.iso'
)) {
    Assert-Throws { Assert-NestedOfficialUri ([uri]$bad) } 'Reject unsafe media URI'
}
# The same validator is used before every redirect and on ResponseUri.
$redirect = [uri]::new([uri]'https://download.microsoft.com/a', 'https://evil.example/b')
Assert-Throws { Assert-NestedOfficialUri $redirect } 'Reject cross-host redirect'
$goodHash = 'A' * 64
Assert-NestedSha256 -Actual $goodHash.ToLowerInvariant() -Expected $goodHash
Assert-Throws { Assert-NestedSha256 -Actual ('B' * 64) -Expected $goodHash } 'Reject hash mismatch'
Assert-Throws { Assert-NestedSha256 -Actual 'bad' -Expected $goodHash } 'Reject invalid hash'

function New-SyntheticImage {
    param([int]$Index, [string]$Name, [string]$Edition, [string]$Type, [string]$Version = '10.0.20348.1')
    return [pscustomobject]@{
        ImageIndex = $Index; ImageName = $Name; EditionId = $Edition
        InstallationType = $Type; Version = $Version; Architecture = 9; Languages = @('en-US')
    }
}
$desktop = New-SyntheticImage 7 'Synthetic Desktop' 'ServerDatacenterEval' 'Server'
$core = New-SyntheticImage 2 'Synthetic Core' 'ServerDatacenterEval' 'Server Core'
$standard = New-SyntheticImage 11 'Synthetic Standard Desktop' 'ServerStandardEval' 'Server'
$newer = New-SyntheticImage 17 'Synthetic 2025' 'ServerDatacenterEval' 'Server' '10.0.26100.1'
Assert-True ((Select-NestedImage @($core, $desktop, $newer)).ImageIndex -eq 7) 'Use metadata, not fixed index'
Assert-Throws { Select-NestedImage @($desktop, $standard) } 'Reject ambiguous desktop images'
Assert-True ((Select-NestedImage @($desktop, $standard) 'Synthetic Standard Desktop').ImageIndex -eq 11) 'Explicit exact image name'
Assert-Throws { Select-NestedImage @($newer) } 'Reject Windows Server 2025'
Assert-Throws { Select-NestedImage @($core) } 'Reject Server Core'
Assert-Throws { Select-NestedImage @($desktop) 'Missing' } 'Reject nonexistent image name'
Assert-True ((Select-NestedImage @($desktop, $standard) -DefaultEvaluation).ImageIndex -eq 11) 'Default uses English Standard Evaluation metadata'
Assert-Throws { Select-NestedImage @($desktop) -DefaultEvaluation } 'Default must not silently choose another edition'
$localized = New-SyntheticImage 12 'Synthetic Japanese' 'ServerStandardEval' 'Server'
$localized.Languages = @('ja-JP')
Assert-Throws { Select-NestedImage @($localized) -DefaultEvaluation } 'Default rejects non-English media'
$retail = New-SyntheticImage 13 'Synthetic Retail' 'ServerStandard' 'Server'
Assert-Throws { Select-NestedImage @($retail) -DefaultEvaluation } 'Default rejects non-Evaluation edition'
$arm = New-SyntheticImage 14 'Synthetic ARM' 'ServerStandardEval' 'Server'
$arm.Architecture = 12
Assert-Throws { Select-NestedImage @($arm) -DefaultEvaluation } 'Default rejects ARM64'

# Synthetic test value only. Never print the generated XML or password.
$sample = 'Synthetic<&>"''Pass!2026'
$secure = ConvertTo-SecureString $sample -AsPlainText -Force
$credential = [pscredential]::new('Administrator', $secure)
$xml = New-NestedUnattendXml -ComputerName 'Test-L2' -Credential $credential
$manager = [Xml.XmlNamespaceManager]::new($xml.NameTable)
$manager.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
$password = $xml.SelectSingleNode('//u:AdministratorPassword/u:Value', $manager)
Assert-True ($password.InnerText -ceq $sample) 'XML special character round trip'
Assert-True ($xml.OuterXml.Contains('&lt;') -and $xml.OuterXml.Contains('&amp;')) 'XML API escapes text'
Assert-True ($xml.SelectSingleNode('//u:ComputerName', $manager).InnerText -eq 'Test-L2') 'Computer name'
Assert-True ($xml.SelectSingleNode('//u:TimeZone', $manager).InnerText -eq 'Tokyo Standard Time') 'Default time zone'
Assert-True ($xml.SelectNodes('//u:AutoLogon', $manager).Count -eq 0) 'No autologon password duplication'
Assert-Throws {
    New-NestedUnattendXml -ComputerName 'Test-L2' -Credential ([pscredential]::new('OtherAdmin', $secure))
} 'Reject non-Administrator username'
Assert-Throws { New-NestedUnattendXml -ComputerName '12345' -Credential $credential } 'Reject invalid computer name'

function New-SyntheticTransportRecord {
    param([string]$Message)
    $exception = [Management.Automation.Remoting.PSRemotingTransportException]::new($Message)
    return [Management.Automation.ErrorRecord]::new(
        $exception, 'SyntheticTransport', [Management.Automation.ErrorCategory]::OpenError, $null)
}
Assert-True (Test-NestedBootTransportError (New-SyntheticTransportRecord 'A remote session might have ended.')) 'Retry documented boot transport error'
Assert-True (-not (Test-NestedBootTransportError (New-SyntheticTransportRecord 'The credential is invalid.'))) 'Do not retry invalid credentials'
Assert-True (-not (Test-NestedBootTransportError (New-SyntheticTransportRecord 'Access is denied. A remote session might have ended.'))) 'Do not mask access denial'
Assert-True (-not (Test-NestedBootTransportError (New-SyntheticTransportRecord 'Unknown failure'))) 'Do not retry unknown errors'
$xml = $null
$credential = $null
$secure = $null
$sample = $null
Write-Output "PASS: $script:checks offline helper assertions. This does not validate ISO, WIM, boot, ACL, or PowerShell Direct."
