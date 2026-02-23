#!/usr/bin/env bash

set -euo pipefail

# ===========================================================================
# multidisk_ia_hydrate_attach.sh
#
# Creates managed disks from snapshots recorded in a metadata JSON file
# (produced by multidisk_ia_snapshot.sh) and attaches them to a target VM.
#
# Optionally detaches existing data disks from the target VM first.
# ===========================================================================

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
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file <path> \
    --target-vm-name <name> \
    --target-resource-group <name> \
    [--target-subscription-id <id>] \
    [--disk-prefix <prefix>] \
    [--disk-sku <sku>] \
    [--detach-existing] \
    [--detach-disks <disk1,disk2,...>] \
    [--delete-after-detach] \
    [--starting-lun <int>] \
    [--auth-method <none|interactive|device-code|service-principal|managed-identity>] \
    [--tenant-id <id>] \
    [--client-id <id>] \
    [--client-secret <secret>] \
    [--log-file <path>] \
    [--debug] \
    [--dry-run]

Description:
  Creates managed disks from snapshots recorded in a metadata JSON file
  (produced by multidisk_ia_snapshot.sh), then attaches them to a target VM.

  The metadata file contains snapshot IDs, source disk names, SKUs, and sizes.
  This script reads those fields and issues "az disk create --source <snapshot>"
  for each entry, then "az vm disk attach" to mount each new disk on the
  target VM.

  Optionally, existing data disks on the target VM can be detached (and
  deleted) before the new disks are attached.

Authentication:
  --auth-method <method>         Authentication method (default: none)
                                  none             – skip login; assume already authenticated
                                  interactive      – browser-based interactive login (az login)
                                  device-code      – device-code flow (az login --use-device-code)
                                  service-principal – service principal with client secret
                                  managed-identity – managed identity (az login --identity)
  --tenant-id <id>               Azure AD tenant ID (required for service-principal)
  --client-id <id>               Application (client) ID for service-principal or
                                  user-assigned managed identity client ID
  --client-secret <secret>       Client secret for service-principal auth.
                                  Can also be supplied via AZURE_CLIENT_SECRET env var.

Required:
  --metadata-file <path>         Path to the JSON metadata file produced by
                                  multidisk_ia_snapshot.sh
  --target-vm-name <name>        Name of the target VM to attach disks to
  --target-resource-group <name> Resource group containing the target VM

Disk creation:
  --target-subscription-id <id>  Azure subscription for the target VM and new disks.
                                  Defaults to the subscription in the metadata file.
  --disk-prefix <prefix>         Prefix for new disk names (default: "restored").
                                  Disks are named <prefix>-<sourceDiskName>.
  --disk-sku <sku>               Override the disk SKU for all new disks.
                                  If omitted, uses the original SKU from the metadata.
                                  Examples: PremiumV2_LRS, UltraSSD_LRS, Premium_LRS

Detach options:
  --detach-existing              Detach ALL existing data disks from the target VM
                                  before attaching the new ones.
  --detach-disks <disk1,...>     Comma-separated list of specific disk names to detach
                                  from the target VM. Cannot be combined with
                                  --detach-existing.
  --delete-after-detach          Delete detached disks after detaching them.
                                  Use with caution — this is irreversible.

Attach options:
  --starting-lun <int>           Starting LUN number for attaching new disks
                                  (default: 0). Increment by 1 for each disk.

Logging & debug:
  --log-file <path>              Write all output to a log file (terminal output preserved)
  --debug                        Enable verbose debug logging

Other:
  --dry-run                      Print commands without executing them
  --help                         Show this help

Examples:
  # Create disks from snapshots and attach to a test VM
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file ./snapshot-metadata.json \
    --target-vm-name test-vm \
    --target-resource-group test-rg

  # Detach all existing data disks first, then attach new ones
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file ./snapshot-metadata.json \
    --target-vm-name test-vm \
    --target-resource-group test-rg \
    --detach-existing

  # Detach specific disks, delete them, then attach new ones with a custom prefix
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file ./snapshot-metadata.json \
    --target-vm-name test-vm \
    --target-resource-group test-rg \
    --detach-disks "old-disk1,old-disk2" \
    --delete-after-detach \
    --disk-prefix "clone"

  # Override the disk SKU for all new disks
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file ./snapshot-metadata.json \
    --target-vm-name test-vm \
    --target-resource-group test-rg \
    --disk-sku Premium_LRS \
    --detach-existing

  # Dry-run with debug output
  ./multidisk_ia_hydrate_attach.sh \
    --metadata-file ./snapshot-metadata.json \
    --target-vm-name test-vm \
    --target-resource-group test-rg \
    --detach-existing \
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
METADATA_FILE=""
TARGET_VM=""
TARGET_RG=""
TARGET_SUBSCRIPTION=""
DISK_PREFIX="restored"
DISK_SKU_OVERRIDE=""
DETACH_EXISTING=false
DETACH_DISKS=""
DELETE_AFTER_DETACH=false
STARTING_LUN=0
LOG_FILE=""
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
    --metadata-file)
      METADATA_FILE="$2"
      shift 2
      ;;
    --target-vm-name)
      TARGET_VM="$2"
      shift 2
      ;;
    --target-resource-group)
      TARGET_RG="$2"
      shift 2
      ;;
    --target-subscription-id)
      TARGET_SUBSCRIPTION="$2"
      shift 2
      ;;
    --disk-prefix)
      DISK_PREFIX="$2"
      shift 2
      ;;
    --disk-sku)
      DISK_SKU_OVERRIDE="$2"
      shift 2
      ;;
    --detach-existing)
      DETACH_EXISTING=true
      shift
      ;;
    --detach-disks)
      DETACH_DISKS="$2"
      shift 2
      ;;
    --delete-after-detach)
      DELETE_AFTER_DETACH=true
      shift
      ;;
    --starting-lun)
      STARTING_LUN="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
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
# Log file setup
# ---------------------------------------------------------------------------
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Logging output to: $LOG_FILE"
fi

if [[ "$DEBUG" == "true" ]]; then
  log "Debug mode enabled."
fi

# ---------------------------------------------------------------------------
# Verify Azure CLI is installed
# ---------------------------------------------------------------------------
if ! command -v az &>/dev/null; then
  log_error "Azure CLI (az) is not installed or not on PATH."
  log_error "Install it from: https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify jq is installed
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  log_error "jq is not installed or not on PATH."
  log_error "Install it from: https://stedolan.github.io/jq/download/"
  exit 1
fi

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

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
if [[ -z "$METADATA_FILE" ]]; then
  log_error "--metadata-file is required."
  usage
  exit 1
fi

if [[ ! -f "$METADATA_FILE" ]]; then
  log_error "Metadata file not found: $METADATA_FILE"
  exit 1
fi

if [[ -z "$TARGET_VM" ]]; then
  log_error "--target-vm-name is required."
  usage
  exit 1
fi

if [[ -z "$TARGET_RG" ]]; then
  log_error "--target-resource-group is required."
  usage
  exit 1
fi

if [[ "$DETACH_EXISTING" == "true" && -n "$DETACH_DISKS" ]]; then
  log_error "--detach-existing and --detach-disks cannot be used together."
  log_error "Use --detach-existing to detach ALL data disks, or --detach-disks to detach specific ones."
  exit 1
fi

if ! [[ "$STARTING_LUN" =~ ^[0-9]+$ ]]; then
  log_error "--starting-lun must be a non-negative integer (got: $STARTING_LUN)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Read metadata file
# ---------------------------------------------------------------------------
log "Reading metadata file: $METADATA_FILE"

META_TIMESTAMP=$(jq -r '.timestamp' "$METADATA_FILE")
SOURCE_VM=$(jq -r '.vm.name' "$METADATA_FILE")
SOURCE_RG=$(jq -r '.vm.resourceGroup' "$METADATA_FILE")
SOURCE_SUBSCRIPTION=$(jq -r '.vm.subscriptionId' "$METADATA_FILE")
SOURCE_LOCATION=$(jq -r '.vm.location' "$METADATA_FILE")
SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA_FILE")
SNAPSHOT_PREFIX=$(jq -r '.parameters.snapshotPrefix' "$METADATA_FILE")

if [[ -z "$TARGET_SUBSCRIPTION" ]]; then
  TARGET_SUBSCRIPTION="$SOURCE_SUBSCRIPTION"
  debug "No --target-subscription-id specified; using source subscription: $TARGET_SUBSCRIPTION"
fi

log ""
log "Metadata summary:"
log "  Created:          $META_TIMESTAMP"
log "  Source VM:         $SOURCE_VM (rg=$SOURCE_RG)"
log "  Source sub:        $SOURCE_SUBSCRIPTION"
log "  Location:          $SOURCE_LOCATION"
log "  Snapshot prefix:   $SNAPSHOT_PREFIX"
log "  Snapshot count:    $SNAP_COUNT"
log ""
log "Target:"
log "  VM:               $TARGET_VM"
log "  Resource group:    $TARGET_RG"
log "  Subscription:      $TARGET_SUBSCRIPTION"
log "  Disk prefix:       $DISK_PREFIX"
if [[ -n "$DISK_SKU_OVERRIDE" ]]; then
  log "  Disk SKU override: $DISK_SKU_OVERRIDE"
fi
log ""

if [[ "$SNAP_COUNT" -eq 0 ]]; then
  log_error "Metadata file contains 0 snapshots. Nothing to do."
  exit 1
fi

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------
azure_authenticate "$AUTH_METHOD"

log "Verifying Azure CLI authentication..."
if ! az account show -o none 2>/dev/null; then
  log_error "Azure CLI is not authenticated. Please log in first or use --auth-method."
  exit 1
fi
LOGGED_IN_TYPE=$(az account show --query "user.type" -o tsv 2>/dev/null) || LOGGED_IN_TYPE="?"
LOGGED_IN_NAME=$(az account show --query "user.name" -o tsv 2>/dev/null) || LOGGED_IN_NAME="?"
log "Authenticated as ${LOGGED_IN_TYPE}: ${LOGGED_IN_NAME}"

# Set subscription context
log "Setting Azure subscription context to: $TARGET_SUBSCRIPTION"
az_with_retry az account set --subscription "$TARGET_SUBSCRIPTION" >/dev/null

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run mode enabled: commands will be printed only."
fi

# ---------------------------------------------------------------------------
# Verify target VM exists
# ---------------------------------------------------------------------------
log "Verifying target VM: $TARGET_VM ..."
if [[ "$DRY_RUN" != "true" ]]; then
  TARGET_VM_LOCATION=$(az_with_retry az vm show \
    --subscription "$TARGET_SUBSCRIPTION" \
    --resource-group "$TARGET_RG" \
    --name "$TARGET_VM" \
    --query "location" -o tsv) || {
    log_error "Failed to retrieve target VM: $TARGET_VM in $TARGET_RG"
    exit 1
  }
  log "Target VM location: $TARGET_VM_LOCATION"

  # Use target VM location for new disks
  DISK_LOCATION="$TARGET_VM_LOCATION"
else
  DISK_LOCATION="$SOURCE_LOCATION"
  log "[DRY-RUN] Skipping VM verification; using source location: $DISK_LOCATION"
fi

# ---------------------------------------------------------------------------
# Detach existing data disks (if requested)
# ---------------------------------------------------------------------------
DETACHED_DISK_NAMES=()
DETACHED_DISK_IDS=()

if [[ "$DETACH_EXISTING" == "true" ]]; then
  log ""
  log "========================================="
  log " Detaching ALL existing data disks"
  log "========================================="

  if [[ "$DRY_RUN" != "true" ]]; then
    # Get list of currently attached data disks
    mapfile -t EXISTING_DISKS < <(az_with_retry az vm show \
      --subscription "$TARGET_SUBSCRIPTION" \
      --resource-group "$TARGET_RG" \
      --name "$TARGET_VM" \
      --query "storageProfile.dataDisks[].[name, managedDisk.id]" \
      -o tsv | while IFS=$'\t' read -r d_name d_id; do
        [[ -z "$d_name" ]] && continue
        printf '%s|%s\n' "$d_name" "$d_id"
      done
    )

    if [[ ${#EXISTING_DISKS[@]} -eq 0 ]]; then
      log "No existing data disks found on $TARGET_VM."
    else
      log "Found ${#EXISTING_DISKS[@]} existing data disk(s) to detach:"
      for entry in "${EXISTING_DISKS[@]}"; do
        IFS='|' read -r d_name d_id <<< "$entry"
        log "  $d_name"
        debug "    $d_id"
        DETACHED_DISK_NAMES+=("$d_name")
        DETACHED_DISK_IDS+=("$d_id")
      done

      log "Detaching all data disks from $TARGET_VM ..."
      for d_name in "${DETACHED_DISK_NAMES[@]}"; do
        log "  Detaching: $d_name"
        az_with_retry az vm disk detach \
          --subscription "$TARGET_SUBSCRIPTION" \
          --resource-group "$TARGET_RG" \
          --vm-name "$TARGET_VM" \
          --name "$d_name" \
          -o none
        log "    Detached."
      done
    fi
  else
    log "[DRY-RUN] Would detach all existing data disks from $TARGET_VM"
  fi

elif [[ -n "$DETACH_DISKS" ]]; then
  log ""
  log "========================================="
  log " Detaching specified data disks"
  log "========================================="

  IFS=',' read -r -a REQUESTED_DETACH <<< "$DETACH_DISKS"

  for req in "${REQUESTED_DETACH[@]}"; do
    # Trim whitespace
    trimmed="${req#"${req%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue

    log "  Detaching: $trimmed"
    DETACHED_DISK_NAMES+=("$trimmed")

    if [[ "$DRY_RUN" != "true" ]]; then
      # Get the disk's resource ID before detaching (for optional delete)
      d_id=$(az_with_retry az vm show \
        --subscription "$TARGET_SUBSCRIPTION" \
        --resource-group "$TARGET_RG" \
        --name "$TARGET_VM" \
        --query "storageProfile.dataDisks[?name=='$trimmed'].managedDisk.id | [0]" \
        -o tsv 2>/dev/null) || d_id=""

      if [[ -z "$d_id" || "$d_id" == "null" ]]; then
        log_error "  Disk '$trimmed' not found on VM $TARGET_VM. Skipping."
        continue
      fi

      DETACHED_DISK_IDS+=("$d_id")

      az_with_retry az vm disk detach \
        --subscription "$TARGET_SUBSCRIPTION" \
        --resource-group "$TARGET_RG" \
        --vm-name "$TARGET_VM" \
        --name "$trimmed" \
        -o none
      log "    Detached."
    else
      log "[DRY-RUN] Would detach disk: $trimmed"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Delete detached disks (if requested)
# ---------------------------------------------------------------------------
if [[ "$DELETE_AFTER_DETACH" == "true" && ${#DETACHED_DISK_NAMES[@]} -gt 0 ]]; then
  log ""
  log "Deleting ${#DETACHED_DISK_NAMES[@]} detached disk(s)..."

  for i in "${!DETACHED_DISK_NAMES[@]}"; do
    d_name="${DETACHED_DISK_NAMES[$i]}"
    d_id="${DETACHED_DISK_IDS[$i]:-}"

    if [[ -z "$d_id" ]]; then
      log "  Skipping delete for $d_name (no resource ID captured)."
      continue
    fi

    log "  Deleting: $d_name"
    debug "    $d_id"

    if [[ "$DRY_RUN" != "true" ]]; then
      az_with_retry az disk delete \
        --ids "$d_id" \
        --yes \
        -o none
      log "    Deleted."
    else
      log "[DRY-RUN] Would delete disk: $d_name ($d_id)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Create managed disks from snapshots (parallel)
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Creating managed disks from snapshots"
log "========================================="

DISK_TEMP_DIR=$(mktemp -d)
declare -a DISK_PIDS=()
declare -a NEW_DISK_NAMES=()
declare -a SNAP_NAMES=()
declare -a SNAP_IDS=()
declare -a SOURCE_DISK_NAMES=()
declare -a DISK_SKUS=()
declare -a DISK_SIZES=()

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_NAME=$(jq -r ".snapshots[$i].snapshotName" "$METADATA_FILE")
  SNAP_ID=$(jq -r ".snapshots[$i].snapshotId" "$METADATA_FILE")
  SRC_DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA_FILE")
  DISK_SKU=$(jq -r ".snapshots[$i].diskSku" "$METADATA_FILE")
  DISK_SIZE=$(jq -r ".snapshots[$i].diskSizeGb" "$METADATA_FILE")

  # Apply SKU override if specified
  if [[ -n "$DISK_SKU_OVERRIDE" ]]; then
    DISK_SKU="$DISK_SKU_OVERRIDE"
  fi

  NEW_DISK_NAME="${DISK_PREFIX}-${SRC_DISK_NAME}"

  SNAP_NAMES+=("$SNAP_NAME")
  SNAP_IDS+=("$SNAP_ID")
  SOURCE_DISK_NAMES+=("$SRC_DISK_NAME")
  NEW_DISK_NAMES+=("$NEW_DISK_NAME")
  DISK_SKUS+=("$DISK_SKU")
  DISK_SIZES+=("$DISK_SIZE")

  log "Creating disk: $NEW_DISK_NAME"
  log "  Source snapshot: $SNAP_NAME"
  log "  SKU: $DISK_SKU  Size: ${DISK_SIZE} GiB"
  log "  Target RG: $TARGET_RG"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] az disk create --subscription $TARGET_SUBSCRIPTION --resource-group $TARGET_RG --name $NEW_DISK_NAME --location $DISK_LOCATION --source $SNAP_ID --sku $DISK_SKU --size-gb $DISK_SIZE"
    printf '0' > "$DISK_TEMP_DIR/${i}.exit"
    printf '%s' "dry-run-id" > "$DISK_TEMP_DIR/${i}.id"
  else
    # Launch disk creation in a background subshell
    CUR_IDX=$i
    (
      disk_out=$(az_with_retry az disk create \
        --subscription "$TARGET_SUBSCRIPTION" \
        --resource-group "$TARGET_RG" \
        --name "$NEW_DISK_NAME" \
        --location "$DISK_LOCATION" \
        --source "$SNAP_ID" \
        --sku "$DISK_SKU" \
        --size-gb "$DISK_SIZE" \
        --query "id" -o tsv 2>&1)
      disk_rc=$?
      printf '%s' "$disk_out" > "$DISK_TEMP_DIR/${CUR_IDX}.id"
      printf '%s' "$disk_rc" > "$DISK_TEMP_DIR/${CUR_IDX}.exit"
    ) &
    DISK_PIDS+=($!)
    log "  Launched in background (PID $!)"
  fi
done

# Wait for all parallel disk creations
if [[ "$DRY_RUN" != "true" && ${#DISK_PIDS[@]} -gt 0 ]]; then
  log ""
  log "Waiting for ${#DISK_PIDS[@]} parallel disk creation(s) to complete..."
  for pid in "${DISK_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  log "All disk creations have returned."
fi

# Collect results
DISK_FAILURES=0
declare -a CREATED_DISK_IDS=()

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  disk_exit=$(cat "$DISK_TEMP_DIR/${i}.exit" 2>/dev/null) || disk_exit="1"
  disk_output=$(cat "$DISK_TEMP_DIR/${i}.id" 2>/dev/null) || disk_output=""

  if [[ "$disk_exit" != "0" ]]; then
    log_error "Failed to create disk ${NEW_DISK_NAMES[$i]}:"
    log_error "$disk_output"
    CREATED_DISK_IDS+=("")
    DISK_FAILURES=$((DISK_FAILURES + 1))
    continue
  fi

  CREATED_DISK_IDS+=("$disk_output")
  log "  Disk ready: ${NEW_DISK_NAMES[$i]}"
  debug "    $disk_output"
done

rm -rf "$DISK_TEMP_DIR"

if [[ $DISK_FAILURES -gt 0 ]]; then
  log_error "$DISK_FAILURES of $SNAP_COUNT disk creation(s) failed."
  log_error "Aborting before attach phase. Created disks remain and can be attached manually."
  exit 1
fi

# ---------------------------------------------------------------------------
# Attach disks to target VM
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Attaching disks to $TARGET_VM"
log "========================================="

CURRENT_LUN=$STARTING_LUN

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  NEW_DISK_NAME="${NEW_DISK_NAMES[$i]}"

  log "  Attaching $NEW_DISK_NAME at LUN $CURRENT_LUN ..."

  if [[ "$DRY_RUN" != "true" ]]; then
    az_with_retry az vm disk attach \
      --subscription "$TARGET_SUBSCRIPTION" \
      --resource-group "$TARGET_RG" \
      --vm-name "$TARGET_VM" \
      --name "$NEW_DISK_NAME" \
      --lun "$CURRENT_LUN" \
      -o none
    log "    Attached."
  else
    log "[DRY-RUN] az vm disk attach --subscription $TARGET_SUBSCRIPTION --resource-group $TARGET_RG --vm-name $TARGET_VM --name $NEW_DISK_NAME --lun $CURRENT_LUN"
  fi

  CURRENT_LUN=$((CURRENT_LUN + 1))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Hydrate and attach completed"
log "========================================="
log ""
log "Source metadata:    $METADATA_FILE"
log "Source VM:          $SOURCE_VM (rg=$SOURCE_RG)"
log "Target VM:          $TARGET_VM (rg=$TARGET_RG)"
log "Disks created:      $SNAP_COUNT"
if [[ ${#DETACHED_DISK_NAMES[@]} -gt 0 ]]; then
  log "Disks detached:     ${#DETACHED_DISK_NAMES[@]}"
  if [[ "$DELETE_AFTER_DETACH" == "true" ]]; then
    log "Detached disks:     DELETED"
  fi
fi
log ""
log "New disks attached (LUN $STARTING_LUN – $((CURRENT_LUN - 1))):"
for i in $(seq 0 $((SNAP_COUNT - 1))); do
  lun=$((STARTING_LUN + i))
  log "  LUN $lun: ${NEW_DISK_NAMES[$i]} (from ${SNAP_NAMES[$i]})"
done

log ""
log "Next steps (on the target VM):"
log "  1. Scan for new block devices:  sudo pvscan --cache"
log "  2. Import the volume group:     sudo vgimportclone --basevgname <new-vg-name> /dev/sd{...}"
log "  3. Activate the VG:             sudo vgchange -ay <new-vg-name>"
log "  4. Mount the filesystem:        sudo mount -o nouuid /dev/<new-vg-name>/<lv-name> /mountpoint"
log ""
log "Done."
