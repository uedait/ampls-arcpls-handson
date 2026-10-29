#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-HandsonAz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$ExpectedContext
    )

    if ($ExpectedContext) { Assert-HandsonAzContext @ExpectedContext }
    $command = Get-Command az -ErrorAction Stop
    $result = & $command.Source @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments[0]). No further changes will be attempted."
    }
    if (-not $result) {
        throw "Azure CLI did not return JSON: az $($Arguments[0])."
    }
    return (($result -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Assert-HandsonAzContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$ExpectedTenantId,
        [Parameter(Mandatory)][guid]$ExpectedSubscriptionId,
        [guid]$ExpectedClientId,
        [string]$ExpectedAzureConfigDir
    )
    if ($ExpectedTenantId -eq [guid]::Empty -or $ExpectedSubscriptionId -eq [guid]::Empty) {
        throw 'Replace placeholder tenant/subscription IDs.'
    }
    if ($PSBoundParameters.ContainsKey('ExpectedClientId')) {
        if ($ExpectedClientId -eq [guid]::Empty) { throw 'Replace the placeholder client ID.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedAzureConfigDir) -or
            [string]::IsNullOrWhiteSpace($env:AZURE_CONFIG_DIR) -or
            -not [IO.Path]::IsPathFullyQualified($ExpectedAzureConfigDir) -or
            -not [IO.Path]::IsPathFullyQualified($env:AZURE_CONFIG_DIR) -or
            -not (Test-Path -LiteralPath $ExpectedAzureConfigDir -PathType Container)) {
            throw 'Service principal execution requires an existing absolute AZURE_CONFIG_DIR.'
        }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $expectedPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ExpectedAzureConfigDir))
        $actualPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($env:AZURE_CONFIG_DIR))
        if (-not [string]::Equals($actualPath, $expectedPath, $comparison)) {
            throw 'Azure CLI authentication cache changed. Restore the approved context before retrying.'
        }
    }
    $account = Invoke-HandsonAz -Arguments @('account', 'show', '--subscription', $ExpectedSubscriptionId.ToString())
    if ($account.tenantId -ne $ExpectedTenantId.ToString() -or
        $account.id -ne $ExpectedSubscriptionId.ToString() -or $account.state -ne 'Enabled') {
        throw 'Azure CLI context mismatch. Select the approved tenant/subscription explicitly before retrying.'
    }
    if ($PSBoundParameters.ContainsKey('ExpectedClientId') -and
        ($account.user.type -ne 'servicePrincipal' -or $account.user.name -ne $ExpectedClientId.ToString())) {
        throw 'Azure CLI service principal context mismatch. Check the approved client ID and authentication type.'
    }
}
