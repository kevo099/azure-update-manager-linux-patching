# Enterprise Linux patching with Azure Update Manager

This guide builds a complete, policy-driven patching setup for Linux Azure VMs and explains each
decision. The steps were run in a live lab; the [live-test record](LIVE-TEST-2026-10-19.md) shows what
each one did and what was not exercised: Azure Arc, a disk rollback, a freeze set through `frozenRings`
(the lab froze a separately tagged configuration) and the remediation branch of the onboarding script
(its rerun found nothing to remediate). The commands use only
resource-group scope, so they are safe to try in a subscription that also hosts other workloads.

```text
Azure Policy (resource group)          Maintenance configurations             Event Grid + Automation
 ├─ periodic assessment (Linux)  ─┐     ├─ ring 0 canary  ── dynamic scope ──┐  ├─ pre-event:  snapshot OS disks,
 ├─ Customer Managed Schedules   ─┼──▶  │   (PatchRing=ring0, Linux)         │  │               start stopped VMs,
 └─ audit: not assessed          ─┘     └─ ring 1 prod    ── dynamic scope ──┼─▶│               cancel on change freeze
                                            (PatchRing=ring1, kernel held)   │  └─ post-event: per-VM results
Resource Graph ──▶ reporting queries, log-search alerts ◀── every run ────────┘
```

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Give private VMs a way to reach their repositories](#2-give-private-vms-a-way-to-reach-their-repositories)
3. [Onboard machines with Azure Policy](#3-onboard-machines-with-azure-policy)
4. [Patch in rings with maintenance configurations](#4-patch-in-rings-with-maintenance-configurations)
5. [Pre- and post-maintenance hooks](#5-pre--and-post-maintenance-hooks)
6. [Emergency (out-of-band) patching](#6-emergency-out-of-band-patching)
7. [Reporting and alerts](#7-reporting-and-alerts)
8. [Operating the setup](#8-operating-the-setup)
9. [Gotchas](#9-gotchas)
10. [Clean up](#10-clean-up)

## 1. Prerequisites

- Azure CLI 2.75 or later (tested with 2.91) and the `maintenance` and `resource-graph` extensions:
  `az extension add --name maintenance --upgrade` and `az extension add --name resource-graph`.
- bash 4 or later with GNU coreutils and Python 3 for the scripts: Linux, WSL or Azure Cloud Shell
  (macOS ships bash 3.2 and BSD `date`).
- Providers registered once per subscription: `Microsoft.Maintenance`, `Microsoft.EventGrid`,
  `Microsoft.GuestConfiguration`, `Microsoft.PolicyInsights`, `Microsoft.Automation`.
- Roles on the target resource group: Owner, or Contributor plus User Access Administrator (policy
  assignments create managed identities and role assignments). For people who only manage schedules,
  start from the built-in **Scheduled Patching Contributor** role; it covers maintenance configurations
  and their assignments but not template deployments, so deploying the ring template (including a freeze
  or a hold) also needs `Microsoft.Resources/deployments/*` on the group.
- A supported image. Update Manager supports Ubuntu, Debian, RHEL, Oracle Linux, AlmaLinux, Rocky Linux,
  SUSE and Azure Linux marketplace images; check the
  [support matrix](https://learn.microsoft.com/azure/update-manager/support-matrix-updates) for your
  exact offer and plan. The lab used Ubuntu 24.04, Debian 12, RHEL 9 (pay-as-you-go) and Azure Linux 3.

Set the values used throughout:

```bash
SUBSCRIPTION_ID='<subscription-id>'
RESOURCE_GROUP='rg-linux-patching'      # holds the VMs; every scope below is this group
LOCATION='centralus'                    # normalized name; display names break assignments
az account set --subscription "$SUBSCRIPTION_ID"
```

## 2. Give private VMs a way to reach their repositories

Patching downloads packages from the distribution's repositories (Ubuntu and Debian mirrors, Red Hat
Update Infrastructure for pay-as-you-go RHEL, `packages.microsoft.com` for Azure Linux). New subnets
should not rely on Azure's retiring default outbound access, so give the subnet an explicit egress path.
A NAT gateway keeps the VMs private and gives them one stable outbound address:

```bash
az network public-ip create -g "$RESOURCE_GROUP" -n pip-natgw-patching --sku Standard --allocation-method Static
az network nat gateway create -g "$RESOURCE_GROUP" -n natgw-patching --public-ip-addresses pip-natgw-patching
az network vnet subnet update -g "$RESOURCE_GROUP" --vnet-name <vnet> -n <subnet> \
  --nat-gateway natgw-patching --default-outbound-access false
```

An Azure Firewall or a proxy works too, as long as the repository endpoints are allowed. Check from a VM
with `az vm run-command invoke ... --scripts "curl -sI https://packages.microsoft.com"` before patching.

## 3. Onboard machines with Azure Policy

Schedules can patch an Azure VM only when Customer Managed Schedules is on. Periodic assessment is not
required for patching, but the reporting, alerts and audit policy below depend on it:

| Setting | VM property | Why |
|---|---|---|
| Customer Managed Schedules (required) | `patchMode = AutomaticByPlatform` and `automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule = true` | Lets your schedules patch the VM and stops Azure's own automatic patching |
| Periodic assessment (recommended) | `osProfile.linuxConfiguration.patchSettings.assessmentMode = AutomaticByPlatform` | Azure checks for missing updates about once a day and records the result |

Assign Microsoft's built-in policies at the resource group so new VMs are onboarded automatically:

| Built-in | Effect | Parameters to set |
|---|---|---|
| `59efceea-0c96-497e-a4a1-4eb2290dac15` Configure periodic checking for missing system updates on Azure VMs | Modify | `osType=Linux` (the default is **Windows**, so a Linux fleet needs its own assignment) |
| `9905ca54-1471-49c6-8291-7582c04cd4d4` Set prerequisite for scheduling recurring updates on Azure VMs | DeployIfNotExists | `operatingSystemTypes=["Linux"]` |
| `bd876905-5b84-4f73-ab2d-2e7a7c4568d9` Machines should be configured to periodically check for missing system updates | Audit | — |

[`scripts/onboard-policy.sh`](../scripts/onboard-policy.sh) creates the three assignments (the two
remediating ones with managed identities that hold Contributor on the resource group), waits until those
two assignments' fresh compliance records stop growing, remediates existing VMs, and then checks every VM
they reported noncompliant. It fails unless each remediation deployed something and those VMs are
onboarded:

```bash
SUBSCRIPTION_ID="$SUBSCRIPTION_ID" RESOURCE_GROUP="$RESOURCE_GROUP" LOCATION="$LOCATION" scripts/onboard-policy.sh
```

What to expect:

- The first compliance results take a few minutes to about twenty. A remediation in the default
  `ExistingNonCompliant` mode only acts on existing noncompliant records, so the script waits for them.
- The built-in policies only match the image publishers and offers on their allow-lists. In the lab,
  the periodic-assessment and audit policies reported Azure Linux 3 **Compliant without changing it**, and
  the prerequisite policy did not evaluate it at all, because it is outside those lists even though Update
  Manager supports it. Onboard such VMs directly:

  ```bash
  scripts/set-customer-managed-schedules.sh "$RESOURCE_GROUP" <vm-name>
  ```

- Once Customer Managed Schedules is on, the Linux patch extension turns off the distribution's own
  automatic updates. On Ubuntu and Debian it sets `APT::Periodic::Update-Package-Lists` and
  `APT::Periodic::Unattended-Upgrade` to `"0"` in `/etc/apt/apt.conf.d/20auto-upgrades`, so the schedule
  is the only thing that installs updates.

## 4. Patch in rings with maintenance configurations

A maintenance configuration (scope `InGuestPatch`) is a schedule plus patch settings. A dynamic scope
attaches machines to it at run time by resource type, OS, region and tag, so moving a VM between rings
is just a tag change. Use one configuration per ring with non-overlapping windows: every machine in a
configuration starts patching at the same time (VMs in one availability set are patched one update
domain at a time).

[`infra/linux-patch-rings.bicep`](../infra/linux-patch-rings.bicep) creates two rings and their
resource-group-level dynamic scopes:

| Ring | Tag | Updates | Holds | Reboot |
|---|---|---|---|---|
| `mc-linux-ring0-canary` | `PatchRing=ring0` | Critical, Security, Other | none | `IfRequired` |
| `mc-linux-ring1-prod` | `PatchRing=ring1` | Critical, Security | `kernel*`, `linux-image*`, `linux-headers*`, `linux-modules*`, `linux-azure*` | `IfRequired` |

```bash
RINGS=(location="$LOCATION" ring0Start='2026-11-07 02:00' ring1Start='2026-11-08 02:00'
       ring0Recur='Week Saturday' ring1Recur='Week Sunday')
az deployment group what-if -g "$RESOURCE_GROUP" -f infra/linux-patch-rings.bicep -p "${RINGS[@]}"
az deployment group create  -g "$RESOURCE_GROUP" -f infra/linux-patch-rings.bicep -p "${RINGS[@]}"
az vm update -g "$RESOURCE_GROUP" -n <vm> --set tags.PatchRing=ring0   # or ring1
```

The dynamic scopes select machines in `machineLocations` only (default: the configurations' `location`).
If the resource group holds VMs in several regions, pass them all, for example
`machineLocations='["centralus","eastus2"]'`. The template owns the configurations' tags: a change freeze
is a template parameter (`frozenRings`, see [Operating the setup](#8-operating-the-setup)), because a
redeploy replaces tags added by hand.

Rules that matter (from Microsoft's documentation; the [live-test record](LIVE-TEST-2026-10-19.md) shows
which ones the lab exercised):

- **Window:** `duration` between `01:30` and `03:55`; the first `startDateTime` at least 15 minutes after
  you create the configuration, or 40 minutes if a pre-event handler is attached; repeats at least six
  hours apart. `recurEvery` accepts `Day`, `3Days`, `Week Saturday,Sunday`, `Month day15` or
  `Month Second Tuesday Offset3` (three days after the second Tuesday). `timeZone` takes Windows time-zone
  IDs such as `UTC` or `Eastern Standard Time`.
- **Machines** must be running at least 15 minutes before the window; scope and tag changes must also be
  finished 15 minutes before (40 with a pre-event).
- **Linux classifications** are `Critical`, `Security` and `Other`. On Azure Linux (TDNF) there is no
  per-update classification: `Critical`/`Security` installs every available update and `Other` installs
  nothing. Package holds still apply. This comes from the Linux patch extension's TDNF handling
  ([Azure/LinuxPatchExtension](https://github.com/Azure/LinuxPatchExtension)), not from the product
  documentation. In the lab every Azure Linux update was assessed as Security, and ring 1 (Critical and
  Security) installed all of them except the held kernel.
- **Package masks** use shell wildcards; an exclusion drops every version of the package.
- **API versions:** `Microsoft.Maintenance/maintenanceConfigurations@2023-04-01` (GA). Resource-group
  dynamic scopes use `Microsoft.Maintenance/configurationAssignments@2023-04-01` deployed into the
  resource group, with normalized `filter.locations`.

## 5. Pre- and post-maintenance hooks

Pre- and post-maintenance events (generally available) are published to an Event Grid system topic per
maintenance configuration. The lab sends both to Azure Automation runbooks through webhooks:

- [`runbooks/AUM-PreMaintenance.ps1`](../runbooks/AUM-PreMaintenance.ps1) takes the run's machines from
  its records in Resource Graph (falling back to Linux VMs with the ring's tag in the configuration's
  region), starts any that are stopped and leaves them running, and takes an incremental snapshot of each
  OS disk named after the run and tagged to expire after three days. A repeated delivery reuses the
  snapshots; an event that arrives after the window started changes nothing and fails the job. If the
  configuration has the tag `ChangeFreeze=true`, it **cancels the run** instead.
- [`runbooks/AUM-PostMaintenance.ps1`](../runbooks/AUM-PostMaintenance.ps1) reports, for each machine in
  the run, the run status and the installation it recorded for that run, then deletes pre-patch snapshots
  whose expiry has passed. The report is written before cleanup.

[`scripts/deploy-hooks.sh`](../scripts/deploy-hooks.sh) creates the Automation account (system identity,
PowerShell runtime environment), publishes both runbooks byte-for-byte, creates the webhooks, grants the
identity **Reader plus a custom role on the resource group only**, and wires one system topic per
configuration. The custom role holds only what the runbooks use: start a VM, create, read and delete
snapshots, `Microsoft.Compute/disks/beginGetAccess/action` (which snapshot creation from a disk may
require, and which also lets the identity export an unattached or deallocated disk in the group), and
cancel a run (`Microsoft.Maintenance/applyUpdates/write`, which no built-in patching role grants;
Microsoft's own sample uses Contributor). Webhooks belong to the Automation account, so name every
configuration wired to it in `MAINTENANCE_CONFIGURATIONS`; when the webhooks are recreated the script
also re-points every other maintenance-configuration topic in the group that has a `pre-to-runbook`
subscription, so use one hook Automation account per resource group. Rerun the script at any time: it
recreates webhooks that are missing, disabled, replaced from another machine or close to expiry, and
re-points the event subscriptions.

```bash
SUBSCRIPTION_ID="$SUBSCRIPTION_ID" RESOURCE_GROUP="$RESOURCE_GROUP" LOCATION="$LOCATION" \
AUTOMATION_ACCOUNT=aa-patch-hooks MAINTENANCE_CONFIGURATIONS="mc-linux-ring0-canary mc-linux-ring1-prod" \
  scripts/deploy-hooks.sh
```

Timing and design notes:

- The pre-event fires 30 to 40 minutes before the window. A handler has about 20 minutes and must cancel
  (if it is going to) no later than 10 minutes before the start. A failed handler does not cancel the run,
  but the platform does if it cannot deliver the pre-event, or if a schedule with a pre-event is created
  or edited less than 40 minutes before its start.
- The script gives pre-event subscriptions a 20-minute event time-to-live, so Event Grid stops retrying
  a pre-event that could no longer act in time.
- The webhook URL is the only credential a caller needs, so both runbooks check the event type and the
  exact shape of the configuration and run IDs before acting, and send the identity's token only to
  Resource Manager.
- Cancelling is a PUT of `{"properties":{"status":"Cancel"}}` to the run's correlation ID
  (`.../maintenanceConfigurations/<name>/providers/Microsoft.Maintenance/applyUpdates/<yyyyMMddHHmmss>`).
- Automation webhooks require local authentication on the account and their URLs are bearer secrets;
  store them like passwords and give them an expiry (`WEBHOOK_EXPIRY`, default one year). An expired
  webhook cannot be renewed, so rerun `deploy-hooks.sh` within `WEBHOOK_RENEW_DAYS` (default 30) of the
  expiry: it replaces both webhooks and re-points the subscriptions. An Azure Function with an Event Grid
  trigger avoids webhook secrets if your organization disables local authentication.
- Avoid Virtual Machine Contributor for the hook identity: it includes Run Command, which would give a
  webhook-triggered identity root on every VM in the group. Starting a VM needs only
  `Microsoft.Compute/virtualMachines/start/action`.

## 6. Emergency (out-of-band) patching

For a vulnerability that cannot wait for the next window, install only the affected packages now:

```bash
az vm install-patches -g "$RESOURCE_GROUP" -n <vm> --maximum-duration PT1H --reboot-setting Never \
  --package-name-masks-to-include 'openssl*'
```

Pass the package masks **without** a classification, as the lab did. The Linux patch extension treats a
classification as an additional selection, so adding one can install more than the named packages. With
`--reboot-setting Never` a run that needs a reboot finishes `CompletedWithWarnings` and the machine
reports a pending reboot; the next scheduled window with `IfRequired` reboots it. The lab installed
exactly the four glibc packages on RHEL (153 other updates not selected) and the two openssl packages on
Azure Linux.

## 7. Reporting and alerts

Update Manager writes assessments (kept 7 days) and installation results (kept 30 days) to Azure Resource
Graph. The [`queries/`](../queries) folder holds the views used in the lab; run them with
[`scripts/report.sh`](../scripts/report.sh):

```bash
SUBSCRIPTION_ID="$SUBSCRIPTION_ID" RESOURCE_GROUP="$RESOURCE_GROUP" scripts/report.sh \
  pending-updates schedule-runs install-runs package-results schedule-assignments
```

[`infra/patch-alerts.bicep`](../infra/patch-alerts.bicep) creates two log-search alert rules that query
Resource Graph through `arg("")` (Update Manager's alerting approach, currently in preview): machines
with pending Critical/Security updates, and runs that failed or completed with warnings in the last day.
Each rule raises one alert per machine, so another machine notifies even while one machine's alert is
open; a repeat on the same machine does not notify again until that machine's alert has resolved (the
rules are stateful and resolve after two clean hourly evaluations; the failed-runs rule looks back a day).
Each rule runs as its own system-assigned identity with Reader on the resource group it is deployed to
and Log Analytics Reader on a small workspace that serves as the rule's scope.
The template creates and owns that workspace: give it a new name, because an existing workspace's
retention, daily cap and tags would be overwritten. Pass `actionGroupIds` to send email, ITSM or webhook
notifications; without it, alerts appear in Azure Monitor only.

```bash
az deployment group create -g "$RESOURCE_GROUP" -f infra/patch-alerts.bicep -p workspaceName=law-patching-alerts
```

## 8. Operating the setup

| Task | How |
|---|---|
| Move a VM between rings | Change its `PatchRing` tag at least 15 minutes (40 with a pre-event) before the next window |
| Exclude a VM | Remove its `PatchRing` tag; dynamic scopes drop it at the next run |
| Change freeze | Redeploy the ring template with `frozenRings='["ring1"]'` (any subset). A redeploy updates every ring in the template, so finish it at least 40 minutes before the next window of **any** ring. Work that window out from each configuration's `startDateTime` and `recurEvery`: `scripts/report.sh schedule-runs` lists a run only once its record appears, about 40 minutes before the window; the configuration gets `ChangeFreeze=true` and the pre-event handler cancels its runs until you redeploy without it. A tag added by hand works too, but the next template deployment removes it |
| Hold a package | Add it to `packageNameMasksToExclude` of the ring that should not receive it and redeploy with the same 40-minute margin (keep `frozenRings` as it is). A held Critical or Security package stays pending, so the pending-updates alert stays open for those machines until the hold is lifted and the package installed |
| Roll back a bad update | Stop the VM, create a disk from the run's `snap-prepatch-<vm>-<yyyyMMddHHmmss>` snapshot (named after the run) and swap the OS disk (the lab created the snapshots but did not exercise a rollback) |
| Investigate a run | `scripts/report.sh schedule-runs install-runs package-results`, the Automation job output of both hooks, and Update Manager → History in the portal |
| Hybrid servers | Onboard on-premises Linux servers to Azure Arc. They need no patch-orchestration prerequisite and use their own periodic-assessment built-in (`bfea026e-043f-4ff4-9d1b-bf301ca7ff46`). To patch them in these rings, add `Microsoft.HybridCompute/machines` to the dynamic scopes' resource types; the hooks (start, snapshot and the post-event report) cover Azure VMs only. Arc-enabled servers are billed per server unless an entitlement covers them. Not exercised in the lab |

## 9. Gotchas

- Azure CLI 2.91 cannot resolve a full built-in definition ID such as
  `/providers/Microsoft.Authorization/policyDefinitions/<guid>` in `az policy assignment create --policy`;
  pass the GUID name.
- Azure CLI 2.91 `az policy definition create --metadata` takes one value: pass JSON
  (`--metadata '{"category":"Security","version":"1.0.0"}'`), not `key=value key=value`.
- The `maintenance` extension 1.2.1 (installed with the tested CLI) has no install-patches options in
  `configuration create`; check `az maintenance configuration create -h` in your version, or use Bicep,
  ARM or REST for guest-scope configurations as this repository does.
- The Maintenance resource provider sometimes answers a write with `GatewayTimeout` although the write
  succeeds. Read the resource back before retrying.
- `az monitor scheduled-query list` shows the rules' identity as `None`; read the rule with
  `az rest` (API `2023-12-01`) to see its system-assigned identity.
- A remediation created seconds after changing a policy assignment can finish `Succeeded` with zero
  deployments. Wait for a compliance record newer than the change first.
- A schedule run cannot be read back through ARM (`GET` on its correlation ID returns `400
  InvalidResource`); read its status from Resource Graph (`queries/schedule-runs.kql`). A cancelled run
  still sends a post-event, whose `EndDateTime` is the window end rather than the time the run stopped.

## 10. Clean up

Delete the alert rules and their role assignments, the alert-scope workspace the alert template created,
the Event Grid system topics, the Automation account
and its role assignments, the maintenance configurations (their dynamic scopes and static assignments are removed with them
within about a minute), the policy
assignments and their role assignments, then the snapshots the pre-event created. Role assignments
outlive the managed identities they were granted to, so remove them explicitly
(`az role assignment list --scope <resource-group-id>` shows them). Then delete the hook operator custom
role definition (`az role definition list --custom-role-only true --scope <resource-group-id>`) and the
local webhook file. Deleting the resource group removes its resources, but not the custom role definition.
