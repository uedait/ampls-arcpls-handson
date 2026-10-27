#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = 'AmplsArcHandson'
if ([Diagnostics.EventLog]::SourceExists($source) -and
    [Diagnostics.EventLog]::LogNameFromSourceName($source, '.') -ne 'Application') {
    throw 'The event source already belongs to another event log.'
}
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Create one synthetic Application event (ID 9001)')) {
    return
}
if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName Application -Source $source
}
$marker = [guid]::NewGuid().ToString()
$utc = [datetime]::UtcNow.ToString('o')
Write-EventLog -LogName Application -Source $source -EventId 9001 `
    -EntryType Information -Message "AmplsArcHandson marker=$marker; utc=$utc"
[pscustomobject]@{ Marker = $marker; GeneratedUtc = $utc; Computer = $env:COMPUTERNAME; EventId = 9001; Source = $source }
