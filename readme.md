# Azure Multi-Disk Snapshot & Restore Toolkit

A set of Bash scripts for creating Azure managed disk snapshots in parallel and restoring them to a target VM, with companion scripts to configure the required RBAC permissions.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `assign_snapshot_rbac.sh` | Assigns RBAC roles needed to **create** snapshots |
| `multidisk_ia_snapshot.sh` | Creates snapshots of all data disks on a source VM in parallel |
| `assign_hydrate_rbac.sh` | Assigns RBAC roles needed to **restore** (hydrate, attach, delete) |
| `multidisk_ia_hydrate_attach.sh` | Creates managed disks from snapshots and attaches them to a target VM |

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. RBAC Setup                                                              │
│     assign_snapshot_rbac.sh  →  grants snapshot-creation permissions         │
│     assign_hydrate_rbac.sh   →  grants restore/attach permissions           │
│                                                                             │
│  2. Snapshot                                                                │
│     multidisk_ia_snapshot.sh →  snapshots all data disks in parallel         │
│                                 produces a metadata JSON file               │
│                                                                             │
│  3. Restore                                                                 │
│     multidisk_ia_hydrate_attach.sh → reads the metadata JSON                │
│                                       creates disks from snapshots          │
│                                       attaches them to the target VM        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- **Azure CLI** ≥ 2.83.0 (`az --version`)
- **jq** (used by the hydrate/attach script to parse JSON metadata)
- **Bash** 4+ (for `mapfile`, associative arrays)
- An Azure identity (user, service principal, or managed identity) with sufficient permissions

---

## Script Details

### 1. `assign_snapshot_rbac.sh` — Snapshot RBAC Setup

Assigns the minimum RBAC roles required by `multidisk_ia_snapshot.sh`.

| Role | Scope | Why |
|------|-------|-----|
| **Disk Backup Reader** | Each data disk (and optionally the OS disk) | Read disk data for snapshot creation |
| **Disk Snapshot Contributor** | VM's resource group | Create and manage snapshots |
| **Disk Snapshot Contributor** | Target resource group *(optional)* | Store snapshots in a different RG |

**Key features:**
- Discovers all data disks on the VM automatically
- Idempotent — skips roles that are already assigned
- `--include-os-disk` to also grant access on the OS disk
- `--target-resource-group` when snapshots go to a separate RG
- `--dry-run` to preview without making changes

### 2. `multidisk_ia_snapshot.sh` — Snapshot Creation

Creates Azure managed disk snapshots for every data disk attached to a source VM.

**Key features:**
- Parallel snapshot creation across all data disks
- Auto-detects Premium SSD v2 / Ultra Disk and enables incremental snapshots
- Instant-access (IA) tier support with `--ia-duration` (1–300 minutes)
- Background copy with `--copy-start` and polling until completion
- Network security defaults: `--public-network-access Disabled`, `--network-access-policy DenyAll`
- Writes a metadata JSON file consumed by the hydrate/attach script
- `--only-disks` to snapshot a subset of data disks
- `--target-resource-group` to store snapshots in a different RG

**Metadata output** (example):
```json
{
  "timestamp": "2026-02-23T10:30:00Z",
  "vm": {
    "name": "prod-vm",
    "resourceGroup": "prod-rg",
    "subscriptionId": "00000000-...",
    "location": "eastus"
  },
  "snapshotCount": 2,
  "snapshots": [
    {
      "snapshotName": "bkp-datadisk1-20260223T103000",
      "snapshotId": "/subscriptions/.../snapshots/bkp-datadisk1-...",
      "sourceDiskName": "datadisk1",
      "diskSku": "PremiumV2_LRS",
      "diskSizeGb": 256
    }
  ]
}
```

### 3. `assign_hydrate_rbac.sh` — Hydrate/Attach RBAC Setup

Assigns the minimum RBAC roles required by `multidisk_ia_hydrate_attach.sh`.

| Role | Scope | Why |
|------|-------|-----|
| **Reader** | Snapshot resource group | Read snapshot metadata for disk creation |
| **Disk Restore Operator** | Target resource group | Create managed disks from snapshots |
| **Virtual Machine Contributor** | Target resource group | Read VM, attach/detach disks, delete disks |

**Key features:**
- Automatically skips the Reader role when snapshot RG = target RG
- `--include-delete` acknowledges that disk delete is covered (no extra role needed)
- Idempotent, dry-run, and debug modes

### 4. `multidisk_ia_hydrate_attach.sh` — Disk Restore & Attach

Reads the metadata JSON produced by the snapshot script, creates managed disks from those snapshots, and attaches them to a target VM.

**Key features:**
- Parallel disk creation from snapshots
- Reads snapshot IDs, SKUs, and sizes from the metadata file
- `--disk-sku` to override the storage tier for all restored disks
- `--detach-existing` to remove all current data disks from the target VM first
- `--detach-disks` to remove specific named disks
- `--delete-after-detach` to delete detached disks (irreversible)
- `--starting-lun` to control LUN assignment
- `--disk-prefix` to name restored disks (default: `restored-<sourceDiskName>`)

---

## End-to-End Workflow

### Step 1 — Assign Snapshot Permissions

Grant the identity that will run the snapshot script the required RBAC roles:

```bash
./assign_snapshot_rbac.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group prod-rg \
  --vm-name prod-vm \
  --assignee 11111111-1111-1111-1111-111111111111
```

If snapshots will be stored in a different resource group:

```bash
./assign_snapshot_rbac.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group prod-rg \
  --vm-name prod-vm \
  --assignee 11111111-1111-1111-1111-111111111111 \
  --target-resource-group snapshots-rg
```

### Step 2 — Create Snapshots

Snapshot all data disks on the source VM:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group prod-rg \
  --vm-name prod-vm \
  --snapshot-prefix bkp \
  --metadata-file ./snapshot-metadata.json
```

With instant-access tier and background copy:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group prod-rg \
  --vm-name prod-vm \
  --snapshot-prefix bkp \
  --copy-start \
  --ia-duration 120 \
  --metadata-file ./snapshot-metadata.json
```

### Step 3 — Assign Hydrate/Attach Permissions

Grant the identity that will run the restore script the required RBAC roles:

```bash
./assign_hydrate_rbac.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --snapshot-resource-group prod-rg \
  --target-resource-group test-rg \
  --assignee 11111111-1111-1111-1111-111111111111
```

If the identity also needs to delete detached disks:

```bash
./assign_hydrate_rbac.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --snapshot-resource-group prod-rg \
  --target-resource-group test-rg \
  --assignee 11111111-1111-1111-1111-111111111111 \
  --include-delete
```

### Step 4 — Restore and Attach Disks

Create managed disks from the snapshots and attach them to the target VM:

```bash
./multidisk_ia_hydrate_attach.sh \
  --metadata-file ./snapshot-metadata.json \
  --target-vm-name test-vm \
  --target-resource-group test-rg
```

Detach existing disks first, then attach the restored ones:

```bash
./multidisk_ia_hydrate_attach.sh \
  --metadata-file ./snapshot-metadata.json \
  --target-vm-name test-vm \
  --target-resource-group test-rg \
  --detach-existing \
  --delete-after-detach
```

---

## RBAC Summary

### Snapshot Permissions (assign_snapshot_rbac.sh)

| Role | Scope | Azure Actions |
|------|-------|---------------|
| Disk Backup Reader | Each managed disk | `Microsoft.Compute/disks/read`, `Microsoft.Compute/disks/beginGetAccess/action` |
| Disk Snapshot Contributor | Resource group | `Microsoft.Compute/snapshots/*` |

### Hydrate/Attach Permissions (assign_hydrate_rbac.sh)

| Role | Scope | Azure Actions |
|------|-------|---------------|
| Reader | Snapshot resource group | `Microsoft.Compute/snapshots/read` |
| Disk Restore Operator | Target resource group | `Microsoft.Compute/disks/write`, `Microsoft.Compute/disks/read` |
| Virtual Machine Contributor | Target resource group | `Microsoft.Compute/virtualMachines/read`, `Microsoft.Compute/virtualMachines/write`, `Microsoft.Compute/disks/delete` |

> **Note:** The identity running the RBAC assignment scripts themselves needs **Owner** or **User Access Administrator** on the target scopes.

---

## Common Options (All Scripts)

| Option | Description |
|--------|-------------|
| `--auth-method` | `none` (default), `interactive`, `device-code`, `service-principal`, `managed-identity` |
| `--tenant-id` | Azure AD tenant (required for `service-principal`) |
| `--client-id` | App registration or user-assigned managed identity client ID |
| `--client-secret` | Client secret (also via `AZURE_CLIENT_SECRET` env var) |
| `--log-file` | Write output to a log file |
| `--debug` | Verbose debug logging |
| `--dry-run` | Print commands without executing |

---

## Throttling & Retry

All scripts share an `az_with_retry` function that automatically retries Azure CLI commands when throttling is detected (`429 TooManyRequests`). Retries use exponential backoff starting at 5 seconds, doubling up to 60 seconds, for a maximum of 8 attempts.
