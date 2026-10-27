targetScope = 'resourceGroup'

@description('英小文字から始まる短いリソース名プレフィックス')
@minLength(2)
@maxLength(12)
param prefix string = 'arclab'
param location string = resourceGroup().location
param workloadVmSize string = 'Standard_D2s_v5'
param dnsVmSize string = 'Standard_D2s_v5'
param hyperVVmSize string = 'Standard_D8s_v5'
param adminUsername string = 'labadmin'
@secure()
@description('デプロイ時に対話入力する。ファイルには保存しない。')
param adminPassword string

var tags = {
  purpose: 'optional-ampls-arcpls-lab'
}

resource hub 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: '10.20.0.0/26' }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '10.20.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-resolver-inbound'
        properties: {
          addressPrefix: '10.20.2.0/28'
          delegations: [
            {
              name: 'dnsResolver'
              properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
            }
          ]
        }
      }
    ]
  }
}

resource spoke 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-spoke1'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.10.0.0/16'] }
    dhcpOptions: { dnsServers: ['10.20.2.4'] }
    subnets: [
      {
        name: 'snet-workload'
        properties: { addressPrefix: '10.10.1.0/24' }
      }
    ]
  }
}

resource onpre 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-onpre'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.30.0.0/16'] }
    dhcpOptions: { dnsServers: ['10.30.1.5'] }
    subnets: [
      {
        name: 'snet-onpre'
        properties: { addressPrefix: '10.30.1.0/24' }
      }
    ]
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke
  name: 'to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hub
  name: 'to-spoke1'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
resource onpreToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: onpre
  name: 'to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
resource hubToOnpre 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hub
  name: 'to-onpre'
  properties: {
    remoteVirtualNetwork: { id: onpre.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: '${prefix}-resolver'
  location: location
  tags: tags
  properties: { virtualNetwork: { id: hub.id } }
}
resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Static'
        privateIpAddress: '10.20.2.4'
        subnet: { id: hub.properties.subnets[2].id }
      }
    ]
  }
}

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${prefix}-fw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource policy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: '${prefix}-fw-policy'
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Alert'
    // Explicit proxy and allow rules are intentionally configured in chapter 03.
  }
}
resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: '${prefix}-fw'
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Standard' }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: hub.properties.subnets[0].id }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
}

// Keep the entire loop input deployment-start calculable.
// Resource properties (including subnets[].id) must not participate in this array.
var machines = [
  { role: 'workload', size: workloadVmSize, vnetName: '${prefix}-spoke1', subnetName: 'snet-workload', ip: '10.10.1.4' }
  { role: 'dns', size: dnsVmSize, vnetName: '${prefix}-onpre', subnetName: 'snet-onpre', ip: '10.30.1.5' }
  { role: 'hyperv', size: hyperVVmSize, vnetName: '${prefix}-onpre', subnetName: 'snet-onpre', ip: '10.30.1.4' }
]
module vms 'modules/windows-vm.bicep' = [for machine in machines: {
  name: '${prefix}-${machine.role}-deployment'
  params: {
    name: '${prefix}-${machine.role}'
    location: location
    vmSize: machine.size
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', machine.vnetName, machine.subnetName)
    privateIp: machine.ip
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
  // resourceId() builds a string and does not infer a resource dependency.
  dependsOn: [
    spoke
    onpre
  ]
}]

output resolverInboundIp string = '10.20.2.4'
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output vmNames array = [for machine in machines: '${prefix}-${machine.role}']
output privateEndpointSubnetId string = hub.properties.subnets[1].id
