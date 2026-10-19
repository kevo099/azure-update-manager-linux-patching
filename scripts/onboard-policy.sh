#!/usr/bin/env bash
# Policy-driven onboarding of Linux Azure VMs to Azure Update Manager, scoped to ONE resource group:
#   - periodic assessment (built-in 59efceea-0c96-497e-a4a1-4eb2290dac15, osType=Linux)
#   - scheduling prerequisite "Customer Managed Schedules" (built-in 9905ca54-1471-49c6-8291-7582c04cd4d4)
#   - audit of machines that are not checked periodically (built-in bd876905-5b84-4f73-ab2d-2e7a7c4568d9)
# then remediates existing VMs, waiting for fresh compliance records first.
# Usage: SUBSCRIPTION_ID=... RESOURCE_GROUP=... LOCATION=centralus scripts/onboard-policy.sh
# Needs: Owner or User Access Administrator + Resource Policy Contributor on the resource group.
# Runs in bash 4+ with GNU coreutils (Linux, WSL or Azure Cloud Shell).
set -euo pipefail
: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID}" "${RESOURCE_GROUP:?set RESOURCE_GROUP}" "${LOCATION:?set LOCATION (normalized, e.g. centralus)}"
SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
PREFIX="${ASSIGNMENT_PREFIX:-aum}"
az account set --subscription "$SUBSCRIPTION_ID"

assign() { # name definitionGuid paramsJson needsIdentity
  local extra=()
  [ "$4" = yes ] && extra=(--mi-system-assigned --location "$LOCATION" --role Contributor --identity-scope "$SCOPE")
  # Pass built-in definitions by GUID name: Azure CLI 2.91 cannot resolve the full
  # /providers/Microsoft.Authorization/policyDefinitions/<guid> ID in --policy.
  az policy assignment create --name "$1" --scope "$SCOPE" --policy "$2" --params "$3" ${extra[@]+"${extra[@]}"} -o none
  echo "assigned $1"
}
assign "$PREFIX-periodic-assessment-linux" 59efceea-0c96-497e-a4a1-4eb2290dac15 \
  '{"osType":{"value":"Linux"},"assessmentMode":{"value":"AutomaticByPlatform"}}' yes
assign "$PREFIX-schedule-prereq-linux" 9905ca54-1471-49c6-8291-7582c04cd4d4 \
  '{"effect":{"value":"DeployIfNotExists"},"operatingSystemTypes":{"value":["Linux"]}}' yes
assign "$PREFIX-audit-periodic-check" bd876905-5b84-4f73-ab2d-2e7a7c4568d9 '{"effect":{"value":"Audit"}}' no

ASSIGNED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
az policy state trigger-scan --resource-group "$RESOURCE_GROUP" --no-wait
records() {  # number of compliance records for assignment $1 newer than the assignments
  az policy state list --resource-group "$RESOURCE_GROUP" --from "$ASSIGNED_AT" \
    --filter "policyAssignmentName eq '$1'" --query 'length(@)' -o tsv
}
# Each assignment is evaluated on its own schedule. Wait until both remediable assignments have records
# and their counts have stopped growing, so the remediations see every existing VM.
echo "waiting for compliance records newer than $ASSIGNED_AT (up to 45 minutes)"
for a in "$PREFIX-periodic-assessment-linux" "$PREFIX-schedule-prereq-linux"; do
  prev=-1; n=0
  for _ in $(seq 1 90); do
    n=$(records "$a"); n=${n:-0}
    [ "$n" -gt 0 ] && [ "$n" -eq "$prev" ] && break
    prev=$n; sleep 30
  done
  [ "$n" -gt 0 ] && [ "$n" -eq "$prev" ] || { echo "$a: compliance records not settled; rerun later" >&2; exit 1; }
  echo "$a: $n compliance record(s)"
done

declare -A TARGETS=()   # VMs that a remediation must change
for a in "$PREFIX-periodic-assessment-linux" "$PREFIX-schedule-prereq-linux"; do
  ids=$(az policy state list --resource-group "$RESOURCE_GROUP" --from "$ASSIGNED_AT" \
    --filter "policyAssignmentName eq '$a' and complianceState eq 'NonCompliant'" --query '[].resourceId' -o tsv | sort -u)
  if [ -z "$ids" ]; then echo "$a: nothing to remediate"; continue; fi
  while read -r id; do TARGETS["${id,,}"]=1; done <<< "$ids"
  rem="rem-$a-$(date -u +%Y%m%d%H%M%S)"
  az policy remediation create --name "$rem" --policy-assignment "$a" --resource-group "$RESOURCE_GROUP" -o none
  for _ in $(seq 1 120); do
    state=$(az policy remediation show --name "$rem" --resource-group "$RESOURCE_GROUP" --query provisioningState -o tsv)
    case "$state" in Succeeded|Complete|Failed|Canceled|Cancelled) break ;; esac
    sleep 15
  done
  total=$(az policy remediation show --name "$rem" --resource-group "$RESOURCE_GROUP" --query deploymentStatus.totalDeployments -o tsv)
  failed=$(az policy remediation show --name "$rem" --resource-group "$RESOURCE_GROUP" --query deploymentStatus.failedDeployments -o tsv)
  echo "$a remediation: $state, $total deployment(s), $failed failed"
  case "$state" in Succeeded|Complete) ;; *) echo "remediation did not complete" >&2; exit 1 ;; esac
  [ "${total:-0}" -gt 0 ] && [ "${failed:-1}" -eq 0 ] || { echo "remediation did not deploy cleanly" >&2; exit 1; }
done

# Verify on the VMs themselves: every machine a policy reported noncompliant is now onboarded.
bad=0
for id in "${!TARGETS[@]}"; do
  s=$(az vm show --ids "$id" --query "[osProfile.linuxConfiguration.patchSettings.patchMode, osProfile.linuxConfiguration.patchSettings.assessmentMode, osProfile.linuxConfiguration.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule]" -o tsv | paste -sd' ' -)
  case "${s,,}" in "automaticbyplatform automaticbyplatform true") ;; *) echo "not onboarded: ${id##*/} ($s); if its image is outside the policies' allow-lists use set-customer-managed-schedules.sh" >&2; bad=1 ;; esac
done
[ "$bad" -eq 0 ] || exit 1

echo "VM patch settings after onboarding:"
az vm list -g "$RESOURCE_GROUP" --query "[?storageProfile.osDisk.osType=='Linux'].{vm:name, patchMode:osProfile.linuxConfiguration.patchSettings.patchMode, assessment:osProfile.linuxConfiguration.patchSettings.assessmentMode, bypass:osProfile.linuxConfiguration.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule}" -o table
echo "VMs still on ImageDefault use an image outside the built-in policies' allow-lists; onboard them with scripts/set-customer-managed-schedules.sh."
