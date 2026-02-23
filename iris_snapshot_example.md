# Snapshotting an InterSystems IRIS Database with multidisk_ia_snapshot.sh

A step-by-step guide for creating **crash-consistent, application-quiesced snapshots** of an InterSystems IRIS database running on Azure VMs with data files spread across multiple disks in a Linux LVM volume group.

---

## Table of Contents

- [Snapshotting an InterSystems IRIS Database with multidisk\_ia\_snapshot.sh](#snapshotting-an-intersystems-iris-database-with-multidisk_ia_snapshotsh)
  - [Table of Contents](#table-of-contents)
  - [Scenario Overview](#scenario-overview)
  - [Why This Approach Works](#why-this-approach-works)
    - [The freeze window problem](#the-freeze-window-problem)
    - [Parallel execution minimizes downtime](#parallel-execution-minimizes-downtime)
    - [Using `--copy-start` to release the freeze faster](#using---copy-start-to-release-the-freeze-faster)
  - [Architecture](#architecture)
  - [Prerequisites](#prerequisites)
    - [IRIS instance details (example values used throughout)](#iris-instance-details-example-values-used-throughout)
  - [Step-by-Step Procedure](#step-by-step-procedure)
    - [Step 1 — Freeze the IRIS Write Daemon](#step-1--freeze-the-iris-write-daemon)
    - [Step 2 — Freeze the XFS Filesystem](#step-2--freeze-the-xfs-filesystem)
    - [Step 3 — Snapshot All Data Disks in Parallel](#step-3--snapshot-all-data-disks-in-parallel)
    - [Step 4 — Thaw the XFS Filesystem](#step-4--thaw-the-xfs-filesystem)
    - [Step 5 — Thaw the IRIS Write Daemon](#step-5--thaw-the-iris-write-daemon)
    - [Step 6 — Wait for Snapshot Completion](#step-6--wait-for-snapshot-completion)
    - [Step 7 — Create Managed Disks from Snapshots](#step-7--create-managed-disks-from-snapshots)
    - [Step 8 — Attach Disks to the Test VM](#step-8--attach-disks-to-the-test-vm)
    - [Step 9 — Import the LVM Volume Group on the Test VM](#step-9--import-the-lvm-volume-group-on-the-test-vm)
      - [Mount the XFS filesystem](#mount-the-xfs-filesystem)
    - [Step 10 — Start the Test IRIS Instance](#step-10--start-the-test-iris-instance)
      - [Optional: Run an integrity check](#optional-run-an-integrity-check)
  - [Complete Automation Script](#complete-automation-script)
  - [Operational Notes](#operational-notes)
    - [Freeze duration budget](#freeze-duration-budget)
    - [Scheduling and retention](#scheduling-and-retention)
    - [LVM considerations](#lvm-considerations)
    - [XFS UUID conflict](#xfs-uuid-conflict)
    - [IRIS configuration on the test VM](#iris-configuration-on-the-test-vm)
  - [Troubleshooting](#troubleshooting)
    - [`iris freeze` hangs](#iris-freeze-hangs)
    - [`xfs_freeze -f` returns an error](#xfs_freeze--f-returns-an-error)
    - [Snapshot creation fails with throttling](#snapshot-creation-fails-with-throttling)
    - [`vgimportclone` fails with "no PVs found"](#vgimportclone-fails-with-no-pvs-found)
    - [IRIS reports "database is corrupted" on test VM](#iris-reports-database-is-corrupted-on-test-vm)

---

## Scenario Overview

An InterSystems IRIS database server on Azure has its **database files (IRIS.DAT)** distributed across **8 or more Azure data disks** that are combined into a single **Linux LVM volume group** and formatted with **XFS**. The goal is to:

1. **Create a point-in-time snapshot** of all data disks simultaneously.
2. **Restore those snapshots as new managed disks** and attach them to a separate **test VM** running IRIS.
3. The test VM imports the LVM volume group, mounts the XFS filesystem, and starts the IRIS instance against the cloned data.

To guarantee a consistent snapshot, the process uses a **two-layer freeze** before triggering the snapshots:

| Layer | Command | Purpose |
|-------|---------|---------|
| **Application** | `iris freeze <instance>` | Flushes the IRIS Write Daemon (WD) buffers to disk and pauses all database writes |
| **Filesystem** | `xfs_freeze -f <mountpoint>` | Quiesces the XFS filesystem, flushing any pending metadata/journal writes and blocking new I/O |

With both layers frozen, the Azure snapshot captures a **fully consistent** state of every IRIS database file across all disks.

---

## Why This Approach Works

### The freeze window problem

The critical constraint is that the IRIS freeze and XFS freeze must remain active **until every disk snapshot has been initiated at the Azure platform level**. Once the snapshot API call is accepted, the platform captures a point-in-time image — the freeze can be released.

With **sequential** snapshot creation across 8 disks, the freeze window might last 3–6 minutes. That means:

- IRIS is **completely blocked from writing** for that entire period.
- Application queries queue up or time out.
- The later disks are snapshotted minutes after the earlier ones (reducing consistency if the freeze were not held).

### Parallel execution minimizes downtime

`multidisk_ia_snapshot.sh` launches all 8+ snapshot API calls **simultaneously** in Phase 1. The Azure platform receives all snapshot requests within milliseconds of each other. This means:

| Metric | Sequential (8 disks) | Parallel (this script) |
|--------|----------------------|------------------------|
| Freeze window | 3–6 minutes | **5–15 seconds** |
| IRIS write pause | 3–6 minutes | **5–15 seconds** |
| Point-in-time skew between disks | Minutes | **Milliseconds** |

For a production IRIS database, reducing the freeze window from minutes to seconds is the difference between a noticeable outage and a brief hiccup that most applications absorb transparently through connection retry.

### Using `--copy-start` to release the freeze faster

By adding `--copy-start`, the `az snapshot create` call returns as soon as the **point-in-time is captured** — before the full data copy completes. This means:

1. **Freeze** IRIS + XFS
2. **Launch** all snapshot creates with `--copy-start` (returns in seconds)
3. **Thaw** XFS + IRIS immediately
4. The data copy continues in the background — poll with `--timeout-minutes`

The application is unfrozen as quickly as possible, and the heavy data copy runs asynchronously.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Production IRIS VM                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  InterSystems IRIS Instance                          │    │
│  │  iris freeze <instance>  /  iris thaw <instance>     │    │
│  └──────────────────────────────────────────────────────┘    │
│                           │                                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  XFS Filesystem  (/irisdb)                           │    │
│  │  xfs_freeze -f  /  xfs_freeze -u                     │    │
│  └──────────────────────────────────────────────────────┘    │
│                           │                                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  LVM Volume Group (vg_irisdata)                      │    │
│  │  Logical Volume: lv_irisdb                           │    │
│  └──────────────────────────────────────────────────────┘    │
│       │       │       │       │       │       │       │      │
│     disk0   disk1   disk2   disk3   disk4   disk5   disk6  … │
│  (Azure data disks — PremiumV2_LRS or UltraSSD_LRS)          │
└──────────────────────────────────────────────────────────────┘
        │       │       │       │       │       │       │
        ▼       ▼       ▼       ▼       ▼       ▼       ▼
   ┌─────────────────────────────────────────────────────────┐
   │          Azure Snapshot (parallel via script)           │
   │  snap-disk0-ts  snap-disk1-ts  snap-disk2-ts  ...       │
   └─────────────────────────────────────────────────────────┘
        │       │       │       │       │       │       │
        ▼       ▼       ▼       ▼       ▼       ▼       ▼
   ┌─────────────────────────────────────────────────────────┐
   │        New Managed Disks (az disk create --source)      │
   │  rst-disk0  rst-disk1  rst-disk2  rst-disk3  ...        │
   └─────────────────────────────────────────────────────────┘
        │       │       │       │       │       │       │
        ▼       ▼       ▼       ▼       ▼       ▼       ▼
┌──────────────────────────────────────────────────────────────┐
│                      Test IRIS VM                            │
│                                                              │
│  vgimportclone → vg_irisdata_clone                           │
│  mount /dev/vg_irisdata_clone/lv_irisdb /irisdb              │
│  iris start <instance>                                       │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Production VM** | Azure VM running Linux with InterSystems IRIS and data disks in LVM/XFS |
| **Test VM** | A separate Azure VM with IRIS installed (same or compatible version), ready to receive the cloned disks |
| **Azure CLI** | Version ≥ 2.83.0 installed on the machine running the script |
| **`multidisk_ia_snapshot.sh`** | The snapshot script from this repository |
| **`jq`** | For parsing the metadata JSON file during disk restore |
| **Root / sudo access** | Required on both VMs for `iris freeze/thaw`, `xfs_freeze`, and LVM operations |
| **Permissions** | Azure Contributor role (or equivalent) on the resource groups for VM, disks, and snapshots |

### IRIS instance details (example values used throughout)

| Setting | Value |
|---------|-------|
| IRIS instance name | `IRISDB` |
| LVM volume group | `vg_irisdata` |
| LVM logical volume | `lv_irisdb` |
| XFS mount point | `/irisdb` |
| Number of data disks | 8 |
| Disk SKU | `PremiumV2_LRS` |

---

## Step-by-Step Procedure

### Step 1 — Freeze the IRIS Write Daemon

Connect to the production VM and freeze the IRIS instance. This flushes the Write Daemon (WD) buffers — all modified database blocks in shared memory are written to disk — and then pauses all further database writes.

```bash
# On the production IRIS VM (as root or irisowner)
iris freeze IRISDB
```

**What this does:**
- The Write Daemon completes any in-flight writes.
- All global buffers are flushed to the IRIS.DAT files on disk.
- The journal file is flushed and synced.
- IRIS enters a frozen state — application processes that attempt writes will block (not error) until thaw.

> **Important:** The freeze is cooperative — IRIS processes pause gracefully. They resume automatically on `iris thaw` without connection drops.

To verify the freeze is active:

```bash
iris list IRISDB
# Look for "running, freezing" or "running, frozen" in the status
```

### Step 2 — Freeze the XFS Filesystem

With IRIS frozen, freeze the XFS filesystem to ensure no pending metadata or journal writes remain in the kernel buffer:

```bash
# Freeze the XFS filesystem
sudo xfs_freeze -f /irisdb
```

**What this does:**
- Flushes the XFS log (journal) to disk.
- Completes any pending metadata operations.
- Blocks all new I/O to the filesystem at the kernel level.

> **Note:** The order matters — freeze IRIS first, then XFS. This ensures IRIS has finished its flush before the filesystem is frozen. Reversing the order could deadlock (IRIS tries to write during its flush, but XFS blocks the I/O).

### Step 3 — Snapshot All Data Disks in Parallel

With both IRIS and XFS frozen, all database files on all disks are in a consistent state. Now create the snapshots. Using `--copy-start` means the API call returns as soon as the point-in-time is captured:

```bash
# Run from a machine with Azure CLI authenticated (can be the VM itself or a jump box)
./multidisk_ia_snapshot.sh \
  --subscription-id "00000000-0000-0000-0000-000000000000" \
  --resource-group "iris-prod-rg" \
  --vm-name "iris-prod-vm" \
  --snapshot-prefix "irissnap" \
  --copy-start \
  --no-wait \
  --ia-duration 120 \
  --incremental \
  --metadata-file ./iris-snapshot-metadata.json \
  --log-file ./iris-snapshot.log
```

**Key flags for this scenario:**

| Flag | Why |
|------|-----|
| `--copy-start` | Returns immediately after point-in-time capture — minimises the freeze window |
| `--no-wait` | Don't poll for copy completion yet — thaw first, poll later |
| `--ia-duration 120` | 2-hour Instant Access window for fast disk creation from the snapshots |
| `--incremental` | Required for PremiumV2/Ultra disks (auto-detected, but explicit here for clarity) |
| `--metadata-file` | Generates JSON used in later steps to create the restored disks |

> **The freeze window ends here.** As soon as this command returns, the Azure platform has captured the point-in-time for all 8+ disks. The freeze can be released.

### Step 4 — Thaw the XFS Filesystem

```bash
# Unfreeze XFS first
sudo xfs_freeze -u /irisdb
```

### Step 5 — Thaw the IRIS Write Daemon

```bash
# Then thaw IRIS
iris thaw IRISDB
```

**Order:** Thaw XFS first, then IRIS. IRIS will immediately attempt to write when thawed, so the filesystem must be accepting I/O. IRIS processes that were paused resume writing automatically.

Verify IRIS is running normally:

```bash
iris list IRISDB
# Status should show "running" (no freeze indicator)
```

> **Total production impact:** The freeze window typically lasts only **5–15 seconds** — the time for Steps 1–3 to execute. Application connections are preserved; blocked writes resume instantly on thaw.

### Step 6 — Wait for Snapshot Completion

Now that the database is back online, poll for the background snapshot copies to complete. You can run this from any machine — the production VM is fully operational:

```bash
# Poll for completion (re-run snapshot script in poll-only mode, or use az CLI directly)
METADATA="./iris-snapshot-metadata.json"
SUBSCRIPTION=$(jq -r '.vm.subscriptionId' "$METADATA")
TARGET_RG=$(jq -r '.parameters.targetResourceGroup' "$METADATA")
SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA")

echo "Waiting for $SNAP_COUNT snapshots to complete..."

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_NAME=$(jq -r ".snapshots[$i].snapshotName" "$METADATA")
  echo -n "  $SNAP_NAME: "

  while true; do
    STATE=$(az snapshot show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$TARGET_RG" \
      --name "$SNAP_NAME" \
      --query "provisioningState" -o tsv 2>/dev/null)
    PCT=$(az snapshot show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$TARGET_RG" \
      --name "$SNAP_NAME" \
      --query "completionPercent" -o tsv 2>/dev/null)

    if [[ "$STATE" == "Succeeded" ]]; then
      echo "complete"
      break
    fi
    echo -n "${PCT:-?}%... "
    sleep 15
  done
done

echo "All snapshots completed."
```

### Step 7 — Create Managed Disks from Snapshots

Use the metadata file to create new managed disks in the **test VM's resource group**:

```bash
#!/usr/bin/env bash
# create_iris_test_disks.sh

METADATA="./iris-snapshot-metadata.json"
TEST_RG="iris-test-rg"

SUBSCRIPTION=$(jq -r '.vm.subscriptionId' "$METADATA")
LOCATION=$(jq -r '.vm.location' "$METADATA")
SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA")

echo "Creating $SNAP_COUNT managed disk(s) in $TEST_RG from snapshots..."

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_ID=$(jq -r ".snapshots[$i].snapshotId" "$METADATA")
  DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA")
  DISK_SKU=$(jq -r ".snapshots[$i].diskSku" "$METADATA")
  DISK_SIZE=$(jq -r ".snapshots[$i].diskSizeGb" "$METADATA")

  NEW_DISK_NAME="iris-test-${DISK_NAME}"

  echo "  Creating $NEW_DISK_NAME (sku=$DISK_SKU, size=${DISK_SIZE} GiB)..."

  az disk create \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$TEST_RG" \
    --name "$NEW_DISK_NAME" \
    --location "$LOCATION" \
    --source "$SNAP_ID" \
    --sku "$DISK_SKU" \
    --size-gb "$DISK_SIZE" \
    -o none

  echo "    Done."
done

echo "All disks created."
```

> **Instant Access benefit:** Because `--ia-duration 120` was set during snapshot creation, the `az disk create --source <snapshot>` calls will complete **near-instantly** (seconds, not minutes). The snapshot data is still in the high-performance local tier, so there is no background hydration wait.

### Step 8 — Attach Disks to the Test VM

```bash
#!/usr/bin/env bash
# attach_iris_test_disks.sh

METADATA="./iris-snapshot-metadata.json"
TEST_RG="iris-test-rg"
TEST_VM="iris-test-vm"

SUBSCRIPTION=$(jq -r '.vm.subscriptionId' "$METADATA")
SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA")

echo "Attaching $SNAP_COUNT disk(s) to $TEST_VM..."

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA")
  NEW_DISK_NAME="iris-test-${DISK_NAME}"

  echo "  Attaching $NEW_DISK_NAME at LUN $i..."

  az vm disk attach \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$TEST_RG" \
    --vm-name "$TEST_VM" \
    --name "$NEW_DISK_NAME" \
    --lun "$i" \
    -o none
done

echo "All disks attached. Proceed to LVM import on the test VM."
```

### Step 9 — Import the LVM Volume Group on the Test VM

SSH into the test VM and import the cloned LVM volume group. Since these disks are copies of the production disks, the LVM metadata contains the **same VG UUID**. Use `vgimportclone` to assign a new UUID and optionally rename the VG:

```bash
# On the test IRIS VM (as root)

# 1. Scan for new block devices (the attached disks)
sudo pvscan --cache

# 2. Identify the new PVs — they will show the production VG name
sudo pvs
# Example output:
#   /dev/sdc   vg_irisdata  lvm2  ...
#   /dev/sdd   vg_irisdata  lvm2  ...
#   /dev/sde   vg_irisdata  lvm2  ...
#   ... (8 or more disks)

# 3. Import the cloned VG with a new name to avoid conflicts
#    List ALL PVs that belong to the volume group
sudo vgimportclone \
  --basevgname vg_irisdata_test \
  /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh /dev/sdi /dev/sdj

# 4. Activate the volume group
sudo vgchange -ay vg_irisdata_test

# 5. Verify the logical volume is available
sudo lvs vg_irisdata_test
# Expected:
#   LV          VG                 Attr       LSize
#   lv_irisdb   vg_irisdata_test   -wi-a----- <total size>
```

#### Mount the XFS filesystem

Since the XFS filesystem also has a UUID from the production volume, use `nouuid` to avoid conflicts if the production filesystem UUID is already known to the kernel:

```bash
# 6. Create the mount point
sudo mkdir -p /irisdb

# 7. Mount with nouuid (required because the XFS UUID matches production)
sudo mount -o nouuid /dev/vg_irisdata_test/lv_irisdb /irisdb

# 8. Verify the mount and data
ls -la /irisdb/
# Should show the IRIS database directories and IRIS.DAT files
df -h /irisdb
```

### Step 10 — Start the Test IRIS Instance

With the database files mounted at the expected path, start the IRIS instance:

```bash
# 9. Verify IRIS can see the databases
iris list IRISDB

# 10. Start the instance
iris start IRISDB

# 11. Verify the instance is running and databases are accessible
iris session IRISDB -U %SYS
# At the IRIS prompt:
#   >do ^%SS        ; show system status
#   >do ^INTEGRITY  ; optional integrity check
#   >halt
```

> **Note:** If the test VM uses a different IRIS instance name, update the IRIS configuration (iris.cpf) to point to the mounted database directories before starting.

#### Optional: Run an integrity check

After starting the test instance, it is good practice to verify database integrity:

```bash
iris session IRISDB -U %SYS <<'EOF'
do ##class(%Library.GlobalEdit).IntegrityCheck("/irisdb",,1)
halt
EOF
```

---

## Complete Automation Script

Below is an end-to-end script that combines all steps. Run it on the **production VM** (or a jump box that has SSH access to both VMs):

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Configuration
# ===========================================================================
IRIS_INSTANCE="IRISDB"
IRIS_MOUNT="/irisdb"

SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
PROD_RG="iris-prod-rg"
PROD_VM="iris-prod-vm"
TEST_RG="iris-test-rg"
TEST_VM="iris-test-vm"

SNAPSHOT_PREFIX="irissnap"
IA_DURATION=120
METADATA_FILE="./iris-snapshot-metadata.json"
LOG_FILE="./iris-snapshot.log"

# ===========================================================================
# Phase A: Freeze → Snapshot → Thaw  (production VM)
# ===========================================================================
echo "=== Phase A: Freeze + Snapshot + Thaw ==="

echo "[1/5] Freezing IRIS instance $IRIS_INSTANCE ..."
iris freeze "$IRIS_INSTANCE"

echo "[2/5] Freezing XFS filesystem at $IRIS_MOUNT ..."
sudo xfs_freeze -f "$IRIS_MOUNT"

echo "[3/5] Creating parallel snapshots of all data disks ..."
./multidisk_ia_snapshot.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --resource-group "$PROD_RG" \
  --vm-name "$PROD_VM" \
  --snapshot-prefix "$SNAPSHOT_PREFIX" \
  --copy-start \
  --no-wait \
  --ia-duration "$IA_DURATION" \
  --incremental \
  --metadata-file "$METADATA_FILE" \
  --log-file "$LOG_FILE"

echo "[4/5] Thawing XFS filesystem ..."
sudo xfs_freeze -u "$IRIS_MOUNT"

echo "[5/5] Thawing IRIS instance ..."
iris thaw "$IRIS_INSTANCE"

echo "=== Freeze window closed. Production is back online. ==="
echo ""

# ===========================================================================
# Phase B: Wait for snapshots to complete
# ===========================================================================
echo "=== Phase B: Waiting for snapshot copies ==="

SNAP_COUNT=$(jq -r '.snapshotCount' "$METADATA_FILE")
TARGET_RG=$(jq -r '.parameters.targetResourceGroup' "$METADATA_FILE")

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_NAME=$(jq -r ".snapshots[$i].snapshotName" "$METADATA_FILE")
  echo -n "  $SNAP_NAME: "
  while true; do
    STATE=$(az snapshot show --subscription "$SUBSCRIPTION_ID" \
      --resource-group "$TARGET_RG" --name "$SNAP_NAME" \
      --query "provisioningState" -o tsv 2>/dev/null) || STATE=""
    if [[ "$STATE" == "Succeeded" ]]; then
      echo "complete"
      break
    fi
    PCT=$(az snapshot show --subscription "$SUBSCRIPTION_ID" \
      --resource-group "$TARGET_RG" --name "$SNAP_NAME" \
      --query "completionPercent" -o tsv 2>/dev/null) || PCT="?"
    echo -n "${PCT}%... "
    sleep 15
  done
done

echo ""
echo "=== All snapshots completed. ==="
echo ""

# ===========================================================================
# Phase C: Create disks and attach to test VM
# ===========================================================================
echo "=== Phase C: Creating managed disks and attaching to $TEST_VM ==="

LOCATION=$(jq -r '.vm.location' "$METADATA_FILE")

for i in $(seq 0 $((SNAP_COUNT - 1))); do
  SNAP_ID=$(jq -r ".snapshots[$i].snapshotId" "$METADATA_FILE")
  DISK_NAME=$(jq -r ".snapshots[$i].sourceDiskName" "$METADATA_FILE")
  DISK_SKU=$(jq -r ".snapshots[$i].diskSku" "$METADATA_FILE")
  DISK_SIZE=$(jq -r ".snapshots[$i].diskSizeGb" "$METADATA_FILE")
  NEW_DISK="iris-test-${DISK_NAME}"

  echo "  Creating disk $NEW_DISK ..."
  az disk create \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$TEST_RG" \
    --name "$NEW_DISK" \
    --location "$LOCATION" \
    --source "$SNAP_ID" \
    --sku "$DISK_SKU" \
    --size-gb "$DISK_SIZE" \
    -o none

  echo "  Attaching $NEW_DISK to $TEST_VM at LUN $i ..."
  az vm disk attach \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$TEST_RG" \
    --vm-name "$TEST_VM" \
    --name "$NEW_DISK" \
    --lun "$i" \
    -o none
done

echo ""
echo "=== Phase C complete. ==="
echo ""
echo "Next steps (on the test VM):"
echo "  1. sudo pvscan --cache"
echo "  2. sudo vgimportclone --basevgname vg_irisdata_test /dev/sd{c..j}"
echo "  3. sudo vgchange -ay vg_irisdata_test"
echo "  4. sudo mkdir -p /irisdb"
echo "  5. sudo mount -o nouuid /dev/vg_irisdata_test/lv_irisdb /irisdb"
echo "  6. iris start $IRIS_INSTANCE"
```

---

## Operational Notes

### Freeze duration budget

| Step | Typical duration | Notes |
|------|-----------------|-------|
| `iris freeze` | 1–3 seconds | Depends on Write Daemon buffer volume |
| `xfs_freeze -f` | < 1 second | Kernel-level, nearly instant |
| `multidisk_ia_snapshot.sh` (with `--copy-start --no-wait`) | 3–10 seconds | Parallel API calls; returns once all are accepted |
| `xfs_freeze -u` | < 1 second | |
| `iris thaw` | < 1 second | |
| **Total freeze window** | **5–15 seconds** | |

### Scheduling and retention

- Run the snapshot during a **low-write-activity window** to minimize the amount of data the Write Daemon needs to flush.
- Use consistent `--snapshot-prefix` values with timestamps to manage retention (e.g., delete snapshots older than N days).
- The `--ia-duration` should be set to cover the time between snapshot creation and test-disk creation. If you create the test disks within an hour, `--ia-duration 120` gives comfortable margin.

### LVM considerations

- **`vgimportclone`** is the safest way to import cloned PVs. It generates new VG/PV UUIDs so there is no conflict with the production VG if both VMs share a SAN or if you ever attach the disks back.
- If the test VM already has a previous clone VG (e.g., `vg_irisdata_test`), deactivate and export it first:

  ```bash
  sudo vgchange -an vg_irisdata_test
  sudo vgexport vg_irisdata_test
  ```

- On some distributions, you may need to run `sudo partprobe` or `echo 1 > /sys/bus/scsi/devices/.../rescan` to detect newly attached disks.

### XFS UUID conflict

XFS filesystems have a UUID baked into the superblock. When you mount a cloned filesystem on a machine that already has the same UUID mounted (unlikely in this scenario), use `mount -o nouuid`. This is included in the instructions as a precaution.

### IRIS configuration on the test VM

If the test IRIS instance has a **different configuration** (instance name, port, etc.), update `iris.cpf` before starting:

```bash
# Edit the CPF file to adjust database paths if needed
sudo vi /iris/sys/iris.cpf

# Update the [Databases] section to point to /irisdb/...
```

---

## Troubleshooting

### `iris freeze` hangs

The freeze waits for the Write Daemon to complete its current cycle. If it takes more than 30 seconds:

- Check for long-running transactions: `iris session IRISDB -U %SYS "do ^%SS"`
- Check disk I/O latency: `iostat -x 1 5`
- As a last resort, kill blocking processes and retry

### `xfs_freeze -f` returns an error

- Verify the filesystem is XFS: `df -T /irisdb` (should show `xfs`)
- Ensure the mount point is correct and mounted: `mountpoint /irisdb`
- Verify `xfs_freeze` is installed: `which xfs_freeze` (provided by the `xfsprogs` package)

### Snapshot creation fails with throttling

The script automatically retries throttled requests (HTTP 429) with exponential back-off. If throttling persists across all 8 attempts:

- Reduce the number of simultaneous snapshots with `--only-disks` to batch in smaller groups
- Contact Azure support to increase your subscription's snapshot API limits

### `vgimportclone` fails with "no PVs found"

- Run `sudo pvscan --cache` to refresh the PV cache
- Check that all disks are attached: `lsblk`
- Ensure the disks have LVM signatures: `sudo pvs --all`

### IRIS reports "database is corrupted" on test VM

This should not happen if the freeze/thaw procedure was followed correctly. However:

- Run `do ^INTEGRITY` from the IRIS terminal to identify affected globals
- Verify the freeze was held for the entire duration of Step 3
- Check `iris-snapshot.log` for any errors during snapshot creation
- Ensure all disks in the LVM volume group were snapshotted (check `--only-disks` was not filtering any out)
