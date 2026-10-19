<#
.SYNOPSIS
Azure Update Manager pre-maintenance handler (Event Grid -> Automation webhook).
- ChangeFreeze=true tag on the maintenance configuration: cancel this run (before the cancellation cut-off).
- Otherwise, for every machine in this run: start it if it is not running (it is left running afterwards),
  then take an incremental snapshot of its OS disk. The snapshot is named after the run, so a repeated
  event delivery does not create a second one.
Machines come from the run's own records in Resource Graph. If those are not visible yet, the configuration's
PatchRing tag selects Linux VMs in the same resource group and region. An event that arrives after the window
has started changes nothing and fails the job.
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
function Get-ArmOrNull([string]$Path) {
    try { Invoke-Arm GET $Path }
    catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }; throw }
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
$evt     = Get-MaintenanceEvent $WebhookData
Assert-MaintenanceEvent $evt 'Microsoft.Maintenance.PreMaintenanceEvent'
$data    = $evt.data
$runId   = [string]$data.CorrelationId
$runName = ($runId -split '/')[-1]
$mcId    = [string]$data.MaintenanceConfigurationId
$sub     = ($mcId -split '/')[2]
$rg      = ($mcId -split '/')[4]
$now     = (Get-Date).ToUniversalTime()
$mc      = Invoke-Arm GET "$($mcId)?api-version=2023-04-01"
$ring    = [string]$mc.tags.PatchRing
$summary = [ordered]@{ handler = 'pre'; eventType = $evt.eventType; runId = $runId; configuration = $mc.name; ring = $ring
    windowStart = $data.StartDateTime; cancellationCutOff = $data.CancellationCutOffDateTime; cancelled = $false
    machineSource = $null; machines = 0; started = @(); snapshots = @(); errors = @() }
function Complete-Handler {
    Write-Output ("SUMMARY " + ($summary | ConvertTo-Json -Compress -Depth 6))
    if ($summary.errors.Count -gt 0) { throw "Pre-maintenance handler finished with $($summary.errors.Count) error(s): $($summary.errors -join '; ')" }
}

# Change freeze: cancel the run. Nothing else is touched. A run cannot be read back through ARM (GET is not
# supported), so its status comes from Resource Graph: a repeated delivery skips a run already cancelled.
if ([string]$mc.tags.ChangeFreeze -eq 'true') {
    $statusQuery = "maintenanceresources | where type =~ 'microsoft.maintenance/maintenanceconfigurations/applyupdates' and tostring(properties.correlationId) =~ '$runId' | project status = tostring(properties.status)"
    $status = ''
    try { $status = [string](@(Search-Graph $sub $statusQuery) | Select-Object -First 1).status } catch { $status = '' }
    if ($status -in @('Cancel', 'Cancelled')) {
        $summary.cancelled = $true; $summary.note = "run already $status"
    } elseif ($now -ge ([datetime]$data.CancellationCutOffDateTime).ToUniversalTime()) {
        $summary.errors += "change freeze: the cancellation cut-off has passed; the run will proceed"
    } else {
        Invoke-Arm PUT "$($runId)?api-version=2023-09-01-preview" @{ properties = @{ status = 'Cancel' } } | Out-Null
        $summary.cancelled = $true
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Seconds 15
            try { $status = [string](@(Search-Graph $sub $statusQuery) | Select-Object -First 1).status } catch { $status = '' }
        } while ($status -notin @('Cancel', 'Cancelled') -and (Get-Date) -lt $deadline)
        $summary.runStatusAfterCancel = if ($status) { $status } else { 'not yet visible' }
    }
    Complete-Handler; return
}

# A late delivery (Event Grid retries) must not start machines or take "pre-patch" snapshots mid-run.
if ($now -ge ([datetime]$data.StartDateTime).ToUniversalTime()) {
    $summary.errors += "event arrived after the window started; no machine was started or snapshotted"
    Complete-Handler; return
}

# Machines in this run: the run's per-machine records, which can take a few minutes to appear.
$runQuery = @"
maintenanceresources
| where type =~ 'microsoft.maintenance/applyupdates' and tostring(properties.correlationId) =~ '$runId'
| where id has '/providers/microsoft.compute/virtualmachines/'
| project resourceId = tolower(tostring(properties.resourceId))
"@
$ids = @(); $deadline = (Get-Date).AddMinutes(3)
do {
    $ids = @(Search-Graph $sub $runQuery | ForEach-Object { $_.resourceId } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -gt 0) { break }; Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)
if ($ids.Count -gt 0) {
    $summary.machineSource = 'run'
    $filter = "tolower(id) in (" + (($ids | ForEach-Object { "'$_'" }) -join ', ') + ")"
} elseif ($ring) {
    $summary.machineSource = 'tag'
    $filter = "resourceGroup =~ '$rg' and tostring(tags.PatchRing) =~ '$ring' and location =~ '$($mc.location)' and tostring(properties.storageProfile.osDisk.osType) =~ 'Linux'"
} else {
    $summary.errors += 'no machines in the run records and no PatchRing tag on the configuration; nothing selected'
    Complete-Handler; return
}
$vms = @(Search-Graph $sub @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| where $filter
| project id, name, location, osDisk = tostring(properties.storageProfile.osDisk.managedDisk.id), power = tostring(properties.extended.instanceView.powerState.code)
"@)
$summary.machines = $vms.Count

# Start stopped machines, then snapshot each OS disk. Names stay within the 80-character limit.
$runStamp = $runName.Substring(0, [Math]::Min(14, $runName.Length))
$expires  = $now.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ssZ')
foreach ($vm in $vms) {
    try {
        if ($vm.power -ne 'PowerState/running') {
            Invoke-Arm POST "$($vm.id)/start?api-version=2024-11-01" | Out-Null
            $summary.started += $vm.name
        }
        $vmPart   = if ($vm.name.Length -gt 51) { $vm.name.Substring(0, 51) } else { $vm.name }
        $snapName = "snap-prepatch-$vmPart-$runStamp"
        $snapPath = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Compute/snapshots/$($snapName)?api-version=2024-03-02"
        if (-not (Get-ArmOrNull $snapPath)) {
            Invoke-Arm PUT $snapPath @{ location = $vm.location; sku = @{ name = 'Standard_LRS' }
                tags = @{ Purpose = 'PrePatch'; MaintenanceRun = $runName; SourceVm = $vm.name; ExpiresUtc = $expires }
                properties = @{ incremental = $true; creationData = @{ createOption = 'Copy'; sourceResourceId = $vm.osDisk } } } | Out-Null
        }
        $summary.snapshots += $snapName
    } catch { $summary.errors += "$($vm.name): $($_.Exception.Message)" }
}

# Wait (bounded) for started machines to run and snapshots to finish; anything else is an error.
$deadline = (Get-Date).AddMinutes(8)
foreach ($name in @($summary.started)) {
    $vm = $vms | Where-Object { $_.name -eq $name } | Select-Object -First 1
    $running = $false
    do {
        try { $codes = @((Invoke-Arm GET "$($vm.id)/instanceView?api-version=2024-11-01").statuses.code) } catch { $codes = @() }
        if ($codes -contains 'PowerState/running') { $running = $true; break }; Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    if (-not $running) { $summary.errors += "$($name): not running after the start request" }
}
foreach ($s in @($summary.snapshots)) {
    $state = ''
    do {
        try { $state = [string](Invoke-Arm GET "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Compute/snapshots/$($s)?api-version=2024-03-02").properties.provisioningState }
        catch { $state = "read failed: $($_.Exception.Message)" }
        if ($state -in @('Succeeded', 'Failed')) { break }; Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    if ($state -ne 'Succeeded') { $summary.errors += "snapshot $($s): $state" }
}
Complete-Handler
