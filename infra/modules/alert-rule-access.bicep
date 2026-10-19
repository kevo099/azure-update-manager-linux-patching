// Reader on the resource group and Log Analytics Reader on the alert-scope workspace for one alert rule's
// system-assigned identity. Assignment names are derived from the principal ID.
targetScope = 'resourceGroup'

param principalId string
param workspaceName string

var readerRole = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, readerRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRole)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, principalId, logAnalyticsReaderRole)
  scope: workspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRole)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
