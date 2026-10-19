// Ring-based Linux patching with Azure Update Manager.
// Deploy into the resource group that holds the machines: the dynamic scopes are
// resource-group-level, so they can only match machines inside that group, and only in machineLocations.
// The template owns each configuration's tags: a redeploy replaces tags added by hand, so set a change
// freeze with frozenRings instead of tagging the configuration manually.
targetScope = 'resourceGroup'

@description('Normalized region name for the configurations, e.g. centralus. Display names break assignments.')
param location string = resourceGroup().location

@description('Normalized regions whose machines the rings select. A resource group can hold VMs in several regions.')
param machineLocations array = [ location ]

@description('Rings under a change freeze, e.g. [ \'ring1\' ]. The pre-event handler cancels their runs. Change it at least 40 minutes before a window.')
@allowed([ 'ring0', 'ring1' ])
param frozenRings array = []

@description('Windows time-zone ID used by every window, e.g. UTC or Eastern Standard Time.')
param timeZone string = 'UTC'

@description('First window for ring 0 (YYYY-MM-DD hh:mm). At least 15 min after deployment; 40 min if a pre-event handler is attached.')
param ring0Start string

@description('First window for ring 1 (YYYY-MM-DD hh:mm). Keep rings non-overlapping.')
param ring1Start string

@description('Recurrence. Production example: Week Saturday (ring 0) / Week Sunday (ring 1), or Month Second Tuesday Offset3.')
param ring0Recur string = 'Day'
param ring1Recur string = 'Day'

@description('When the schedules stop creating runs (YYYY-MM-DD hh:mm).')
param expiration string = '9999-12-31 23:59'

@description('Guest windows must be between 01:30 and 03:55.')
param duration string = '01:30'

// Package-name masks that hold kernels back in production. Exclude matches every version.
var kernelHold = [
  'kernel*'
  'linux-image*'
  'linux-headers*'
  'linux-modules*'
  'linux-azure*'
]

var rings = [
  {
    name: 'mc-linux-ring0-canary'
    ring: 'ring0'
    start: ring0Start
    recur: ring0Recur
    classifications: [ 'Critical', 'Security', 'Other' ]
    exclude: []
  }
  {
    name: 'mc-linux-ring1-prod'
    ring: 'ring1'
    start: ring1Start
    recur: ring1Recur
    classifications: [ 'Critical', 'Security' ]
    exclude: kernelHold
  }
]

resource configs 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = [for r in rings: {
  name: r.name
  location: location
  tags: union({ PatchRing: r.ring }, contains(frozenRings, r.ring) ? { ChangeFreeze: 'true' } : {})
  properties: {
    maintenanceScope: 'InGuestPatch'
    visibility: 'Custom'
    extensionProperties: {
      InGuestPatchMode: 'User'
    }
    maintenanceWindow: {
      startDateTime: r.start
      expirationDateTime: expiration
      duration: duration
      timeZone: timeZone
      recurEvery: r.recur
    }
    installPatches: {
      rebootSetting: 'IfRequired'
      linuxParameters: {
        classificationsToInclude: r.classifications
        packageNameMasksToExclude: r.exclude
        packageNameMasksToInclude: []
      }
    }
  }
}]

// Resource-group-level dynamic scopes: membership is evaluated at run time from the tag.
resource scopes 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = [for (r, i) in rings: {
  name: 'ds-${r.name}'
  location: location
  properties: {
    maintenanceConfigurationId: configs[i].id
    filter: {
      resourceTypes: [
        'Microsoft.Compute/virtualMachines'
      ]
      osTypes: [
        'Linux'
      ]
      locations: machineLocations
      tagSettings: {
        filterOperator: 'All'
        tags: {
          PatchRing: [
            r.ring
          ]
        }
      }
    }
  }
}]

output maintenanceConfigurationIds array = [for (r, i) in rings: configs[i].id]
