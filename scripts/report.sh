#!/usr/bin/env bash
# Print Update Manager reporting views for one resource group from Azure Resource Graph.
# Usage: SUBSCRIPTION_ID=... RESOURCE_GROUP=... scripts/report.sh [query-name ...]
set -euo pipefail
: "${SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
az extension show --name resource-graph -o none 2>/dev/null || az extension add --name resource-graph --only-show-errors
queries=("$@"); [ ${#queries[@]} -gt 0 ] || queries=(pending-updates schedule-runs install-runs)
for q in "${queries[@]}"; do
  echo "== $q"
  kql=$(sed -e '/^\/\//d' -e "s/{RESOURCE_GROUP}/$RESOURCE_GROUP/g" "$HERE/queries/$q.kql")
  az graph query --subscriptions "$SUBSCRIPTION_ID" --first 1000 -q "$kql" --query data -o table
  more=$(az graph query --subscriptions "$SUBSCRIPTION_ID" --first 1000 -q "$kql" --query skip_token -o tsv)
  [ -z "$more" ] || echo "WARNING: $q has more than 1000 rows; only the first 1000 are shown" >&2
done
