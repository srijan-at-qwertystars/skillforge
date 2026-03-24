# Common Azure Resource Bicep Patterns

## Table of Contents
- [Storage Account](#storage-account)
- [App Service + Plan](#app-service--plan)
- [Azure SQL](#azure-sql)
- [Key Vault](#key-vault)
- [Virtual Network](#virtual-network)
- [Container Registry](#container-registry)
- [AKS Cluster](#aks-cluster)
- [Function App](#function-app)
- [Cosmos DB](#cosmos-db)
- [Application Insights](#application-insights)

---

## Storage Account

```bicep
@description('Storage account name prefix')
@minLength(3) @maxLength(11)
param storagePrefix string

@description('Storage SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS', 'Premium_LRS'])
param storageSku string = 'Standard_LRS'

param location string = resourceGroup().location
param enableBlobVersioning bool = false

var storageName = '${storagePrefix}${uniqueString(resourceGroup().id)}'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: { name: storageSku }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }

  resource blobSvc 'blobServices' = {
    name: 'default'
    properties: {
      isVersioningEnabled: enableBlobVersioning
      deleteRetentionPolicy: { enabled: true, days: 7 }
      containerDeleteRetentionPolicy: { enabled: true, days: 7 }
    }

    resource dataContainer 'containers' = {
      name: 'data'
      properties: { publicAccess: 'None' }
    }
  }
}

output storageId string = sa.id
output storageName string = sa.name
output blobEndpoint string = sa.properties.primaryEndpoints.blob
output primaryKey string = sa.listKeys().keys[0].value
```

**Key points:**
- Always set `minimumTlsVersion: 'TLS1_2'`, `supportsHttpsTrafficOnly: true`
- Use `allowBlobPublicAccess: false` unless public access is required
- Enable soft delete for production workloads
- Use `networkAcls` for firewall rules; `bypass: 'AzureServices'` allows Azure-internal access

---

## App Service + Plan

```bicep
@description('App name (globally unique)')
param appName string

@allowed(['F1', 'B1', 'B2', 'S1', 'P1v2', 'P2v3'])
param skuName string = 'P1v2'

@allowed(['dotnet', 'node', 'python', 'java'])
param runtime string = 'dotnet'

param location string = resourceGroup().location

var runtimeMap = {
  dotnet: { linuxFxVersion: 'DOTNETCORE|8.0', workerRuntime: 'dotnet-isolated' }
  node: { linuxFxVersion: 'NODE|20-lts', workerRuntime: 'node' }
  python: { linuxFxVersion: 'PYTHON|3.12', workerRuntime: 'python' }
  java: { linuxFxVersion: 'JAVA|17-java17', workerRuntime: 'java' }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${appName}-plan'
  location: location
  kind: 'linux'
  sku: { name: skuName }
  properties: { reserved: true }    // required for Linux
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: runtimeMap[runtime].linuxFxVersion
      alwaysOn: skuName != 'F1'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
      ]
    }
  }
}

resource stagingSlot 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: app
  name: 'staging'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: runtimeMap[runtime].linuxFxVersion
      autoSwapSlotName: 'production'
    }
  }
}

resource appDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'appDiag'
  scope: app
  properties: {
    logs: [{ category: 'AppServiceHTTPLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
    workspaceId: logAnalyticsWorkspaceId
  }
}

output appUrl string = 'https://${app.properties.defaultHostName}'
output appIdentityPrincipalId string = app.identity.principalId
```

---

## Azure SQL

```bicep
@description('SQL Server name')
param sqlServerName string

@description('Database name')
param databaseName string = 'appdb'

@secure()
param adminLogin string

@secure()
param adminPassword string

@allowed(['Basic', 'S0', 'S1', 'S2', 'P1', 'P2'])
param dbSku string = 'S0'

param location string = resourceGroup().location
param allowAzureServices bool = true

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: { name: dbSku, tier: dbSku == 'Basic' ? 'Basic' : (startsWith(dbSku, 'P') ? 'Premium' : 'Standard') }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648    // 2GB
    zoneRedundant: startsWith(dbSku, 'P')
    requestedBackupStorageRedundancy: 'Local'
  }
}

resource allowAzureFw 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (allowAzureServices) {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource auditSettings 'Microsoft.Sql/servers/auditingSettings@2023-08-01-preview' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    retentionDays: 90
  }
}

resource tde 'Microsoft.Sql/servers/databases/transparentDataEncryption@2023-08-01-preview' = {
  parent: sqlDb
  name: 'current'
  properties: { state: 'Enabled' }
}

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output connectionString string = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${databaseName};Encrypt=true;'
```

---

## Key Vault

```bicep
@description('Key Vault name')
param kvName string

param location string = resourceGroup().location
param enablePurgeProtection bool = true

@description('Object IDs of principals to grant access')
param accessPolicies array = []

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null
    enableRbacAuthorization: true     // prefer RBAC over access policies
    enabledForDeployment: false
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: false
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Example: store a secret
resource dbSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'DatabasePassword'
  properties: {
    value: databasePassword
    attributes: { enabled: true }
    contentType: 'text/plain'
  }
}

// RBAC-based access (preferred over access policies)
resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in accessPolicies: {
  name: guid(kv.id, principalId, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets Officer
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

output kvUri string = kv.properties.vaultUri
output kvId string = kv.id
```

**Key points:**
- Prefer `enableRbacAuthorization: true` over access policies for new vaults
- Always enable soft delete and purge protection for production
- Use `enabledForTemplateDeployment: true` if Bicep references secrets

---

## Virtual Network

```bicep
@description('VNet name')
param vnetName string = 'main-vnet'

param location string = resourceGroup().location
param addressPrefix string = '10.0.0.0/16'

@description('Subnet configurations')
param subnets array = [
  { name: 'web',      prefix: '10.0.1.0/24',  nsg: true,  serviceEndpoints: ['Microsoft.Storage'] }
  { name: 'app',      prefix: '10.0.2.0/24',  nsg: true,  serviceEndpoints: ['Microsoft.Sql', 'Microsoft.KeyVault'] }
  { name: 'data',     prefix: '10.0.3.0/24',  nsg: true,  serviceEndpoints: ['Microsoft.Sql'] }
  { name: 'AzureBastionSubnet', prefix: '10.0.255.0/26', nsg: false, serviceEndpoints: [] }
]

resource nsgs 'Microsoft.Network/networkSecurityGroups@2023-11-01' = [for s in subnets: if (s.nsg) {
  name: '${vnetName}-${s.name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [for (s, i) in subnets: {
      name: s.name
      properties: {
        addressPrefix: s.prefix
        networkSecurityGroup: s.nsg ? { id: nsgs[i].id } : null
        serviceEndpoints: [for ep in s.serviceEndpoints: { service: ep }]
        privateEndpointNetworkPolicies: 'Enabled'
      }
    }]
  }
}

output vnetId string = vnet.id
output subnetIds object = reduce(subnets, {}, (acc, s, i) => union(acc, { '${s.name}': vnet.properties.subnets[i].id }))
```

---

## Container Registry

```bicep
@description('Registry name (globally unique, alphanumeric)')
@minLength(5) @maxLength(50)
param acrName string

@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string = 'Premium'

param location string = resourceGroup().location
param enableAdminUser bool = false

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: acrSku }
  properties: {
    adminUserEnabled: enableAdminUser
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: acrSku == 'Premium' ? 'Enabled' : 'Disabled'
    policies: {
      retentionPolicy: acrSku == 'Premium' ? { status: 'enabled', days: 30 } : null
      trustPolicy: acrSku == 'Premium' ? { type: 'Notary', status: 'enabled' } : null
    }
    encryption: acrSku == 'Premium' ? { status: 'disabled' } : null
  }
}

// Geo-replication (Premium only)
resource acrReplication 'Microsoft.ContainerRegistry/registries/replications@2023-11-01-preview' = if (acrSku == 'Premium') {
  parent: acr
  name: 'westeurope'
  location: 'westeurope'
  properties: { zoneRedundancy: 'Enabled' }
}

// RBAC: Grant AKS identity AcrPull
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aksPrincipalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: aksPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output acrLoginServer string = acr.properties.loginServer
output acrId string = acr.id
```

---

## AKS Cluster

```bicep
@description('AKS cluster name')
param aksName string

param location string = resourceGroup().location
param nodeCount int = 3
param nodeVmSize string = 'Standard_D4s_v5'

@secure()
param sshPublicKey string

param kubernetesVersion string = '1.29'

resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: aksName
  location: location
  identity: { type: 'SystemAssigned' }
  sku: { name: 'Base', tier: 'Standard' }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: aksName
    enableRBAC: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      serviceCidr: '10.1.0.0/16'
      dnsServiceIP: '10.1.0.10'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeVmSize
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        enableAutoScaling: true
        minCount: 1
        maxCount: 5
        availabilityZones: ['1', '2', '3']
        vnetSubnetID: aksSubnetId
      }
    ]
    linuxProfile: {
      adminUsername: 'azureuser'
      ssh: { publicKeys: [{ keyData: sshPublicKey }] }
    }
    autoUpgradeProfile: { upgradeChannel: 'stable' }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: workspaceId }
      }
      azurepolicy: { enabled: true }
    }
    autoScalerProfile: {
      scaleDownDelayAfterAdd: '15m'
      scaleDownUnreadyTime: '20m'
      scanInterval: '10s'
    }
  }
}

// User node pool
resource userPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-01-01' = {
  parent: aks
  name: 'userpool'
  properties: {
    count: 2
    vmSize: 'Standard_D8s_v5'
    mode: 'User'
    osType: 'Linux'
    enableAutoScaling: true
    minCount: 0
    maxCount: 10
    availabilityZones: ['1', '2', '3']
    vnetSubnetID: aksSubnetId
    nodeTaints: []
    nodeLabels: { workload: 'user' }
  }
}

output aksClusterName string = aks.name
output aksClusterFqdn string = aks.properties.fqdn
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
```

---

## Function App

```bicep
@description('Function app name')
param funcName string

@allowed(['dotnet-isolated', 'node', 'python', 'java', 'powershell'])
param runtime string = 'dotnet-isolated'

param location string = resourceGroup().location

resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${replace(funcName, '-', '')}st'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: { supportsHttpsTrafficOnly: true, minimumTlsVersion: 'TLS1_2' }
}

resource consumptionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${funcName}-plan'
  location: location
  kind: 'functionapp'
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: true }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: '${funcName}-ai'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web' }
}

resource funcApp 'Microsoft.Web/sites@2023-12-01' = {
  name: funcName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: consumptionPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: runtime == 'dotnet-isolated' ? 'DOTNET-ISOLATED|8.0' : (runtime == 'node' ? 'NODE|20' : (runtime == 'python' ? 'PYTHON|3.11' : ''))
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${funcStorage.listKeys().keys[0].value}' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${funcStorage.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: runtime }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
      ]
    }
  }
}

output funcAppUrl string = 'https://${funcApp.properties.defaultHostName}'
output funcAppIdentity string = funcApp.identity.principalId
```

---

## Cosmos DB

```bicep
@description('Cosmos DB account name')
param cosmosName string

@allowed(['Strong', 'BoundedStaleness', 'Session', 'ConsistentPrefix', 'Eventual'])
param consistencyLevel string = 'Session'

param location string = resourceGroup().location
param enableFreeTier bool = false
param databaseName string = 'appdb'
param containerName string = 'items'
param partitionKeyPath string = '/partitionKey'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: enableFreeTier
    consistencyPolicy: {
      defaultConsistencyLevel: consistencyLevel
      maxStalenessPrefix: consistencyLevel == 'BoundedStaleness' ? 100000 : null
      maxIntervalInSeconds: consistencyLevel == 'BoundedStaleness' ? 300 : null
    }
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: true }
    ]
    capabilities: []
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: { tier: 'Continuous7Days' }
    }
    enableAutomaticFailover: true
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: 'Tls12'
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: cosmos
  name: databaseName
  properties: {
    resource: { id: databaseName }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: { paths: [partitionKeyPath], kind: 'Hash', version: 2 }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [{ path: '/*' }]
        excludedPaths: [{ path: '/_etag/?' }]
      }
      defaultTtl: -1     // enable TTL without default expiry
    }
    options: { throughput: 400 }
  }
}

output cosmosEndpoint string = cosmos.properties.documentEndpoint
output cosmosId string = cosmos.id
output primaryKey string = cosmos.listKeys().primaryMasterKey
```

---

## Application Insights

```bicep
@description('Application Insights name')
param aiName string

param location string = resourceGroup().location
param dailyCapGb int = 1
param retentionDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${aiName}-workspace'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: retentionDays
  }
}

// Daily cap
resource aiDailyCap 'Microsoft.Insights/components/CurrentBillingFeatures@2015-05-01' = {
  name: '${ai.name}/Basic'
  properties: {
    CurrentBillingFeatures: ['Basic']
    DataVolumeCap: { Cap: dailyCapGb, ResetTime: 0, WarningThreshold: 80 }
  }
}

// Availability test (URL ping)
resource pingTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: '${aiName}-ping'
  location: location
  kind: 'ping'
  tags: { 'hidden-link:${ai.id}': 'Resource' }
  properties: {
    SyntheticMonitorId: '${aiName}-ping'
    Name: 'Health Check'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'ping'
    Locations: [
      { Id: 'us-va-ash-azr' }
      { Id: 'emea-nl-ams-azr' }
    ]
    Configuration: {
      WebTest: '<WebTest Name="HealthCheck" Url="https://myapp.azurewebsites.net/health" Timeout="30" />'
    }
  }
}

// Alert rule
resource failureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${aiName}-failure-alert'
  location: 'global'
  properties: {
    severity: 2
    enabled: true
    scopes: [ai.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'FailedRequests'
        metricName: 'requests/failed'
        metricNamespace: 'microsoft.insights/components'
        operator: 'GreaterThan'
        threshold: 5
        timeAggregation: 'Count'
        criterionType: 'StaticThresholdCriterion'
      }]
    }
  }
}

output aiConnectionString string = ai.properties.ConnectionString
output aiInstrumentationKey string = ai.properties.InstrumentationKey
output workspaceId string = workspace.id
```
