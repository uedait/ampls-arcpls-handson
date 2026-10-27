#Requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-HandsonAz {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $command = Get-Command az -ErrorAction Stop
    $result = & $command.Source @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments[0]). No further changes will be attempted."
    }
    if (-not $result) {
        throw "Azure CLI did not return JSON: az $($Arguments[0])."
    }
    return (($result -join "`n") | ConvertFrom-Json -AsHashtable)
}

function Assert-HandsonAzContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$ExpectedTenantId,
        [Parameter(Mandatory)][guid]$ExpectedSubscriptionId
    )
    if ($ExpectedTenantId -eq [guid]::Empty -or $ExpectedSubscriptionId -eq [guid]::Empty) {
        throw 'Replace placeholder tenant/subscription IDs.'
    }
    $account = Invoke-HandsonAz -Arguments @('account', 'show')
    if ($account.tenantId -ne $ExpectedTenantId.ToString() -or
        $account.id -ne $ExpectedSubscriptionId.ToString() -or $account.state -ne 'Enabled') {
        throw 'Azure CLI context mismatch. Select the approved tenant/subscription explicitly before retrying.'
    }
}
