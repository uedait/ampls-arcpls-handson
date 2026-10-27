#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [uri]$ProxyUri,
    [string]$InstallerPath,
    [string]$WorkingDirectory = (Join-Path $env:ProgramData 'AmplsArcHandson')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path -LiteralPath $agent) {
    throw 'Arc agent already exists. Review the existing installation; this script does not upgrade it.'
}
if (-not $InstallerPath) {
    if (-not $ProxyUri -or $ProxyUri.Scheme -ne 'http' -or
        $ProxyUri.UserInfo -or $ProxyUri.AbsolutePath -ne '/' -or $ProxyUri.Query -or $ProxyUri.Fragment) {
        throw 'Specify an unauthenticated HTTP proxy URL, or provide an approved local MSI via InstallerPath.'
    }
}
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Download/verify and install Microsoft Azure Connected Machine Agent')) {
    return
}

$null = New-Item -ItemType Directory -Path $WorkingDirectory -Force
if (-not $InstallerPath) {
    $InstallerPath = Join-Path $WorkingDirectory 'AzureConnectedMachineAgent.msi'
    if (Test-Path -LiteralPath $InstallerPath) {
        throw 'Download destination already exists. Review it and use InstallerPath explicitly, or choose another working directory.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/AzureConnectedMachineAgent' `
        -Proxy $ProxyUri.AbsoluteUri -OutFile $InstallerPath
}
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
if ([IO.Path]::GetExtension($InstallerPath) -ne '.msi') {
    throw 'InstallerPath must be an MSI file.'
}
$signature = Get-AuthenticodeSignature -FilePath $InstallerPath
if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
    $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
    throw "Microsoft MSI signature verification failed. Status: $($signature.Status)"
}
$logPath = Join-Path $WorkingDirectory ('ArcSetup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$result = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
    '/i', "`"$InstallerPath`"", '/qn', '/norestart', '/L*v', "`"$logPath`""
)
if ($result.ExitCode -notin 0, 3010) {
    throw "MSI installation failed (exit $($result.ExitCode)). Review $logPath."
}
if (-not (Test-Path -LiteralPath $agent)) {
    throw "MSI returned $($result.ExitCode), but azcmagent.exe was not found. Review $logPath."
}
[pscustomobject]@{
    Installed = $true
    RebootRequired = ($result.ExitCode -eq 3010)
    AgentPath = $agent
    SetupLog = $logPath
}
if ($result.ExitCode -eq 3010) {
    Write-Warning 'Restart during the approved maintenance window before continuing.'
}
