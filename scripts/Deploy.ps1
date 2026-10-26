#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,80}$')][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$NamePrefix = 'sredemo',
    [ValidateRange(2, 5)][int]$NodeCount = 2,
    [string]$NodeVmSize = 'Standard_D4s_v5',
    [string]$KubernetesVersion = '',
    [ValidateRange(1, 100000)][int]$AlertThreshold = 5
)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Command az
Assert-Command kubectl
Invoke-Azure -Arguments @('account', 'show', '--subscription', $SubscriptionId, '-o', 'none')
Invoke-Azure -Arguments @('bicep', 'version')

if (Test-Path $script:StateFile) {
    $previous = Get-Content $script:StateFile -Raw | ConvertFrom-Json
    if ($previous.subscriptionId -ne $SubscriptionId -or $previous.resourceGroup -ne $ResourceGroup) {
        throw 'This directory already contains state for a different deployment. Use a separate copy of the project for each active deployment.'
    }
}

$groupExists = Invoke-Azure -Arguments @(
    'group', 'exists', '--subscription', $SubscriptionId, '--name', $ResourceGroup, '-o', 'tsv'
)
if ($groupExists -eq 'true') {
    $group = Invoke-Azure -Arguments @(
        'group', 'show', '--subscription', $SubscriptionId, '--name', $ResourceGroup, '-o', 'json'
    ) | ConvertFrom-Json -AsHashtable
    if (-not $group.tags -or $group.tags['project'] -ne 'aks-sre-demo' -or $group.tags['demoName'] -ne $NamePrefix) {
        throw 'Use a new dedicated resource group. This existing group is not owned by this demo/prefix.'
    }
}
else {
    Invoke-Azure -Arguments @(
        'group', 'create', '--subscription', $SubscriptionId, '--name', $ResourceGroup,
        '--location', $Location, '--tags', 'project=aks-sre-demo', "demoName=$NamePrefix", '-o', 'none'
    )
}

foreach ($provider in @(
    'Microsoft.ContainerService', 'Microsoft.ContainerRegistry', 'Microsoft.OperationalInsights',
    'Microsoft.Insights', 'Microsoft.AlertsManagement', 'Microsoft.Monitor',
    'Microsoft.ManagedIdentity', 'Microsoft.Compute', 'Microsoft.Network'
)) {
    Invoke-Azure -Arguments @(
        'provider', 'register', '--subscription', $SubscriptionId, '--namespace', $provider, '--wait', '-o', 'none'
    )
}

Write-Host 'Deploying AKS, registry, Log Analytics, Application Insights, and HTTP 5XX alert...'
$deployment = Invoke-Azure -Arguments @(
    'deployment', 'group', 'create', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
    '--name', 'aks-sre-demo', '--template-file', (Join-Path $script:ProjectRoot 'infra\main.bicep'),
    '--parameters', "namePrefix=$NamePrefix", "location=$Location", "nodeCount=$NodeCount",
    "nodeVmSize=$NodeVmSize", "kubernetesVersion=$KubernetesVersion", "alertThreshold=$AlertThreshold",
    '--query', 'properties.outputs', '-o', 'json'
) | ConvertFrom-Json

Enable-DemoMonitoring -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -ClusterName $deployment.aksName.value -WorkspaceId $deployment.workspaceId.value

$imageTag = 'demo-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss') + '-' +
    [guid]::NewGuid().ToString('N').Substring(0, 8)
$image = "$($deployment.registryLoginServer.value)/demo-web:$imageTag"
Write-Host "Building $image in Azure Container Registry (no local Docker required)..."
Invoke-Azure -Arguments @(
    'acr', 'build', '--subscription', $SubscriptionId, '--registry', $deployment.registryName.value,
    '--image', "demo-web:$imageTag", '--platform', 'linux/amd64',
    '--file', (Join-Path $script:ProjectRoot 'Dockerfile'), $script:ProjectRoot
)

New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
Invoke-Azure -Arguments @(
    'aks', 'get-credentials', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
    '--name', $deployment.aksName.value, '--admin', '--file', $script:Kubeconfig, '--overwrite-existing'
)
$state = [ordered]@{
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroup
    location = $Location
    aksName = $deployment.aksName.value
    aksId = $deployment.aksId.value
    workspaceId = $deployment.workspaceId.value
    workspaceCustomerId = $deployment.workspaceCustomerId.value
    applicationInsightsId = $deployment.applicationInsightsId.value
    alertId = $deployment.alertId.value
    registryName = $deployment.registryName.value
    image = $image
}
$state | ConvertTo-Json | Set-Content $script:StateFile -Encoding utf8

Invoke-Kube -Arguments @('apply', '-f', (Join-Path $script:ProjectRoot 'k8s\namespace.yaml'))
Invoke-Kube -Arguments @('apply', '-f', (Join-Path $script:ProjectRoot 'k8s\configmap.yaml'))
$connectionString = Invoke-Azure -Arguments @(
    'resource', 'show', '--subscription', $SubscriptionId, '--ids', $deployment.applicationInsightsId.value,
    '--api-version', '2020-02-02', '--query', 'properties.ConnectionString', '-o', 'tsv'
)
if ([string]::IsNullOrWhiteSpace($connectionString)) {
    throw 'Application Insights returned an empty connection string. Refusing to deploy without telemetry.'
}
$secret = @{
    apiVersion = 'v1'
    kind = 'Secret'
    metadata = @{ name = 'demo-telemetry'; namespace = 'sre-demo' }
    type = 'Opaque'
    stringData = @{ 'connection-string' = $connectionString }
} | ConvertTo-Json -Depth 5
Invoke-Kube -Arguments @('apply', '--server-side', '--field-manager=demo-deploy', '-f', '-') -InputText $secret
Remove-Variable secret, connectionString

$manifest = (Get-Content (Join-Path $script:ProjectRoot 'k8s\app.yaml') -Raw).Replace('__APP_IMAGE__', $image)
Invoke-Kube -Arguments @('apply', '-f', '-') -InputText $manifest
Invoke-Kube -Arguments @('apply', '-f', (Join-Path $script:ProjectRoot 'k8s\traffic.yaml'))
Invoke-Kube -Arguments @('rollout', 'status', 'deployment/demo-web', '-n', 'sre-demo', '--timeout=600s')
Invoke-Kube -Arguments @('rollout', 'status', 'deployment/demo-traffic', '-n', 'sre-demo', '--timeout=180s')

Write-Host 'Waiting for the public LoadBalancer IP...'
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
$endpoint = ''
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $ip = Invoke-Kube -Arguments @(
        'get', 'service', 'demo-web', '-n', 'sre-demo',
        '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}'
    )
    if (-not [string]::IsNullOrWhiteSpace($ip)) {
        $endpoint = "http://$ip"
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $endpoint) {
    throw 'Timed out waiting for a public IP. Inspect kubectl describe service demo-web -n sre-demo using .state\kubeconfig.'
}
$status = Wait-DemoMode -BaseUrl $endpoint -Mode healthy
$page = Invoke-WebRequest "$endpoint/" -TimeoutSec 15
if ([int]$page.StatusCode -ne 200 -or $page.Content -notmatch 'All systems operational') {
    throw 'The JSON endpoint is healthy, but the browser page did not pass its HTTP 200/content check.'
}
Write-Host "`nDeployment verified: HTTP $($status.statusCode), mode=$($status.mode)"
Write-Host "Open: $endpoint"
Write-Host "Failure: .\scripts\Set-FailureMode.ps1 -Mode http500"
Write-Host "Recovery: .\scripts\Set-FailureMode.ps1 -Mode healthy"
Write-Host "Verify telemetry before recording: .\scripts\Test-Demo.ps1 -CheckTelemetry"
Write-Host "Dedicated kubeconfig: $script:Kubeconfig (your default context was not changed)"
