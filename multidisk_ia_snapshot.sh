#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '%s %s\n' "$(timestamp)" "$*"
}

log_error() {
  printf '%s %s\n' "$(timestamp)" "$*" >&2
}

debug() {
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s [DEBUG] %s\n' "$(timestamp)" "$*" >&2
  fi
}

is_throttling_error() {
  local error_text="$1"
  if echo "$error_text" | grep -qiE 'TooManyRequests|too many requests have been received|retry after|throttl'; then
    return 0
  fi
  return 1
}

az_with_retry() {
  local max_attempts=8
  local attempt=1
  local delay_seconds=5
  local output

  while true; do
    debug "Executing: $*"
    if output=$("$@" 2>&1); then
      [[ -n "$output" ]] && printf '%s\n' "$output"
      return 0
    fi

    local exit_code=$?
    if ! is_throttling_error "$output"; then
      log_error "Azure CLI command failed: $*"
      log_error "$output"
      return $exit_code
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      log_error "Azure throttling persisted after $max_attempts attempts: $*"
      log_error "$output"
      return $exit_code
    fi

    log "Azure throttling detected; retrying in ${delay_seconds}s (attempt ${attempt}/${max_attempts})..."
    sleep "$delay_seconds"
    if [[ "$delay_seconds" -lt 60 ]]; then
      delay_seconds=$((delay_seconds * 2))
      if [[ "$delay_seconds" -gt 60 ]]; then
        delay_seconds=60
      fi
    fi
    attempt=$((attempt + 1))
  done
}

usage() {
  cat <<'EOF'
Usage:
  ./multidisk_ia_snapshot.sh \
    [--auth-method <none|interactive|device-code|service-principal|managed-identity>] \
    [--tenant-id <id>] \
    [--client-id <id>] \
    [--client-secret <secret>] \
    --subscription-id <id> \
    --resource-group <name> \
    --vm-name <name> \
    --snapshot-prefix <prefix> \
    [--target-resource-group <name>] \
    [--incremental] \
    [--copy-start] \
    [--timeout-minutes <int>] \
    [--poll-seconds <int>] \
    [--ia-duration <minutes>] \
    [--only-disks <disk1,disk2,...>] \
    [--log-file <path>] \
    [--debug] \
    [--dry-run]

Description:
  Creates Azure snapshots of each data disk attached to a VM using
  "az snapshot create". Designed for Premium SSD v2 (PremiumV2_LRS) and
  Ultra Disk (UltraSSD_LRS) data disks which require incremental snapshots.

  By default snapshots are created in the same resource group as the VM.
  Use --target-resource-group to store them elsewhere.

Authentication:
  --auth-method <method>         Authentication method (default: none)
                                  none             – skip login; assume already authenticated
                                  interactive      – browser-based interactive login (az login)
                                  device-code      – device-code flow (az login --use-device-code)
                                  service-principal – service principal with client secret
                                  managed-identity – managed identity (az login --identity)
  --tenant-id <id>               Azure AD tenant ID (required for service-principal)
  --client-id <id>               Application (client) ID for service-principal o
                                  user-assigned managed identity client ID
  --client-secret <secret>       Client secret for service-principal auth.
                                  Can also be supplied via AZURE_CLIENT_SECRET env var.

Required:
  --subscription-id <id>         Azure subscription ID
  --resource-group <name>        Resource group containing the source VM
  --vm-name <name>               Name of the source VM
  --snapshot-prefix <prefix>     Prefix for snapshot names
                                  (e.g. "bkp" produces bkp-<disk-name>-<timestamp>)

Snapshot options:
  --incremental                  Create incremental snapshots (required for PV2/Ultra;
                                  enabled by default when PV2 or Ultra disks are detected)
  --copy-start                   Start the snapshot copy as a background operation.
                                  Without this flag, az snapshot create blocks until copy
                                  completes. With it, the script will poll for completion
                                  unless --no-wait is also set.
  --no-wait                      Do not wait for background copy completion
                                  (only relevant with --copy-start)
  --timeout-minutes <int>        Maximum minutes to wait for each snapshot copy
                                  to complete (default: 60)
  --poll-seconds <int>           Seconds between completion polls (default: 15)
  --ia-duration <minutes>        Instant access duration in minutes for the snapshot.
                                  Sets how long the snapshot remains in the instant-access
                                  tier before being moved to standard storage.
                                  Valid range: 1 – 300. No default.

Network access:
  --public-network-access <val>  Public network access setting for the snapshot.
                                  Valid values: Enabled, Disabled (default: Disabled)
  --network-access-policy <val>  Network access policy for the snapshot.
                                  Valid values: AllowAll, AllowPrivate, DenyAll
                                  (default: DenyAll)

Disk selection:
  --only-disks <disk1,...>       Comma-separated list of data disk names to snapshot.
                                  If omitted, all data disks on the VM are included.

Target:
  --target-resource-group <rg>   Resource group for the snapshots.
                                  Defaults to the VM's resource group.

Logging & debug:
  --log-file <path>              Write all output to a log file (terminal output preserved)
  --debug                        Enable verbose debug logging for commands and polling

Output:
  --metadata-file <path>         Write snapshot metadata to a JSON file (creates or replaces).
                                  Contains VM details, parameters, and per-snapshot info.

Other:
  --dry-run                      Print snapshot commands without executing them
  --help                         Show this help

Examples:
  # Snapshot all data disks (auto-detects PV2/Ultra and sets incremental)
  ./multidisk_ia_snapshot.sh \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp

  # Snapshot with background copy, 90-minute timeout, and 2-hour IA duration
  ./multidisk_ia_snapshot.sh \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp \
    --copy-start \
    --timeout-minutes 90 \
    --ia-duration 120

  # Snapshot specific disks into a different resource group
  ./multidisk_ia_snapshot.sh \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp \
    --target-resource-group snapshots-rg \
    --only-disks "datadisk1,datadisk2"

  # Authenticate with a service principal
  ./multidisk_ia_snapshot.sh \
    --auth-method service-principal \
    --tenant-id <tenant> \
    --client-id <app-id> \
    --client-secret <secret> \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp

  # Authenticate with managed identity
  ./multidisk_ia_snapshot.sh \
    --auth-method managed-identity \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp

  # Dry-run with debug logging to a file
  ./multidisk_ia_snapshot.sh \
    --subscription-id <sub> \
    --resource-group <rg> \
    --vm-name <vm> \
    --snapshot-prefix bkp \
    --log-file ./snapshot.log \
    --debug \
    --dry-run
EOF
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AUTH_METHOD="none"
TENANT_ID=""
CLIENT_ID=""
CLIENT_SECRET=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
VM_NAME=""
SNAPSHOT_PREFIX=""
TARGET_RG=""
INCREMENTAL=""          # auto-detected if not set
COPY_START=false
NO_WAIT=false
TIMEOUT_MINUTES=60
POLL_SECONDS=15
IA_DURATION=""
ONLY_DISKS=""
PUBLIC_NETWORK_ACCESS="Disabled"
NETWORK_ACCESS_POLICY="DenyAll"
LOG_FILE=""
METADATA_FILE=""
DEBUG=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-method)
      AUTH_METHOD="$2"
      shift 2
      ;;
    --tenant-id)
      TENANT_ID="$2"
      shift 2
      ;;
    --client-id)
      CLIENT_ID="$2"
      shift 2
      ;;
    --client-secret)
      CLIENT_SECRET="$2"
      shift 2
      ;;
    --subscription-id)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --vm-name)
      VM_NAME="$2"
      shift 2
      ;;
    --snapshot-prefix)
      SNAPSHOT_PREFIX="$2"
      shift 2
      ;;
    --target-resource-group)
      TARGET_RG="$2"
      shift 2
      ;;
    --incremental)
      INCREMENTAL="true"
      shift
      ;;
    --copy-start)
      COPY_START=true
      shift
      ;;
    --no-wait)
      NO_WAIT=true
      shift
      ;;
    --timeout-minutes)
      TIMEOUT_MINUTES="$2"
      shift 2
      ;;
    --poll-seconds)
      POLL_SECONDS="$2"
      shift 2
      ;;
    --ia-duration)
      IA_DURATION="$2"
      shift 2
      ;;
    --only-disks)
      ONLY_DISKS="$2"
      shift 2
      ;;
    --public-network-access)
      PUBLIC_NETWORK_ACCESS="$2"
      shift 2
      ;;
    --network-access-policy)
      NETWORK_ACCESS_POLICY="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --metadata-file)
      METADATA_FILE="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Log file setup (tee to file while preserving terminal output)
# ---------------------------------------------------------------------------
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Logging output to: $LOG_FILE"
fi

if [[ "$DEBUG" == "true" ]]; then
  log "Debug mode enabled."
fi

# ---------------------------------------------------------------------------
# Verify Azure CLI is installed and meets minimum version requirement
# ---------------------------------------------------------------------------
REQUIRED_AZ_VERSION="2.83.0"

if ! command -v az &>/dev/null; then
  log_error "Azure CLI (az) is not installed or not on PATH."
  log_error "Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi

AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null) || AZ_VERSION=""
if [[ -z "$AZ_VERSION" ]]; then
  log_error "Unable to determine Azure CLI version."
  exit 1
fi

# Compare versions: split on '.' and compare numerically
version_gte() {
  local IFS='.'
  local -a v1=($1) v2=($2)
  for i in 0 1 2; do
    local a="${v1[$i]:-0}" b="${v2[$i]:-0}"
    if (( a > b )); then return 0; fi
    if (( a < b )); then return 1; fi
  done
  return 0
}

if ! version_gte "$AZ_VERSION" "$REQUIRED_AZ_VERSION"; then
  log_error "Azure CLI version $AZ_VERSION is too old. Version >= $REQUIRED_AZ_VERSION is required."
  log_error "Upgrade with: az upgrade"
  exit 1
fi

log "Azure CLI version $AZ_VERSION (>= $REQUIRED_AZ_VERSION) — OK"

# ---------------------------------------------------------------------------
# Azure Authentication
# ---------------------------------------------------------------------------
azure_authenticate() {
  local method="$1"

  case "$method" in
    none)
      log "Auth method: none — assuming already authenticated."
      ;;

    interactive)
      log "Auth method: interactive — launching browser login..."
      local login_args=(login)
      [[ -n "$TENANT_ID" ]] && login_args+=(--tenant "$TENANT_ID")
      if ! az_with_retry az "${login_args[@]}" -o none; then
        log_error "Interactive login failed."
        exit 1
      fi
      log "Interactive login succeeded."
      ;;

    device-code)
      log "Auth method: device-code — follow the instructions below..."
      local login_args=(login --use-device-code)
      [[ -n "$TENANT_ID" ]] && login_args+=(--tenant "$TENANT_ID")
      if ! az "${login_args[@]}" -o none; then
        log_error "Device-code login failed."
        exit 1
      fi
      log "Device-code login succeeded."
      ;;

    service-principal)
      log "Auth method: service-principal"
      if [[ -z "$TENANT_ID" ]]; then
        log_error "--tenant-id is required for service-principal authentication."
        exit 1
      fi
      if [[ -z "$CLIENT_ID" ]]; then
        log_error "--client-id is required for service-principal authentication."
        exit 1
      fi
      # Allow client secret from argument or AZURE_CLIENT_SECRET env va
      if [[ -z "$CLIENT_SECRET" ]]; then
        CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
      fi
      if [[ -z "$CLIENT_SECRET" ]]; then
        log_error "--client-secret or AZURE_CLIENT_SECRET env var is required for service-principal authentication."
        exit 1
      fi
      if ! az_with_retry az login --service-principal \
           --username "$CLIENT_ID" \
           --password "$CLIENT_SECRET" \
           --tenant "$TENANT_ID" \
           -o none; then
        log_error "Service-principal login failed."
        exit 1
      fi
      log "Service-principal login succeeded."
      ;;

    managed-identity)
      log "Auth method: managed-identity"
      local login_args=(login --identity)
      if [[ -n "$CLIENT_ID" ]]; then
        login_args+=(--username "$CLIENT_ID")
        debug "Using user-assigned managed identity with client-id: $CLIENT_ID"
      fi
      if ! az_with_retry az "${login_args[@]}" -o none; then
        log_error "Managed-identity login failed."
        exit 1
      fi
      log "Managed-identity login succeeded."
      ;;

    *)
      log_error "Unknown --auth-method: $method"
      log_error "Valid values: none, interactive, device-code, service-principal, managed-identity"
      exit 1
      ;;
  esac
}

azure_authenticate "$AUTH_METHOD"

# Verify authentication — confirm the CLI can reach Azure
log "Verifying Azure CLI authentication..."
if ! az account show -o none 2>/dev/null; then
  log_error "Azure CLI is not authenticated. Please log in first or use --auth-method."
  exit 1
fi
LOGGED_IN_TYPE=$(az account show --query "user.type" -o tsv 2>/dev/null) || LOGGED_IN_TYPE="?"
LOGGED_IN_NAME=$(az account show --query "user.name" -o tsv 2>/dev/null) || LOGGED_IN_NAME="?"
log "Authenticated as ${LOGGED_IN_TYPE}: ${LOGGED_IN_NAME}"

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  log_error "--subscription-id is required."
  usage
  exit 1
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  log_error "--resource-group is required."
  usage
  exit 1
fi

if [[ -z "$VM_NAME" ]]; then
  log_error "--vm-name is required."
  usage
  exit 1
fi

if [[ -z "$SNAPSHOT_PREFIX" ]]; then
  log_error "--snapshot-prefix is required."
  usage
  exit 1
fi

if [[ -z "$TARGET_RG" ]]; then
  TARGET_RG="$RESOURCE_GROUP"
  log "No --target-resource-group specified; using source resource group: $TARGET_RG"
fi

if [[ -n "$IA_DURATION" ]]; then
  if ! [[ "$IA_DURATION" =~ ^[0-9]+$ ]]; then
    log_error "--ia-duration must be a positive integer (got: $IA_DURATION)."
    exit 1
  fi
  if (( IA_DURATION < 1 || IA_DURATION > 300 )); then
    log_error "--ia-duration must be between 1 and 300 minutes. Got: $IA_DURATION."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Set subscription context
# ---------------------------------------------------------------------------
log "Setting Azure subscription context..."
az_with_retry az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run mode enabled: snapshot commands will be printed only."
fi

# ---------------------------------------------------------------------------
# Get VM details and enumerate data disks
# ---------------------------------------------------------------------------
log "Reading VM details for: $VM_NAME ..."

VM_LOCATION=$(az_with_retry az vm show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "location" -o tsv)
debug "VM location: $VM_LOCATION"

# Extract data disk details: name|id|sku
# Use JMESPath list syntax [].[field,...] to guarantee column order (name, id, sku)
mapfile -t DISK_ENTRIES < <(az_with_retry az vm show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "storageProfile.dataDisks[].[name, managedDisk.id, managedDisk.storageAccountType]" \
  -o tsv | while IFS=$'\t' read -r d_name d_id d_sku; do
    [[ -z "$d_name" || -z "$d_id" ]] && continue
    printf '%s|%s|%s\n' "$d_name" "$d_id" "${d_sku:-}"
  done
)

if [[ ${#DISK_ENTRIES[@]} -eq 0 ]]; then
  log_error "No data disks found on VM $VM_NAME."
  exit 1
fi

log "Found ${#DISK_ENTRIES[@]} data disk(s) on VM $VM_NAME:"
for entry in "${DISK_ENTRIES[@]}"; do
  IFS='|' read -r d_name d_id d_sku <<< "$entry"
  log "  $d_name (sku=$d_sku)"
  debug "    id=$d_id"
done

# ---------------------------------------------------------------------------
# Apply --only-disks filte
# ---------------------------------------------------------------------------
SELECTED_ENTRIES=()
if [[ -n "$ONLY_DISKS" ]]; then
  IFS=',' read -r -a REQUESTED <<< "$ONLY_DISKS"
  for req in "${REQUESTED[@]}"; do
    trimmed="${req#"${req%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue

    found=false
    for entry in "${DISK_ENTRIES[@]}"; do
      IFS='|' read -r d_name _ _ <<< "$entry"
      if [[ "$d_name" == "$trimmed" ]]; then
        SELECTED_ENTRIES+=("$entry")
        found=true
        break
      fi
    done

    if [[ "$found" != "true" ]]; then
      log_error "Requested disk '$trimmed' not found on VM $VM_NAME."
      log_error "Available data disks:"
      for entry in "${DISK_ENTRIES[@]}"; do
        IFS='|' read -r d_name _ _ <<< "$entry"
        log_error "  $d_name"
      done
      exit 1
    fi
  done
  log "Snapshotting subset of ${#SELECTED_ENTRIES[@]} disk(s)."
else
  SELECTED_ENTRIES=("${DISK_ENTRIES[@]}")
  log "Snapshotting all ${#SELECTED_ENTRIES[@]} data disk(s)."
fi

# ---------------------------------------------------------------------------
# Auto-detect incremental requirement for PV2 / Ultra disks
# ---------------------------------------------------------------------------
if [[ -z "$INCREMENTAL" ]]; then
  HAS_PV2_OR_ULTRA=false
  for entry in "${SELECTED_ENTRIES[@]}"; do
    IFS='|' read -r d_name d_id d_sku <<< "$entry"
    # SKU might not come from VM show; fetch from disk if empty
    if [[ -z "$d_sku" ]]; then
      d_sku=$(az_with_retry az disk show --ids "$d_id" --query "sku.name" -o tsv 2>/dev/null) || d_sku=""
    fi
    if [[ "$d_sku" == "PremiumV2_LRS" || "$d_sku" == "UltraSSD_LRS" ]]; then
      HAS_PV2_OR_ULTRA=true
      break
    fi
  done

  if [[ "$HAS_PV2_OR_ULTRA" == "true" ]]; then
    INCREMENTAL="true"
    log "PremiumV2 or Ultra Disk detected — enabling incremental snapshots automatically."
  else
    INCREMENTAL="false"
  fi
fi

# ---------------------------------------------------------------------------
# Build a UTC timestamp suffix for snapshot names
# ---------------------------------------------------------------------------
TIMESTAMP_SUFFIX="$(date -u +%Y%m%d%H%M%S)"

# ---------------------------------------------------------------------------
# Create snapshots (parallel execution)
# ---------------------------------------------------------------------------
CREATED_SNAPSHOT_NAMES=()
CREATED_SNAPSHOT_IDS=()
CREATED_DISK_NAMES=()
CREATED_DISK_IDS=()
CREATED_DISK_SKUS=()
CREATED_DISK_SIZES=()
PENDING_BG_SNAPSHOTS=()    # for --copy-start: names that need polling

# Temp directory for capturing parallel snapshot output
SNAP_TEMP_DIR=$(mktemp -d)
declare -a SNAP_PIDS=()
SNAP_IDX=0

# --- Phase 1: Resolve disk info and launch snapshot creation in parallel ---
for entry in "${SELECTED_ENTRIES[@]}"; do
  IFS='|' read -r DISK_NAME DISK_ID DISK_SKU <<< "$entry"
  SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-${DISK_NAME}-${TIMESTAMP_SUFFIX}"

  # Resolve SKU if not available from VM show
  if [[ -z "$DISK_SKU" ]]; then
    DISK_SKU=$(az_with_retry az disk show --ids "$DISK_ID" --query "sku.name" -o tsv 2>/dev/null) || DISK_SKU="unknown"
    debug "Resolved disk SKU via CLI: $DISK_SKU"
  fi

  # Resolve disk size (needed for logging)
  DISK_SIZE_GB=$(az_with_retry az disk show --ids "$DISK_ID" --query "diskSizeGb" -o tsv 2>/dev/null) || DISK_SIZE_GB="unknown"

  log "Creating snapshot: $SNAPSHOT_NAME"
  log "  Source disk: $DISK_NAME ($DISK_SKU, ${DISK_SIZE_GB} GiB)"
  log "  Target RG:   $TARGET_RG"
  log "  Incremental: $INCREMENTAL"
  [[ -n "$IA_DURATION" ]] && log "  IA duration: ${IA_DURATION} minutes"

  # Store disk info (indexed for result collection later)
  CREATED_SNAPSHOT_NAMES+=("$SNAPSHOT_NAME")
  CREATED_DISK_NAMES+=("$DISK_NAME")
  CREATED_DISK_IDS+=("$DISK_ID")
  CREATED_DISK_SKUS+=("$DISK_SKU")
  CREATED_DISK_SIZES+=("$DISK_SIZE_GB")

  # Build az snapshot create command
  SNAP_ARGS=(snapshot create
    --subscription "$SUBSCRIPTION_ID"
    --resource-group "$TARGET_RG"
    --name "$SNAPSHOT_NAME"
    --location "$VM_LOCATION"
    --source "$DISK_ID"
    --incremental "$INCREMENTAL"
    --public-network-access "$PUBLIC_NETWORK_ACCESS"
    --network-access-policy "$NETWORK_ACCESS_POLICY")

  if [[ -n "$IA_DURATION" ]]; then
    SNAP_ARGS+=(--instant-access-duration-minutes "$IA_DURATION")
  fi

  if [[ "$COPY_START" == "true" ]]; then
    SNAP_ARGS+=(--copy-start true)
    debug "  Background copy mode (CopyStart)"
  fi

  debug "az ${SNAP_ARGS[*]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] az ${SNAP_ARGS[*]}"
    printf '%s' "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.Compute/snapshots/${SNAPSHOT_NAME}" \
      > "$SNAP_TEMP_DIR/${SNAP_IDX}.id"
    printf '0' > "$SNAP_TEMP_DIR/${SNAP_IDX}.exit"
  else
    # Launch snapshot creation in a background subshell
    CUR_IDX=$SNAP_IDX
    (
      snap_out=$(az_with_retry az "${SNAP_ARGS[@]}" --query "id" -o tsv 2>&1)
      snap_rc=$?
      printf '%s' "$snap_out" > "$SNAP_TEMP_DIR/${CUR_IDX}.id"
      printf '%s' "$snap_rc" > "$SNAP_TEMP_DIR/${CUR_IDX}.exit"
    ) &
    SNAP_PIDS+=($!)
    log "  Launched in background (PID $!)"
  fi

  SNAP_IDX=$((SNAP_IDX + 1))
done

# --- Phase 2: Wait for all parallel snapshot creations to complete ---
if [[ "$DRY_RUN" != "true" && ${#SNAP_PIDS[@]} -gt 0 ]]; then
  log ""
  log "Waiting for ${#SNAP_PIDS[@]} parallel snapshot creation(s) to complete..."
  for pid in "${SNAP_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  log "All snapshot creations have returned."
fi

# --- Phase 3: Collect results, verify IA duration, track for polling ---
SNAP_FAILURES=0
for i in "${!CREATED_SNAPSHOT_NAMES[@]}"; do
  SNAPSHOT_NAME="${CREATED_SNAPSHOT_NAMES[$i]}"

  snap_exit=$(cat "$SNAP_TEMP_DIR/${i}.exit" 2>/dev/null) || snap_exit="1"
  snap_output=$(cat "$SNAP_TEMP_DIR/${i}.id" 2>/dev/null) || snap_output=""

  if [[ "$snap_exit" != "0" ]]; then
    log_error "Failed to create snapshot $SNAPSHOT_NAME:"
    log_error "$snap_output"
    CREATED_SNAPSHOT_IDS+=("")
    SNAP_FAILURES=$((SNAP_FAILURES + 1))
    continue
  fi

  SNAP_ID="$snap_output"
  CREATED_SNAPSHOT_IDS+=("$SNAP_ID")
  log "  Snapshot ready: $SNAPSHOT_NAME"
  debug "    $SNAP_ID"

  # Verify instant access duration was set if requested
  if [[ -n "$IA_DURATION" && "$DRY_RUN" != "true" ]]; then
    set +e
    IA_OUTPUT=$(az_with_retry az snapshot show \
      --subscription "$SUBSCRIPTION_ID" \
      --resource-group "$TARGET_RG" \
      --name "$SNAPSHOT_NAME" \
      --query "creationData.instantAccessDurationMinutes" -o tsv 2>&1)
    IA_EXIT=$?
    set -e
    if [[ $IA_EXIT -ne 0 || -z "$IA_OUTPUT" || "$IA_OUTPUT" == "None" ]]; then
      log "  WARNING: Could not verify instant access duration on $SNAPSHOT_NAME"
      # Attempt to set it via snapshot update as fallback
      log "  Attempting snapshot update to set instant access duration..."
      debug "az snapshot update --subscription $SUBSCRIPTION_ID -g $TARGET_RG -n $SNAPSHOT_NAME --set creationData.instantAccessDurationMinutes=$IA_DURATION"
      set +e
      IA_PATCH_OUTPUT=$(az_with_retry az snapshot update \
        --subscription "$SUBSCRIPTION_ID" \
        --resource-group "$TARGET_RG" \
        --name "$SNAPSHOT_NAME" \
        --set "creationData.instantAccessDurationMinutes=$IA_DURATION" \
        --query "creationData.instantAccessDurationMinutes" -o tsv 2>&1)
      IA_PATCH_EXIT=$?
      set -e
      if [[ $IA_PATCH_EXIT -ne 0 ]]; then
        log_error "  WARNING: Failed to set instant access duration on $SNAPSHOT_NAME:"
        log_error "  $IA_PATCH_OUTPUT"
      else
        log "  Instant access duration set: ${IA_PATCH_OUTPUT} minutes"
      fi
    else
      log "  Instant access duration set: ${IA_OUTPUT} minutes"
    fi
  fi

  # Track background-copy snapshots for polling
  if [[ "$COPY_START" == "true" && "$DRY_RUN" != "true" ]]; then
    PENDING_BG_SNAPSHOTS+=("$SNAPSHOT_NAME")
  fi
done

rm -rf "$SNAP_TEMP_DIR"

if [[ $SNAP_FAILURES -gt 0 ]]; then
  log_error "$SNAP_FAILURES of ${#CREATED_SNAPSHOT_NAMES[@]} snapshot creation(s) failed."
  exit 1
fi

# ---------------------------------------------------------------------------
# Poll for background copy completion (--copy-start mode)
# ---------------------------------------------------------------------------
if [[ "$COPY_START" == "true" && "$NO_WAIT" != "true" && "$DRY_RUN" != "true" && ${#PENDING_BG_SNAPSHOTS[@]} -gt 0 ]]; then
  log ""
  log "Waiting for background snapshot copies to complete..."
  log "  Timeout: ${TIMEOUT_MINUTES} minutes per snapshot"
  log "  Poll interval: ${POLL_SECONDS} seconds"

  TIMEOUT_SECS=$(( TIMEOUT_MINUTES * 60 ))

  for snap_name in "${PENDING_BG_SNAPSHOTS[@]}"; do
    log "Polling snapshot: $snap_name ..."
    elapsed=0

    while (( elapsed < TIMEOUT_SECS )); do
      PROV_STATE=$(az_with_retry az snapshot show \
        --subscription "$SUBSCRIPTION_ID" \
        --resource-group "$TARGET_RG" \
        --name "$snap_name" \
        --query "provisioningState" -o tsv 2>/dev/null) || PROV_STATE=""
      COMP_PERCENT=$(az_with_retry az snapshot show \
        --subscription "$SUBSCRIPTION_ID" \
        --resource-group "$TARGET_RG" \
        --name "$snap_name" \
        --query "completionPercent" -o tsv 2>/dev/null) || COMP_PERCENT=""

      debug "  $snap_name: provisioningState=$PROV_STATE completionPercent=$COMP_PERCENT elapsed=${elapsed}s"

      if [[ "$PROV_STATE" == "Succeeded" ]]; then
        log "  $snap_name: copy completed (provisioningState=Succeeded)"
        break
      fi

      if [[ "$PROV_STATE" == "Failed" ]]; then
        COPY_ERR=$(az_with_retry az snapshot show \
          --subscription "$SUBSCRIPTION_ID" \
          --resource-group "$TARGET_RG" \
          --name "$snap_name" \
          --query "copyCompletionError" -o json 2>/dev/null) || COPY_ERR="unknown"
        log_error "  $snap_name: copy FAILED."
        log_error "  Error: $COPY_ERR"
        exit 1
      fi

      pct_display="${COMP_PERCENT:-?}"
      log "  $snap_name: ${pct_display}% complete (state=$PROV_STATE). Waiting ${POLL_SECONDS}s..."
      sleep "$POLL_SECONDS"
      elapsed=$(( elapsed + POLL_SECONDS ))
    done

    if (( elapsed >= TIMEOUT_SECS )); then
      log_error "  $snap_name: timed out after ${TIMEOUT_MINUTES} minutes."
      log_error "  The snapshot copy is still in progress. Check manually:"
      log_error "    az snapshot show --subscription ${SUBSCRIPTION_ID} -g ${TARGET_RG} -n ${snap_name} --query '{state:provisioningState, pct:completionPercent}'"
      exit 1
    fi
  done
elif [[ "$COPY_START" == "true" && "$NO_WAIT" == "true" && "$DRY_RUN" != "true" ]]; then
  log ""
  log "Background copy started for ${#PENDING_BG_SNAPSHOTS[@]} snapshot(s). Not waiting (--no-wait)."
  log "Check progress manually:"
  for snap_name in "${PENDING_BG_SNAPSHOTS[@]}"; do
    log "  az snapshot show --subscription ${SUBSCRIPTION_ID} -g ${TARGET_RG} -n ${snap_name} --query '{state:provisioningState, pct:completionPercent}'"
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Snapshot creation completed"
log "========================================="
log "Snapshots created: ${#CREATED_SNAPSHOT_NAMES[@]}"
for i in "${!CREATED_SNAPSHOT_NAMES[@]}"; do
  log "  ${CREATED_SNAPSHOT_NAMES[$i]}"
  debug "    ${CREATED_SNAPSHOT_IDS[$i]}"
done
log ""
log "Source VM:        $VM_NAME"
log "Source RG:        $RESOURCE_GROUP"
log "Target RG:        $TARGET_RG"
log "Incremental:      $INCREMENTAL"
log "Copy-start:       $COPY_START"

# ---------------------------------------------------------------------------
# Write metadata file (optional)
# ---------------------------------------------------------------------------
if [[ -n "$METADATA_FILE" ]]; then
  log ""
  log "Writing metadata to $METADATA_FILE ..."

  # Build JSON snapshots array
  META_SNAPSHOTS="["
  for i in "${!CREATED_SNAPSHOT_NAMES[@]}"; do
    [[ $i -gt 0 ]] && META_SNAPSHOTS+=","
    # Escape any double quotes in values (unlikely but safe)
    s_name="${CREATED_SNAPSHOT_NAMES[$i]//\"/\\\"}"
    s_id="${CREATED_SNAPSHOT_IDS[$i]//\"/\\\"}"
    d_name="${CREATED_DISK_NAMES[$i]//\"/\\\"}"
    d_id="${CREATED_DISK_IDS[$i]//\"/\\\"}"
    d_sku="${CREATED_DISK_SKUS[$i]//\"/\\\"}"
    d_size="${CREATED_DISK_SIZES[$i]//\"/\\\"}"
    META_SNAPSHOTS+=$(printf '{"snapshotName":"%s","snapshotId":"%s","sourceDiskName":"%s","sourceDiskId":"%s","diskSku":"%s","diskSizeGb":"%s"}' \
      "$s_name" "$s_id" "$d_name" "$d_id" "$d_sku" "$d_size")
  done
  META_SNAPSHOTS+="]"

  # Build full metadata JSON
  META_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$METADATA_FILE" <<EOMETA
{
  "timestamp": "${META_TIMESTAMP}",
  "vm": {
    "name": "${VM_NAME}",
    "resourceGroup": "${RESOURCE_GROUP}",
    "subscriptionId": "${SUBSCRIPTION_ID}",
    "location": "${VM_LOCATION}"
  },
  "parameters": {
    "snapshotPrefix": "${SNAPSHOT_PREFIX}",
    "targetResourceGroup": "${TARGET_RG}",
    "incremental": ${INCREMENTAL},
    "copyStart": ${COPY_START},
    "iaAccessDurationMinutes": ${IA_DURATION:-null},
    "azCliVersion": "${AZ_VERSION}"
  },
  "snapshotCount": ${#CREATED_SNAPSHOT_NAMES[@]},
  "snapshots": ${META_SNAPSHOTS}
}
EOMETA

  log "Metadata written to $METADATA_FILE"
fi

log "Done."
