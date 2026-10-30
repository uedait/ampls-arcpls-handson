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

function Invoke-TestBiosLookup {
    param([string]$Mode)
    & {
        param($Mode,$Definition)
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$Namespace,[string]$ClassName,[string]$Filter)
            if ($Namespace -ne 'root\virtualization\v2' -or $ClassName -ne 'Msvm_VirtualSystemSettingData' -or
                -not $Filter.Contains('11111111-1111-1111-1111-111111111111') -or
                -not $Filter.Contains('Microsoft:Hyper-V:System:Realized')) { throw 'Unexpected BIOS lookup scope' }
            if ($Mode -eq 'error') { throw 'Synthetic CIM lookup failure' }
            if ($Mode -eq 'missing') { return }
            $record=[pscustomobject]@{
                VirtualSystemIdentifier='11111111-1111-1111-1111-111111111111'
                VirtualSystemType='Microsoft:Hyper-V:System:Realized'
                BIOSGUID='{22222222-2222-2222-2222-222222222222}'
            }
            if ($Mode -eq 'wrong-vm') { $record.VirtualSystemIdentifier='33333333-3333-3333-3333-333333333333' }
            if ($Mode -eq 'snapshot') { $record.VirtualSystemType='Microsoft:Hyper-V:Snapshot:Realized' }
            if ($Mode -eq 'bad-guid') { $record.BIOSGUID='invalid' }
            if ($Mode -eq 'empty-guid') { $record.BIOSGUID=[guid]::Empty.ToString() }
            $record
            if ($Mode -eq 'multiple') { $record }
        }
        . ([scriptblock]::Create($Definition))
        Get-NestedVmBiosGuid -VmId '11111111-1111-1111-1111-111111111111'
    } $Mode ('function Get-NestedVmBiosGuid { ' + ${function:Get-NestedVmBiosGuid}.ToString() + ' }')
}
$bios = @(Invoke-TestBiosLookup good)
Assert-True ($bios.Count -eq 1 -and $bios[0] -is [guid] -and
    $bios[0] -eq [guid]'22222222-2222-2222-2222-222222222222') 'Resolve the current BIOS GUID rather than substituting the VM ID'
foreach ($mode in @('missing','multiple','wrong-vm','snapshot','bad-guid','empty-guid','error')) {
    Assert-Throws { Invoke-TestBiosLookup $mode } 'Reject missing, ambiguous or mismatched BIOS identity without fallback'
}
Assert-Throws { Get-NestedVmBiosGuid -VmId ([guid]::Empty) } 'Reject an empty VM ID before CIM lookup'
foreach ($name in @('New-NestedLabFromIso.ps1','New-NestedLab.ps1','Invoke-LabRole.ps1')) {
    $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    Assert-True (-not ($text -match '\$vm\.BiosGuid') -and
        $text.Contains('Get-NestedVmBiosGuid -VmId $vm.Id')) 'Every VM BIOS identity consumer uses the shared CIM lookup'
}

$networkTokens=$null
$networkErrors=$null
$networkAst=[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Initialize-NestedNetwork.ps1'),[ref]$networkTokens,[ref]$networkErrors)
function New-TestNetworkState {
    @{
        SwitchExists=$false; AdapterReadyAfter=2; AdapterPolls=0; Sleeps=0
        InternalIps=@(); Nats=@(); SwitchCreates=0; IpCreates=0; NatCreates=0
        FailAdapterRead=$false
    }
}
function Invoke-TestNetworkSetup {
    param([hashtable]$State)
    & {
        param($State,$Body)
        $SwitchName='OptionalLab-Internal'
        $NatName='OptionalLab-NAT'
        function Get-Service { param($Name) [pscustomobject]@{Status='Running'} }
        function Get-NetIPAddress {
            [CmdletBinding()]
            param([string]$AddressFamily,[int]$InterfaceIndex)
            if ($PSBoundParameters.ContainsKey('InterfaceIndex')) { throw 'A missing interface IPv4 query is not an empty result' }
            [pscustomobject]@{IPAddress='10.30.1.4'; InterfaceAlias='Ethernet'; InterfaceIndex=4; PrefixLength=24}
            $State.InternalIps
        }
        function Get-VMSwitch {
            [CmdletBinding()]
            param($Name)
            if ($State.SwitchExists) { [pscustomobject]@{SwitchType='Internal'} }
        }
        function New-VMSwitch {
            param($Name,$SwitchType)
            $State.SwitchCreates++
            $State.SwitchExists=$true
            [pscustomobject]@{SwitchType='Internal'}
        }
        function Get-NetNat {
            [CmdletBinding()]
            param($Name)
            if ($Name) { $State.Nats | Where-Object Name -eq $Name } else { $State.Nats }
        }
        function Get-NetAdapter {
            [CmdletBinding()]
            param($Name)
            if ($State.FailAdapterRead) { throw 'Synthetic CIM adapter failure' }
            if ($Name) { throw 'A missing named adapter query must not bypass readiness handling' }
            $State.AdapterPolls++
            [pscustomobject]@{Name='Ethernet'; ifIndex=4}
            if ($State.AdapterPolls -gt $State.AdapterReadyAfter) {
                [pscustomobject]@{Name='vEthernet (OptionalLab-Internal)'; ifIndex=14}
            }
        }
        function Start-Sleep { param($Seconds) $State.Sleeps++ }
        function New-NetIPAddress {
            param($InterfaceIndex,$IPAddress,$PrefixLength)
            if ($InterfaceIndex -ne 14 -or $IPAddress -ne '192.168.100.1' -or $PrefixLength -ne 24) { throw 'Unexpected static IPv4 target' }
            $State.IpCreates++
            $State.InternalIps=@([pscustomobject]@{
                IPAddress=$IPAddress; PrefixLength=$PrefixLength; InterfaceIndex=14
                InterfaceAlias='vEthernet (OptionalLab-Internal)'
            })
        }
        function New-NetNat {
            param($Name,$InternalIPInterfaceAddressPrefix)
            if ($Name -ne 'OptionalLab-NAT' -or $InternalIPInterfaceAddressPrefix -ne '192.168.100.0/24') { throw 'Unexpected NAT target' }
            $State.NatCreates++
            $State.Nats=@([pscustomobject]@{Name=$Name; InternalIPInterfaceAddressPrefix=$InternalIPInterfaceAddressPrefix})
        }
        . ([scriptblock]::Create($Body))
    } $State $networkAst.EndBlock.Extent.Text
}
$freshNetwork=New-TestNetworkState
Invoke-TestNetworkSetup $freshNetwork
Assert-True ($freshNetwork.AdapterPolls -eq 3 -and $freshNetwork.Sleeps -eq 2) 'Wait for the internal NIC instead of assuming immediate visibility'
Assert-True ($freshNetwork.SwitchCreates -eq 1 -and $freshNetwork.IpCreates -eq 1 -and
    $freshNetwork.NatCreates -eq 1) 'An initially empty IPv4 interface is configured once'
Invoke-TestNetworkSetup $freshNetwork
Assert-True ($freshNetwork.SwitchCreates -eq 1 -and $freshNetwork.IpCreates -eq 1 -and
    $freshNetwork.NatCreates -eq 1) 'A correct existing network is not recreated'
$conflict=New-TestNetworkState
$conflict.SwitchExists=$true
$conflict.InternalIps=@([pscustomobject]@{
    IPAddress='192.168.100.2'; PrefixLength=24; InterfaceIndex=14
    InterfaceAlias='vEthernet (OptionalLab-Internal)'
})
Assert-Throws { Invoke-TestNetworkSetup $conflict } 'Reject a conflicting static IP without removing it'
Assert-True ($conflict.IpCreates -eq 0 -and $conflict.NatCreates -eq 0) 'A conflicting interface is not overwritten'
$readFailure=New-TestNetworkState
$readFailure.FailAdapterRead=$true
Assert-Throws { Invoke-TestNetworkSetup $readFailure } 'A CIM read failure is not treated as an absent adapter'
Assert-True ($readFailure.IpCreates -eq 0 -and $readFailure.NatCreates -eq 0) 'Adapter read errors prevent IP and NAT changes'
$timeoutGuard=$networkAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($watch.Elapsed.TotalSeconds -ge 30')
},$true)
Assert-True ($null -ne $timeoutGuard) 'Internal adapter readiness has a 30-second deadline'
foreach ($seconds in @(29,30)) {
    $probe={
        & {
            param($Seconds,$Guard)
            $watch=[pscustomobject]@{Elapsed=[timespan]::FromSeconds($Seconds)}
            . ([scriptblock]::Create($Guard.Extent.Text))
        } $seconds $timeoutGuard
    }
    if ($seconds -eq 29) { & $probe; Assert-True $true 'Adapter readiness is allowed before 30 seconds' }
    else { Assert-Throws $probe 'Adapter readiness stops at 30 seconds' }
}
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
