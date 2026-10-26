#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Common.ps1')

$script:Calls = [Collections.Generic.List[object]]::new()
$script:Response = 'null'
$script:FailOperation = ''
$script:Assertions = 0
$parameters = @{
    SubscriptionId = 'test-subscription'
    ResourceGroup = 'test-group'
    ClusterName = 'test-cluster'
    WorkspaceId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.OperationalInsights/workspaces/demo'
}

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $script:Calls.Add($Arguments)
    $global:LASTEXITCODE = 0
    if ($Arguments[1] -eq $script:FailOperation) {
        $global:LASTEXITCODE = 7
        return
    }
    if ($Arguments[1] -eq 'show') {
        return $script:Response
    }
    if ($Arguments[1] -ne 'update' -or $Arguments -notcontains '--enable-azure-monitor-logs') {
        throw "Unexpected mocked Azure CLI call: $($Arguments -join ' ')"
    }
}

function Assert-Equal($Expected, $Actual, [string]$Label) {
    if ($Expected -ne $Actual) {
        throw "$Label : expected '$Expected', got '$Actual'."
    }
    $script:Assertions++
}

function Test-Configuration {
    param(
        [string]$Response,
        [int]$ExpectedCalls,
        [string]$ExpectedError = '',
        [string]$FailOperation = ''
    )
    $script:Calls.Clear()
    $script:Response = $Response
    $script:FailOperation = $FailOperation
    $actualError = ''
    try {
        Enable-DemoMonitoring @parameters
    }
    catch {
        $actualError = $_.Exception.Message
    }
    if ($ExpectedError) {
        Assert-Equal $true ($actualError -like "*$ExpectedError*") 'Expected explicit failure'
    }
    else {
        Assert-Equal '' $actualError 'Configuration succeeds'
    }
    Assert-Equal $ExpectedCalls $script:Calls.Count 'CLI call count'
    Assert-Equal 'show' $script:Calls[0][1] 'Inspect before updating'
    if ($ExpectedCalls -eq 2) {
        Assert-Equal 'update' $script:Calls[1][1] 'Enable only when needed'
        Assert-Equal $true ($script:Calls[1] -contains $parameters.WorkspaceId) 'Expected workspace passed'
    }
}

Test-Configuration -Response 'null' -ExpectedCalls 2
Test-Configuration -Response '{"enabled":false}' -ExpectedCalls 2
$matching = @{
    enabled = $true
    config = @{
        logAnalyticsWorkspaceResourceID = $parameters.WorkspaceId.ToUpperInvariant()
        useAADAuth = 'true'
    }
}
$matchingJson = $matching | ConvertTo-Json -Depth 4
Test-Configuration -Response $matchingJson -ExpectedCalls 1
Test-Configuration -Response $matchingJson -ExpectedCalls 1
$matching.config.logAnalyticsWorkspaceResourceID = '/different-workspace'
Test-Configuration -Response ($matching | ConvertTo-Json -Depth 4) -ExpectedCalls 1 -ExpectedError 'different or missing workspace'
$matching.config.logAnalyticsWorkspaceResourceID = $parameters.WorkspaceId
$matching.config.useAADAuth = 'false'
Test-Configuration -Response ($matching | ConvertTo-Json -Depth 4) -ExpectedCalls 1 -ExpectedError 'without managed-identity'
$matching.config.Remove('useAADAuth')
Test-Configuration -Response ($matching | ConvertTo-Json -Depth 4) -ExpectedCalls 1 -ExpectedError 'without managed-identity'
Test-Configuration -Response '{"enabled":true}' -ExpectedCalls 1 -ExpectedError 'different or missing workspace'
Test-Configuration -Response 'null' -ExpectedCalls 1 -ExpectedError 'exit 7' -FailOperation show
Test-Configuration -Response 'null' -ExpectedCalls 2 -ExpectedError 'exit 7' -FailOperation update

Write-Host "PASS: $script:Assertions assertions; first-run enablement, safe reruns, case-insensitive resource IDs, mismatched/missing configuration, and CLI failure propagation."
