#Requires -Version 7.0
[CmdletBinding()]
param([switch]$SkipMockTests)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|\.local)[\\/]' })
$failures = [Collections.Generic.List[string]]::new()
$scriptCount = 0
$linkCount = 0
$fencedCodePattern = '(?ms)^[ \t]*(`{3,}|~{3,})[^\r\n]*\r?\n.*?^[ \t]*\1[ \t]*\r?$'
foreach ($newline in @("`n", "`r`n")) {
    $sample = @('```powershell', '[uri](Read-Host)', '```', '[guide](docs/iso-build.md)') -join $newline
    $sampleContent = [regex]::Replace($sample, $fencedCodePattern, '')
    $sampleLinks = [regex]::Matches($sampleContent, '\]\(([^)\r\n]+)\)')
    if ($sampleLinks.Count -ne 1 -or $sampleLinks[0].Groups[1].Value -ne 'docs/iso-build.md') {
        throw 'Markdown fence/link regression check failed.'
    }
}
foreach ($file in $files) {
    if ($file.Extension -eq '.ps1') {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($errorItem in $parseErrors) {
            $failures.Add("$($file.Name):$($errorItem.Extent.StartLineNumber): $($errorItem.Message)")
        }
        $scriptCount++
    }
    if ($file.Extension -in '.json', '.excalidraw') {
        $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
    if ($file.Extension -eq '.md') {
        $markdown = Get-Content -LiteralPath $file.FullName -Raw
        $linkContent = [regex]::Replace($markdown, $fencedCodePattern, '')
        foreach ($match in [regex]::Matches($linkContent, '\]\(([^)\r\n]+)\)')) {
            $target = $match.Groups[1].Value.Trim('<', '>')
            if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:|^#') { continue }
            $relative = [uri]::UnescapeDataString(($target -split '#', 2)[0])
            if (-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $relative))) {
                $failures.Add("$($file.Name): missing relative link $target")
            }
            $linkCount++
        }
    }
    if ($file.Extension -in '.ps1', '.md', '.bicep', '.bicepparam', '.json', '.kql') {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match '-----BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY-----') {
            $failures.Add("$($file.Name): private key material detected.")
        }
    }
}
$details = Get-Content -LiteralPath (Join-Path $root 'docs\architecture.md') -Raw
foreach ($domain in @(
    'his.arc.azure.com', 'guestconfiguration.azure.com', 'monitor.azure.com',
    'oms.opinsights.azure.com', 'ods.opinsights.azure.com',
    'agentsvc.azure-automation.net', 'blob.core.windows.net'
)) {
    if (-not $details.Contains("``$domain``")) { $failures.Add("Missing DNS mapping: $domain") }
}
foreach ($query in 'heartbeat.kql', 'test-events.kql') {
    $queryText = Get-Content -LiteralPath (Join-Path $root "queries\$query") -Raw
    if ($queryText -notmatch 'ago\(30m\)' -or $queryText -notmatch 'take 100') {
        $failures.Add("$query must bound time and result count.")
    }
}
if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Output "PASS: $scriptCount PowerShell files parsed; $linkCount relative links resolved; JSON, DNS mapping, query limits and private-key markers checked."
if ($SkipMockTests) {
    Write-Warning 'Synthetic CLI tests were explicitly skipped.'
} else {
    & (Join-Path $root 'tests\Invoke-LocalTests.ps1')
}
