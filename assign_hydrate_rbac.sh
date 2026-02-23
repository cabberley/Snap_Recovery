#!/usr/bin/env bash

set -euo pipefail

# ===========================================================================
# assign_hydrate_rbac.sh
#
# Assigns the RBAC permissions required for the hydrate/attach workflow
# (multidisk_ia_hydrate_attach.sh):
#
#   - "Reader"                     on the snapshot resource group
#                                   (to read snapshot metadata for disk create)
#   - "Disk Restore Operator"      on the target resource group
#                                   (to create managed disks from snapshots)
#   - "Virtual Machine Contributor" on the target resource group
#                                   (to read the VM, attach/detach data disks)
#   - Optional: "Disk Pool Operator" or custom role for disk delete
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
  ./assign_hydrate_rbac.sh \
    --subscription-id <id> \
    --snapshot-resource-group <name> \
    --target-resource-group <name> \
    --assignee <object-id-or-upn> \
    [--assignee-object-id <id>] \
    [--include-delete] \
    [--auth-method <none|interactive|device-code|service-principal|managed-identity>] \
    [--tenant-id <id>] \
    [--client-id <id>] \
    [--client-secret <secret>] \
    [--log-file <path>] \
    [--debug] \
    [--dry-run]

Description:
  Assigns the RBAC roles required to run multidisk_ia_hydrate_attach.sh
  (create managed disks from snapshots, attach/detach disks on a target VM,
  and optionally delete detached disks).

  The following built-in roles are assigned:

    1. "Reader" on the snapshot resource group.
       Grants read access to snapshot metadata so that "az disk create
       --source <snapshotId>" can reference the source snapshot.
       Skipped if the snapshot RG is the same as the target RG
       (covered by the roles assigned in steps 2-3).

    2. "Disk Restore Operator" on the target resource group.
       Grants permission to create managed disks from snapshots
       (Microsoft.Compute/disks/write, Microsoft.Compute/disks/read).

    3. "Virtual Machine Contributor" on the target resource group.
       Grants permission to read the target VM, attach data disks,
       and detach data disks.

    4. (Optional, with --include-delete)
       "Virtual Machine Contributor" already includes
       Microsoft.Compute/disks/delete, so no additional role is needed.
       This flag simply logs confirmation that disk delete is covered.

  The assignee can be:
    - A service principal object ID
    - A managed identity object ID
    - A user principal name (UPN, e.g., user@domain.com)
    - An Azure AD group object ID

Required:
  --subscription-id <id>              Azure subscription ID
  --snapshot-resource-group <name>    Resource group containing the snapshots
                                       (source snapshot RG)
  --target-resource-group <name>      Resource group containing the target VM
                                       (where new disks will also be created)
  --assignee <id-or-upn>              Object ID or UPN of the identity to grant
                                       permissions to

Assignee type:
  --assignee-object-id <id>           Use when --assignee is a display name and
                                       you want to provide the object ID explicitly

Options:
  --include-delete                    Confirm that the identity should be able to
                                       delete detached disks. No additional role is
                                       needed (Virtual Machine Contributor covers it),
                                       but the script logs a clear acknowledgement.

Authentication:
  --auth-method <method>              Authentication method (default: none)
                                       none             – assume already authenticated
                                       interactive      – browser-based login
                                       device-code      – device-code flow
                                       service-principal – client ID + secret
                                       managed-identity – managed identity
  --tenant-id <id>                    Azure AD tenant ID (for service-principal)
  --client-id <id>                    Application (client) ID for service-principal
                                       or user-assigned managed identity client ID
  --client-secret <secret>            Client secret for service-principal auth.
                                       Also accepted via AZURE_CLIENT_SECRET env var.

Logging & debug:
  --log-file <path>                   Write all output to a log file
  --debug                             Enable verbose debug logging

Other:
  --dry-run                           Print role assignment commands without executing
  --help                              Show this help

Role-to-operation mapping:
  ┌──────────────────────────────────┬──────────────────────────────┬──────────────────────┐
  │ Script Operation                 │ Azure Action Required        │ Role                 │
  ├──────────────────────────────────┼──────────────────────────────┼──────────────────────┤
  │ Read snapshot for disk create    │ Microsoft.Compute/           │ Reader               │
  │                                  │    snapshots/read            │  (snapshot RG)       │
  ├──────────────────────────────────┼──────────────────────────────┼──────────────────────┤
  │ Create managed disk from snapshot│ Microsoft.Compute/           │ Disk Restore         │
  │                                  │    disks/write               │  Operator            │
  │                                  │ Microsoft.Compute/           │  (target RG)         │
  │                                  │    disks/read                │                      │
  ├──────────────────────────────────┼──────────────────────────────┼──────────────────────┤
  │ Read target VM                   │ Microsoft.Compute/           │ Virtual Machine      │
  │ Attach disks to VM               │    virtualMachines/read      │  Contributor         │
  │ Detach disks from VM             │ Microsoft.Compute/           │  (target RG)         │
  │                                  │    virtualMachines/write     │                      │
  ├──────────────────────────────────┼──────────────────────────────┼──────────────────────┤
  │ Delete detached disks (optional) │ Microsoft.Compute/           │ Virtual Machine      │
  │                                  │    disks/delete              │  Contributor         │
  │                                  │                              │  (target RG)         │
  └──────────────────────────────────┴──────────────────────────────┴──────────────────────┘

Examples:
  # Basic: assign permissions for hydrate + attach
  ./assign_hydrate_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --snapshot-resource-group snapshot-rg \
    --target-resource-group test-rg \
    --assignee 11111111-1111-1111-1111-111111111111

  # Snapshots and target VM in the same resource group
  ./assign_hydrate_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --snapshot-resource-group prod-rg \
    --target-resource-group prod-rg \
    --assignee user@contoso.com

  # Include delete capability and confirm
  ./assign_hydrate_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --snapshot-resource-group snapshot-rg \
    --target-resource-group test-rg \
    --assignee 11111111-1111-1111-1111-111111111111 \
    --include-delete

  # Dry-run with debug
  ./assign_hydrate_rbac.sh \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --snapshot-resource-group snapshot-rg \
    --target-resource-group test-rg \
    --assignee 11111111-1111-1111-1111-111111111111 \
    --include-delete \
    --debug \
    --dry-run

  # Service principal auth (CI/CD)
  ./assign_hydrate_rbac.sh \
    --auth-method service-principal \
    --tenant-id 00000000-0000-0000-0000-000000000000 \
    --client-id 00000000-0000-0000-0000-000000000000 \
    --client-secret "$AZURE_CLIENT_SECRET" \
    --subscription-id 00000000-0000-0000-0000-000000000000 \
    --snapshot-resource-group snapshot-rg \
    --target-resource-group test-rg \
    --assignee 11111111-1111-1111-1111-111111111111
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
SNAPSHOT_RG=""
TARGET_RG=""
ASSIGNEE=""
ASSIGNEE_OBJECT_ID=""
INCLUDE_DELETE=false
LOG_FILE=""
DEBUG=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Built-in role names
# ---------------------------------------------------------------------------
ROLE_READER="Reader"
ROLE_DISK_RESTORE_OPERATOR="Disk Restore Operator"
ROLE_VM_CONTRIBUTOR="Virtual Machine Contributor"

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
    --snapshot-resource-group)
      SNAPSHOT_RG="$2"
      shift 2
      ;;
    --target-resource-group)
      TARGET_RG="$2"
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
    --include-delete)
      INCLUDE_DELETE=true
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

if [[ -z "$SNAPSHOT_RG" ]]; then
  log_error "--snapshot-resource-group is required."
  usage
  exit 1
fi

if [[ -z "$TARGET_RG" ]]; then
  log_error "--target-resource-group is required."
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
# Construct resource group scopes
# ---------------------------------------------------------------------------
SNAPSHOT_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${SNAPSHOT_RG}"
TARGET_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TARGET_RG}"
SAME_RG=false

if [[ "$SNAPSHOT_RG" == "$TARGET_RG" ]]; then
  SAME_RG=true
  log "Snapshot RG and target RG are the same: $TARGET_RG"
fi

debug "Snapshot RG scope: $SNAPSHOT_RG_SCOPE"
debug "Target RG scope:   $TARGET_RG_SCOPE"

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
# Display plan
# ---------------------------------------------------------------------------
log ""
log "========================================="
log " Hydrate/Attach RBAC Assignment Plan"
log "========================================="
log ""
log "Assignee:               $ASSIGNEE"
log "Subscription:           $SUBSCRIPTION_ID"
log "Snapshot resource group: $SNAPSHOT_RG"
log "Target resource group:   $TARGET_RG"
log "Include disk delete:     $INCLUDE_DELETE"
log ""
log "Roles to assign:"
if [[ "$SAME_RG" != "true" ]]; then
  log "  1. $ROLE_READER → $SNAPSHOT_RG (read snapshot metadata)"
fi
log "  2. $ROLE_DISK_RESTORE_OPERATOR → $TARGET_RG (create disks from snapshots)"
log "  3. $ROLE_VM_CONTRIBUTOR → $TARGET_RG (VM read, attach, detach)"
if [[ "$INCLUDE_DELETE" == "true" ]]; then
  log "  4. Disk delete covered by $ROLE_VM_CONTRIBUTOR (no extra role needed)"
fi
log ""

ASSIGNMENT_FAILURES=0
ASSIGNMENT_COUNT=0

# ---------------------------------------------------------------------------
# Phase 1: Assign "Reader" on the snapshot resource group
# ---------------------------------------------------------------------------
if [[ "$SAME_RG" != "true" ]]; then
  log "========================================="
  log " Phase 1: $ROLE_READER"
  log " Scope:   Snapshot RG ($SNAPSHOT_RG)"
  log " Purpose: Read snapshot metadata for az disk create --source"
  log "========================================="
  log ""

  if ! assign_role "$ROLE_READER" "$SNAPSHOT_RG_SCOPE" "snapshot resource group $SNAPSHOT_RG"; then
    ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
  fi
  ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
  log ""
else
  log "Skipping Phase 1 (Reader on snapshot RG) — same as target RG."
  log "Virtual Machine Contributor (Phase 3) covers read access."
  log ""
fi

# ---------------------------------------------------------------------------
# Phase 2: Assign "Disk Restore Operator" on the target resource group
# ---------------------------------------------------------------------------
log "========================================="
log " Phase 2: $ROLE_DISK_RESTORE_OPERATOR"
log " Scope:   Target RG ($TARGET_RG)"
log " Purpose: Create managed disks from snapshots"
log "========================================="
log ""

if ! assign_role "$ROLE_DISK_RESTORE_OPERATOR" "$TARGET_RG_SCOPE" "target resource group $TARGET_RG"; then
  ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
fi
ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
log ""

# ---------------------------------------------------------------------------
# Phase 3: Assign "Virtual Machine Contributor" on the target resource group
# ---------------------------------------------------------------------------
log "========================================="
log " Phase 3: $ROLE_VM_CONTRIBUTOR"
log " Scope:   Target RG ($TARGET_RG)"
log " Purpose: VM read, disk attach/detach, disk delete"
log "========================================="
log ""

if ! assign_role "$ROLE_VM_CONTRIBUTOR" "$TARGET_RG_SCOPE" "target resource group $TARGET_RG"; then
  ASSIGNMENT_FAILURES=$((ASSIGNMENT_FAILURES + 1))
fi
ASSIGNMENT_COUNT=$((ASSIGNMENT_COUNT + 1))
log ""

# ---------------------------------------------------------------------------
# Phase 4: Acknowledge disk delete capability
# ---------------------------------------------------------------------------
if [[ "$INCLUDE_DELETE" == "true" ]]; then
  log "========================================="
  log " Phase 4: Disk delete capability"
  log "========================================="
  log ""
  log "  The '$ROLE_VM_CONTRIBUTOR' role (assigned in Phase 3) includes"
  log "  Microsoft.Compute/disks/delete, which covers the --delete-after-detach"
  log "  option in multidisk_ia_hydrate_attach.sh."
  log ""
  log "  No additional role assignment is required."
  log ""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "========================================="
log " RBAC assignment summary"
log "========================================="
log ""
log "Assignee:           $ASSIGNEE"
if [[ -n "$ASSIGNEE_OBJECT_ID" ]]; then
  log "Assignee OID:       $ASSIGNEE_OBJECT_ID"
fi
log "Subscription:       $SUBSCRIPTION_ID"
log "Snapshot RG:         $SNAPSHOT_RG"
log "Target RG:           $TARGET_RG"
log ""
log "Assignments attempted: $ASSIGNMENT_COUNT"

if [[ $ASSIGNMENT_FAILURES -gt 0 ]]; then
  log_error "Failures:              $ASSIGNMENT_FAILURES"
  log_error ""
  log_error "Some role assignments failed. Check the errors above."
  log_error "Ensure you have Owner or User Access Administrator permissions on the"
  log_error "target scopes to create role assignments."
  exit 1
fi

log "Failures:            0"
log ""
log "Roles assigned:"
log ""
if [[ "$SAME_RG" != "true" ]]; then
  log "  $ROLE_READER:"
  log "    - $SNAPSHOT_RG (snapshot resource group)"
  log "    Grants: Microsoft.Compute/snapshots/read"
  log ""
fi
log "  $ROLE_DISK_RESTORE_OPERATOR:"
log "    - $TARGET_RG (target resource group)"
log "    Grants: Microsoft.Compute/disks/write, Microsoft.Compute/disks/read"
log ""
log "  $ROLE_VM_CONTRIBUTOR:"
log "    - $TARGET_RG (target resource group)"
log "    Grants: Microsoft.Compute/virtualMachines/read,"
log "            Microsoft.Compute/virtualMachines/write (attach/detach),"
log "            Microsoft.Compute/disks/delete"
log ""

if [[ "$INCLUDE_DELETE" == "true" ]]; then
  log "  Disk delete: ENABLED (covered by $ROLE_VM_CONTRIBUTOR)"
  log ""
fi

log "The identity '$ASSIGNEE' can now run multidisk_ia_hydrate_attach.sh"
log "to create disks from snapshots in '$SNAPSHOT_RG' and attach them to"
log "a VM in '$TARGET_RG'."
if [[ "$INCLUDE_DELETE" == "true" ]]; then
  log "The --delete-after-detach flag is also permitted."
fi
log ""
log "Done."
