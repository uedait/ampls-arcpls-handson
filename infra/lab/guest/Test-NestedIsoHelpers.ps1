#requires -Version 5.1
# No Pester, administrator rights, network or Hyper-V. One temporary fixture is removed.
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
foreach ($code in @(10013,10060,10061,11001,10051,10022)) {
    $socket=[Net.Sockets.SocketException]::new($code)
    $expected=$code -in @(10013,10060,10061)
    $record=[Management.Automation.ErrorRecord]::new($socket,'SyntheticSocket',[Management.Automation.ErrorCategory]::ConnectionError,$null)
    Assert-True ((Test-NestedBlockedConnectError $record) -eq $expected) 'Synchronous socket failures are classified by known connection error codes only'
    $aggregate=[AggregateException]::new($socket)
    $wrapped=[Management.Automation.RuntimeException]::new('Synthetic method wrapper',$aggregate)
    $record=[Management.Automation.ErrorRecord]::new($wrapped,'SyntheticWait',[Management.Automation.ErrorCategory]::ConnectionError,$null)
    Assert-True ((Test-NestedBlockedConnectError $record) -eq $expected) 'Asynchronous socket failures use the same narrow classification'
}
$multiple=[AggregateException]::new([Exception[]]@(
    [Net.Sockets.SocketException]::new(10013),[InvalidOperationException]::new('Unknown failure')))
$record=[Management.Automation.ErrorRecord]::new($multiple,'SyntheticMultiple',[Management.Automation.ErrorCategory]::NotSpecified,$null)
Assert-True (-not (Test-NestedBlockedConnectError $record)) 'Multiple aggregate failures are not converted into a passing block check'
$record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Unknown failure'),'SyntheticUnknown',[Management.Automation.ErrorCategory]::NotSpecified,$null)
Assert-True (-not (Test-NestedBlockedConnectError $record)) 'Unknown failures remain errors'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('nested-validation-' + [guid]::NewGuid().ToString('N') + '.ps1')
$fixtureCredential=$null
try {
    [IO.File]::WriteAllText($fixture,'param([guid]$Identity,[hashtable]$Hashes,[bool]$Restricted) [pscustomobject]@{Identity=$Identity; HashCount=$Hashes.Count; Restricted=$Restricted; ClassifierPresent=($null -ne (Get-Command Test-NestedBlockedConnectError -CommandType Function -ErrorAction Stop))}',[Text.UTF8Encoding]::new($false))
    $fixtureCredential=[pscredential]::new('Synthetic',(ConvertTo-SecureString 'SyntheticOnly-123!' -AsPlainText -Force))
    $transport=& {
        param($Definition,$Path,$Credential)
        function Invoke-Command {
            [CmdletBinding()]
            param($VMName,$Credential,$ScriptBlock,[object[]]$ArgumentList)
            if ($VMName -ne 'SyntheticVm' -or $null -eq $Credential) { throw 'Unexpected validation transport target' }
            & $ScriptBlock @ArgumentList
        }
        . ([scriptblock]::Create($Definition))
        Invoke-NestedValidationFile -VmName SyntheticVm -Credential $Credential -FilePath $Path `
            -Arguments @([guid]'11111111-1111-1111-1111-111111111111',@{a='1';b='2';c='3'},$true)
    } ('function Invoke-NestedValidationFile { ' + ${function:Invoke-NestedValidationFile}.ToString() + ' }') $fixture $fixtureCredential
    Assert-True ($transport.Identity -eq [guid]'11111111-1111-1111-1111-111111111111' -and
        $transport.HashCount -eq 3 -and $transport.Restricted -eq $true -and $transport.ClassifierPresent) 'In-memory validation transport preserves GUID, hashtable and bool arguments without a guest helper file'
} finally {
    if ($fixtureCredential) { $fixtureCredential.Password.Dispose() }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
}
function New-TestContinuationLayout {
    @{
        Vm=[pscustomobject]@{Name='Test-L2'; Id=[guid]'11111111-1111-1111-1111-111111111111'; Generation=2; State='Running'}
        State=[pscustomobject]@{
            Status='Failed'; FailureStage='PowerShellDirectReadiness'; FailureKind=$null; VmName='Test-L2'
            VmId='11111111-1111-1111-1111-111111111111'; BiosGuid='22222222-2222-2222-2222-222222222222'
            ChildPath='C:\Synthetic\Test-L2.vhdx'; ParentPath='C:\SyntheticCache\parent.vhdx'
            AnswerFilesRemoved=$false; ActivationChecked=$false; InternetDenyReady=$false
        }
        Drives=@([pscustomobject]@{Path='C:\Synthetic\Test-L2.vhdx'})
        Adapters=@([pscustomobject]@{SwitchName='OptionalLab-Internal'})
        Disk=[pscustomobject]@{
            Path='C:\Synthetic\Test-L2.vhdx'; ParentPath='C:\SyntheticCache\parent.vhdx'
            VhdType='Differencing'; Attached=$true
        }
        BiosGuid=[guid]'22222222-2222-2222-2222-222222222222'
        VmName='Test-L2'; ChildPath='C:\Synthetic\Test-L2.vhdx'
    }
}
$layout=New-TestContinuationLayout
Assert-NestedContinuationLayout @layout
Assert-True $true 'An identified running VM can complete configuration without recreation'
$layout.Vm.State='Off'
$layout.Disk.Attached=$false
Assert-NestedContinuationLayout @layout
Assert-True $true 'An identified stopped VM can be started without replacing its disk'
$interrupted=New-TestContinuationLayout
$interrupted.State.Status='Booting'
$interrupted.State.FailureStage=$null
$interrupted.Vm.State='Off'
$interrupted.Disk.Attached=$false
Assert-NestedContinuationLayout @interrupted
Assert-True $true 'A power-interrupted initial boot can continue from its existing stopped VM'
foreach ($change in @(
    {param($x) $x.State.Status='Configuring'},
    {param($x) $x.State.Status='Configured'},
    {param($x) $x.State.FailureStage='GuestNetworkAndImds'},
    {param($x) $x.State.FailureKind='UnknownFailure'},
    {param($x) $x.State.AnswerFilesRemoved=$true},
    {param($x) $x.State.ActivationChecked=$true},
    {param($x) $x.State.InternetDenyReady=$true},
    {param($x) $x.Vm.Id=[guid]'33333333-3333-3333-3333-333333333333'},
    {param($x) $x.Disk.ParentPath='C:\OtherParent.vhdx'},
    {param($x) $x.Adapters[0].SwitchName='OtherSwitch'}
)) {
    $invalidInterrupted=New-TestContinuationLayout
    $invalidInterrupted.State.Status='Booting'
    $invalidInterrupted.State.FailureStage=$null
    & $change $invalidInterrupted
    Assert-Throws { Assert-NestedContinuationLayout @invalidInterrupted } 'Interrupted boot cannot bypass stage or identity checks'
}
$configured=New-TestContinuationLayout
$configured.State.Status='Configured'
$configured.State.FailureStage=$null
$configured.State.AnswerFilesRemoved=$true
$configured.State.ActivationChecked=$true
$configured.State.InternetDenyReady=$true
Assert-NestedContinuationLayout @configured -Configured
Assert-True $true 'Read-only verification requires the completed identity-matched creation record'
$configured.State.ActivationChecked=$false
Assert-Throws { Assert-NestedContinuationLayout @configured -Configured } 'Verification cannot bypass recorded licensing readiness'
foreach ($change in @(
    {param($x) $x.Vm.Id=[guid]'33333333-3333-3333-3333-333333333333'},
    {param($x) $x.BiosGuid=[guid]'33333333-3333-3333-3333-333333333333'},
    {param($x) $x.Vm.Generation=1},
    {param($x) $x.Vm.State='Paused'},
    {param($x) $x.State.Status='Configured'},
    {param($x) $x.State.FailureStage='Activation'},
    {param($x) $x.Drives=@()},
    {param($x) $x.Drives[0].Path='C:\Other.vhdx'},
    {param($x) $x.Adapters[0].SwitchName='Other'},
    {param($x) $x.Disk.ParentPath='C:\OtherParent.vhdx'},
    {param($x) $x.Disk.VhdType='Dynamic'},
    {param($x) $x.Vm.State='Off'; $x.Disk.Attached=$true}
)) {
    $invalidLayout=New-TestContinuationLayout
    & $change $invalidLayout
    Assert-Throws { Assert-NestedContinuationLayout @invalidLayout } 'Identity or layout mismatch fails closed without a fresh-creation fallback'
}
$builderTokens=$null
$builderErrors=$null
$builderAst=[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'New-NestedLabFromIso.ps1'),[ref]$builderTokens,[ref]$builderErrors)
$continuation=$builderAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$ContinueExistingVm' -and
    $node.Clauses[0].Item2.Extent.Text.Contains('Assert-NestedContinuationLayout')
},$true)
Assert-True ($null -ne $continuation) 'Existing VM continuation has its own explicit validation branch'
$forbidden=@($continuation.Clauses[0].Item2.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -in @('New-VM','New-VHD','Mount-VHD','Dismount-VHD',
        'Mount-DiskImage','Dismount-DiskImage','New-NestedUnattendXml','Initialize-NestedNetwork.ps1')
},$true))
Assert-True ($forbidden.Count -eq 0) 'Continuation cannot recreate VM, disk, answer file or network and cannot unmount active disks'

$sdkCatch=${function:Wait-NestedDirect}.Ast.Find({
    param($node)
    $node -is [Management.Automation.Language.CatchClauseAst] -and
    $node.Extent.Text.Contains('$pipeline.InvocationStateInfo.Reason')
},$true)
Assert-True ($null -ne $sdkCatch) 'SDK terminating failures retain their invocation-reason error record'
$sdkCatchBody=($sdkCatch.Body.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
foreach ($case in @(
    @{Message='A remote session might have ended.'; Type='Transport'; Inner='None'; Initial=$false; Retry=$true},
    @{Message='A remote session might have ended. The credential is invalid.'; Type='Transport'; Inner='None'; Initial=$true; Retry=$true},
    @{Message='Unclassified transport failure'; Type='Transport'; Inner='None'; Initial=$true; Retry=$true},
    @{Message='Unclassified transport failure'; Type='Transport'; Inner='None'; Initial=$false; Retry=$false},
    @{Message='Synthetic initialization failure'; Type='Data'; Inner='None'; Initial=$true; Retry=$true},
    @{Message='Synthetic initialization failure'; Type='Data'; Inner='Unknown'; Initial=$true; Retry=$true},
    @{Message='Synthetic initialization failure'; Type='Data'; Inner='Authentication'; Initial=$true; Retry=$true},
    @{Message='Synthetic initialization failure'; Type='Data'; Inner='None'; Initial=$false; Retry=$false},
    @{Message='Access is denied.'; Type='Data'; Inner='None'; Initial=$true; Retry=$true},
    @{Message='The credential is invalid.'; Type='Direct'; Inner='None'; Initial=$true; Retry=$true},
    @{Message='The credential is invalid.'; Type='Direct'; Inner='None'; Initial=$false; Retry=$false}
)) {
    $pipeline=[PowerShell]::Create()
    try {
        [void]$pipeline.AddScript('param($Message,$Type,$Inner) $ErrorActionPreference="Stop"; function Invoke-SyntheticBootError { [CmdletBinding()] param($Text,$Kind,$InnerKind) $inner=if ($InnerKind -eq "Authentication") { [ComponentModel.Win32Exception]::new(1326) } elseif ($InnerKind -eq "Unknown") { [IO.InvalidDataException]::new("Synthetic nested failure") } else { $null }; $e=if ($Kind -eq "Data") { [System.Management.Automation.Remoting.PSRemotingDataStructureException]::new($Text,$inner) } elseif ($Kind -eq "Direct") { [System.Management.Automation.Remoting.PSDirectException]::new($Text) } else { [System.Management.Automation.Remoting.PSRemotingTransportException]::new($Text,$inner) }; $r=[Management.Automation.ErrorRecord]::new($e,"SyntheticBoot",[Management.Automation.ErrorCategory]::OpenError,$null); $PSCmdlet.ThrowTerminatingError($r) }; Invoke-SyntheticBootError -Text $Message -Kind $Type -InnerKind $Inner -ErrorAction Stop')
        [void]$pipeline.AddParameter('Message',$case.Message)
        [void]$pipeline.AddParameter('Type',$case.Type)
        [void]$pipeline.AddParameter('Inner',$case.Inner)
        $async=$pipeline.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne(10000)) { $pipeline.Stop(); throw 'Synthetic SDK test timed out' }
        $failure=$null
        $caught=$false
        try { $null=$pipeline.EndInvoke($async) }
        catch { $caught=$true; . ([scriptblock]::Create($sdkCatchBody)) }
        Assert-True ($caught -and $pipeline.Streams.Error.Count -eq 0) 'The real SDK reproduces a stopping exception without a stream record'
        $expectedType=if ($case.Type -eq 'Data') {
            [System.Management.Automation.Remoting.PSRemotingDataStructureException]
        } elseif ($case.Type -eq 'Direct') {
            [System.Management.Automation.Remoting.PSDirectException]
        } else { [System.Management.Automation.Remoting.PSRemotingTransportException] }
        Assert-True ($failure.Exception -is $expectedType) 'The original remoting error survives EndInvoke wrapping'
        Assert-True ((Test-NestedBootTransportError $failure -InitialBoot:$case.Initial) -eq $case.Retry) 'SDK remoting errors retry during initial setup and preserve normal connection behavior'
    } finally { $pipeline.Dispose() }
}
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
function New-SyntheticProtocolRecord {
    param([string]$Message='SyntheticSecretNeverLog', [Exception]$Inner,
        [Management.Automation.ErrorCategory]$Category='OpenError')
    $exception=[Management.Automation.Remoting.PSRemotingDataStructureException]::new($Message,$Inner)
    return [Management.Automation.ErrorRecord]::new($exception,'SyntheticSecretErrorId',$Category,$null)
}
$protocol=New-SyntheticProtocolRecord
Assert-True (Test-NestedBootTransportError $protocol -InitialBoot) 'Retry protocol initialization only during initial boot'
Assert-True (-not (Test-NestedBootTransportError $protocol)) 'Normal connections reject data structure failures'
foreach ($category in @('SecurityError','PermissionDenied','AuthenticationError')) {
    $failure=New-SyntheticProtocolRecord -Category $category
    Assert-True (Test-NestedBootTransportError $failure -InitialBoot) 'Initial setup retries connection refusals regardless of authentication category'
    Assert-True (-not (Test-NestedBootTransportError $failure)) 'Normal connections still reject authentication categories'
}
foreach ($code in @(5,86,1326,1327,1328,1329,1330,1331,1385,1907,1909)) {
    $failure=New-SyntheticTransportRecord 'A remote session might have ended.'
    $failure.Exception.ErrorCode=$code
    Assert-True (Test-NestedBootTransportError $failure -InitialBoot) 'Initial setup retries connection refusals regardless of authentication code'
    Assert-True (-not (Test-NestedBootTransportError $failure)) 'Normal connections still reject authentication codes'
}
$inner=[ComponentModel.Win32Exception]::new(1326)
$failure=[Management.Automation.ErrorRecord]::new(
    [Management.Automation.Remoting.PSRemotingTransportException]::new('A remote session might have ended.',$inner),
    'SyntheticInnerAuthentication',[Management.Automation.ErrorCategory]::OpenError,$null)
Assert-True (Test-NestedBootTransportError $failure -InitialBoot) 'Initial setup retries inner native logon failures'
Assert-True (-not (Test-NestedBootTransportError $failure)) 'Normal connections still reject inner native logon failures'
$nestedProtocol=New-SyntheticProtocolRecord -Inner ([IO.InvalidDataException]::new('SyntheticInnerSecretNeverLog'))
Assert-True (Test-NestedBootTransportError $nestedProtocol -InitialBoot) 'Initial connection retries do not depend on the presence of inner exceptions'
Assert-True (-not (Test-NestedBootTransportError $nestedProtocol)) 'Normal connections still reject nested protocol failures'
Assert-True (Test-NestedBootTransportError (New-SyntheticTransportRecord 'Synthetic localized connection failure') -InitialBoot) 'Initial transport retries do not depend on English wording'
Assert-True (Test-NestedBootTransportError (New-SyntheticProtocolRecord -Message 'Preparing credentials and authentication services') -InitialBoot) 'Mentioning credentials alone does not mean rejection'
Assert-True (Test-NestedBootTransportError (New-SyntheticProtocolRecord -Message 'The credential is invalid.') -InitialBoot) 'Initial setup does not stop at an invalid-credential message'
$nestedAuth=New-SyntheticProtocolRecord -Inner ([ComponentModel.Win32Exception]::new(1326))
Assert-True ((Get-NestedBootConnectionDecision $nestedAuth -InitialBoot) -eq 'InitialBootConnection') 'Initial setup takes priority over authentication rejection'
Assert-True ((Get-NestedBootConnectionDecision $nestedAuth) -eq 'AuthenticationCode') 'Normal authentication rejection retains its numeric diagnostic reason'
Assert-True ((Get-NestedBootConnectionDecision (New-SyntheticProtocolRecord -Category PermissionDenied)) -eq 'AuthenticationCategory') 'Normal authentication categories have a fixed diagnostic reason'
Assert-True ((Get-NestedBootConnectionDecision (New-SyntheticProtocolRecord -Message 'Authentication failed')) -eq 'AuthenticationMessage') 'Normal explicit authentication rejection has a fixed diagnostic reason'
$directAuth=[Management.Automation.ErrorRecord]::new(
    [Management.Automation.Remoting.PSDirectException]::new('The credential is invalid.'),
    'SyntheticDirectAuthentication',[Management.Automation.ErrorCategory]::OpenError,$null)
Assert-True (Test-NestedBootTransportError $directAuth -InitialBoot) 'The observed PSDirect authentication exception retries during initial setup'
Assert-True (-not (Test-NestedBootTransportError $directAuth)) 'PSDirect authentication rejection still stops a normal connection'
$unknown=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Synthetic'),'Synthetic',
    [Management.Automation.ErrorCategory]::OpenError,$null)
Assert-True (-not (Test-NestedBootTransportError $unknown -InitialBoot)) 'Unknown exception types stop even during initial boot'

function Invoke-TestDirectWait {
    param([object[]]$Failures=@(), [switch]$InitialBoot, [int]$TimeoutSeconds=300,
        [switch]$RepeatFailure, [int]$TimeoutAttempt=0, [switch]$LogFailure, [int]$FirstAttemptSeconds=0)
    & {
        param($Failures,$InitialBoot,$TimeoutSeconds,$RepeatFailure,$TimeoutAttempt,$LogFailure,$FirstAttemptSeconds)
        $script:directTest=@{
            Failures=$Failures; Seconds=0; Pipelines=[Collections.Generic.List[object]]::new()
            RepeatFailure=$RepeatFailure; TimeoutAttempt=$TimeoutAttempt; ClosedSessions=0; WaitMilliseconds=@()
            FirstAttemptSeconds=$FirstAttemptSeconds
        }
        function New-TestDirectWatch {
            $watch=[pscustomobject]@{}
            $watch | Add-Member -MemberType ScriptProperty -Name Elapsed -Value {
                [timespan]::FromSeconds($script:directTest.Seconds)
            }
            return $watch
        }
        function New-TestDirectPipeline {
            $index=$script:directTest.Pipelines.Count
            $failure=if ($script:directTest.RepeatFailure) { $script:directTest.Failures[0] }
                elseif ($index -lt $script:directTest.Failures.Count) { $script:directTest.Failures[$index] }
                else { $null }
            $handle=[pscustomobject]@{Attempt=$index+1}
            $handle | Add-Member -MemberType ScriptMethod -Name WaitOne -Value {
                param($milliseconds)
                $script:directTest.WaitMilliseconds+= $milliseconds
                if ($this.Attempt -eq $script:directTest.TimeoutAttempt) {
                    $script:directTest.Seconds+= $milliseconds/1000
                    return $false
                }
                if ($this.Attempt -eq 1) { $script:directTest.Seconds+=$script:directTest.FirstAttemptSeconds }
                return $true
            }
            $pipeline=[pscustomobject]@{
                Failure=$failure; Streams=@{Error=@(if ($failure) { $failure })}
                Handle=$handle; Disposed=$false; Stopped=$false
            }
            $pipeline | Add-Member -MemberType ScriptMethod -Name AddCommand -Value { param($name) return $this }
            $pipeline | Add-Member -MemberType ScriptMethod -Name AddParameter -Value { param($name,$value) return $this }
            $pipeline | Add-Member -MemberType ScriptMethod -Name BeginInvoke -Value { return [pscustomobject]@{AsyncWaitHandle=$this.Handle} }
            $pipeline | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {
                param($async)
                if ($this.Failure) { throw $this.Failure.Exception }
                return [pscustomobject]@{State='Opened'}
            }
            $pipeline | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped=$true }
            $pipeline | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed=$true }
            $script:directTest.Pipelines.Add($pipeline)
            return $pipeline
        }
        function Start-Sleep {
            param([int]$Seconds,[int]$Milliseconds)
            if ($PSBoundParameters.ContainsKey('Milliseconds')) { $script:directTest.Seconds+=$Milliseconds/1000 }
            else { $script:directTest.Seconds+=$Seconds }
        }
        function Remove-PSSession { [CmdletBinding()]param($Session) $script:directTest.ClosedSessions++ }
        $body=${function:Wait-NestedDirect}.ToString().Replace('[PowerShell]::Create()', '(New-TestDirectPipeline)').
            Replace('[Diagnostics.Stopwatch]::StartNew()', '(New-TestDirectWatch)')
        $directory=Join-Path ([IO.Path]::GetTempPath()) ('nested-direct-'+[guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $directory)
        $path=if ($LogFailure) { $directory } else { Join-Path $directory 'direct.jsonl' }
        $result=$null
        $caught=$null
        try {
            try { $result=& ([scriptblock]::Create($body)) -VmName Synthetic -InitialBoot:$InitialBoot -TimeoutSeconds $TimeoutSeconds -DiagnosticPath $path }
            catch { $caught=$_ }
            $records=@(if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json } })
            return @{
                Succeeded=($null -ne $result); Failed=($null -ne $caught); Records=$records
                SuccessfulPipelineRetained=($null -ne $result -and -not $result.Pipeline.Disposed)
                Seconds=$script:directTest.Seconds; Pipelines=@($script:directTest.Pipelines.ToArray())
                ClosedSessions=$script:directTest.ClosedSessions; WaitMilliseconds=$script:directTest.WaitMilliseconds
            }
        } finally {
            if ($result) { Remove-PSSession -Session $result.Session; $result.Pipeline.Dispose() }
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
            Remove-Item -LiteralPath $directory -Force
            $script:directTest=$null
        }
    } $Failures $InitialBoot $TimeoutSeconds $RepeatFailure $TimeoutAttempt $LogFailure $FirstAttemptSeconds
}
$wait=Invoke-TestDirectWait -Failures @($protocol) -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 10 -and $wait.Records[0].Status -eq 'Retry' -and $wait.Records[1].Status -eq 'Opened') 'Initial protocol failure retries at ten seconds then opens a session'
Assert-True ($wait.Pipelines[0].Disposed) 'Failed attempt releases its pipeline'
Assert-True ($wait.SuccessfulPipelineRetained) 'Successful session retains its creating pipeline until the caller closes it'
Assert-True ($wait.Records[0].Attempt -eq 1 -and $wait.Records[1].Attempt -eq 2) 'Diagnostic attempt numbers are retained'
$diagnostic=$wait.Records | ConvertTo-Json -Depth 5
Assert-True (-not $diagnostic.Contains('SyntheticSecretNeverLog') -and -not $diagnostic.Contains('SyntheticSecretErrorId')) 'Diagnostics contain no arbitrary exception message or error ID'
$wait=Invoke-TestDirectWait -Failures @($nestedProtocol) -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 10 -and $wait.Records[0].Decision -eq 'InitialBootConnection') 'Nested protocol failures retry and report the decision'
Assert-True ($wait.Records[0].ExceptionChain.Count -eq 2 -and
    $wait.Records[0].ExceptionChain[1].ExceptionType -eq 'System.IO.InvalidDataException') 'Diagnostic output retains the original exception hierarchy'
$diagnostic=$wait.Records | ConvertTo-Json -Depth 6
Assert-True (-not $diagnostic.Contains('SyntheticInnerSecretNeverLog') -and -not $diagnostic.Contains('SyntheticSecretErrorId')) 'Inner exception messages and raw IDs are not logged'
$wait=Invoke-TestDirectWait -Failures @($nestedAuth) -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 10 -and $wait.Records[0].Decision -eq 'InitialBootConnection' -and
    $wait.Records[0].ExceptionChain[1].NativeErrorCode -eq 1326) 'Initial authentication rejection retries and preserves the numeric cause'
$wait=Invoke-TestDirectWait -Failures @($nestedAuth)
Assert-True ($wait.Failed -and $wait.Seconds -eq 0 -and $wait.Records[0].Decision -eq 'AuthenticationCode') 'Normal authentication rejection still stops immediately'
$wait=Invoke-TestDirectWait -Failures @((New-SyntheticTransportRecord 'Synthetic localized connection failure')) -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 10) 'An arbitrary transport message retries through the full wait loop'
$wait=Invoke-TestDirectWait -Failures @($protocol)
Assert-True ($wait.Failed -and $wait.Pipelines.Count -eq 1 -and $wait.Seconds -eq 0 -and $wait.Records[0].Status -eq 'Rejected') 'Ordinary connections fail immediately on protocol errors'
$wait=Invoke-TestDirectWait -Failures @((New-SyntheticProtocolRecord -Category AuthenticationError)) -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Pipelines.Count -eq 2 -and $wait.Seconds -eq 10) 'Initial boot retries structured authentication failures'
$observedBootFailure=New-SyntheticProtocolRecord -Inner (
    [Management.Automation.PSInvalidOperationException]::new('A remote session might have ended.'))
$wait=Invoke-TestDirectWait -Failures @($observedBootFailure,$directAuth) -InitialBoot -FirstAttemptSeconds 30
Assert-True ($wait.Succeeded -and $wait.Pipelines.Count -eq 3 -and $wait.Seconds -eq 50 -and
    @($wait.Records | Where-Object Status -eq 'Retry').Count -eq 2 -and $wait.Records[-1].Status -eq 'Opened') 'The observed boot transport then PSDirect credential rejection sequence reaches an open session without intervention'
$wait=Invoke-TestDirectWait -Failures @($directAuth) -InitialBoot -RepeatFailure
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.Records[-1].Status -eq 'Timeout') 'Persistent initial PSDirect failures stop at the configured deadline'
$lateReadyFailures=@(1..19 | ForEach-Object { $directAuth })
$wait=Invoke-TestDirectWait -Failures $lateReadyFailures -InitialBoot
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 190 -and $wait.Records[-1].Status -eq 'Opened') 'Initial setup can connect successfully after the former three-minute cutoff'
$timeoutParameter=@(${function:Wait-NestedDirect}.Ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'TimeoutSeconds'
},$true))
Assert-True ($timeoutParameter.Count -eq 1 -and $timeoutParameter[0].DefaultValue.Value -eq 1800) 'The shared connection wait retains its thirty-minute default'
$timeoutParameter=@($builderAst.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'ReadinessTimeoutSeconds' })
Assert-True ($timeoutParameter.Count -eq 1 -and $timeoutParameter[0].DefaultValue.Value -eq 1800) 'The ISO builder supplies the same thirty-minute default'
$wait=Invoke-TestDirectWait -Failures @($unknown) -InitialBoot
Assert-True ($wait.Failed -and $wait.Seconds -eq 0) 'Unknown exceptions fail without sleeping'
$wait=Invoke-TestDirectWait -Failures @($protocol) -InitialBoot -RepeatFailure
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.Records[-1].Status -eq 'Timeout') 'Repeated protocol failures use the configured timeout without a short initial cap'
Assert-True (@($wait.Pipelines | Where-Object { -not $_.Disposed }).Count -eq 0) 'All exhausted attempts dispose their pipelines'
$wait=Invoke-TestDirectWait -Failures @($nestedProtocol) -InitialBoot -RepeatFailure -FirstAttemptSeconds 30
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.Pipelines.Count -eq 27) 'The configured budget includes time spent in the first connection attempt'
$wait=Invoke-TestDirectWait -Failures @($protocol) -InitialBoot -RepeatFailure -TimeoutSeconds 25
Assert-True ($wait.Failed -and $wait.Seconds -eq 25) 'An explicitly short timeout is respected'
$wait=Invoke-TestDirectWait -Failures @($protocol) -InitialBoot -TimeoutAttempt 2
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.WaitMilliseconds[1] -eq 290000 -and $wait.Pipelines[1].Stopped) 'An in-flight retry receives the remaining configured deadline'
$transport=New-SyntheticTransportRecord 'A remote session might have ended.'
$wait=Invoke-TestDirectWait -Failures @($transport)
Assert-True ($wait.Succeeded -and $wait.Seconds -eq 10) 'Existing transport retries remain available without InitialBoot'
$wait=Invoke-TestDirectWait -Failures @($transport) -RepeatFailure -TimeoutSeconds 240
Assert-True ($wait.Failed -and $wait.Seconds -eq 240) 'Normal connection waits retain their configured timeout'
$mixedFailures=@($protocol)+@(1..35 | ForEach-Object { $transport })
$wait=Invoke-TestDirectWait -Failures $mixedFailures -InitialBoot
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.Pipelines.Count -eq 30) 'Transport failures cannot reset the configured deadline'
$wait=Invoke-TestDirectWait -InitialBoot -TimeoutAttempt 1
Assert-True ($wait.Failed -and $wait.Seconds -eq 300 -and $wait.WaitMilliseconds[0] -eq 300000) 'A hanging first initial-boot attempt uses the configured deadline'
$wait=Invoke-TestDirectWait -TimeoutAttempt 1 -TimeoutSeconds 25
Assert-True ($wait.Failed -and $wait.Seconds -eq 25 -and $wait.Pipelines[0].Stopped -and $wait.Pipelines[0].Disposed) 'An in-flight initial attempt is stopped and disposed at the total deadline'
$wait=Invoke-TestDirectWait -LogFailure
Assert-True ($wait.Failed -and $wait.ClosedSessions -eq 1 -and $wait.Pipelines[0].Disposed) 'Diagnostic persistence failure closes the newly opened session and fails explicitly'
$readinessCall=@($builderAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Wait-NestedDirect'
},$true))
Assert-True ($readinessCall.Count -eq 1 -and $readinessCall[0].Extent.Text.Contains('-InitialBoot') -and
    $readinessCall[0].Extent.Text.Contains('direct-readiness.jsonl')) 'The ISO builder and validated initial continuation share the bounded initial-boot wait'
$xml = $null
$credential = $null
$secure = $null
$sample = $null
Write-Output "PASS: $script:checks offline helper assertions. This does not validate ISO, WIM, boot, ACL, or PowerShell Direct."
