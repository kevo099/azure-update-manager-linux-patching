<#
.SYNOPSIS
Azure Update Manager post-maintenance handler (Event Grid -> Automation webhook).
Reports each machine's result for this run from Azure Resource Graph, then removes expired pre-patch snapshots.
The report is written before any cleanup, so a cleanup failure (for example a delete lock) cannot lose it.
#>
param([object] $WebhookData)
# Shared helpers, duplicated in both runbooks (edit both). REST-only: no Az modules required.
$ErrorActionPreference = 'Stop'
$script:Arm = 'https://management.azure.com'
function Get-ArmToken {
    $uri = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString("$script:Arm/"))&api-version=2019-08-01"
    (Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' }).access_token
}
function Invoke-Arm([string]$Method, [string]$Path, $Body = $null) {
    # Relative ARM paths only: the bearer token is never sent anywhere but Resource Manager.
    if (-not $Path.StartsWith('/')) { throw "Refusing non-relative ARM path" }
    $headers = @{ Authorization = "Bearer $script:Token" }
    $params = @{ Method = $Method; Uri = "$script:Arm$Path"; Headers = $headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    Invoke-RestMethod @params
}
function Get-MaintenanceEvent($WebhookData) {
    # PowerShell 7 runbooks can receive WebhookData as a JSON string.
    if ($WebhookData -is [string]) { $WebhookData = $WebhookData | ConvertFrom-Json }
    $body = $WebhookData.RequestBody
    if ($body -is [string]) { $body = $body | ConvertFrom-Json }
    @($body)[0]   # Event Grid delivers an array; maintenance events arrive one per delivery
}
function Assert-MaintenanceEvent($MaintenanceEvent, [string]$ExpectedType) {
    # The webhook URL is the only credential, so validate the payload before acting on it.
    if ([string]$MaintenanceEvent.eventType -ne $ExpectedType) { throw "Unexpected event type '$($MaintenanceEvent.eventType)'" }
    $mc = [string]$MaintenanceEvent.data.MaintenanceConfigurationId
    if ($mc -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Maintenance/maintenanceConfigurations/[A-Za-z0-9._-]+$') {
        throw "Unexpected maintenance configuration ID" }
    if ([string]$MaintenanceEvent.data.CorrelationId -notmatch ('^' + [regex]::Escape("$mc/providers/Microsoft.Maintenance/applyUpdates/") + '[0-9]{14}$')) {
        throw "Unexpected run ID" }
}
function Search-Graph([string]$SubscriptionId, [string]$Query) {
    $r = Invoke-Arm POST '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' @{ subscriptions = @($SubscriptionId); query = $Query }
    @($r.data)
}

$script:Token = Get-ArmToken
$evt   = Get-MaintenanceEvent $WebhookData
Assert-MaintenanceEvent $evt 'Microsoft.Maintenance.PostMaintenanceEvent'
$data  = $evt.data
$runId = [string]$data.CorrelationId
$mcId  = [string]$data.MaintenanceConfigurationId
$sub   = ($mcId -split '/')[2]
$rg    = ($mcId -split '/')[4]

# The run's machines and their per-machine run status, joined to the installation each machine recorded
# for this run (maintenanceRunId is the run's correlation ID). Resource Graph can lag the run, so poll until every machine has a
# terminal installation result or ten minutes pass.
$query = @"
maintenanceresources
| where type =~ 'microsoft.maintenance/applyupdates' and tostring(properties.correlationId) =~ '$runId'
| where id has '/providers/microsoft.compute/virtualmachines/'
| project vmId = tolower(tostring(properties.resourceId)), runStatus = tostring(properties.status)
| join kind=leftouter (
    patchinstallationresources
    | where type !has 'softwarepatches' and resourceGroup =~ '$rg'
    | extend p = properties
    | where tostring(p.maintenanceRunId) =~ '$runId'
    | project vmId = tolower(strcat_array(array_slice(split(id, '/'), 0, 8), '/')), status = tostring(p.status),
              installed = toint(p.installedPatchCount), failed = toint(p.failedPatchCount), excluded = toint(p.excludedPatchCount),
              notSelected = toint(p.notSelectedPatchCount), pending = toint(p.pendingPatchCount), reboot = tostring(p.rebootStatus),
              started = todatetime(p.startDateTime)
    | summarize arg_max(started, *) by vmId
  ) on vmId
| project vm = tostring(split(vmId, '/')[8]), runStatus, status, installed, failed, excluded, notSelected, pending, reboot
"@
$terminal = @('Succeeded', 'Failed', 'CompletedWithWarnings', 'Canceled', 'Cancelled')
$notRun   = @('Cancel', 'Canceled', 'Cancelled', 'Skipped', 'NoUpdatesPending')   # no installation expected
$rows = @(); $open = @(); $deadline = (Get-Date).AddMinutes(10)
do {
    $rows = @(Search-Graph $sub $query)
    $open = @($rows | Where-Object { $_.status -notin $terminal -and $_.runStatus -notin $notRun })
    if ($rows.Count -gt 0 -and $open.Count -eq 0) { break }; Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)
$summary = [ordered]@{ handler = 'post'; runId = $runId; runStatus = $data.Status; configuration = ($mcId -split '/')[-1]
    eventStart = $data.StartDateTime; eventEnd = $data.EndDateTime; machines = $rows
    incomplete = @($open | ForEach-Object { $_.vm }) }
Write-Output ("SUMMARY " + ($summary | ConvertTo-Json -Compress -Depth 6))

# Cleanup: only snapshots this automation created (Purpose=PrePatch) whose ExpiresUtc tag has passed.
$removed = @(); $cleanupErrors = @(); $now = (Get-Date).ToUniversalTime()
$snaps = Search-Graph $sub "resources | where type =~ 'microsoft.compute/snapshots' and resourceGroup =~ '$rg' and tostring(tags.Purpose) == 'PrePatch' | project id, name, expires = tostring(tags.ExpiresUtc)"
foreach ($s in $snaps) {
    try {
        if ($s.expires -and ([datetime]$s.expires).ToUniversalTime() -lt $now) {
            Invoke-Arm DELETE "$($s.id)?api-version=2024-03-02" | Out-Null; $removed += $s.name
        }
    } catch { $cleanupErrors += "$($s.name): $($_.Exception.Message)" }
}
Write-Output ("CLEANUP " + ([ordered]@{ expiredSnapshotsRemoved = $removed; errors = $cleanupErrors } | ConvertTo-Json -Compress -Depth 4))
if ($cleanupErrors.Count -gt 0) { throw "Snapshot cleanup failed for $($cleanupErrors.Count) snapshot(s)" }
