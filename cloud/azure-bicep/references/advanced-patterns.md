# Advanced Azure Bicep Patterns

## Table of Contents
- [Deployment Scripts](#deployment-scripts)
- [Bicep Extensibility (Providers)](#bicep-extensibility-providers)
- [Private Module Registry](#private-module-registry)
- [Template Specs](#template-specs)
- [Deployment Stacks & Deny Settings](#deployment-stacks--deny-settings)
- [What-If Change Types](#what-if-change-types)
- [Cross-Scope Deployments](#cross-scope-deployments)
- [Managed Identity in Deployments](#managed-identity-in-deployments)
- [Custom Types with @discriminator](#custom-types-with-discriminator)
- [Bicep with Azure Services](#bicep-with-azure-services)

---

## Deployment Scripts

Run PowerShell or Azure CLI inside a deployment via `Microsoft.Resources/deploymentScripts`. Executes in an Azure Container Instance with managed identity.

```bicep
resource script 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'seedDatabase'
  location: location
  kind: 'AzureCLI'               // or 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentity.id}': {} }
  }
  properties: {
    azCliVersion: '2.52.0'       // pin CLI version
    retentionInterval: 'PT1H'    // cleanup after 1 hour
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'DB_CONN', secureValue: dbConnectionString }
    ]
    scriptContent: '''
      az sql db execute --name mydb --resource-group $RESOURCE_GROUP \
        --server myserver --query "INSERT INTO config VALUES('initialized', 'true')"
      echo '{"status":"complete"}' > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
}
// Access script outputs in other resources
output scriptResult string = script.properties.outputs.status
```

**Key properties:**
| Property | Purpose |
|---|---|
| `retentionInterval` | How long to keep the ACI + storage after completion (ISO 8601) |
| `timeout` | Max execution time (default PT1H) |
| `cleanupPreference` | `Always`, `OnSuccess`, `OnExpiration` |
| `forceUpdateTag` | Change to force re-execution (e.g., `utcNow()`) |
| `supportingScriptUris` | Array of URLs for additional scripts to download |
| `primaryScriptUri` | URL to main script instead of inline `scriptContent` |

**PowerShell variant:**
```bicep
resource psScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'createCert'
  location: location
  kind: 'AzurePowerShell'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${mi.id}': {} } }
  properties: {
    azPowerShellVersion: '11.0'
    retentionInterval: 'PT1H'
    scriptContent: '''
      $cert = New-SelfSignedCertificate -Subject "CN=myapp" -CertStoreLocation "Cert:\\CurrentUser\\My"
      $DeploymentScriptOutputs = @{ thumbprint = $cert.Thumbprint }
    '''
  }
}
```

---

## Bicep Extensibility (Providers)

Extensibility lets Bicep manage non-ARM resources (Kubernetes, Microsoft Graph). Enable in `bicepconfig.json`:

```json
{
  "experimentalFeaturesEnabled": {
    "extensibility": true
  }
}
```

### Kubernetes Provider
Deploy K8s manifests directly from Bicep:

```bicep
@secure()
param kubeConfig string

extension kubernetes with {
  namespace: 'default'
  kubeConfig: kubeConfig
} as k8s

resource deployment 'apps/Deployment@v1' = {
  metadata: { name: 'my-app', labels: { app: 'my-app' } }
  spec: {
    replicas: 3
    selector: { matchLabels: { app: 'my-app' } }
    template: {
      metadata: { labels: { app: 'my-app' } }
      spec: {
        containers: [
          { name: 'app', image: 'myacr.azurecr.io/app:latest', ports: [{ containerPort: 80 }] }
        ]
      }
    }
  }
}
```

### Microsoft Graph Provider
Manage Entra ID resources (groups, app registrations):

```bicep
extension microsoftGraph

resource appReg 'Microsoft.Graph/applications@v1.0' = {
  displayName: 'MyBicepApp'
  uniqueName: 'my-bicep-app'
}

resource group 'Microsoft.Graph/groups@v1.0' = {
  displayName: 'Platform Team'
  mailEnabled: false
  mailNickname: 'platform-team'
  securityEnabled: true
  uniqueName: 'platform-team'
}
```

Configure custom extension source in `bicepconfig.json`:
```json
{
  "extensions": {
    "microsoftGraphV1": "br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.9-preview"
  }
}
```

---

## Private Module Registry

Publish reusable modules to Azure Container Registry for org-wide sharing.

### Publish
```bash
# Publish module with semantic version
bicep publish modules/storage.bicep \
  --target br:myacr.azurecr.io/bicep/modules/storage:1.0.0

# Publish with documentation
bicep publish modules/storage.bicep \
  --target br:myacr.azurecr.io/bicep/modules/storage:1.0.0 \
  --documentation-uri https://wiki.example.com/storage-module
```

### Consume
```bicep
// Full registry path
module sa 'br:myacr.azurecr.io/bicep/modules/storage:1.0.0' = {
  name: 'storageDeploy'
  params: { name: 'mysa', sku: 'Standard_LRS' }
}

// Using alias (configured in bicepconfig.json)
module sa 'br/myregistry:modules/storage:1.0.0' = {
  name: 'storageDeploy'
  params: { name: 'mysa', sku: 'Standard_LRS' }
}

// Public Microsoft registry (Azure Verified Modules)
module vnet 'br/public:avm/res/network/virtual-network:0.4.0' = {
  name: 'vnetDeploy'
  params: { name: 'myVnet', addressPrefixes: ['10.0.0.0/16'] }
}
```

### Registry alias in bicepconfig.json
```json
{
  "moduleAliases": {
    "br": {
      "myregistry": {
        "registry": "myacr.azurecr.io",
        "modulePath": "bicep"
      }
    }
  }
}
```

---

## Template Specs

Store versioned templates in Azure as first-class resources.

```bash
# Create template spec
az ts create --name StorageSpec --version 1.0 \
  --resource-group specs-rg --location eastus \
  --template-file modules/storage.bicep

# List versions
az ts show --name StorageSpec --resource-group specs-rg --query "versions[].name"

# Deploy directly
az deployment group create --resource-group myRg \
  --template-spec "/subscriptions/{sub}/resourceGroups/specs-rg/providers/Microsoft.Resources/templateSpecs/StorageSpec/versions/1.0"
```

Consume in Bicep:
```bicep
module fromSpec 'ts:{subscriptionId}/specs-rg/StorageSpec:1.0' = {
  name: 'specDeploy'
  params: { location: 'eastus' }
}
```

Configure alias:
```json
{
  "moduleAliases": {
    "ts": {
      "myspecs": {
        "subscription": "00000000-0000-0000-0000-000000000000",
        "resourceGroup": "specs-rg"
      }
    }
  }
}
```

---

## Deployment Stacks & Deny Settings

Deployment stacks manage resources as an atomic unit with drift protection.

### Deny Settings Modes

| Mode | Effect |
|---|---|
| `none` | No restrictions |
| `denyDelete` | Block deletion of managed resources |
| `denyWriteAndDelete` | Block both modification and deletion |

### Action on Unmanage (resource removed from template)

| Value | Effect |
|---|---|
| `detachAll` | Resources remain in Azure, just unmanaged |
| `deleteResources` | Delete resources but keep resource groups |
| `deleteAll` | Delete resources AND resource groups |

### Full example
```bash
# Create stack at resource group scope
az stack group create \
  --name myAppStack \
  --resource-group myRg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --deny-settings-mode denyWriteAndDelete \
  --deny-settings-excluded-principals "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
  --deny-settings-excluded-actions "Microsoft.Compute/virtualMachines/write" \
  --action-on-unmanage deleteResources

# Create stack at subscription scope
az stack sub create \
  --name platformStack \
  --location eastus \
  --template-file platform.bicep \
  --deny-settings-mode denyDelete \
  --action-on-unmanage detachAll

# Create stack at management group scope
az stack mg create \
  --name policyStack \
  --management-group-id myMG \
  --location eastus \
  --template-file policies.bicep \
  --deny-settings-mode denyWriteAndDelete \
  --action-on-unmanage deleteAll

# Update existing stack
az stack group create --name myAppStack --resource-group myRg \
  --template-file main.bicep --parameters main.bicepparam \
  --deny-settings-mode denyDelete --action-on-unmanage detachAll

# List managed resources
az stack group show --name myAppStack --resource-group myRg \
  --query "resources[].id"

# Delete stack
az stack group delete --name myAppStack --resource-group myRg \
  --action-on-unmanage detachAll
```

**Exclusion limits:** Up to 5 `excludedPrincipals` and 200 `excludedActions`.

---

## What-If Change Types

The what-if operation returns these change types per resource:

| Change Type | Meaning |
|---|---|
| `Create` | Resource will be created (doesn't exist) |
| `Delete` | Resource will be deleted (exists, not in template) |
| `Modify` | Resource properties will change |
| `NoChange` | Resource exists and no properties differ |
| `Ignore` | Resource exists but isn't in template scope |
| `Deploy` | Resource will be redeployed (no property diff detectable) |

### Programmatic what-if
```bash
# Default: ResourceIdOnly format
az deployment group what-if -g myRg \
  --template-file main.bicep --parameters @params.json

# Full payload (shows property-level diffs)
az deployment group what-if -g myRg \
  --template-file main.bicep \
  --result-format FullResourcePayloads

# JSON output for CI parsing
az deployment group what-if -g myRg \
  --template-file main.bicep --no-pretty-print -o json

# Subscription scope
az deployment sub what-if --location eastus \
  --template-file sub.bicep

# CI gate: fail on deletes
result=$(az deployment group what-if -g myRg --template-file main.bicep -o json)
if echo "$result" | jq -e '.changes[] | select(.changeType == "Delete")' > /dev/null; then
  echo "BLOCKED: deployment would delete resources" && exit 1
fi
```

**Known false positives:** Read-only properties (e.g., `provisioningState`), computed values, and resources with `if` conditions may show spurious `Modify` diffs. Always review before acting on deletes.

---

## Cross-Scope Deployments

Orchestrate resources across scopes in a single deployment chain.

### Subscription → Resource Groups
```bicep
targetScope = 'subscription'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'app-rg'
  location: 'eastus'
}

resource networkRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'network-rg'
  location: 'eastus'
}

module app './modules/app.bicep' = {
  name: 'appDeploy'
  scope: rg
  params: { location: rg.location }
}

module network './modules/network.bicep' = {
  name: 'networkDeploy'
  scope: networkRg
  params: { location: networkRg.location }
}
```

### Management Group → Subscriptions → Resource Groups
```bicep
targetScope = 'managementGroup'

module subPolicy './modules/policy.bicep' = {
  name: 'policyDeploy'
  scope: subscription('sub-id-here')
}

module rgResources './modules/resources.bicep' = {
  name: 'resourcesDeploy'
  scope: resourceGroup('sub-id-here', 'my-rg')
}
```

### Tenant scope
```bicep
targetScope = 'tenant'

resource mg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: 'myMG'
  properties: { displayName: 'My Management Group' }
}

module subSetup './modules/subscription-setup.bicep' = {
  name: 'subSetup'
  scope: subscription('target-sub-id')
}
```

### Cross-resource-group references
```bicep
// Reference resources in another RG
resource remoteVnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'hub-vnet'
  scope: resourceGroup('network-sub-id', 'hub-rg')
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spokeVnet
  name: 'spoke-to-hub'
  properties: {
    remoteVirtualNetwork: { id: remoteVnet.id }
    allowForwardedTraffic: true
  }
}
```

---

## Managed Identity in Deployments

### User-assigned identity for deployment scripts
```bicep
resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'deploy-identity'
  location: location
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, mi.id, 'Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: mi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
```

### System-assigned identity on resources
```bicep
resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: { serverFarmId: plan.id }
}

// Grant Key Vault access using the system identity
resource kvPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: kv
  name: 'add'
  properties: {
    accessPolicies: [{
      tenantId: tenant().tenantId
      objectId: app.identity.principalId
      permissions: { secrets: ['get', 'list'] }
    }]
  }
}
```

---

## Custom Types with @discriminator

Build polymorphic configurations with compile-time validation.

```bicep
// Define discriminated union for different database types
@discriminator('type')
type databaseConfig = sqlConfig | cosmosConfig | postgresConfig

type sqlConfig = {
  type: 'sql'
  serverName: string
  databaseName: string
  sku: 'Basic' | 'S0' | 'S1' | 'P1'
}

type cosmosConfig = {
  type: 'cosmos'
  accountName: string
  consistencyLevel: 'Strong' | 'Session' | 'Eventual'
  enableMultiRegion: bool
}

type postgresConfig = {
  type: 'postgres'
  serverName: string
  version: '14' | '15' | '16'
  storageSizeGB: int
}

param databases databaseConfig[]

// Use in deployment logic
resource sqlServers 'Microsoft.Sql/servers@2023-08-01-preview' = [for db in filter(databases, d => d.type == 'sql'): {
  name: db.serverName
  location: location
  properties: { administratorLogin: 'sqladmin', administratorLoginPassword: sqlPassword }
}]
```

### Nested discriminated unions
```bicep
@discriminator('kind')
type notification = emailNotification | webhookNotification

type emailNotification = {
  kind: 'email'
  recipients: string[]
  subject: string
}

type webhookNotification = {
  kind: 'webhook'
  url: string
  headers: object?
}

@discriminator('severity')
type alert = criticalAlert | warningAlert

type criticalAlert = {
  severity: 'critical'
  notifications: notification[]  // nested union
  autoResolve: bool
}

type warningAlert = {
  severity: 'warning'
  notifications: notification[]
  silenceMinutes: int?
}
```

---

## Bicep with Azure Services

### AKS Cluster
```bicep
resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: aksName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: aksName
    enableRBAC: true
    networkProfile: { networkPlugin: 'azure', serviceCidr: '10.1.0.0/16', dnsServiceIP: '10.1.0.10' }
    agentPoolProfiles: [{
      name: 'system'
      count: 3
      vmSize: 'Standard_D4s_v5'
      mode: 'System'
      osType: 'Linux'
      vnetSubnetID: aksSubnet.id
      enableAutoScaling: true
      minCount: 1
      maxCount: 5
    }]
    autoUpgradeProfile: { upgradeChannel: 'stable' }
    addonProfiles: {
      omsagent: { enabled: true, config: { logAnalyticsWorkspaceResourceID: workspace.id } }
    }
  }
}
```

### App Service with slots
```bicep
resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: ai.properties.InstrumentationKey }
        { name: 'KeyVaultUri', value: kv.properties.vaultUri }
      ]
    }
  }
}

resource stagingSlot 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: app
  name: 'staging'
  location: location
  properties: { serverFarmId: plan.id }
}
```

### Azure Functions (Consumption)
```bicep
resource funcApp 'Microsoft.Web/sites@2023-12-01' = {
  name: funcName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: consumptionPlan.id
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${sa.name};AccountKey=${sa.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
      ]
    }
  }
}
```

### Azure SQL with firewall
```bicep
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: sqlAdminUser
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

resource db 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: dbName
  location: location
  sku: { name: 'S0', tier: 'Standard' }
  properties: { collation: 'SQL_Latin1_General_CP1_CI_AS', maxSizeBytes: 2147483648 }
}
```
