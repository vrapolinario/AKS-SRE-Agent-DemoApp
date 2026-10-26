#Requires -Version 7.2
[CmdletBinding()]
param([string]$DotnetPath = 'dotnet')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\Common.ps1')
$project = Join-Path $root 'src\DemoWeb\DemoWeb.csproj'
& $DotnetPath build $project -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    throw 'Application build failed.'
}
$dll = Join-Path $root 'src\DemoWeb\bin\Release\net10.0\DemoWeb.dll'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "aks-sre-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary | Out-Null
$modeFile = Join-Path $temporary 'failure-mode'
Set-Content $modeFile healthy
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$url = "http://127.0.0.1:$port"
$process = [Diagnostics.Process]::new()
$process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName = (Get-Command $DotnetPath).Source
$process.StartInfo.ArgumentList.Add($dll)
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.StartInfo.Environment['ASPNETCORE_URLS'] = $url
$process.StartInfo.Environment['FAILURE_MODE_FILE'] = $modeFile
$process.StartInfo.Environment.Remove('APPLICATIONINSIGHTS_CONNECTION_STRING') | Out-Null
$script:Assertions = 0

function Assert-Equal($Expected, $Actual, [string]$Label) {
    if ($Expected -ne $Actual) {
        throw "$Label : expected '$Expected', got '$Actual'."
    }
    $script:Assertions++
}

function Assert-Mode([string]$Mode, [int]$Code) {
    $api = Invoke-WebRequest "$url/api/status" -SkipHttpErrorCheck -TimeoutSec 5
    $body = $api.Content | ConvertFrom-Json
    Assert-Equal $Code ([int]$api.StatusCode) 'API HTTP status'
    Assert-Equal $Code $body.statusCode 'JSON statusCode'
    Assert-Equal $Mode $body.mode 'JSON mode'
    Assert-Equal $true (-not [string]::IsNullOrWhiteSpace($body.traceId)) 'Trace ID present'
    Assert-Equal $true ($api.Headers['Cache-Control'] -contains 'no-store') 'API is not cached'
    $page = Invoke-WebRequest "$url/" -SkipHttpErrorCheck -TimeoutSec 5
    Assert-Equal $Code ([int]$page.StatusCode) 'Browser HTTP status'
    Assert-Equal $true ($page.Content -match "HTTP $Code") 'Browser shows status'
    Assert-Equal $true ($page.Content -match [regex]::Escape($Mode)) 'Browser shows mode'
    foreach ($path in @('/health/live', '/health/ready')) {
        $health = Invoke-WebRequest "$url$path" -SkipHttpErrorCheck -TimeoutSec 5
        Assert-Equal 200 ([int]$health.StatusCode) "$path remains healthy"
    }
}

$started = $false
$passed = $false
try {
    $started = $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($process.HasExited) {
            throw "Application exited during startup (exit $($process.ExitCode))."
        }
        try {
            $health = Invoke-WebRequest "$url/health/live" -TimeoutSec 1
            $ready = [int]$health.StatusCode -eq 200
        }
        catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException] {
            Write-Verbose "Waiting for app: $($_.Exception.Message)"
        }
        if ($ready) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { throw 'Application did not become responsive.' }

    Assert-Mode healthy 200
    $observed = Wait-DemoMode -BaseUrl $url -Mode healthy -TimeoutSeconds 30
    Assert-Equal healthy $observed.mode 'Deployment wait helper observes healthy'
    Set-Content $modeFile "http500`n"
    Assert-Mode http500 500
    $observed = Wait-DemoMode -BaseUrl $url -Mode http500 -TimeoutSeconds 30
    Assert-Equal http500 $observed.mode 'Deployment wait helper observes failure'
    Set-Content $modeFile healthy
    Assert-Mode healthy 200
    Set-Content $modeFile invalid-setting
    Assert-Mode configuration-error 500
    Set-Content $modeFile ''
    Assert-Mode configuration-error 500
    Remove-Item -LiteralPath $modeFile
    Assert-Mode configuration-error 500
    Set-Content $modeFile healthy
    Assert-Mode healthy 200
    Assert-Equal $false $process.HasExited 'Same process survives all changes'
    $passed = $true
}
finally {
    if ($started) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id
        }
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if (-not $passed) {
            Write-Host $output
            Write-Host $errors
        }
    }
    $process.Dispose()
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
Write-Host "PASS: $script:Assertions assertions; healthy -> HTTP 500 -> recovery, invalid/empty/missing configuration, browser HTML, JSON, probes, and no restart."
