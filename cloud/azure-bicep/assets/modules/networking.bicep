// modules/networking.bicep — VNet + subnets + NSG module
// Deploys a Virtual Network with configurable subnets, each with its own NSG and security rules.

metadata description = 'Virtual Network with subnets, NSGs, and security rules'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Virtual network name')
param vnetName string

@description('Azure region')
param location string = resourceGroup().location

@description('VNet address space')
param addressPrefix string = '10.0.0.0/16'

@description('Subnet configurations')
param subnets array = [
  {
    name: 'web'
    addressPrefix: '10.0.1.0/24'
    serviceEndpoints: ['Microsoft.Storage', 'Microsoft.KeyVault']
    delegations: []
    nsgRules: [
      { name: 'AllowHTTPS', priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', destinationPortRange: '443' }
      { name: 'AllowHTTP', priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '*', destinationPortRange: '80' }
    ]
  }
  {
    name: 'app'
    addressPrefix: '10.0.2.0/24'
    serviceEndpoints: ['Microsoft.Sql', 'Microsoft.KeyVault']
    delegations: []
    nsgRules: [
      { name: 'AllowFromWeb', priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '10.0.1.0/24', destinationPortRange: '8080' }
    ]
  }
  {
    name: 'data'
    addressPrefix: '10.0.3.0/24'
    serviceEndpoints: ['Microsoft.Sql']
    delegations: []
    nsgRules: [
      { name: 'AllowFromApp', priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: '10.0.2.0/24', destinationPortRange: '1433' }
      { name: 'DenyDirectInternet', priority: 4000, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefix: 'Internet', destinationPortRange: '*' }
    ]
  }
]

@description('Enable DDoS protection (requires Standard plan)')
param enableDdosProtection bool = false

@description('Resource tags')
param tags object = {}

// ── NSGs ──────────────────────────────────────────────────────────────────────

resource nsgs 'Microsoft.Network/networkSecurityGroups@2023-11-01' = [for subnet in subnets: {
  name: '${vnetName}-${subnet.name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [for rule in subnet.nsgRules: {
      name: rule.name
      properties: {
        priority: rule.priority
        direction: rule.direction
        access: rule.access
        protocol: rule.protocol
        sourcePortRange: '*'
        destinationPortRange: rule.destinationPortRange
        sourceAddressPrefix: rule.sourceAddressPrefix
        destinationAddressPrefix: '*'
      }
    }]
  }
}]

// ── NSG Diagnostic Settings ───────────────────────────────────────────────────

// Uncomment and supply workspaceId param to enable NSG flow logging
// resource nsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (subnet, i) in subnets: {
//   name: '${vnetName}-${subnet.name}-nsg-diag'
//   scope: nsgs[i]
//   properties: {
//     workspaceId: workspaceId
//     logs: [{ category: 'NetworkSecurityGroupEvent', enabled: true }]
//   }
// }]

// ── Virtual Network ───────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    enableDdosProtection: enableDdosProtection
    subnets: [for (subnet, i) in subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        networkSecurityGroup: { id: nsgs[i].id }
        serviceEndpoints: [for ep in subnet.serviceEndpoints: { service: ep }]
        delegations: [for del in subnet.delegations: {
          name: '${del}-delegation'
          properties: { serviceName: del }
        }]
        privateEndpointNetworkPolicies: 'Enabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    }]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output vnetId string = vnet.id
output vnetName string = vnet.name

@description('Map of subnet name to resource ID')
output subnetIds array = [for (subnet, i) in subnets: {
  name: subnet.name
  id: vnet.properties.subnets[i].id
}]

@description('Map of NSG name to resource ID')
output nsgIds array = [for (subnet, i) in subnets: {
  name: nsgs[i].name
  id: nsgs[i].id
}]
