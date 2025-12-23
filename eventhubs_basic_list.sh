#!/usr/bin/env bash
set -euo pipefail

#####################################
# Config (override via env if needed)
#####################################
OUTROOT="${OUTROOT:-./reports}"

#####################################
# Helpers
#####################################
csv_escape() {
  # Escape for CSV: double quotes are doubled and field is wrapped in quotes
  local s=${1//\"/\"\"}
  printf '"%s"' "$s"
}

info() { echo "[INFO] $*"; }

#####################################
# Pre-flight checks
#####################################
command -v az >/dev/null 2>&1 || { echo "Azure CLI 'az' not found."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "'jq' is required."; exit 1; }

if ! az account show >/dev/null 2>&1; then
  echo "You are not logged in. Run: az login"
  exit 1
fi

#####################################
# Time / output directory
#####################################
TS=$(date -u +%Y%m%d_%H%M%S)
OUTDIR="$OUTROOT/eventhubs_basic_$TS"
mkdir -p "$OUTDIR"

info "Output directory: $OUTDIR"

#####################################
# Output files
#####################################
NAMESPACE_CSV="$OUTDIR/namespaces.csv"
EVENTHUB_CSV="$OUTDIR/eventhubs.csv"

# Namespace header
echo "SubscriptionId,SubscriptionName,ResourceGroup,NamespaceName,NamespaceId,Location,SkuName,SkuTier,SkuCapacity,Status,ProvisioningState,KafkaEnabled,ZoneRedundant,AutoInflateEnabled,MaximumThroughputUnits,TagsJson" \
  > "$NAMESPACE_CSV"

# EventHub header (basic details only)
echo "SubscriptionId,SubscriptionName,ResourceGroup,NamespaceName,NamespaceId,EventHubName,EventHubId,Location,Status,PartitionCount,MessageRetentionInDays,CaptureEnabled,CaptureIntervalSeconds,CaptureSizeLimitBytes,CaptureEncoding,CaptureSkipEmptyArchives,CaptureDestinationName,CaptureStorageAccountResourceId,CaptureBlobContainer,CaptureArchiveNameFormat" \
  > "$EVENTHUB_CSV"

#####################################
# Main
#####################################
subs_json=$(az account list --query "[?state=='Enabled']" -o json)

echo "$subs_json" | jq -c '.[]' | while read -r sub; do
  sub_id=$(echo "$sub" | jq -r '.id')
  sub_name=$(echo "$sub" | jq -r '.name')

  info "Subscription: $sub_name ($sub_id)"
  az account set --subscription "$sub_id" >/dev/null

  # Namespaces in this subscription
  ns_json=$(az eventhubs namespace list -o json 2>/dev/null || echo "[]")
  echo "$ns_json" | jq -c '.[]' | while read -r ns; do
    rg=$(echo "$ns" | jq -r '.resourceGroup')
    ns_name=$(echo "$ns" | jq -r '.name')
    ns_id=$(echo "$ns" | jq -r '.id')
    location=$(echo "$ns" | jq -r '.location')

    sku_name=$(echo "$ns" | jq -r '.sku.name // ""')
    sku_tier=$(echo "$ns" | jq -r '.sku.tier // ""')
    sku_capacity=$(echo "$ns" | jq -r '.sku.capacity // ""')

    ns_status=$(echo "$ns" | jq -r '.properties.status // ""')
    ns_prov_state=$(echo "$ns" | jq -r '.properties.provisioningState // ""')
    kafka_enabled=$(echo "$ns" | jq -r '.properties.kafkaEnabled // ""')
    zone_redundant=$(echo "$ns" | jq -r '.properties.zoneRedundant // ""')
    auto_inflate=$(echo "$ns" | jq -r '.properties.isAutoInflateEnabled // ""')
    max_tu=$(echo "$ns" | jq -r '.properties.maximumThroughputUnits // ""')
    tags_json=$(echo "$ns" | jq -c '.tags // {}')

    ns_line=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$sub_id")" \
      "$(csv_escape "$sub_name")" \
      "$(csv_escape "$rg")" \
      "$(csv_escape "$ns_name")" \
      "$(csv_escape "$ns_id")" \
      "$(csv_escape "$location")" \
      "$(csv_escape "$sku_name")" \
      "$(csv_escape "$sku_tier")" \
      "$(csv_escape "$sku_capacity")" \
      "$(csv_escape "$ns_status")" \
      "$(csv_escape "$ns_prov_state")" \
      "$(csv_escape "$kafka_enabled")" \
      "$(csv_escape "$zone_redundant")" \
      "$(csv_escape "$auto_inflate")" \
      "$(csv_escape "$max_tu")" \
      "$(csv_escape "$tags_json")")

    echo "$ns_line" >> "$NAMESPACE_CSV"

    #####################################
    # Event Hubs in this namespace
    #####################################
    eh_json=$(az eventhubs eventhub list -g "$rg" --namespace-name "$ns_name" -o json 2>/dev/null || echo "[]")
    echo "$eh_json" | jq -c '.[]' | while read -r eh; do
      eh_name=$(echo "$eh" | jq -r '.name')

      # Get full EH info (properties)
      eh_show=$(az eventhubs eventhub show -g "$rg" --namespace-name "$ns_name" --name "$eh_name" -o json 2>/dev/null || echo "")
      [ -z "$eh_show" ] && continue

      eh_id=$(echo "$eh_show" | jq -r '.id')
      eh_status=$(echo "$eh_show" | jq -r '.properties.status // ""')
      partition_count=$(echo "$eh_show" | jq -r '.properties.partitionCount // ""')
      message_retention=$(echo "$eh_show" | jq -r '.properties.messageRetentionInDays // ""')

      capture_enabled=$(echo "$eh_show" | jq -r '.properties.captureDescription.enabled // ""')
      capture_interval=$(echo "$eh_show" | jq -r '.properties.captureDescription.intervalInSeconds // ""')
      capture_size=$(echo "$eh_show" | jq -r '.properties.captureDescription.sizeLimitInBytes // ""')
      capture_encoding=$(echo "$eh_show" | jq -r '.properties.captureDescription.encoding // ""')
      capture_skip=$(echo "$eh_show" | jq -r '.properties.captureDescription.skipEmptyArchives // ""')
      capture_dest_name=$(echo "$eh_show" | jq -r '.properties.captureDescription.destination.name // ""')
      capture_storage=$(echo "$eh_show" | jq -r '.properties.captureDescription.destination.storageAccountResourceId // ""')
      capture_blob=$(echo "$eh_show" | jq -r '.properties.captureDescription.destination.blobContainer // ""')
      capture_archive=$(echo "$eh_show" | jq -r '.properties.captureDescription.destination.archiveNameFormat // ""')

      eh_line=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$sub_id")" \
        "$(csv_escape "$sub_name")" \
        "$(csv_escape "$rg")" \
        "$(csv_escape "$ns_name")" \
        "$(csv_escape "$ns_id")" \
        "$(csv_escape "$eh_name")" \
        "$(csv_escape "$eh_id")" \
        "$(csv_escape "$location")" \
        "$(csv_escape "$eh_status")" \
        "$(csv_escape "$partition_count")" \
        "$(csv_escape "$message_retention")" \
        "$(csv_escape "$capture_enabled")" \
        "$(csv_escape "$capture_interval")" \
        "$(csv_escape "$capture_size")" \
        "$(csv_escape "$capture_encoding")" \
        "$(csv_escape "$capture_skip")" \
        "$(csv_escape "$capture_dest_name")" \
        "$(csv_escape "$capture_storage")" \
        "$(csv_escape "$capture_blob")" \
        "$(csv_escape "$capture_archive")" )

      echo "$eh_line" >> "$EVENTHUB_CSV"
    done
  done
done

info "Done."
info "Namespaces CSV: $NAMESPACE_CSV"
info "Event Hubs CSV: $EVENTHUB_CSV"
