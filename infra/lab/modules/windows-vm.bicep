param name string
param location string
param vmSize string
param subnetId string
param privateIp string
param adminUsername string
param initialDnsServers array
@secure()
param adminPassword string

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${name}-pip'
  location: location
  tags: { purpose: 'optional-ampls-arcpls-lab' }
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${name}-nsg'
  location: location
  tags: { purpose: 'optional-ampls-arcpls-lab' }
  properties: {
    securityRules: [
      {
        name: 'AllowBastionRdp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.20.3.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'DenyOtherRdp'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowDnsTcp'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: ['10.30.1.5', '10.20.2.4', '168.63.129.16']
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowDnsUdp'
        properties: {
          priority: 101
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: ['10.30.1.5', '10.20.2.4', '168.63.129.16']
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowPrivateEndpoints'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.20.1.0/24'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowExplicitProxy'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.20.0.4'
          destinationPortRange: '3128'
        }
      }
      {
        name: 'AllowAzureWireServer'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '168.63.129.16'
          destinationPortRanges: ['80', '32526']
        }
      }
      {
        name: 'AllowHostImds'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzurePlatformIMDS'
          destinationPortRange: '80'
        }
      }
      {
        name: 'LabInternetOutbound'
        properties: {
          priority: 400
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    dnsSettings: { dnsServers: initialDnsServers }
    networkSecurityGroup: { id: nsg.id }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
          subnet: { id: subnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: name
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: { securityType: 'Standard' }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}
