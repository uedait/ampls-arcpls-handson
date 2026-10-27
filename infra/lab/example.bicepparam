// Standalone parameter set. Deploy-Lab.ps1 compiles this against main.bicep.
// Bicep 0.31+ is required for "using none".
using none

param prefix = 'arclab'
param location = 'japaneast'
param workloadVmSize = 'Standard_D2s_v5'
param dnsVmSize = 'Standard_D2s_v5'
param hyperVVmSize = 'Standard_D8s_v5'
