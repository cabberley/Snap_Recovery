#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/rp_ia_module.sh"

usage() {
  cat <<'EOF'
Usage:
  ./rp_ia_client.sh [command] [options]

Commands:
  run-all        Create/update RPC, create app-consistent RP, and GET RP (default)
  rpc            Create/update restore point collection only
  rp             Create/update restore point only
  get            Get restore point only
  instance-view  Get restore point instance view

Options:
  --subscription-id <id>       Azure subscription ID (or AZURE_SUBSCRIPTION_ID)
  --resource-group <name>      Resource group (or AZURE_RESOURCE_GROUP)
  --rpc-name <name>            Restore point collection name (or AZURE_RESTORE_POINT_COLLECTION)
  --rp-name <name>             Restore point base name (or AZURE_RESTORE_POINT_NAME)
  --location <region>          Azure region (or AZURE_LOCATION)
  --source-vm-id <id>          Source VM ARM ID (or AZURE_SOURCE_VM_ID)
  --duration-minutes <int>     Instant access duration in minutes (or AZURE_INSTANT_ACCESS_DURATION_MINUTES)
  --consistency-mode <mode>    Restore point consistency mode (omit for app-consistent; use CrashConsistent for crash-only)
  --exclude-os-disk            Exclude the OS disk from the restore point
  --exclude-data-disk <name>   Exclude a data disk by name or ARM resource ID (repeatable)
  --metadata-file <path>       Path for the JSON metadata file (default: <rp-name>.metadata.json in CWD)
  --log-file <path>            Write all output to a log file (includes debug output when --debug is set)
  --no-wait                    Do not wait for restore point provisioning completion
  --poll-seconds <int>         Poll interval when waiting (default: 10)
  --debug                      Enable verbose debug logging for REST requests and polling
  --help                       Show this help

Restore point naming:
  For create operations (run-all, rp), a UTC timestamp suffix is appended:
  <rp-name>-YYYYMMDDHHMMSS. If --rp-name is omitted, base name defaults to "rp".

Examples:
  ./rp_ia_client.sh --help
  ./rp_ia_client.sh run-all --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --rp-name <rp> --location eastus2 --source-vm-id <vm-id>
  ./rp_ia_client.sh rpc --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --location eastus2 --source-vm-id <vm-id>
  ./rp_ia_client.sh rp --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --rp-name <rp> --duration-minutes 120
  ./rp_ia_client.sh rp --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --rp-name <rp> --exclude-os-disk --exclude-data-disk diskA
  ./rp_ia_client.sh get --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --rp-name <rp>
  ./rp_ia_client.sh instance-view --subscription-id <sub> --resource-group <rg> --rpc-name <rpc> --rp-name <rp>
EOF
}

COMMAND="run-all"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
RPC_NAME="${AZURE_RESTORE_POINT_COLLECTION:-}"
RP_NAME="${AZURE_RESTORE_POINT_NAME:-}"
LOCATION="${AZURE_LOCATION:-}"
SOURCE_VM_ID="${AZURE_SOURCE_VM_ID:-}"
DURATION_MINUTES="${AZURE_INSTANT_ACCESS_DURATION_MINUTES:-120}"
CONSISTENCY_MODE=""
WAIT_FOR_COMPLETION=true
POLL_SECONDS=10
DEBUG_MODE=false
EXCLUDE_OS_DISK=false
EXCLUDE_DATA_DISKS=()
METADATA_FILE=""
LOG_FILE=""

if [[ $# -gt 0 ]]; then
  case "$1" in
    run-all|rpc|rp|get|instance-view)
      COMMAND="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --rpc-name)
      RPC_NAME="$2"
      shift 2
      ;;
    --rp-name)
      RP_NAME="$2"
      shift 2
      ;;
    --location)
      LOCATION="$2"
      shift 2
      ;;
    --source-vm-id)
      SOURCE_VM_ID="$2"
      shift 2
      ;;
    --duration-minutes)
      DURATION_MINUTES="$2"
      shift 2
      ;;
    --consistency-mode)
      CONSISTENCY_MODE="$2"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_COMPLETION=false
      shift
      ;;
    --poll-seconds)
      POLL_SECONDS="$2"
      shift 2
      ;;
    --debug)
      DEBUG_MODE=true
      shift
      ;;
    --exclude-os-disk)
      EXCLUDE_OS_DISK=true
      shift
      ;;
    --exclude-data-disk)
      EXCLUDE_DATA_DISKS+=("$2")
      shift 2
      ;;
    --metadata-file)
      METADATA_FILE="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ia_log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$LOG_FILE" ]]; then
  # Tee all stdout and stderr to the log file while still printing to the terminal
  exec > >(tee -a "$LOG_FILE") 2>&1
  ia_log "Logging output to: $LOG_FILE"
fi

if [[ "$DEBUG_MODE" == "true" ]]; then
  IA_DEBUG=true
  ia_log "Debug mode enabled."
fi

write_metadata() {
  local metadata_path="$1"
  local rpc_resource_id rp_resource_id created_at

  rpc_resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/restorePointCollections/${RPC_NAME}"
  rp_resource_id="${rpc_resource_id}/restorePoints/${RP_NAME}"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Gather RP details from Azure (best-effort)
  local rp_json="{}"
  rp_json=$(az restore-point show \
    --subscription "$SUBSCRIPTION_ID" \
    -g "$RESOURCE_GROUP" \
    --collection-name "$RPC_NAME" \
    -n "$RP_NAME" \
    -o json 2>/dev/null) || rp_json="{}"

  local provisioning_state consistency_mode_actual instant_access_duration
  provisioning_state=$(echo "$rp_json" | grep -o '"provisioningState"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "")
  consistency_mode_actual=$(echo "$rp_json" | grep -o '"consistencyMode"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "")
  instant_access_duration=$(echo "$rp_json" | grep -o '"instantAccessDurationMinutes"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/.*:[[:space:]]*//' || echo "")

  # Build excluded disks JSON array
  local excluded_disks_arr="[]"
  if [[ "$EXCLUDE_OS_DISK" == "true" ]] || [[ ${#EXCLUDE_DATA_DISKS[@]} -gt 0 ]]; then
    excluded_disks_arr="["
    local _first=true
    if [[ "$EXCLUDE_OS_DISK" == "true" ]]; then
      excluded_disks_arr+='"OS_DISK"'
      _first=false
    fi
    local _ed
    for _ed in "${EXCLUDE_DATA_DISKS[@]+${EXCLUDE_DATA_DISKS[@]}}"; do
      [[ "$_first" == "false" ]] && excluded_disks_arr+=","
      excluded_disks_arr+="\"${_ed}\""
      _first=false
    done
    excluded_disks_arr+="]"
  fi

  cat > "$metadata_path" <<METAEOF
{
  "createdAt": "${created_at}",
  "command": "${COMMAND}",
  "subscriptionId": "${SUBSCRIPTION_ID}",
  "resourceGroup": "${RESOURCE_GROUP}",
  "restorePointCollection": {
    "name": "${RPC_NAME}",
    "resourceId": "${rpc_resource_id}",
    "location": "${LOCATION}",
    "sourceVmId": "${SOURCE_VM_ID}"
  },
  "restorePoint": {
    "name": "${RP_NAME}",
    "resourceId": "${rp_resource_id}",
    "provisioningState": "${provisioning_state}",
    "consistencyMode": "${consistency_mode_actual}",
    "instantAccessDurationMinutes": ${instant_access_duration:-null},
    "excludedDisks": ${excluded_disks_arr}
  }
}
METAEOF

  ia_log "Metadata written to: $metadata_path"
}

require_common() {
  : "${SUBSCRIPTION_ID:?subscription id is required (--subscription-id or AZURE_SUBSCRIPTION_ID)}"
  : "${RESOURCE_GROUP:?resource group is required (--resource-group or AZURE_RESOURCE_GROUP)}"
  : "${RPC_NAME:?restore point collection is required (--rpc-name or AZURE_RESTORE_POINT_COLLECTION)}"
  az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
}

wait_for_restore_point() {
  local timeout_seconds=1800
  local elapsed=0

  while (( elapsed <= timeout_seconds )); do
    local state
    state=$(az restore-point show \
      --subscription "$SUBSCRIPTION_ID" \
      -g "$RESOURCE_GROUP" \
      --collection-name "$RPC_NAME" \
      -n "$RP_NAME" \
      --query provisioningState -o tsv 2>/dev/null || true)

    if [[ "$state" == "Succeeded" ]]; then
      ia_log "Restore point provisioning succeeded: $RP_NAME"
      return 0
    fi

    if [[ "$state" == "Failed" || "$state" == "Canceled" || "$state" == "Cancelled" ]]; then
      ia_log_error "Restore point provisioning ended in state: $state"
      az restore-point show \
        --subscription "$SUBSCRIPTION_ID" \
        -g "$RESOURCE_GROUP" \
        --collection-name "$RPC_NAME" \
        -n "$RP_NAME" >&2 || true
      return 1
    fi

    ia_log "Restore point state: ${state:-NotFoundYet}. Waiting ${POLL_SECONDS}s..."
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done

  ia_log_error "Timed out waiting for restore point provisioning: $RP_NAME"
  return 1
}

run_rpc() {
  require_common
  : "${LOCATION:?location is required (--location or AZURE_LOCATION)}"
  : "${SOURCE_VM_ID:?source VM id is required (--source-vm-id or AZURE_SOURCE_VM_ID)}"
  ia_log "Creating/updating restore point collection..."
  ia_create_or_update_restore_point_collection \
    "$SUBSCRIPTION_ID" \
    "$RESOURCE_GROUP" \
    "$RPC_NAME" \
    "$LOCATION" \
    "$SOURCE_VM_ID" \
    true \
    '{"scenario":"instant-access-bash-example"}'
}

run_rp() {
  require_common
  local rp_name_base timestamp_suffix
  rp_name_base="${RP_NAME:-rp}"
  timestamp_suffix="$(date -u +%Y%m%d%H%M%S)"

  if [[ "$rp_name_base" =~ -[0-9]{14}$ ]]; then
    RP_NAME="$rp_name_base"
  else
    RP_NAME="${rp_name_base}-${timestamp_suffix}"
  fi

  ia_log "Using restore point name: $RP_NAME"

  # --- Build excludeDisks JSON when disk exclusions are requested ---
  local exclude_disks_json=""
  if [[ "$EXCLUDE_OS_DISK" == "true" ]] || [[ ${#EXCLUDE_DATA_DISKS[@]} -gt 0 ]]; then
    local vm_id="${SOURCE_VM_ID:-}"
    if [[ -z "$vm_id" ]]; then
      ia_log "Looking up source VM from restore point collection..."
      vm_id=$(az rest --method get \
        --url "${IA_BASE_URL}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/restorePointCollections/${RPC_NAME}?api-version=${IA_API_VERSION}" \
        --query "properties.source.id" -o tsv 2>/dev/null) || true
      if [[ -z "$vm_id" ]]; then
        ia_log_error "Cannot determine source VM. Provide --source-vm-id."
        return 1
      fi
      ia_debug "Resolved source VM from RPC: $vm_id"
    fi

    local disk_ids=()

    if [[ "$EXCLUDE_OS_DISK" == "true" ]]; then
      local os_disk_id
      os_disk_id=$(az vm show --ids "$vm_id" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null) || true
      if [[ -n "$os_disk_id" ]]; then
        disk_ids+=("$os_disk_id")
        ia_log "Excluding OS disk: $os_disk_id"
      else
        ia_log_error "Could not determine OS disk ID for VM: $vm_id"
        return 1
      fi
    fi

    local _di
    for _di in "${!EXCLUDE_DATA_DISKS[@]}"; do
      local disk_ref="${EXCLUDE_DATA_DISKS[$_di]}"
      if [[ "$disk_ref" == /* ]]; then
        disk_ids+=("$disk_ref")
        ia_log "Excluding data disk: $disk_ref"
      else
        local data_disk_id
        data_disk_id=$(az vm show --ids "$vm_id" \
          --query "storageProfile.dataDisks[?name=='${disk_ref}'].managedDisk.id | [0]" -o tsv 2>/dev/null) || true
        if [[ -n "$data_disk_id" && "$data_disk_id" != "None" && "$data_disk_id" != "null" ]]; then
          disk_ids+=("$data_disk_id")
          ia_log "Excluding data disk '${disk_ref}': $data_disk_id"
        else
          ia_log_error "Data disk '${disk_ref}' not found on VM: $vm_id"
          return 1
        fi
      fi
    done

    if [[ ${#disk_ids[@]} -gt 0 ]]; then
      exclude_disks_json="["
      local _dj
      for _dj in "${!disk_ids[@]}"; do
        (( _dj > 0 )) && exclude_disks_json+=","
        exclude_disks_json+="{\"id\":\"${disk_ids[$_dj]}\"}"
      done
      exclude_disks_json+="]"
      ia_debug "excludeDisks payload: $exclude_disks_json"
    fi
  fi

  ia_log "Creating/updating restore point..."
  ia_create_or_update_restore_point \
    "$SUBSCRIPTION_ID" \
    "$RESOURCE_GROUP" \
    "$RPC_NAME" \
    "$RP_NAME" \
    "$CONSISTENCY_MODE" \
    "$DURATION_MINUTES" \
    "$exclude_disks_json"

  if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
    wait_for_restore_point
  else
    ia_log "Not waiting for provisioning completion (--no-wait)."
  fi

  # Write metadata file
  local meta_path="${METADATA_FILE:-${RP_NAME}.metadata.json}"
  write_metadata "$meta_path"
}

run_get() {
  require_common
  : "${RP_NAME:?restore point name is required (--rp-name or AZURE_RESTORE_POINT_NAME)}"
  ia_log "Getting restore point details..."
  ia_get_restore_point \
    "$SUBSCRIPTION_ID" \
    "$RESOURCE_GROUP" \
    "$RPC_NAME" \
    "$RP_NAME"
}

run_instance_view() {
  require_common
  : "${RP_NAME:?restore point name is required (--rp-name or AZURE_RESTORE_POINT_NAME)}"
  ia_log "Getting restore point instance view..."
  ia_get_restore_point_instance_view \
    "$SUBSCRIPTION_ID" \
    "$RESOURCE_GROUP" \
    "$RPC_NAME" \
    "$RP_NAME"
}

case "$COMMAND" in
  run-all)
    run_rpc
    run_rp
    run_get
    ia_log "Done."
    ;;
  rpc)
    run_rpc
    ;;
  rp)
    run_rp
    ;;
  get)
    run_get
    ;;
  instance-view)
    run_instance_view
    ;;
  *)
    ia_log_error "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
