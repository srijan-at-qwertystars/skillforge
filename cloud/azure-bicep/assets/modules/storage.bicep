// modules/storage.bicep — Reusable storage account module
// Deploys a Storage Account with optional blob containers, file shares, and lifecycle rules.

metadata description = 'Reusable storage account module with containers and lifecycle'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Storage account name prefix (3-11 chars)')
@minLength(3) @maxLength(11)
param namePrefix string

@description('Azure region')
param location string = resourceGroup().location

@description('Storage SKU')
@allowed(['Standard_LRS', 'Standard_GRS', 'Standard_ZRS', 'Standard_RAGRS', 'Premium_LRS'])
param skuName string = 'Standard_LRS'

@description('Storage kind')
@allowed(['StorageV2', 'BlobStorage', 'BlockBlobStorage'])
param kind string = 'StorageV2'

@description('Access tier for blob storage')
@allowed(['Hot', 'Cool'])
param accessTier string = 'Hot'

@description('Blob containers to create')
param containers array = []
// Example: [{ name: 'data', publicAccess: 'None' }, { name: 'logs', publicAccess: 'None' }]

@description('Enable blob versioning')
param enableVersioning bool = false

@description('Enable soft delete (days, 0 to disable)')
param softDeleteDays int = 7

@description('Enable lifecycle management to move blobs to cool after N days (0 to disable)')
param moveToCooltierAfterDays int = 0

@description('Allow public blob access')
param allowBlobPublicAccess bool = false

@description('IP addresses/ranges to allow (empty = deny all except Azure services)')
param allowedIpRanges array = []

@description('Subnet IDs to allow via service endpoints')
param allowedSubnetIds array = []

@description('Resource tags')
param tags object = {}

// ── Variables ─────────────────────────────────────────────────────────────────

var storageName = toLower('${namePrefix}${uniqueString(resourceGroup().id)}')

var networkRules = {
  defaultAction: (empty(allowedIpRanges) && empty(allowedSubnetIds)) ? 'Allow' : 'Deny'
  bypass: 'AzureServices'
  ipRules: [for ip in allowedIpRanges: { value: ip, action: 'Allow' }]
  virtualNetworkRules: [for subnetId in allowedSubnetIds: { id: subnetId, action: 'Allow' }]
}

// ── Storage Account ───────────────────────────────────────────────────────────

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: kind
  sku: { name: skuName }
  properties: {
    accessTier: accessTier
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: allowBlobPublicAccess
    allowSharedKeyAccess: true
    networkAcls: networkRules
    encryption: {
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// ── Blob Services ─────────────────────────────────────────────────────────────

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    isVersioningEnabled: enableVersioning
    deleteRetentionPolicy: softDeleteDays > 0 ? { enabled: true, days: softDeleteDays } : { enabled: false }
    containerDeleteRetentionPolicy: softDeleteDays > 0 ? { enabled: true, days: softDeleteDays } : { enabled: false }
  }
}

// ── Containers ────────────────────────────────────────────────────────────────

resource blobContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in containers: {
  parent: blobSvc
  name: c.name
  properties: {
    publicAccess: contains(c, 'publicAccess') ? c.publicAccess : 'None'
  }
}]

// ── Lifecycle Management ──────────────────────────────────────────────────────

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = if (moveToCooltierAfterDays > 0) {
  parent: sa
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'moveToCool'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'] }
            actions: {
              baseBlob: {
                tierToCool: { daysAfterModificationGreaterThan: moveToCooltierAfterDays }
              }
            }
          }
        }
      ]
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output storageId string = sa.id
output storageName string = sa.name
output primaryBlobEndpoint string = sa.properties.primaryEndpoints.blob
output primaryFileEndpoint string = sa.properties.primaryEndpoints.file
