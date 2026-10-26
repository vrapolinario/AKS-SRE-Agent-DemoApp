#Requires -Version 7.2
[CmdletBinding()]
param([switch]$CheckTelemetry)

. (Join-Path $PSScriptRoot 'Common.ps1')
$state = Read-Deployment
$url = Get-DemoUrl
$response = Invoke-WebRequest "$url/api/status" -SkipHttpErrorCheck -TimeoutSec 15
$status = $response.Content | ConvertFrom-Json
$expected = switch ($status.mode) {
    'healthy' { 200 }
    'http500' { 500 }
    default { throw "Unexpected app mode: $($status.mode). Inspect application logs." }
}
if ([int]$response.StatusCode -ne $expected -or $status.statusCode -ne $expected) {
    throw "API status is inconsistent with mode=$($status.mode)."
}
$page = Invoke-WebRequest "$url/" -SkipHttpErrorCheck -TimeoutSec 15
if ([int]$page.StatusCode -ne $expected -or $page.Content -notmatch "HTTP $expected") {
    throw 'The browser page has an unexpected status or content.'
}
foreach ($path in @('/health/live', '/health/ready')) {
    $health = Invoke-WebRequest "$url$path" -SkipHttpErrorCheck -TimeoutSec 15
    if ([int]$health.StatusCode -ne 200) {
        throw "Probe $path returned HTTP $([int]$health.StatusCode)."
    }
}
Write-Host "Verified $url : mode=$($status.mode), HTTP $expected; both probes return 200."
Invoke-Kube -Arguments @('get', 'pods', '-n', 'sre-demo', '-o', 'wide')

if ($CheckTelemetry) {
    Assert-Command az
    $query = @"
AppRequests
| where TimeGenerated > ago(15m)
| where _ResourceId =~ '$($state.applicationInsightsId)'
| where AppRoleName == 'aks-sre-demo'
| summarize Requests=count(), Failures=countif(toint(ResultCode) between (500 .. 599))
"@
    # Use the Logs REST API so the optional log-analytics CLI extension is not needed.
    $body = @{ query = $query; timespan = 'PT15M' } | ConvertTo-Json
    $queryFile = [IO.Path]::GetTempFileName()
    try {
        Set-Content $queryFile -Value $body -Encoding utf8
        $uri = "https://api.loganalytics.io/v1/workspaces/$($state.workspaceCustomerId)/query"
        $telemetry = Invoke-Azure -Arguments @(
            'rest', '--subscription', $state.subscriptionId, '--method', 'post', '--uri', $uri,
            '--resource', 'https://api.loganalytics.io', '--body', "@$queryFile", '-o', 'json'
        ) | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $queryFile -Force
    }
    if ($telemetry.PSObject.Properties['error']) {
        throw "Application Insights query returned an error: $($telemetry.error | ConvertTo-Json -Depth 10)"
    }
    $requests = [long]$telemetry.tables[0].rows[0][0]
    $failures = [long]$telemetry.tables[0].rows[0][1]
    if ($requests -eq 0) {
        throw 'No matching Application Insights requests in the last 15 minutes. Allow ingestion time, then retry; inspect the connection string, egress, and application logs if it persists.'
    }
    if ($status.mode -eq 'http500' -and $failures -eq 0) {
        throw 'The app is failing, but no HTTP 5XX telemetry has arrived yet. Wait and retry.'
    }
    Write-Host "Application Insights ingestion verified: requests=$requests, HTTP 5XX=$failures (last 15 minutes)."
    $containersQuery = @"
ContainerLogV2
| where TimeGenerated > ago(15m)
| where PodNamespace == 'sre-demo'
| where _ResourceId =~ '$($state.aksId)'
| summarize Rows=count()
"@
    $containerFile = [IO.Path]::GetTempFileName()
    try {
        @{ query = $containersQuery; timespan = 'PT15M' } | ConvertTo-Json |
            Set-Content $containerFile -Encoding utf8
        $containerLogs = Invoke-Azure -Arguments @(
            'rest', '--subscription', $state.subscriptionId, '--method', 'post', '--uri', $uri,
            '--resource', 'https://api.loganalytics.io', '--body', "@$containerFile", '-o', 'json'
        ) | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $containerFile -Force
    }
    if ($containerLogs.PSObject.Properties['error']) {
        throw "Container log query returned an error: $($containerLogs.error | ConvertTo-Json -Depth 10)"
    }
    if ([long]$containerLogs.tables[0].rows[0][0] -eq 0) {
        throw 'No ContainerLogV2 records for this cluster/namespace in the last 15 minutes. Allow ingestion time, then inspect Container Insights and its data collection rule.'
    }
    Write-Host 'Log Analytics container log ingestion verified.'
    $alert = Invoke-Azure -Arguments @(
        'rest', '--subscription', $state.subscriptionId, '--method', 'get', '--uri',
        "https://management.azure.com$($state.alertId)?api-version=2023-12-01",
        '-o', 'json'
    ) | ConvertFrom-Json
    if (-not $alert.properties.enabled) {
        throw 'The HTTP 5XX alert rule exists but is disabled.'
    }
    Write-Host "Alert rule enabled: $($alert.name), severity=$($alert.properties.severity)"
    Write-Host 'Confirm the alert is Fired/Resolved in Azure Monitor > Alerts; querying the rule above does not verify that an alert instance fired.'
}
