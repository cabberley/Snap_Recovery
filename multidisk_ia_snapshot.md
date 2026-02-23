# multidisk_ia_snapshot.sh

Azure multi-disk snapshot creation tool with **parallel execution**, **Instant Access** support, and optional **metadata export** for downstream automation.

---

## Table of Contents

- [Purpose](#purpose)
- [Why Parallel Execution Matters](#why-parallel-execution-matters)
- [Requirements](#requirements)
- [Parameters](#parameters)
- [Authentication](#authentication)
- [Examples](#examples)
- [Instant Access Snapshots](#instant-access-snapshots)
- [Metadata File Output](#metadata-file-output)
- [Creating Managed Disks from Snapshots](#creating-managed-disks-from-snapshots)

---

## Purpose

`multidisk_ia_snapshot.sh` creates Azure snapshots of **every data disk** (or a selected subset) attached to a virtual machine. It is specifically designed for **Premium SSD v2 (PremiumV2_LRS)** and **Ultra Disk (UltraSSD_LRS)** workloads that require incremental snapshots, though it works equally well with standard Premium and Standard SSD disks.

The script wraps the Azure CLI `az snapshot create` command with:

- **Automatic SKU detection** — PremiumV2 and Ultra disks are identified and incremental mode is enabled automatically.
- **Parallel snapshot creation** — all snapshots launch simultaneously instead of one-at-a-time.
- **Retry with exponential back-off** — Azure throttling (HTTP 429) is detected and retried transparently (up to 8 attempts, 5 s → 60 s).
- **Background copy polling** — when `--copy-start` is used, the script tracks each snapshot's `completionPercent` until it reaches `Succeeded`.
- **Network access hardening** — public network access and network access policy default to `Disabled` / `DenyAll`.
- **Metadata JSON output** — a structured file that can drive downstream automation such as disk restore.

---

## Why Parallel Execution Matters

Traditional snapshot scripts create disks **sequentially** — disk 1 finishes, then disk 2 starts, then disk 3, and so on. For VMs with many large data disks this can mean **tens of minutes to hours of wall-clock time**, and the later disks are snapshotted at a significantly different point in time than the earlier ones.

`multidisk_ia_snapshot.sh` uses a **three-phase parallel architecture**:

| Phase | What happens |
|-------|-------------|
| **Phase 1 — Resolve & Launch** | For each data disk, the script resolves disk metadata (SKU, size), then launches `az snapshot create` in a **background subshell** (`&`). Each subshell writes its result to a temp file. All creates are in flight simultaneously. |
| **Phase 2 — Wait** | The script calls `wait` on every background PID. This blocks until *all* snapshot API calls have returned, but since they run in parallel the total time ≈ the **slowest single disk**, not the sum of all disks. |
| **Phase 3 — Collect & Verify** | Exit codes and snapshot resource IDs are read from the temp files. If Instant Access duration was requested, the script verifies it was applied (and falls back to `az snapshot update` if needed). Snapshots using `--copy-start` are queued for polling. |

### Concrete benefit

Consider a VM with **8 data disks**, each taking ~45 seconds to snapshot:

| Approach | Wall-clock time |
|----------|----------------|
| Sequential | 8 × 45 s = **6 minutes** |
| Parallel (this script) | max(45 s) ≈ **45 seconds** |

Beyond raw speed, parallel creation also gives you a **closer-in-time crash-consistent view** across all disks because every snapshot API call is issued within milliseconds of the others.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **Azure CLI** | Version **≥ 2.83.0** (the script validates this on start-up) |
| **Bash** | Version 4+ (uses `mapfile`, associative constructs) |
| **Permissions** | Contributor (or a custom role with `Microsoft.Compute/snapshots/write`, `Microsoft.Compute/disks/read`, `Microsoft.Compute/virtualMachines/read`) on the relevant resource groups |

---

## Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `--subscription-id <id>` | Azure subscription ID |
| `--resource-group <name>` | Resource group containing the source VM |
| `--vm-name <name>` | Name of the source VM |
| `--snapshot-prefix <prefix>` | Prefix for snapshot names. Snapshots are named `<prefix>-<disk-name>-<yyyyMMddHHmmss>` |

### Authentication

| Parameter | Description |
|-----------|-------------|
| `--auth-method <method>` | Authentication method. Default: `none` (assumes already authenticated). Values: `none`, `interactive`, `device-code`, `service-principal`, `managed-identity` |
| `--tenant-id <id>` | Azure AD tenant ID (required for `service-principal`) |
| `--client-id <id>` | Application (client) ID for `service-principal`, or client ID for a user-assigned managed identity |
| `--client-secret <secret>` | Client secret for `service-principal` auth. Can also be set via `AZURE_CLIENT_SECRET` env var |

### Snapshot Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--incremental` | Auto-detected | Create incremental snapshots. Automatically enabled when PremiumV2 or Ultra disks are detected |
| `--copy-start` | Off | Start snapshot copy as a background operation. Without this flag `az snapshot create` blocks until the copy completes |
| `--no-wait` | Off | Do not poll for background copy completion (only relevant with `--copy-start`) |
| `--timeout-minutes <int>` | `60` | Maximum minutes to wait for each snapshot to reach `Succeeded` |
| `--poll-seconds <int>` | `15` | Seconds between polling intervals during background copy |
| `--ia-duration <minutes>` | None | Instant Access duration in minutes (1–300). See [Instant Access Snapshots](#instant-access-snapshots) |

### Network Access

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--public-network-access <val>` | `Disabled` | Public network access for snapshots. Values: `Enabled`, `Disabled` |
| `--network-access-policy <val>` | `DenyAll` | Network access policy. Values: `AllowAll`, `AllowPrivate`, `DenyAll` |

### Disk Selection

| Parameter | Description |
|-----------|-------------|
| `--only-disks <disk1,disk2,...>` | Comma-separated list of data disk names to snapshot. If omitted, **all** data disks on the VM are included |

### Target

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--target-resource-group <rg>` | Same as `--resource-group` | Resource group where snapshots are created |

### Logging & Debug

| Parameter | Description |
|-----------|-------------|
| `--log-file <path>` | Tee all output to a log file (terminal output is preserved) |
| `--debug` | Enable verbose debug logging (commands, polling details, disk IDs) |

### Other

| Parameter | Description |
|-----------|-------------|
| `--metadata-file <path>` | Write a JSON metadata file after snapshot creation. See [Metadata File Output](#metadata-file-output) |
| `--dry-run` | Print snapshot commands without executing them |
| `--help` | Show the built-in help text |

---

## Authentication

The script supports five authentication methods via `--auth-method`:

| Method | When to use |
|--------|------------|
| `none` (default) | You have already run `az login` in the current shell |
| `interactive` | Opens a browser for Azure AD login |
| `device-code` | Displays a device code for headless / SSH environments |
| `service-principal` | CI/CD pipelines with a client ID and secret |
| `managed-identity` | Running on an Azure VM or container with a managed identity |

After authentication, the script verifies connectivity with `az account show` and prints the logged-in identity.

---

## Examples

### 1. Snapshot all data disks (simplest invocation)

Auto-detects PremiumV2/Ultra and enables incremental mode automatically:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix bkp
```

This creates snapshots named `bkp-<diskname>-<timestamp>` for every data disk on the VM.

### 2. Instant Access Snapshot with background copy

Create snapshots with a 2-hour Instant Access window and let the copy run in the background with a 90-minute timeout:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix ia-snap \
  --copy-start \
  --ia-duration 120 \
  --timeout-minutes 90
```

The script will:
1. Launch all `az snapshot create` calls in parallel with `--copy-start true` and `--instant-access-duration-minutes 120`.
2. Wait for all creates to return.
3. Verify the Instant Access duration was set (falling back to `az snapshot update` if needed).
4. Poll each snapshot's `completionPercent` every 15 seconds until `provisioningState` reaches `Succeeded` or the 90-minute timeout is hit.

### 3. Snapshot specific disks into a different resource group

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix bkp \
  --target-resource-group snapshots-rg \
  --only-disks "datadisk1,datadisk2"
```

### 4. Service principal authentication (CI/CD)

```bash
./multidisk_ia_snapshot.sh \
  --auth-method service-principal \
  --tenant-id 00000000-0000-0000-0000-000000000000 \
  --client-id 00000000-0000-0000-0000-000000000000 \
  --client-secret "$AZURE_CLIENT_SECRET" \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix ci-snap \
  --metadata-file ./snapshot-metadata.json
```

### 5. Managed identity on an Azure VM

```bash
./multidisk_ia_snapshot.sh \
  --auth-method managed-identity \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix snap
```

### 6. Dry-run with debug logging

Preview what commands would be executed without making any API calls:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id 00000000-0000-0000-0000-000000000000 \
  --resource-group my-rg \
  --vm-name my-vm \
  --snapshot-prefix test \
  --log-file ./snapshot.log \
  --debug \
  --dry-run
```

---

## Instant Access Snapshots

### What is Instant Access?

Azure Instant Access snapshots keep the snapshot data in the **high-performance, local tier** for a configurable period before it is moved to standard storage. During this window:

- **Restores are near-instant** — creating a managed disk from the snapshot completes in seconds rather than waiting for a background hydration.
- **Read latency is the same as the source disk** — the snapshot is backed by the same storage infrastructure.

This is especially valuable for **PremiumV2_LRS** and **UltraSSD_LRS** disks where large dataset restore times can be significant.

### How to use it with this script

Use the `--ia-duration` parameter to set the Instant Access window in **minutes**:

```bash
./multidisk_ia_snapshot.sh \
  --subscription-id <sub> \
  --resource-group <rg> \
  --vm-name <vm> \
  --snapshot-prefix ia \
  --ia-duration 120 \
  --copy-start
```

| `--ia-duration` value | Meaning |
|-----------------------|---------|
| `60` | 1 hour of instant access |
| `120` | 2 hours of instant access |
| `300` | 5 hours (maximum) |

### What the script does behind the scenes

1. Passes `--instant-access-duration-minutes <value>` to `az snapshot create`.
2. After creation, reads the snapshot back with `az snapshot show` and checks `creationData.instantAccessDurationMinutes`.
3. If the value is not set (some API versions silently ignore it), the script falls back to `az snapshot update --set creationData.instantAccessDurationMinutes=<value>` to patch it.

### When to combine with `--copy-start`

For large PremiumV2/Ultra disks you will typically want **both** flags:

- `--copy-start` — the snapshot create call returns immediately while the data copy runs in the background.
- `--ia-duration` — keeps the snapshot in the instant-access tier so that early restores during or after the copy are fast.

Without `--copy-start`, the `az snapshot create` call blocks until the copy completes. This is simpler but ties up the script for the duration of the copy (which can be minutes to hours for multi-TiB disks).

---

## Metadata File Output

When `--metadata-file <path>` is specified, the script writes a JSON file containing everything needed to automate downstream tasks such as creating managed disks from the snapshots.

### Structure

```json
{
  "timestamp": "2025-07-14T09:30:00Z",
  "vm": {
    "name": "my-vm",
    "resourceGroup": "my-rg",
    "subscriptionId": "00000000-0000-0000-0000-000000000000",
    "location": "eastus2"
  },
  "parameters": {
    "snapshotPrefix": "bkp",
    "targetResourceGroup": "my-rg",
    "incremental": true,
    "copyStart": false,
    "iaAccessDurationMinutes": 120,
    "azCliVersion": "2.83.0"
  },
  "snapshotCount": 3,
  "snapshots": [
    {
      "snapshotName": "bkp-datadisk0-20250714093000",
      "snapshotId": "/subscriptions/.../snapshots/bkp-datadisk0-20250714093000",
      "sourceDiskName": "datadisk0",
      "sourceDiskId": "/subscriptions/.../disks/datadisk0",
      "diskSku": "PremiumV2_LRS",
      "diskSizeGb": "512"
    },
    {
      "snapshotName": "bkp-datadisk1-20250714093000",
      "snapshotId": "/subscriptions/.../snapshots/bkp-datadisk1-20250714093000",
      "sourceDiskName": "datadisk1",
      "sourceDiskId": "/subscriptions/.../disks/datadisk1",
      "diskSku": "PremiumV2_LRS",
      "diskSizeGb": "1024"
    },
    {
      "snapshotName": "bkp-datadisk2-20250714093000",
      "snapshotId": "/subscriptions/.../snapshots/bkp-datadisk2-20250714093000",
      "sourceDiskName": "datadisk2",
      "sourceDiskId": "/subscriptions/.../disks/datadisk2",
      "diskSku": "UltraSSD_LRS",
      "diskSizeGb": "2048"
    }
  ]
}
```

### Key fields

| Field | Description |
|-------|-------------|
| `timestamp` | UTC timestamp when the metadata file was written |
| `vm.name` / `vm.resourceGroup` / `vm.location` | Source VM details |
| `parameters.iaAccessDurationMinutes` | Instant Access duration (or `null` if not set) |
| `parameters.azCliVersion` | Azure CLI version used to create the snapshots |
| `snapshots[].snapshotId` | Full ARM resource ID of each snapshot — used as `--source` when creating disks |
| `snapshots[].diskSku` | Original disk SKU — use this to create the new disk with the same storage tier |
| `snapshots[].diskSizeGb` | Original disk size — use this as `--size-gb` when creating the new disk |

---

## Creating Managed Disks from Snapshots

The metadata file is designed to feed directly into `az disk create` to restore or clone data disks. Below are examples using `jq` to extract the relevant fields.

### Restore all disks from a metadata file

```bash
#!/usr/bin/env bash
# restore_disks.sh — create managed disks from snapshot metadata

METADATA_FILE="./snapshot-metadata.json"
TARGET_RG="restore-rg"

SUBSCRIPTION=$(jq -r '.vm.subscriptionId' "$METADATA_FILE")
LOCATION=$(jq -r '.vm.location' "$METADATA_FILE")
SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA_FILE")

echo "Restoring $SNAP_COUNT disk(s) in $TARGET_RG ..."

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_ID=$(jq -r ".snapshots[$i].snapshotId" "$METADATA_FILE")
  DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA_FILE")
  DISK_SKU=$(jq -r ".snapshots[$i].diskSku" "$METADATA_FILE")
  DISK_SIZE=$(jq -r ".snapshots[$i].diskSizeGb" "$METADATA_FILE")

  NEW_DISK_NAME="restored-${DISK_NAME}"

  echo "Creating disk: $NEW_DISK_NAME (sku=$DISK_SKU, size=${DISK_SIZE} GiB)"

  az disk create \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$TARGET_RG" \
    --name "$NEW_DISK_NAME" \
    --location "$LOCATION" \
    --source "$SNAP_ID" \
    --sku "$DISK_SKU" \
    --size-gb "$DISK_SIZE" \
    -o none
done

echo "All disks restored."
```

### Restore a single disk

```bash
# Extract the first snapshot's ID
SNAP_ID=$(jq -r '.snapshots[0].snapshotId' snapshot-metadata.json)

az disk create \
  --subscription "$(jq -r '.vm.subscriptionId' snapshot-metadata.json)" \
  --resource-group restore-rg \
  --name restored-datadisk0 \
  --location "$(jq -r '.vm.location' snapshot-metadata.json)" \
  --source "$SNAP_ID" \
  --sku PremiumV2_LRS \
  --size-gb 512 \
  -o none
```

### Find a snapshot by disk name

```bash
# Get the snapshot ID for a specific source disk
SNAP_ID=$(jq -r '.snapshots[] | select(.sourceDiskName == "datadisk1") | .snapshotId' snapshot-metadata.json)
echo "$SNAP_ID"
```

### Attach restored disks to a VM

After creating the disks, attach them to a VM:

```bash
for i in $(seq 0 $((SNAP_COUNT - 1))); do
  DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA_FILE")
  NEW_DISK_NAME="restored-${DISK_NAME}"

  az vm disk attach \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$TARGET_RG" \
    --vm-name my-restored-vm \
    --name "$NEW_DISK_NAME" \
    --lun "$i" \
    -o none

  echo "Attached $NEW_DISK_NAME at LUN $i"
done
```

---

## Error Handling & Resilience

The script includes several layers of error handling:

| Feature | Details |
|---------|---------|
| **Throttle retry** | `az_with_retry()` detects Azure 429 / throttling responses and retries with exponential back-off (5 s → 10 s → 20 s → 40 s → 60 s, up to 8 attempts) |
| **Strict mode** | `set -euo pipefail` — any unhandled error or undefined variable terminates the script immediately |
| **Parallel failure tracking** | Each background subshell writes its exit code to a temp file. Phase 3 checks every exit code and reports individual failures |
| **IA duration fallback** | If `az snapshot create` does not apply the Instant Access duration, the script patches it with `az snapshot update` |
| **Copy-start timeout** | When polling for background copy completion, the script enforces `--timeout-minutes` and exits with clear instructions for manual follow-up |
| **Input validation** | All required parameters are checked before any API call is made. `--ia-duration` is validated to be an integer between 1 and 300 |

---

## Security Defaults

The script applies secure-by-default network settings to every snapshot:

| Setting | Default | Effect |
|---------|---------|--------|
| `--public-network-access` | `Disabled` | Snapshots cannot be accessed over the public internet |
| `--network-access-policy` | `DenyAll` | No network access is allowed (use Private Link for access) |

To allow public access (e.g. for development or export), override explicitly:

```bash
--public-network-access Enabled --network-access-policy AllowAll
```
