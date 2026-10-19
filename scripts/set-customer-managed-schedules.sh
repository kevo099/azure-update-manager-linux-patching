#!/usr/bin/env bash
# Set "Customer Managed Schedules" and periodic assessment on one Linux VM directly (REST PATCH).
# Use it for images that Update Manager supports but the built-in onboarding policies skip
# (for example Azure Linux 3 at the time of writing).
# Usage: scripts/set-customer-managed-schedules.sh <resource-group> <vm-name> [IfRequired|Never|Always]
set -euo pipefail
RG="${1:?resource group}"; VM="${2:?vm name}"; REBOOT="${3:-IfRequired}"
VM_ID=$(az vm show -g "$RG" -n "$VM" --query id -o tsv)
az rest --method patch --url "https://management.azure.com$VM_ID?api-version=2024-11-01" --body "{
  \"properties\": {\"osProfile\": {\"linuxConfiguration\": {\"patchSettings\": {
    \"patchMode\": \"AutomaticByPlatform\", \"assessmentMode\": \"AutomaticByPlatform\",
    \"automaticByPlatformSettings\": {\"bypassPlatformSafetyChecksOnUserSchedule\": true, \"rebootSetting\": \"$REBOOT\"}}}}}}" -o none
az vm show -g "$RG" -n "$VM" --query 'osProfile.linuxConfiguration.patchSettings' -o jsonc
