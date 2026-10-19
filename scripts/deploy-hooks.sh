#!/usr/bin/env bash
# Wire Azure Update Manager pre/post-maintenance events to two Azure Automation runbooks:
#   Automation Account (system identity, PowerShell 7.4 runtime) -> runbooks -> webhooks
#   -> one Event Grid system topic per maintenance configuration -> pre/post subscriptions.
# Usage: SUBSCRIPTION_ID=... RESOURCE_GROUP=... LOCATION=centralus AUTOMATION_ACCOUNT=aa-patch-hooks \
#        MAINTENANCE_CONFIGURATIONS="mc-linux-ring0-canary mc-linux-ring1-prod" scripts/deploy-hooks.sh
# Grants the Automation identity Reader plus one custom role (start VMs, manage snapshots, cancel
# maintenance runs) on the resource group only. Webhook URIs are bearer secrets: they are kept in a
# mode-0600 file (WEBHOOK_FILE), never printed and never passed on a command line. Safe to rerun: webhooks
# that are missing, disabled or expire within WEBHOOK_RENEW_DAYS (default 30) are recreated and the event
# subscriptions re-pointed.
set -euo pipefail
umask 077
: "${SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}" "${LOCATION:?}" "${AUTOMATION_ACCOUNT:?}" "${MAINTENANCE_CONFIGURATIONS:?}"
RUNTIME="${RUNTIME_ENVIRONMENT:-PowerShell74-Patching}"; RUNTIME_VERSION="${RUNTIME_VERSION:-7.4}"
WEBHOOK_EXPIRY="${WEBHOOK_EXPIRY:-$(date -u -d '+1 year' +%Y-%m-%dT00:00:00Z)}"
WEBHOOK_FILE="${WEBHOOK_FILE:-$HOME/.aum-webhooks-$SUBSCRIPTION_ID-$RESOURCE_GROUP-$AUTOMATION_ACCOUNT.env}"
WEBHOOK_RENEW_DAYS="${WEBHOOK_RENEW_DAYS:-30}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM=https://management.azure.com; RGP="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
AAP="$RGP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT"
az account set --subscription "$SUBSCRIPTION_ID"

# 1. Automation account with a system-assigned identity. Webhooks require local authentication.
az rest --method put --url "$ARM$AAP?api-version=2024-10-23" --body "{\"location\":\"$LOCATION\",\"identity\":{\"type\":\"SystemAssigned\"},\"properties\":{\"sku\":{\"name\":\"Basic\"},\"publicNetworkAccess\":true,\"disableLocalAuth\":false}}" -o none
for _ in $(seq 1 30); do P=$(az rest --method get --url "$ARM$AAP?api-version=2024-10-23" --query identity.principalId -o tsv 2>/dev/null || true); [ -n "$P" ] && break; sleep 5; done
[ -n "$P" ] || { echo "Automation identity not available" >&2; exit 1; }
echo "automation account ready"

# 2. Runtime environment (the runbooks are REST-only: no packages needed).
az rest --method put --url "$ARM$AAP/runtimeEnvironments/$RUNTIME?api-version=2024-10-23" --body "{\"location\":\"$LOCATION\",\"properties\":{\"runtime\":{\"language\":\"PowerShell\",\"version\":\"$RUNTIME_VERSION\"},\"defaultPackages\":{}}}" -o none

# 3. Runbooks: create linked to the runtime, upload raw bytes, publish, verify the published hash.
tmp=$(mktemp); body=$(mktemp); new=''; trap 'rm -f "$tmp" "$body" ${new:+"$new"}' EXIT
for rb in AUM-PreMaintenance AUM-PostMaintenance; do
  az rest --method put --url "$ARM$AAP/runbooks/$rb?api-version=2024-10-23" --body "{\"location\":\"$LOCATION\",\"properties\":{\"runbookType\":\"PowerShell\",\"runtimeEnvironment\":\"$RUNTIME\",\"logProgress\":false,\"logVerbose\":false}}" -o none
  token=$(az account get-access-token --resource "$ARM/" --query accessToken -o tsv)
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - -s --proto '=https' -X PUT \
    -H 'Content-Type: text/plain; charset=utf-8' --data-binary @"$HERE/runbooks/$rb.ps1" -o /dev/null -w '%{http_code}' \
    "$ARM$AAP/runbooks/$rb/draft/content?api-version=2023-11-01"); unset token
  case "$code" in 200|201|202|204) ;; *) echo "draft upload for $rb returned HTTP $code" >&2; exit 1 ;; esac
  az rest --method post --url "$ARM$AAP/runbooks/$rb/publish?api-version=2023-11-01" -o none
  for _ in $(seq 1 30); do
    state=$(az rest --method get --url "$ARM$AAP/runbooks/$rb?api-version=2024-10-23" --query properties.state -o tsv)
    az rest --method get --url "$ARM$AAP/runbooks/$rb/content?api-version=2023-11-01" --output-file "$tmp" 2>/dev/null || true
    [ "$state" = Published ] && cmp -s "$tmp" "$HERE/runbooks/$rb.ps1" && break; sleep 5
  done
  if [ "$state" != Published ] || ! cmp -s "$tmp" "$HERE/runbooks/$rb.ps1"; then
    echo "$rb not published byte-for-byte" >&2; exit 1
  fi
  echo "$rb published (sha256 $(sha256sum < "$HERE/runbooks/$rb.ps1" | cut -c1-12))"
done

# 4. Webhooks. The service never returns a webhook's URI, so the file also records each webhook's creation
#    time; the stored URIs are reused only while both webhooks are the same ones (same creation time), are
#    enabled, target their runbook and stay valid for WEBHOOK_RENEW_DAYS. Otherwise both are recreated.
webhook_ok() {  # runbook expected-creation-time
  local enabled runbook expiry created
  read -r enabled runbook expiry created < <(az rest --method get --url "$ARM$AAP/webhooks/wh-$1?api-version=2015-10-31" \
    --query "[properties.isEnabled, properties.runbook.name, properties.expiryTime, properties.creationTime]" -o tsv 2>/dev/null | paste -sd' ' -) || return 1
  [ "${enabled,,}" = true ] && [ "$runbook" = "$1" ] && [ -n "$2" ] && [ "$created" = "$2" ] &&
    [ "$(date -u -d "$expiry" +%s)" -gt "$(date -u -d "+$WEBHOOK_RENEW_DAYS days" +%s)" ]
}
RECREATED=''
unset AUM_PreMaintenance_URI AUM_PostMaintenance_URI AUM_PreMaintenance_CREATED AUM_PostMaintenance_CREATED
# shellcheck disable=SC1090
if [ -s "$WEBHOOK_FILE" ]; then source "$WEBHOOK_FILE"; fi
if [ -z "${AUM_PreMaintenance_URI:-}" ] || [ -z "${AUM_PostMaintenance_URI:-}" ] ||
   ! webhook_ok AUM-PreMaintenance "${AUM_PreMaintenance_CREATED:-}" || ! webhook_ok AUM-PostMaintenance "${AUM_PostMaintenance_CREATED:-}"; then
  rm -f "$WEBHOOK_FILE"                  # an interrupted recreation must force a full recreation next time
  new=$(mktemp "$WEBHOOK_FILE.XXXXXX")   # same directory; becomes the file only when both webhooks exist
  for rb in AUM-PreMaintenance AUM-PostMaintenance; do
    az rest --method delete --url "$ARM$AAP/webhooks/wh-$rb?api-version=2015-10-31" -o none 2>/dev/null || true
    uri=$(az rest --method post --url "$ARM$AAP/webhooks/generateUri?api-version=2015-10-31" -o tsv)
    printf '{"name":"wh-%s","properties":{"isEnabled":true,"uri":"%s","expiryTime":"%s","runbook":{"name":"%s"}}}' \
      "$rb" "$uri" "$WEBHOOK_EXPIRY" "$rb" > "$body"
    az rest --method put --url "$ARM$AAP/webhooks/wh-$rb?api-version=2015-10-31" --body @"$body" -o none
    created=$(az rest --method get --url "$ARM$AAP/webhooks/wh-$rb?api-version=2015-10-31" --query properties.creationTime -o tsv)
    printf '%s_URI=%q\n%s_CREATED=%q\n' "${rb//-/_}" "$uri" "${rb//-/_}" "$created" >> "$new"; unset uri
  done
  : > "$body"; mv -f "$new" "$WEBHOOK_FILE"; new=''; RECREATED=1
  # shellcheck disable=SC1090
  source "$WEBHOOK_FILE"
  echo "webhooks created; URIs stored in $WEBHOOK_FILE (expire $WEBHOOK_EXPIRY)"
else
  echo "webhooks valid; reusing $WEBHOOK_FILE"
fi
: "${AUM_PreMaintenance_URI:?}" "${AUM_PostMaintenance_URI:?}"

# 5. Access for the hook identity, on this resource group only: Reader (Resource Graph and configuration
#    reads) and a custom role with exactly the writes the runbooks make. Cancelling a run needs
#    Microsoft.Maintenance/applyUpdates/write, which no built-in patching role grants.
ROLE_GUID=$(python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))' "$RGP/aum-hook-operator")
cat > "$body" <<EOF
{"properties":{"roleName":"Update Manager Hook Operator ($RESOURCE_GROUP, ${SUBSCRIPTION_ID:0:8})","type":"CustomRole",
 "description":"Start VMs, manage pre-patch snapshots and cancel maintenance runs in one resource group (Azure Update Manager hooks).",
 "permissions":[{"actions":["Microsoft.Compute/virtualMachines/start/action","Microsoft.Compute/snapshots/read",
   "Microsoft.Compute/snapshots/write","Microsoft.Compute/snapshots/delete","Microsoft.Compute/disks/beginGetAccess/action",
   "Microsoft.Maintenance/applyUpdates/read","Microsoft.Maintenance/applyUpdates/write"],"notActions":[]}],
 "assignableScopes":["$RGP"]}}
EOF
az rest --method put --url "$ARM$RGP/providers/Microsoft.Authorization/roleDefinitions/$ROLE_GUID?api-version=2022-04-01" --body @"$body" -o none
assign() {   # retries cover identity and role-definition propagation; fails loudly if the grant never lands
  local role="$1" err; err=$(mktemp)
  for _ in $(seq 1 18); do
    [ "$(az role assignment list --assignee-object-id "$P" --scope "$RGP" --role "$role" --fill-principal-name false --query 'length(@)' -o tsv 2>/dev/null)" = 1 ] && { rm -f "$err"; return 0; }
    az role assignment create --assignee-object-id "$P" --assignee-principal-type ServicePrincipal --role "$role" --scope "$RGP" -o none 2>"$err" || true
    sleep 10
  done
  cat "$err" >&2; rm -f "$err"; echo "role $role could not be assigned to the hook identity" >&2; return 1
}
assign acdd72a7-3385-48ef-bd42-f606fba81ae7   # Reader
assign "$ROLE_GUID"
echo "hook identity roles on the resource group: $(az role assignment list --assignee-object-id "$P" --scope "$RGP" --fill-principal-name false --query '[].roleDefinitionName' -o tsv | sort | paste -sd, -)"
echo "(roles other than Reader and the hook operator role are left from earlier versions; remove them if unused)"

# 6. One system topic per maintenance configuration, with pre and post subscriptions (Event Grid schema).
#    Subscriptions are written by PUT from a body file, so the webhook URI never appears on a command line.
#    Pre-events older than 20 minutes are useless (the cancel cut-off is 10 minutes before the window).
SPECS=("pre-to-runbook|Microsoft.Maintenance.PreMaintenanceEvent|AUM_PreMaintenance_URI|20"
       "post-to-runbook|Microsoft.Maintenance.PostMaintenanceEvent|AUM_PostMaintenance_URI|1440")
wire() {  # topic force(1/'') -- create or re-point both subscriptions of one topic and wait for Succeeded
  local topic="$1" force="$2" spec sub_name event_type uri_var ttl sub_url state
  for spec in "${SPECS[@]}"; do
    IFS='|' read -r sub_name event_type uri_var ttl <<< "$spec"
    sub_url="$ARM$RGP/providers/Microsoft.EventGrid/systemTopics/$topic/eventSubscriptions/$sub_name?api-version=2022-06-15"
    if [ -n "$force" ] || ! az rest --method get --url "$sub_url" -o none 2>/dev/null; then
      printf '{"properties":{"destination":{"endpointType":"WebHook","properties":{"endpointUrl":"%s"}},"filter":{"includedEventTypes":["%s"]},"eventDeliverySchema":"EventGridSchema","retryPolicy":{"maxDeliveryAttempts":30,"eventTimeToLiveInMinutes":%s}}}' \
        "${!uri_var}" "$event_type" "$ttl" > "$body"
      az rest --method put --url "$sub_url" --body @"$body" -o none
      : > "$body"
    fi
    for _ in $(seq 1 30); do
      state=$(az rest --method get --url "$sub_url" --query properties.provisioningState -o tsv 2>/dev/null || true)
      case "$state" in Succeeded|Failed|Canceled) break ;; esac; sleep 5
    done
    [ "$state" = Succeeded ] || { echo "$topic/$sub_name provisioning state: ${state:-unknown}" >&2; exit 1; }
  done
  echo "$topic: pre-to-runbook and post-to-runbook Succeeded"
}
declare -A WIRED=()
for mc in $MAINTENANCE_CONFIGURATIONS; do
  topic="st-$mc"; source_id="$RGP/providers/Microsoft.Maintenance/maintenanceConfigurations/$mc"
  az eventgrid system-topic show -g "$RESOURCE_GROUP" -n "$topic" -o none 2>/dev/null || \
    az eventgrid system-topic create -g "$RESOURCE_GROUP" -n "$topic" -l "$LOCATION" \
      --topic-type Microsoft.Maintenance.MaintenanceConfigurations --source "$source_id" -o none
  wire "$topic" "$RECREATED"; WIRED[$topic]=1
done
# New webhooks invalidate every subscription that used the old ones, including those of configurations
# wired by an earlier run but not named in this one: re-point them too.
if [ -n "$RECREATED" ]; then
  for topic in $(az eventgrid system-topic list -g "$RESOURCE_GROUP" --query "[?topicType=='Microsoft.Maintenance.MaintenanceConfigurations'].name" -o tsv); do
    [ -n "${WIRED[$topic]:-}" ] && continue
    if az rest --method get --url "$ARM$RGP/providers/Microsoft.EventGrid/systemTopics/$topic/eventSubscriptions/pre-to-runbook?api-version=2022-06-15" -o none 2>/dev/null; then
      echo "re-pointing $topic (not in MAINTENANCE_CONFIGURATIONS but wired to these webhooks)"; wire "$topic" 1
    fi
  done
fi
unset AUM_PreMaintenance_URI AUM_PostMaintenance_URI AUM_PreMaintenance_CREATED AUM_PostMaintenance_CREATED
echo "Done. Create or change schedules at least 40 minutes before a window that has a pre-event handler."
