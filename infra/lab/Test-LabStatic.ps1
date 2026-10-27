#requires -Version 7.0
# Local-only checks. Does not authenticate to Azure, install tools, or deploy resources.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($errorItem in $parseErrors) { $failures.Add("$($file.Name): $errorItem") }
}
$bicep = Get-Command bicep -ErrorAction SilentlyContinue
if (-not $bicep) {
    $failures.Add('Bicep CLI not found on PATH. Bicep build and build-params were not executed.')
}
else {
    & $bicep.Source build (Join-Path $PSScriptRoot 'main.bicep') --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add('main.bicep compilation failed.') }
    & $bicep.Source build-params (Join-Path $PSScriptRoot 'example.bicepparam') --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add('example.bicepparam compilation failed; Bicep 0.31+ is required.') }
}
if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Output 'PASS: PowerShell syntax (current PS7 parser), Bicep template and standalone parameters compiled.'
Write-Output 'Not tested: PS5.1 runtime, Azure availability/quota/cost, deployment, guest boot, DNS, WinNAT, PowerShell Direct and IMDS isolation.'
