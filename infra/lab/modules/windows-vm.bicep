param name string
param location string
param vmSize string
param subnetId string
param privateIp string
param adminUsername string
@secure()
param adminPassword string

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
          subnet: { id: subnetId }
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
