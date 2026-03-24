---
name: azure-bicep
description: >
  Azure Bicep infrastructure-as-code skill. Covers Bicep syntax (resources, params, variables, outputs,
  modules), types (string, int, bool, array, object, union, discriminated unions), decorators (@description,
  @minLength, @secure, @allowed, @export), conditional deployment, loops, existing/child/extension resources,
  modules (local, registry, template specs), deployment scopes (resourceGroup, subscription, managementGroup,
  tenant), deployment stacks, what-if, linting, user-defined types/functions, .bicepparam files, import/export,
  Bicep CLI, ARM migration, testing, CI/CD. Triggers: "Bicep", "Azure IaC", "ARM template", "Azure deployment",
  ".bicep file", "deployment stack". NOT for Terraform, NOT for Pulumi, NOT for AWS CloudFormation,
  NOT for Azure CLI scripting without IaC, NOT for plain ARM JSON authoring.
---

# Azure Bicep Skill Reference

## File Structure

```bicep
metadata description = 'Deploy web app with storage'
targetScope = 'resourceGroup' // resourceGroup | subscription | managementGroup | tenant
@description('Environment') @allowed(['dev', 'staging', 'prod'])
param environment string
var location = resourceGroup().location
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = { name: 'mysa', location: location, sku: { name: 'Standard_LRS' }, kind: 'StorageV2' }
module network './modules/network.bicep' = { name: 'netDeploy', params: { location: location } }
output storageId string = sa.id
```

## Parameters

```bicep
@description('Prefix') @minLength(3) @maxLength(11)
param storagePrefix string
@allowed(['Standard_LRS', 'Standard_GRS', 'Premium_LRS'])
param skuName string = 'Standard_LRS'
@secure() param adminPassword string
param tags object = { env: 'dev' }
param subnetNames array
param enableDiag bool = false
param count int = 2
```

Types: `string`, `int`, `bool`, `array`, `object`, user-defined types. Use `@secure()` for secrets — never set defaults on secure params.

## Variables

```bicep
var uniqueName = '${storagePrefix}${uniqueString(resourceGroup().id)}'
var tags = union(baseTags, { lastDeployed: utcNow() })
```

## Resources

```bicep
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: uniqueName
  location: location
  kind: 'StorageV2'
  sku: { name: skuName }
  properties: { supportsHttpsTrafficOnly: true, minimumTlsVersion: 'TLS1_2' }
}
```

Always pin API versions. Prefer interpolation `'${x}-${y}'` over `concat()`.

### Existing Resources — reference without deploying

```bicep
resource existingVnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = { name: 'myVnet' }
resource remoteKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'myKv'
  scope: resourceGroup('other-rg')
}
```

### Child Resources — nested or parent property

```bicep
// Nested
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'mystorage'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  resource blobSvc 'blobServices' = {
    name: 'default'
    resource container 'containers' = { name: 'data' }
  }
}
// Parent property
resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}
```

### Extension Resources — attach to another resource via `scope`

```bicep
resource lock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'doNotDelete'
  scope: sa
  properties: { level: 'CanNotDelete' }
}
```

## Outputs

```bicep
output storageId string = sa.id
output blobEndpoint string = sa.properties.primaryEndpoints.blob
output endpoints object = sa.properties.primaryEndpoints
```

## Conditional Deployment

```bicep
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDiag) {
  name: 'diagSetting'
  scope: sa
  properties: { /* ... */ }
}
output diagId string = enableDiag ? diag.id : 'not-deployed'
```

## Loops

```bicep
// Array loop
resource stores 'Microsoft.Storage/storageAccounts@2023-05-01' = [for name in storageNames: {
  name: '${name}${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
}]
// Index loop
resource subnets 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = [for (name, i) in subnetNames: {
  name: name
  properties: { addressPrefix: '10.0.${i}.0/24' }
}]
// Loop + condition
resource prodStores 'Microsoft.Storage/storageAccounts@2023-05-01' = [for n in names: if (env == 'prod') {
  name: n
  location: location
  kind: 'StorageV2'
  sku: { name: 'Premium_LRS' }
}]
// Property loop
var subnetConfigs = [for (name, i) in subnetNames: { name: name, properties: { addressPrefix: '10.0.${i}.0/24' } }]
```

## Modules

### Local
```bicep
module vnet './modules/vnet.bicep' = {
  name: 'vnetDeploy'
  params: { location: location, vnetName: 'myVnet' }
}
output vnetId string = vnet.outputs.vnetId
```

### Registry (ACR)
```bicep
module app 'br:myacr.azurecr.io/bicep/modules/appservice:1.0.0' = {
  name: 'appDeploy'
  params: { appName: 'myapp', location: location }
}
module cosmos 'br/public:avm/res/document-db/database-account:0.8.1' = {
  name: 'cosmosDeploy'
  params: { name: 'mycosmosdb' }
}
```

### Template Specs
```bicep
module spec 'ts:00000000-0000-0000-0000-000000000000/myRg/mySpec:1.0' = {
  name: 'specDeploy'
  params: { location: location }
}
```

### Cross-Scope
```bicep
module crossRg './modules/storage.bicep' = {
  name: 'crossRgDeploy'
  scope: resourceGroup('other-sub-id', 'other-rg')
  params: { location: 'eastus' }
}
```

## Deployment Scopes

```bicep
targetScope = 'subscription'
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = { name: 'myRg', location: 'eastus' }
module rgDeploy './main.bicep' = { name: 'rgResources', scope: rg, params: { location: rg.location } }
```

Scopes: `resourceGroup` (default), `subscription`, `managementGroup`, `tenant`.

## User-Defined Types

```bicep
@export()
type storageConfig = {
  @description('Account name') name: string
  @allowed(['Standard_LRS', 'Premium_LRS']) sku: string
  enableEncryption: bool?  // nullable
}
param config storageConfig
```

### Discriminated Unions
```bicep
@discriminator('kind')
type pet = { kind: 'cat', lives: int } | { kind: 'dog', isGoodBoy: bool }
param myPet pet
```

### String Literal Unions
```bicep
param env 'dev' | 'staging' | 'prod'
type sku = 'Basic' | 'Standard' | 'Premium'
```

## User-Defined Functions

```bicep
@export()
func generateName(prefix string, token string) string =>
  '${prefix}-${token}-${uniqueString(resourceGroup().id)}'
func getTier(sku string) string => sku == 'Premium_LRS' ? 'Premium' : 'Standard'
output tier string = getTier('Premium_LRS')
```

## Import/Export

```bicep
// shared.bicep
@export() type appConfig = { name: string, tier: 'Free' | 'Basic' | 'Premium' }
@export() var defaultTags = { managedBy: 'bicep' }
@export() func prefixName(prefix string, name string) string => '${prefix}-${name}'

// main.bicep
import { appConfig, defaultTags, prefixName } from './shared.bicep'
import * as shared from './shared.bicep'  // wildcard
```

## .bicepparam Files

```bicep
// main.bicepparam
using './main.bicep'
param environment = 'prod'
param location = 'eastus'
param tags = { team: 'platform', costCenter: 'CC-1234' }
param suffix = uniqueString(readEnvironmentVariable('DEPLOY_ID', 'default'))
```

Deploy: `az deployment group create -g myRg --template-file main.bicep --parameters main.bicepparam`

## Deployment Stacks

```bash
az stack group create --name myStack --resource-group myRg \
  --template-file main.bicep --parameters main.bicepparam \
  --action-on-unmanage deleteAll --deny-settings-mode none
az stack group delete --name myStack --resource-group myRg --action-on-unmanage deleteAll
az stack sub create --name myStack --location eastus \
  --template-file main.bicep --deny-settings-mode denyWriteAndDelete
```

## What-If Operations

```bash
az deployment group what-if -g myRg --template-file main.bicep --parameters main.bicepparam
# Shows Create/Modify/Delete/NoChange per resource — use as CI gate before production deploy
az deployment group what-if -g myRg --template-file main.bicep --result-format FullResourcePayloads
```

## Bicep CLI

```bash
bicep build main.bicep                   # Compile → ARM JSON
bicep build main.bicep --outfile out.json # Custom output path
bicep build-params main.bicepparam       # Compile param file
bicep decompile template.json            # ARM JSON → Bicep
bicep lint main.bicep                    # Run linter
bicep format main.bicep                  # Auto-format
bicep generate-params main.bicep         # Generate param file stub
bicep publish main.bicep --target br:myacr.azurecr.io/bicep/modules/app:1.0.0
bicep restore main.bicep                 # Restore external modules
bicep test tests/main.test.bicep         # Run tests
az bicep install && az bicep upgrade     # Install/upgrade CLI
```

## Linting — bicepconfig.json

Place at repo root. Inline suppress: `#disable-next-line rule-name`.

```json
{
  "analyzers": {
    "core": {
      "enabled": true,
      "rules": {
        "no-unused-params": { "level": "warning" },
        "no-unused-vars": { "level": "warning" },
        "no-hardcoded-location": { "level": "error" },
        "prefer-interpolation": { "level": "warning" },
        "adminusername-should-not-be-literal": { "level": "error" },
        "use-parent-property": { "level": "warning" },
        "no-hardcoded-env-urls": { "level": "warning" },
        "secure-parameter-default": { "level": "error" },
        "protect-commandtoexecute-secrets": { "level": "error" },
        "use-stable-resource-identifiers": { "level": "warning" }
      }
    }
  }
}
```

## ARM Template Migration

```bash
bicep decompile azuredeploy.json  # produces azuredeploy.bicep
```

Post-migration: remove unnecessary `dependsOn` (Bicep infers), replace `concat()` with interpolation, replace `reference()` with symbolic names, add decorators, extract modules.

## Testing

```bicep
// tests/storage.test.bicep
test storageTest './modules/storage.bicep' = {
  params: { name: 'teststorage', location: 'eastus', sku: 'Standard_LRS' }
}
```

Run: `bicep test tests/storage.test.bicep`

Validation: `az deployment group validate -g myRg --template-file main.bicep --parameters main.bicepparam`

## CI/CD Integration

### GitHub Actions
```yaml
name: Deploy Bicep
on: [push]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with: { creds: '${{ secrets.AZURE_CREDENTIALS }}' }
      - run: az bicep lint --file main.bicep
      - run: az deployment group validate -g myRg --template-file main.bicep --parameters main.bicepparam
      - run: az deployment group what-if -g myRg --template-file main.bicep --parameters main.bicepparam
      - run: az deployment group create -g myRg --template-file main.bicep --parameters main.bicepparam
```

### Azure DevOps
```yaml
- task: AzureCLI@2
  inputs:
    azureSubscription: 'myServiceConnection'
    scriptType: bash
    inlineScript: |
      az deployment group create --resource-group $(rgName) \
        --template-file main.bicep --parameters main.bicepparam
```

Pipeline flow: Lint → Validate → What-If (with approval gate) → Deploy.

## Examples

### Example 1: Storage with conditional container

**Input:** "Create a storage account with an optional blob container."

**Output:**
```bicep
@description('Name prefix') @minLength(3)
param prefix string
param deployContainer bool = true
param location string = resourceGroup().location
var name = '${prefix}${uniqueString(resourceGroup().id)}'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
}
resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (deployContainer) {
  parent: sa
  name: 'default'
}
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (deployContainer) {
  parent: blobSvc
  name: 'data'
}
output storageId string = sa.id
```

### Example 2: VNet with dynamic subnets

**Input:** "Bicep for a VNet with subnets from an array parameter."

**Output:**
```bicep
param vnetName string = 'myVnet'
param location string = resourceGroup().location
param subnets array = [
  { name: 'web', prefix: '10.0.1.0/24' }
  { name: 'app', prefix: '10.0.2.0/24' }
  { name: 'db',  prefix: '10.0.3.0/24' }
]
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [for s in subnets: { name: s.name, properties: { addressPrefix: s.prefix } }]
  }
}
output vnetId string = vnet.id
output subnetIds array = [for (s, i) in subnets: vnet.properties.subnets[i].id]
```

## Key Rules

- Pin API versions on every resource declaration.
- Use `@secure()` for secrets; never default secure params.
- Prefer `'${x}-${y}'` over `concat()`.
- Use `existing` to reference pre-deployed resources.
- Extract shared logic into modules; publish to Bicep registry for reuse.
- Use `@description()` on all params and outputs.
- Set `targetScope` explicitly for non-resource-group deployments.
- Use `.bicepparam` over JSON parameter files.
- Run `bicep lint` + `validate` + `what-if` before every deploy.
- Use deployment stacks for lifecycle management.
- Configure `bicepconfig.json` with linter rule severities at repo root.
- Use `@export()`/`import` for cross-file sharing of types, vars, and functions.

## Skill Files

### References

Deeply researched reference documents for advanced usage, troubleshooting, and resource patterns.

| File | Description |
|---|---|
| [references/advanced-patterns.md](references/advanced-patterns.md) | Deployment scripts, Bicep extensibility (Kubernetes/Graph providers), private module registries, template specs, deployment stacks with deny settings, what-if change types, cross-scope deployments, managed identity patterns, `@discriminator` custom types, Bicep with AKS/App Service/Functions/SQL |
| [references/troubleshooting.md](references/troubleshooting.md) | Diagnosing deployment failures (ResourceNotFound, InvalidTemplate, AuthorizationFailed, RequestDisallowedByPolicy, DeploymentQuotaExceeded), module resolution errors, circular dependencies, what-if false positives, linter rule suppression, ARM→Bicep decompilation issues, API version compatibility, debugging techniques |
| [references/resource-reference.md](references/resource-reference.md) | Production-ready Bicep patterns for Storage Account, App Service + Plan, Azure SQL, Key Vault, Virtual Network, Container Registry, AKS cluster, Function App, Cosmos DB, Application Insights — each with security defaults, monitoring, and outputs |

### Scripts

Executable bash helpers for Bicep workflow automation.

| File | Description |
|---|---|
| [scripts/setup-bicep.sh](scripts/setup-bicep.sh) | Install Bicep CLI (via `az` or standalone), configure VS Code extension, initialize project structure with `bicepconfig.json`, stub `main.bicep`, and parameter files |
| [scripts/deploy-bicep.sh](scripts/deploy-bicep.sh) | Deploy Bicep with lint → validate → what-if → deploy pipeline. Supports parameter files, environment targeting, subscription scope, deployment stacks with deny settings |
| [scripts/lint-bicep.sh](scripts/lint-bicep.sh) | Run Bicep linter on all files, compile-check to ARM, best-practices analysis (hardcoded locations, missing `@description`, `concat()` usage), optional Azure validation. Supports `--strict`, `--fix`, `--ci` modes |

### Assets

Ready-to-use Bicep templates, modules, and configuration files.

| File | Description |
|---|---|
| [assets/main.bicep](assets/main.bicep) | Multi-resource deployment template: App Service + Azure SQL + Key Vault + Application Insights with managed identity, Key Vault secret references, environment-aware SKUs |
| [assets/modules/storage.bicep](assets/modules/storage.bicep) | Reusable storage account module with configurable containers, lifecycle management, soft delete, versioning, and network ACLs |
| [assets/modules/networking.bicep](assets/modules/networking.bicep) | VNet + dynamic subnets + per-subnet NSGs with configurable security rules, service endpoints, and subnet delegations |
| [assets/bicepconfig.json](assets/bicepconfig.json) | Complete Bicep linter configuration with all 35 built-in rules configured, formatting options, module aliases, and experimental feature flags |
| [assets/pipeline.yml](assets/pipeline.yml) | Dual CI/CD pipeline (GitHub Actions + Azure DevOps) with lint → validate → what-if → deploy stages, OIDC auth, environment gates, and deployment outputs |

<!-- tested: pass -->
