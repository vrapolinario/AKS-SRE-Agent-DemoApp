#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('healthy', 'http500')][string]$Mode,
    [ValidateRange(30, 1800)][int]$TimeoutSeconds = 240
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$null = Read-Deployment
$patch = @{ data = @{ 'failure-mode' = $Mode } } | ConvertTo-Json -Compress
# Pass patch JSON through a file to avoid native argument quoting differences on Windows.
$patchFile = [IO.Path]::GetTempFileName()
try {
    Set-Content $patchFile -Value $patch -Encoding utf8
    Invoke-Kube -Arguments @(
        'patch', 'configmap', 'demo-settings', '-n', 'sre-demo', '--type=merge', '--patch-file', $patchFile
    )
}
finally {
    Remove-Item -LiteralPath $patchFile -Force
}

Write-Host "ConfigMap updated to '$Mode'. Waiting for projected-volume propagation; no pod restart is required..."
$url = Get-DemoUrl
$status = Wait-DemoMode -BaseUrl $url -Mode $Mode -TimeoutSeconds $TimeoutSeconds
$page = Invoke-WebRequest "$url/" -SkipHttpErrorCheck -TimeoutSec 15
if ([int]$page.StatusCode -ne $status.statusCode) {
    throw "Browser page returned HTTP $([int]$page.StatusCode), expected $($status.statusCode)."
}
Write-Host "Verified browser page and API: HTTP $($status.statusCode), mode=$($status.mode), pod=$($status.pod)"
Write-Host "Open or refresh: $url"
if ($Mode -eq 'http500') {
    Write-Host 'Traffic continues every two seconds. Allow several minutes for ingestion and the Azure Monitor alert.'
}
