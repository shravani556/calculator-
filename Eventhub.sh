#!/usr/bin/env bash
set -euo pipefail

#####################################
# Config (override via env if needed)
#####################################
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"   # how many days back to check metrics
OUTROOT="${OUTROOT:-./reports}"
SKIP_METRICS="${SKIP_METRICS:-0}"     # set SKIP_METRICS=1 to skip monitor metrics

#####################################
# Helpers
#####################################
csv_escape() {
  # Escape for CSV: double quotes are doubled and field is wrapped in quotes
  local s=${1//\"/\"\"}
  printf '"%s"' "$s"
}

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

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
# Time / output directory (cross-platform date)
#####################################
TS=$(date -u +%Y%m%d_%H%M%S)
OUTDIR="$OUTROOT/eventhubs_$TS"
mkdir -p "$OUTDIR"

# START_TIME: try GNU date (-d) first, fall back to BSD/macOS date (-v)
if START_TIME=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  START_TIME=$(date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
fi
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

info "Output directory: $OUTDIR"
info "Metrics lookback: ${LOOKBACK_DAYS} days (${START_TIME} .. ${END_TIME} UTC)"
[ "$SKIP_METRICS" = "1" ] && warn "SKIP_METRICS=1 -> InUse will rely only on EH Status."

#####################################
# Output files
#####################################
NAMESPACE_CSV="$OUTDIR/namespaces.csv"
EVENTHUB_CSV="$OUTDIR/eventhubs.csv"
NOTINUSE_CSV="$OUTDIR/eventhubs_not_in_use.csv"

# Namespace header
echo "SubscriptionId,SubscriptionName,ResourceGroup,NamespaceName,NamespaceId,Location,SkuName,SkuTier,SkuCapacity,Status,ProvisioningState,KafkaEnabled,ZoneRedundant,AutoInflateEnabled,MaximumThroughputUnits,TagsJson" \
  > "$NAMESPACE_CSV"

# EventHub headers (same header for NotInUse)
EH_HEADER="SubscriptionId,SubscriptionName,ResourceGroup,NamespaceName,NamespaceId,EventHubName,EventHubId,Location,Status,PartitionCount,MessageRetentionInDays,CaptureEnabled,CaptureIntervalSeconds,CaptureSizeLimitBytes,CaptureEncoding,CaptureSkipEmptyArchives,CaptureDestinationName,CaptureStorageAccountResourceId,CaptureBlobContainer,CaptureArchiveNameFormat,IncomingMessagesTotal,OutgoingMessagesTotal,ActiveConnectionsMaxAvg,LastNonZeroUtc,MetricsStatus,InUse"
echo "$EH_HEADER" > "$EVENTHUB_CSV"
echo "$EH_HEADER" > "$NOTINUSE_CSV"

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

      # Defaults
      metrics_status="Skipped"
      incoming_total=""
      outgoing_total=""
      active_maxavg=""
      last_nonzero=""
      in_use="No"   # will be flipped to Yes when criteria met

      ###################################
      # Decide InUse
      # 1) Try metrics (if allowed)
      # 2) If metrics not used/available -> fall back to Status
      ###################################
      used_metrics=false

      if [ "$SKIP_METRICS" != "1" ]; then
        if metrics_json=$(az monitor metrics list \
              --resource "$eh_id" \
              --metrics IncomingMessages OutgoingMessages ActiveConnections \
              --aggregation Total Average \
              --interval PT1H \
              --start-time "$START_TIME" \
              --end-time "$END_TIME" \
              -o json 2>/dev/null); then

          metrics_status="OK"
          used_metrics=true

          read -r incoming_total outgoing_total active_maxavg last_nonzero raw_in_use <<<"$(
            echo "$metrics_json" | jq -r '
              def sumvals(name):
                [ .value[]?
                  | select(.name.value==name)
                  | .timeseries[]?.data[]?.total // 0
                ] | (add // 0);

              def maxavg(name):
                [ .value[]?
                  | select(.name.value==name)
                  | .timeseries[]?.data[]?.average // empty
                ] as $vals
                | if ($vals|length)==0 then 0 else ($vals|max) end;

              def lastNonZero():
                [ .value[]? as $m
                  | $m.timeseries[]?.data[]?
                  | select(
                      ($m.name.value=="IncomingMessages"  and ((.total   // 0) > 0)) or
                      ($m.name.value=="OutgoingMessages"  and ((.total   // 0) > 0)) or
                      ($m.name.value=="ActiveConnections" and ((.average // 0) > 0))
                    )
                  | .timeStamp
                ] as $ts
                | if ($ts|length)==0 then "" else ($ts|max) end;

              $in := sumvals("IncomingMessages");
              $out := sumvals("OutgoingMessages");
              $conn := maxavg("ActiveConnections");
              $last := lastNonZero();
              [$in,$out,$conn,$last,
               (if ($in>0 or $out>0 or $conn>0) then "Yes" else "No" end)
              ] | @tsv
            '
          )"

          in_use="$raw_in_use"
        else
          metrics_status="Unavailable"
        fi
      fi

      # Fallback: if we did NOT successfully use metrics, rely on EH status
      if [ "$used_metrics" = false ]; then
        # simple rule: Active -> Yes, anything else -> No
        if [ "$eh_status" = "Active" ]; then
          in_use="Yes"
        else
          in_use="No"
        fi
      fi

      eh_line=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
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
        "$(csv_escape "$capture_archive")" \
        "$(csv_escape "$incoming_total")" \
        "$(csv_escape "$outgoing_total")" \
        "$(csv_escape "$active_maxavg")" \
        "$(csv_escape "$last_nonzero")" \
        "$(csv_escape "$metrics_status")" \
        "$(csv_escape "$in_use")" )

      echo "$eh_line" >> "$EVENTHUB_CSV"

      if [ "$in_use" = "No" ]; then
        echo "$eh_line" >> "$NOTINUSE_CSV"
      fi
    done
  done
done

info "Done."
info "Namespaces CSV:        $NAMESPACE_CSV"
info "Event Hubs CSV:        $EVENTHUB_CSV"
info "Not-in-use Event Hubs: $NOTINUSE_CSV"
