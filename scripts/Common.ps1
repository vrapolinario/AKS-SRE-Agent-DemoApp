#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$script:StateDirectory = Join-Path $script:ProjectRoot '.state'
$script:StateFile = Join-Path $script:StateDirectory 'deployment.json'
$script:Kubeconfig = Join-Path $script:StateDirectory 'kubeconfig'

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or is not on PATH. See README.md."
    }
}

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    return $result
}

function Enable-DemoMonitoring {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$WorkspaceId
    )
    $monitoring = Invoke-Azure -Arguments @(
        'aks', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
        '--name', $ClusterName, '--query', 'addonProfiles.omsagent', '-o', 'json'
    ) | ConvertFrom-Json -AsHashtable

    if ($monitoring -and $monitoring['enabled'] -eq $true) {
        $config = $monitoring['config']
        if (-not $config -or $config['logAnalyticsWorkspaceResourceID'] -ine $WorkspaceId) {
            throw "Container Insights is already enabled with a different or missing workspace configuration. Expected '$WorkspaceId'. Inspect addonProfiles.omsagent before changing it; this script will not disable existing monitoring."
        }
        if ($config['useAADAuth'] -ine 'true') {
            throw 'Container Insights is already enabled without managed-identity authentication. Migrate its configuration explicitly before rerunning; this script will not disable existing monitoring.'
        }
        Write-Host 'Container Insights already uses the expected workspace and managed identity; skipping enablement.'
        return
    }

    Write-Host 'Enabling managed-identity Container Insights (including log collection)...'
    Invoke-Azure -Arguments @(
        'aks', 'update', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup,
        '--name', $ClusterName, '--enable-azure-monitor-logs',
        '--workspace-resource-id', $WorkspaceId, '-o', 'none'
    )
}

function Invoke-Kube {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText
    )
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $result = $InputText | & kubectl --kubeconfig $script:Kubeconfig @Arguments
    }
    else {
        $result = & kubectl --kubeconfig $script:Kubeconfig @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed (exit $LASTEXITCODE): kubectl $($Arguments -join ' ')"
    }
    return $result
}

function Read-Deployment {
    Assert-Command kubectl
    if (-not (Test-Path $script:StateFile) -or -not (Test-Path $script:Kubeconfig)) {
        throw 'Deployment state or dedicated kubeconfig is missing. Run scripts\Deploy.ps1 first.'
    }
    return Get-Content $script:StateFile -Raw | ConvertFrom-Json
}

function Get-DemoUrl {
    $service = Invoke-Kube -Arguments @('get', 'service', 'demo-web', '-n', 'sre-demo', '-o', 'json') |
        ConvertFrom-Json
    $ingress = @($service.status.loadBalancer.ingress)
    if ($ingress.Count -eq 0) {
        throw 'The LoadBalancer does not have a public endpoint yet.'
    }
    $ipProperty = $ingress[0].PSObject.Properties['ip']
    if ($ipProperty -and $ipProperty.Value) {
        return "http://$($ipProperty.Value)"
    }
    $hostProperty = $ingress[0].PSObject.Properties['hostname']
    if ($hostProperty -and $hostProperty.Value) {
        return "http://$($hostProperty.Value)"
    }
    throw 'The LoadBalancer ingress has neither an IP address nor a hostname.'
}

function Wait-DemoMode {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][ValidateSet('healthy', 'http500')][string]$Mode,
        [int]$TimeoutSeconds = 240
    )
    $expectedCode = if ($Mode -eq 'healthy') { 200 } else { 500 }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $consecutive = 0
    $lastObservation = 'No response received'
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-WebRequest "$BaseUrl/api/status" -SkipHttpErrorCheck -TimeoutSec 10
            $status = $response.Content | ConvertFrom-Json
            $lastObservation = "HTTP $([int]$response.StatusCode), mode=$($status.mode)"
            if ([int]$response.StatusCode -eq $expectedCode -and $status.mode -eq $Mode) {
                $consecutive++
                if ($consecutive -ge 3) {
                    return $status
                }
            }
            else {
                $consecutive = 0
            }
        }
        catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException] {
            $consecutive = 0
            $lastObservation = $_.Exception.Message
            Write-Warning "Waiting for endpoint: $lastObservation"
        }
        Start-Sleep -Seconds 3
    }
    throw "Timed out waiting for mode=$Mode and HTTP $expectedCode. Last observation: $lastObservation"
}
