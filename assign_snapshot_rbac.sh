#!/usr/bin/env bash

set -euo pipefail

# ===========================================================================
# assign_snapshot_rbac.sh
#
# Assigns the RBAC permissions required for snapshot operations:
#
#   - "Disk Backup Reader"       on every data disk attached to the source VM
#   - "Disk Snapshot Contributor" on the VM's resource group
#   - "Disk Snapshot Contributor" on an optional target resource group
#                                  (where snapshots will be stored)
#
# The assignee can be a service principal, managed identity, or user
# (identified by object ID or user principal name).
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
  ./assign_snapshot_rbac.sh \
    --subscription-id <id> \
    --resource-group <name> \
    --vm-name <name> \
    --assignee <object-id-or-upn> \
    [--assignee-object-id <id>] \
    [--target-resource-group <name>] \
    [--include-os-disk] \
    [--auth-method <none|interactive|device-code|service-principal|managed-identity>] \
    [--tenant-id <id>] \
    [--client-id <id>] \
    [--client-secret <secret>] \
    [--log-file <path>] \
    [--debug] \
    [--dry-run]

Description:
  Assigns the RBAC roles required for creating disk snapshots:

    1. "Disk Backup Reader" on each attached data disk of the VM
       (and optionally the OS disk with --include-os-disk).
       This role grants read access to disk data needed for backup/snapshot.

    2. "Disk Snapshot Contributor" on the VM's resource group.
       This role grants permissions to create and manage disk snapshots.

    3. "Disk Snapshot Contributor" on an optional --target-resource-group
       where snapshots will be stored (if different from the VM's resource group).

  The assignee can be:
    - A service principal object ID
    - A managed identity object ID
    - A user principal name (UPN, e.g., user@domain.com)
    - An Azure AD group object ID

Required:
  --subscription-id <id>         Azure subscription ID
  --resource-group <name>        Resource group containing the source VM
  --vm-name <name>               Name of the source VM
  --assignee <id-or-upn>         Object ID or User Principal Name (UPN) of the
                                  identity to grant permissions to. Accepts:
                                    - Service principal object ID
                                    - Managed identity object ID
                                    - User principal name (user@domain.com)
                                    - Azure AD group object ID

Assignee type:
  --assignee-object-id <id>      Use this flag when --assignee is a display name
                                  and you want to provide the object ID explicitly.
                                  When set, this value is used as the --assignee
                                  for az role assignment create.

Options:
  --target-resource-group <name> Optional second resource group where snapshots
                                  will be stored. "Disk Snapshot Contributor" is
                                  assigned at this scope in addition to the VM's
                                  resource group.
  --include-os-disk              Also assign "Disk Backup Reader" on the VM's
                                  OS disk (not just data disks).

Authentication:
  --auth-method <method>         Authentication method (default: none)
                                  none             – skip login; assume already authenticated
                                  interactive      – browser-based interactive login
                                  device-code      – device-code flow
                                  service-principal – service principal with client secret
                                  managed-identity – managed identity
  --tenant-id <id>               Azure AD tenant ID (required for service-principal)
  --client-id <id>               Application (client) ID for service-principal or
                                  user-assigned managed identity client ID
  --client-secret <secret>       Client secret for service-principal auth.
                                  Can also be supplied via AZURE_CLIENT_SECRET env var.

Logging & debug:
  --log-file <path>              Write all output to a log file
  --debug                        Enable verbose debug logging

Other:
  --dry-run                      Print role assignment commands without executing
  --help                         Show this help

Examples:
  # Assign snapshot permissions for a managed identity
  ./assign_snapshot_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --resource-group prod-rg \
    --vm-name prod-vm \
    --assignee 11111111-1111-1111-1111-111111111111

  # Assign to a user, with snapshots stored in a different RG
  ./assign_snapshot_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --resource-group prod-rg \
    --vm-name prod-vm \
    --assignee user@contoso.com \
    --target-resource-group snapshots-rg

  # Include the OS disk and dry-run
  ./assign_snapshot_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --resource-group prod-rg \
    --vm-name prod-vm \
    --assignee 11111111-1111-1111-1111-111111111111 \
    --include-os-disk \
    --dry-run \
    --debug

  # Service principal auth (CI/CD pipeline)
  ./assign_snapshot_rbac.sh \
    --auth-method service-principal \
    --tenant-id 00000000-0000-0000-0000-000000000000 \
    --client-id 00000000-0000-0000-0000-000000000000 \
    --client-secret "$AZURE_CLIENT_SECRET" \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --resource-group prod-rg \
    --vm-name prod-vm \
    --assignee 11111111-1111-1111-1111-111111111111 \
    --target-resource-group snapshots-rg
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
ASSIGNEE=""
ASSIGNEE_OBJECT_ID=""
TARGET_RG=""
INCLUDE_OS_DISK=false
LOG_FILE=""
DEBUG=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Built-in role names
# ---------------------------------------------------------------------------
ROLE_DISK_BACKUP_READER="Disk Backup Reader"
ROLE_DISK_SNAPSHOT_CONTRIBUTOR="Disk Snapshot Contributor"

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
    --assignee)
      ASSIGNEE="$2"
      shift 2
      ;;
    --assignee-object-id)
      ASSIGNEE_OBJECT_ID="$2"
      shift 2
      ;;
    --target-resource-group)
      TARGET_RG="$2"
      shift 2
      ;;
    --include-os-disk)
      INCLUDE_OS_DISK=true
      shift
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

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run mode enabled: commands will be printed only."
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

if [[ -z "$ASSIGNEE" ]]; then
  log_error "--assignee is required."
  usage
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
log "Setting Azure subscription context to: $SUBSCRIPTION_ID"
az_with_retry az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

# ---------------------------------------------------------------------------
# Resolve the effective assignee value
# ---------------------------------------------------------------------------
EFFECTIVE_ASSIGNEE="$ASSIGNEE"
if [[ -n "$ASSIGNEE_OBJECT_ID" ]]; then
  EFFECTIVE_ASSIGNEE="$ASSIGNEE_OBJECT_ID"
  log "Using --assignee-object-id as assignee: $EFFECTIVE_ASSIGNEE"
fi
debug "Effective assignee: $EFFECTIVE_ASSIGNEE"

# ---------------------------------------------------------------------------
# Helper: assign a role (with idempotency check)
# ---------------------------------------------------------------------------
assign_role() {
  local role="$1"
  local scope="$2"
  local description="$3"

  log "  Role:  $role"
  log "  Scope: $scope"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [DRY-RUN] az role assignment create --assignee \"$EFFECTIVE_ASSIGNEE\" --role \"$role\" --scope \"$scope\""
    return 0
  fi

  # Check if assignment already exists
  local existing
  existing=$(az_with_retry az role assignment list \
    --assignee "$EFFECTIVE_ASSIGNEE" \
    --role "$role" \
    --scope "$scope" \
    --query "length([])" \
    -o tsv 2>/dev/null) || existing="0"

  if [[ "$existing" -gt 0 ]]; then
    log "  Already assigned — skipping."
    return 0
  fi

  if ! az_with_retry az role assignment create \
    --assignee "$EFFECTIVE_ASSIGNEE" \
    --role "$role" \
    --scope "$scope" \
    -o none; then
    log_error "  Failed to assign role: $role at $description"
    return 1
  fi

  log "  Assigned."
}

# ---------------------------------------------------------------------------
# Retrieve VM information and disk list
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Retrieving VM and disk information"
log "========================================="

log "Querying VM: $VM_NAME (rg=$RESOURCE_GROUP) ..."

VM_JSON=$(az_with_retry az vm show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  -o json) || {
  log_error "Failed to retrieve VM: $VM_NAME in $RESOURCE_GROUP"
  exit 1
}

VM_ID=$(echo "$VM_JSON" | jq -r '.id')
VM_LOCATION=$(echo "$VM_JSON" | jq -r '.location')
debug "VM ID:       $VM_ID"
debug "VM Location: $VM_LOCATION"

# Construct the resource group scope
RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
debug "RG Scope: $RG_SCOPE"

# Collect data disk IDs and names
declare -a DATA_DISK_IDS=()
declare -a DATA_DISK_NAMES=()

mapfile -t DISK_ENTRIES < <(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[] | "\(.name)|\(.managedDisk.id)"')

for entry in "${DISK_ENTRIES[@]}"; do
  IFS='|' read -r d_name d_id <<< "$entry"
  [[ -z "$d_name" || "$d_name" == "null" ]] && continue
  DATA_DISK_NAMES+=("$d_name")
  DATA_DISK_IDS+=("$d_id")
done

log "Found ${#DATA_DISK_NAMES[@]} data disk(s) on $VM_NAME:"
for d_name in "${DATA_DISK_NAMES[@]}"; do
  log "  $d_name"
done

# Optionally include OS disk
OS_DISK_ID=""
OS_DISK_NAME=""
if [[ "$INCLUDE_OS_DISK" == "true" ]]; then
  OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')
  OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id')
  log "Including OS disk: $OS_DISK_NAME"
  debug "  $OS_DISK_ID"
fi

if [[ ${#DATA_DISK_NAMES[@]} -eq 0 && "$INCLUDE_OS_DISK" != "true" ]]; then
  log_error "VM $VM_NAME has no data disks and --include-os-disk was not specified. Nothing to do."
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: Assign "Disk Backup Reader" on each disk
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Assigning: $ROLE_DISK_BACKUP_READER"
log " Scope:     Individual managed disks"
log " Assignee:  $ASSIGNEE"
log "========================================="

ASSIGNMENT_FAILURES=0
ASSIGNMENT_COUNT=0

for i in "${!DATA_DISK_NAMES[@]}"; do
  d_name="${DATA_DISK_NAMES[$i]}"
  d_id="${DATA_DISK_IDS[$i]}"

  log ""
  log "Disk: $d_name"
  if ! assign_role "$ROLE_DISK_BACKUP_READER" "$d_id" "disk $d_name"; then
    ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
  fi
  ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
done

if [[ "$INCLUDE_OS_DISK" == "true" && -n "$OS_DISK_ID" ]]; then
  log ""
  log "OS Disk: $OS_DISK_NAME"
  if ! assign_role "$ROLE_DISK_BACKUP_READER" "$OS_DISK_ID" "OS disk $OS_DISK_NAME"; then
    ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
  fi
  ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# Phase 2: Assign "Disk Snapshot Contributor" on the VM's resource group
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Assigning: $ROLE_DISK_SNAPSHOT_CONTRIBUTOR"
log " Scope:     Resource group ($RESOURCE_GROUP)"
log " Assignee:  $ASSIGNEE"
log "========================================="

log ""
log "Resource group: $RESOURCE_GROUP"
if ! assign_role "$ROLE_DISK_SNAPSHOT_CONTRIBUTOR" "$RG_SCOPE" "resource group $RESOURCE_GROUP"; then
  ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
fi
ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))

# ---------------------------------------------------------------------------
# Phase 3: Assign "Disk Snapshot Contributor" on the target resource group
# ---------------------------------------------------------------------------
if [[ -n "$TARGET_RG" && "$TARGET_RG" != "$RESOURCE_GROUP" ]]; then
  TARGET_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TARGET_RG}"
  debug "Target RG Scope: $TARGET_RG_SCOPE"

  log ""
  log "========================================="
  log " Assigning: $ROLE_DISK_SNAPSHOT_CONTRIBUTOR"
  log " Scope:     Target resource group ($TARGET_RG)"
  log " Assignee:  $ASSIGNEE"
  log "========================================="

  log ""
  log "Target resource group: $TARGET_RG"
  if ! assign_role "$ROLE_DISK_SNAPSHOT_CONTRIBUTOR" "$TARGET_RG_SCOPE" "target resource group $TARGET_RG"; then
    ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
  fi
  ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
elif [[ -n "$TARGET_RG" && "$TARGET_RG" == "$RESOURCE_GROUP" ]]; then
  log ""
  log "Target resource group ($TARGET_RG) is the same as the VM's resource group."
  log "Disk Snapshot Contributor was already assigned above — skipping."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " RBAC assignment summary"
log "========================================="
log ""
log "VM:                $VM_NAME (rg=$RESOURCE_GROUP)"
log "Subscription:      $SUBSCRIPTION_ID"
log "Assignee:          $ASSIGNEE"
if [[ -n "$ASSIGNEE_OBJECT_ID" ]]; then
  log "Assignee OID:      $ASSIGNEE_OBJECT_ID"
fi
log ""
log "Assignments attempted: $ASSIGNMENT_COUNT"
if [[ $ASSIGNMENT_FAILURES -gt 0 ]]; then
  log_error "Failures:              $ASSIGNMENT_FAILURES"
  log_error ""
  log_error "Some role assignments failed. Check the errors above."
  log_error "Ensure you have Owner or User Access Administrator permissions."
  exit 1
fi
log "Failures:           0"
log ""

log "Roles assigned:"
log ""
log "  $ROLE_DISK_BACKUP_READER:"
for d_name in "${DATA_DISK_NAMES[@]}"; do
  log "    - $d_name"
done
if [[ "$INCLUDE_OS_DISK" == "true" && -n "$OS_DISK_NAME" ]]; then
  log "    - $OS_DISK_NAME (OS disk)"
fi
log ""
log "  $ROLE_DISK_SNAPSHOT_CONTRIBUTOR:"
log "    - $RESOURCE_GROUP (VM resource group)"
if [[ -n "$TARGET_RG" && "$TARGET_RG" != "$RESOURCE_GROUP" ]]; then
  log "    - $TARGET_RG (target resource group)"
fi

log ""
log "The identity '$ASSIGNEE' can now create snapshots of the"
log "managed disks on VM '$VM_NAME' using multidisk_ia_snapshot.sh."
log ""
log "Done."
