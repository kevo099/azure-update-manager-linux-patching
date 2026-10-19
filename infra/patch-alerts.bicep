// Azure Update Manager alerts (preview pattern): log search alert rules that query
// Azure Resource Graph through arg(""), run by each rule's system-assigned identity.
targetScope = 'resourceGroup'

// Deploy into the resource group that holds the machines; the rules report that group only.
param location string = resourceGroup().location
@description('Name of a NEW workspace that this template creates and owns as the alert scope (no data is ingested). Do not pass an existing workspace: its retention, daily cap and tags would be overwritten.')
param workspaceName string
@description('Optional action group resource IDs (email, ITSM, webhook). Empty = alerts appear in Azure Monitor only.')
param actionGroupIds array = []

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  tags: { Purpose: 'UpdateManagerAlertScope' }
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') }
  }
}

var rules = [
  {
    name: 'aum-linux-pending-security-updates'
    description: 'Linux machines whose latest assessment reports pending Critical/Security updates.'
    severity: 3
    query: 'arg("").patchassessmentresources | where type !has "softwarepatches" | where resourceGroup =~ "${resourceGroup().name}" | where tostring(properties.osType) =~ "Linux" | extend pending = toint(coalesce(properties.availablePatchCountByClassification.security, 0)) + toint(coalesce(properties.availablePatchCountByClassification.critical, 0)) | where pending > 0 | project vm = tostring(split(id, "/")[8]), pending, assessed = todatetime(properties.lastModifiedDateTime)'
  }
  {
    name: 'aum-linux-failed-patch-runs'
    description: 'Patch installation runs that failed or completed with warnings in the last 24 hours.'
    severity: 2
    query: 'arg("").patchinstallationresources | where type !has "softwarepatches" | where resourceGroup =~ "${resourceGroup().name}" | where todatetime(properties.lastModifiedDateTime) > ago(1d) | where tostring(properties.status) in~ ("Failed", "CompletedWithWarnings") | project vm = tostring(split(id, "/")[8]), status = tostring(properties.status), started = todatetime(properties.startDateTime), failed = toint(properties.failedPatchCount)'
  }
]

resource alertRules 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for r in rules: {
  name: r.name
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: r.name
    description: r.description
    severity: r.severity
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: r.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          // One alert per machine: another machine notifies while one machine's alert is open. A repeat on the
          // same machine does not notify again until its alert has resolved (stateful rule, auto-mitigated).
          dimensions: [ { name: 'vm', operator: 'Include', values: [ '*' ] } ]
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    autoMitigate: true
    actions: { actionGroups: actionGroupIds }
  }
}]

// Each rule's identity reads the machines' data (Reader on this group) and the scope workspace. The assignment
// names include the principal, so recreating a rule (new identity) does not collide with an orphaned grant.
module ruleAccess 'modules/alert-rule-access.bicep' = [for (r, i) in rules: {
  name: 'access-${r.name}'
  params: {
    principalId: alertRules[i].identity.principalId
    workspaceName: workspace.name
  }
}]
