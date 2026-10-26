targetScope = 'resourceGroup'

@description('Short lowercase prefix. Resource names also include a deterministic unique suffix.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'sredemo'

param location string = resourceGroup().location

@minValue(2)
@maxValue(5)
param nodeCount int = 2

param nodeVmSize string = 'Standard_D4s_v5'

@description('Empty means the current AKS default supported version.')
param kubernetesVersion string = ''

@description('Minimum HTTP 5XX requests in the five-minute window that fires the alert.')
@minValue(1)
param alertThreshold int = 5

var suffix = uniqueString(resourceGroup().id, namePrefix)
var tags = {
  project: 'aks-sre-demo'
  purpose: 'Disposable demonstration, not production'
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appi-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${namePrefix}${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: '${namePrefix}-aks-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${namePrefix}-${suffix}'
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    disableLocalAccounts: false
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        osDiskSizeGB: 64
        osDiskType: 'Managed'
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      podCidr: '10.244.0.0/16'
    }
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, aks.id, 'AcrPull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource http5xxAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-http5xx'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'AKS demo - HTTP 5XX application failures'
    description: 'Investigate AKS deployment sre-demo/demo-web, ConfigMap demo-settings key failure-mode, AppRequests, AppTraces, and ContainerLogV2. Restore failure-mode to healthy after diagnosis.'
    enabled: true
    severity: 1
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      workspace.id
    ]
    targetResourceTypes: [
      'Microsoft.Insights/components'
    ]
    autoMitigate: true
    // A fresh workspace has no AppRequests table until its first telemetry arrives.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: replace('''
            AppRequests
            | where _ResourceId =~ '__APPLICATION_INSIGHTS_ID__'
            | where AppRoleName == "aks-sre-demo"
            | where toint(ResultCode) between (500 .. 599)
            | project TimeGenerated, _ResourceId
            ''', '__APPLICATION_INSIGHTS_ID__', appInsights.id)
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: alertThreshold
          resourceIdColumn: '_ResourceId'
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: []
      customProperties: {
        aksResourceId: aks.id
        namespace: 'sre-demo'
        deployment: 'demo-web'
        configMap: 'demo-settings'
      }
    }
  }
}

output aksName string = aks.name
output aksId string = aks.id
output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output applicationInsightsId string = appInsights.id
output alertId string = http5xxAlert.id
