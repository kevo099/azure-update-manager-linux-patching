# Azure Update Manager: enterprise Linux patching

A live-tested reference for patching Linux Azure VMs with
[Azure Update Manager](https://learn.microsoft.com/azure/update-manager/overview) the way an enterprise
runs it: machines onboarded by Azure Policy, updates installed in rings by schedule, a snapshot taken
before every run, change freezes that cancel runs, out-of-band patching for urgent vulnerabilities, and
Resource Graph reporting with alerts.

> **Part of an Azure governance suite.** The
> [suite overview](https://github.com/kevo099/azure-enterprise-policy-baseline/blob/main/docs/SUITE.md)
> lists the related Policy baseline and Automation runbooks.

## What is in this repository

| Path | What it does |
|---|---|
| [`scripts/onboard-policy.sh`](scripts/onboard-policy.sh) | Assigns Microsoft's Update Manager built-in policies to one resource group (periodic assessment, Customer Managed Schedules prerequisite, audit) and remediates existing Linux VMs |
| [`scripts/set-customer-managed-schedules.sh`](scripts/set-customer-managed-schedules.sh) | Onboards a VM directly when its image is supported by Update Manager but skipped by the built-in policies (for example Azure Linux 3) |
| [`infra/linux-patch-rings.bicep`](infra/linux-patch-rings.bicep) | Two maintenance configurations (canary and production rings) and resource-group dynamic scopes selected by the `PatchRing` tag |
| [`runbooks/`](runbooks) + [`scripts/deploy-hooks.sh`](scripts/deploy-hooks.sh) | Pre-maintenance (snapshot, start stopped VMs, change-freeze cancel) and post-maintenance (results report) handlers wired through Event Grid to Azure Automation, with a least-privilege custom role |
| [`queries/`](queries) + [`scripts/report.sh`](scripts/report.sh) | Resource Graph views: pending updates, schedule runs, per-machine and per-package results, assignments |
| [`infra/patch-alerts.bicep`](infra/patch-alerts.bicep) | Log-search alert rules over Resource Graph: pending security updates and failed runs |

Start with the [setup guide](docs/GUIDE.md); the [live-test record](docs/LIVE-TEST-2026-10-19.md) shows
what each part did in a real subscription.

## Design in one page

- **Onboarding is policy, not a checklist.** New VMs in the resource group whose images are on the
  built-in policies' allow-lists get Customer Managed Schedules and periodic assessment automatically, and
  compliance shows any that drift. Supported images outside the lists (Azure Linux 3 in the lab) are
  onboarded directly and checked with the reporting queries.
- **Rings are schedules plus tags.** Each ring is a maintenance configuration with its own window,
  classifications, package holds and reboot setting; a dynamic scope picks machines by tag at run time.
- **Every run is recoverable and stoppable.** The pre-event handler snapshots OS disks and can cancel a
  run during a change freeze; the post-event handler reports each machine's outcome.
- **Urgent fixes do not wait for the window.** One-time installs target exact package names.
- **Evidence comes from Resource Graph.** The report script and the alert rules both read Update
  Manager's Resource Graph tables; the hooks use them to find each run's machines and results.

## Scope and limits

Linux Azure VMs only. Windows VMs use the same policies with `osType`/`operatingSystemTypes` set to
Windows and Windows classifications in their schedules. Azure Arc-enabled servers use a separate
periodic-assessment built-in, need no scheduling prerequisite and join a ring only if the dynamic scope
includes `Microsoft.HybridCompute/machines`; Arc is described in the guide but was not part of the live
test.
Update Manager is free for Azure VMs; Arc-enabled servers are billed per server unless an entitlement
covers them. Check current pricing before use.

This is a community project. It is not affiliated with or endorsed by Microsoft.

## License

[MIT](LICENSE)
