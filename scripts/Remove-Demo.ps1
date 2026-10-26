#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$NamePrefix = 'sredemo'
)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Command az
$group = Invoke-Azure -Arguments @(
    'group', 'show', '--subscription', $SubscriptionId, '--name', $ResourceGroup, '-o', 'json'
) | ConvertFrom-Json -AsHashtable
if (-not $group.tags -or $group.tags['project'] -ne 'aks-sre-demo' -or $group.tags['demoName'] -ne $NamePrefix) {
    throw 'Refusing deletion: the resource group is not tagged for this demo and prefix.'
}
if ($PSCmdlet.ShouldProcess("$SubscriptionId / $ResourceGroup", 'Delete the ENTIRE demo resource group, AKS managed node resources, and all monitoring data')) {
    Invoke-Azure -Arguments @(
        'group', 'delete', '--subscription', $SubscriptionId, '--name', $ResourceGroup, '--yes'
    )
    if (Test-Path $script:StateFile) {
        $state = Get-Content $script:StateFile -Raw | ConvertFrom-Json
        if ($state.subscriptionId -eq $SubscriptionId -and $state.resourceGroup -eq $ResourceGroup) {
            if (Test-Path $script:Kubeconfig) {
                Remove-Item -LiteralPath $script:Kubeconfig -Force
            }
            Remove-Item -LiteralPath $script:StateFile -Force
        }
    }
    Write-Host 'Demo deletion completed. Check Azure for any retained resources or soft-deleted monitoring data.'
}
