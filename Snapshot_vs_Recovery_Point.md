# Azure Disk Snapshots vs Recovery Point Collections

A comparison of the two Azure-native approaches for capturing point-in-time copies of VM disks, and why **Recovery Point Collections** are the superior choice for multi-disk VMs using **Premium SSD v2** and **Ultra Disk** storage.

---

## Table of Contents

- [Azure Disk Snapshots vs Recovery Point Collections](#azure-disk-snapshots-vs-recovery-point-collections)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Azure Disk Snapshots](#azure-disk-snapshots)
    - [How disk snapshots work](#how-disk-snapshots-work)
    - [Strengths](#strengths)
    - [Limitations for multi-disk VMs](#limitations-for-multi-disk-vms)
  - [Recovery Point Collections](#recovery-point-collections)
    - [How recovery points work](#how-recovery-points-work)
    - [Consistency levels](#consistency-levels)
    - [Strengths](#strengths-1)
  - [Side-by-Side Comparison](#side-by-side-comparison)
  - [Why Recovery Points Are the Best Approach for PremiumV2 and Ultra Disks](#why-recovery-points-are-the-best-approach-for-premiumv2-and-ultra-disks)
    - [1. Platform-level multi-disk consistency](#1-platform-level-multi-disk-consistency)
    - [2. Single API call for all disks](#2-single-api-call-for-all-disks)
    - [3. Instant Access tier integration](#3-instant-access-tier-integration)
    - [4. No application-level freeze coordination required](#4-no-application-level-freeze-coordination-required)
    - [5. Incremental by design](#5-incremental-by-design)
  - [The Multi-Disk Consistency Problem](#the-multi-disk-consistency-problem)
    - [Disk snapshots: consistency is your responsibility](#disk-snapshots-consistency-is-your-responsibility)
    - [Recovery points: consistency is the platform's responsibility](#recovery-points-consistency-is-the-platforms-responsibility)
  - [Performance and Cost Implications](#performance-and-cost-implications)
  - [When to Use Each Approach](#when-to-use-each-approach)
    - [Use Recovery Point Collections when:](#use-recovery-point-collections-when)
    - [Use individual Disk Snapshots when:](#use-individual-disk-snapshots-when)
    - [Use `multidisk_ia_snapshot.sh` with application freeze when:](#use-multidisk_ia_snapshotsh-with-application-freeze-when)
  - [Recovery Points with PremiumV2 and Ultra Disk: What Changed](#recovery-points-with-premiumv2-and-ultra-disk-what-changed)
  - [Summary](#summary)

---

## Overview

Azure provides two mechanisms for capturing point-in-time copies of managed disks:

| Mechanism | Scope | Consistency guarantee | API surface |
|-----------|-------|----------------------|-------------|
| **Disk Snapshot** (`Microsoft.Compute/snapshots`) | Single disk | Individual disk only — no cross-disk coordination | One `az snapshot create` per disk |
| **Recovery Point** (`Microsoft.Compute/restorePointCollections/restorePoints`) | Entire VM (all disks) | All disks captured atomically in a single platform operation | One `az restore-point create` for all disks |

Both produce incremental, copy-on-write copies of disk data. The critical difference is **scope**: a disk snapshot operates on one disk at a time, while a recovery point captures **all disks attached to a VM as a single atomic unit**.

---

## Azure Disk Snapshots

### How disk snapshots work

A disk snapshot (`az snapshot create --source <disk-id>`) creates a read-only, incremental copy of a single managed disk at the moment the API call is processed by the Azure storage platform.

```
VM
├── OS Disk ──────► az snapshot create ──► snapshot-osdisk
├── Data Disk 1 ──► az snapshot create ──► snapshot-disk1    (separate API call)
├── Data Disk 2 ──► az snapshot create ──► snapshot-disk2    (separate API call)
└── Data Disk 3 ──► az snapshot create ──► snapshot-disk3    (separate API call)
```

Each `az snapshot create` is an **independent operation**. The platform has no awareness that these snapshots are related or that they should represent the same point in time.

### Strengths

- **Simple** — one command, one disk, one snapshot.
- **Flexible** — you can snapshot any subset of disks, target different resource groups, and apply different settings per snapshot.
- **Scriptable** — straightforward to automate with tools like `multidisk_ia_snapshot.sh`.
- **Granular control** — individual snapshots can be deleted, copied across regions, or shared independently.

### Limitations for multi-disk VMs

- **No atomic multi-disk capture** — each snapshot is a separate API call. Even with parallel execution, there is a window (milliseconds to seconds) between when the platform processes each call. For databases or applications with write-ahead logs spanning multiple disks, this can result in an inconsistent capture.
- **Consistency is caller-owned** — to achieve multi-disk consistency, the caller must freeze the application (e.g., `iris freeze`) and filesystem (e.g., `xfs_freeze -f`) before issuing the snapshot calls, then thaw afterwards. This adds complexity, operational risk, and a brief I/O pause.
- **No built-in grouping** — there is no platform-level record that a set of snapshots belongs together. You must track the relationship yourself (e.g., via naming conventions, tags, or a metadata file).
- **Multiple API calls scale linearly** — a VM with 16 data disks requires 16 separate `az snapshot create` invocations, each subject to independent throttling and failure.

---

## Recovery Point Collections

### How recovery points work

A **Recovery Point Collection** (`Microsoft.Compute/restorePointCollections`) is a container resource associated with a specific VM. Within it, you create **Recovery Points** — each one captures the state of **all disks** attached to the VM in a single, atomic platform operation.

```
VM (with 8 data disks)
│
└──► az restore-point create ──► Recovery Point (single API call)
       ├── disk-snapshot: OS Disk
       ├── disk-snapshot: Data Disk 1
       ├── disk-snapshot: Data Disk 2
       ├── disk-snapshot: Data Disk 3
       ├── disk-snapshot: Data Disk 4
       ├── disk-snapshot: Data Disk 5
       ├── disk-snapshot: Data Disk 6
       ├── disk-snapshot: Data Disk 7
       └── disk-snapshot: Data Disk 8
```

The Azure platform coordinates the point-in-time capture across **all disks simultaneously** at the storage layer. From the caller's perspective, it is a single API call.

### Consistency levels

Recovery points support two consistency levels:

| Level | How it works | When to use |
|-------|-------------|-------------|
| **Crash-consistent** | The platform captures all disks at the exact same storage-layer point in time. Equivalent to pulling the power cord — all writes that reached the disk are captured, in-flight writes are not. | Databases and applications that can recover from a crash (most modern databases with WAL/journaling) |
| **Application-consistent** | The platform invokes the VM's guest agent (or VSS on Windows) to quiesce the application before capturing the disks. On Linux, this can trigger pre/post scripts. | Applications that require explicit flush before snapshot (e.g., legacy databases without crash recovery) |

### Strengths

- **Atomic multi-disk capture** — all disks are captured at the same point in time by the platform. No application-level freeze is needed for crash-consistent captures.
- **Single API call** — one `az restore-point create` regardless of how many disks the VM has.
- **Built-in grouping** — the recovery point is a first-class Azure resource that logically groups all disk snapshots. No need for naming conventions or metadata files to track relationships.
- **Incremental** — each recovery point stores only the changed blocks since the previous recovery point in the same collection, minimizing storage costs.
- **Platform-managed consistency** — the storage platform ensures the point-in-time is identical across all disks. There is zero skew.
- **Instant Access support** — recovery points for PremiumV2 and Ultra disks use the same instant-access storage tier as individual snapshots, enabling near-instant disk creation from the recovery point.

---

## Side-by-Side Comparison

| Capability | Disk Snapshots | Recovery Point Collections |
|-----------|---------------|---------------------------|
| **Scope** | Single disk | All VM disks (atomic) |
| **API calls for 8 disks** | 8 separate calls | 1 call |
| **Multi-disk consistency** | Caller must coordinate (freeze/thaw) | Platform-guaranteed |
| **Point-in-time skew** | Milliseconds to seconds (even with parallel) | **Zero** (same storage-layer instant) |
| **Application freeze required** | Yes, for consistency across disks | No (crash-consistent) or via guest agent (app-consistent) |
| **Incremental** | Yes | Yes (within collection) |
| **Instant Access tier** | Yes (per snapshot) | Yes (per recovery point) |
| **Grouping / relationship tracking** | Manual (tags, naming, metadata file) | Automatic (recovery point resource) |
| **Selective disk snapshot** | Yes (any subset) | No (all disks or exclude list) |
| **Cross-region copy** | Yes (per snapshot) | Yes (replicate collection) |
| **Throttling surface** | N API calls = N throttle checks | 1 API call = 1 throttle check |
| **Failure blast radius** | Individual — one disk can fail, others succeed | All-or-nothing — the recovery point succeeds or fails as a unit |
| **Granular retention** | Per snapshot | Per recovery point (all disks together) |
| **PremiumV2 / Ultra support** | Yes (incremental required) | Yes (incremental, instant access) |
| **Azure CLI** | `az snapshot create` | `az restore-point create` |
| **REST API** | `Microsoft.Compute/snapshots` | `Microsoft.Compute/restorePointCollections/restorePoints` |

---

## Why Recovery Points Are the Best Approach for PremiumV2 and Ultra Disks

### 1. Platform-level multi-disk consistency

PremiumV2 and Ultra Disk workloads are typically high-performance databases (IRIS, SQL Server, Oracle, SAP HANA) that spread data across **many disks** for IOPS and throughput. These databases have strict requirements about cross-disk consistency — a write-ahead log on disk A must be consistent with the data files on disks B through H.

With **disk snapshots**, achieving this consistency requires:
1. Freezing the application (e.g., `iris freeze`)
2. Freezing the filesystem (e.g., `xfs_freeze -f`)
3. Issuing all snapshot API calls (hoping they all succeed)
4. Thawing everything

With **recovery points**, the platform captures all disks at the **exact same storage-layer instant**. No freeze is needed for crash-consistent captures. The database simply recovers from the crash-consistent state on startup (using its journal/WAL), exactly as it would after a power failure.

### 2. Single API call for all disks

A VM with 8–16 PremiumV2 data disks requires 8–16 individual `az snapshot create` calls. Each call is subject to:
- Azure API throttling (HTTP 429)
- Independent failure
- Network latency variation

A recovery point is a **single API call** that the platform decomposes internally. Throttling is checked once. The operation succeeds or fails atomically — there are no partial snapshots to clean up.

### 3. Instant Access tier integration

When a recovery point is created for PremiumV2 or Ultra disks, the snapshot data is stored in the **instant-access tier** automatically. This means:

- Creating managed disks from the recovery point completes in **seconds**, not minutes.
- The instant-access duration applies to **all disks in the recovery point** uniformly — no risk of some disks having instant access while others have expired.
- The cost model is the same as individual instant-access snapshots, but management is simpler.

### 4. No application-level freeze coordination required

For **crash-consistent** recovery points, the platform handles everything. Modern databases like InterSystems IRIS, SQL Server, PostgreSQL, and MySQL all have crash recovery mechanisms (write-ahead logging, journaling) that can recover from a crash-consistent snapshot without data loss.

This eliminates:
- The `iris freeze` / `iris thaw` window
- The `xfs_freeze -f` / `xfs_freeze -u` window
- The risk of a deadlock or timeout during the freeze
- The operational complexity of coordinating freeze/snapshot/thaw in the correct order

> **When is the application freeze still needed?** Only when you require **application-consistent** recovery points for applications that do not have crash recovery, or when you want to guarantee zero recovery time (no WAL replay) on restore. For most modern database workloads, crash-consistent is sufficient and preferred for its simplicity.

### 5. Incremental by design

Recovery points within a collection are **automatically incremental** — each new recovery point stores only the blocks that changed since the previous one. For PremiumV2 and Ultra disks that may be terabytes in size, this is critical for both **cost** and **speed**:

| Recovery point | Data captured |
|---------------|--------------|
| RP-1 (first) | Full copy of all disks |
| RP-2 | Only blocks changed since RP-1 |
| RP-3 | Only blocks changed since RP-2 |
| ... | Incremental delta only |

With individual disk snapshots, incremental behaviour works per-disk but there is no cross-disk incremental relationship. Recovery point collections maintain the incremental chain across **all disks as a group**.

---

## The Multi-Disk Consistency Problem

### Disk snapshots: consistency is your responsibility

Consider a database with its write-ahead log (WAL/journal) on Disk 1 and data files on Disks 2–8. If the snapshots are not perfectly simultaneous:

```
Timeline ──────────────────────────────────────────────►

Disk 1 (WAL):    ──── write A ────── write B ──────────
Disk 2 (data):   ──── write A' ───────────── write B' ─
                         ▲                       ▲
                    snap-disk1               snap-disk2
                    (captures A)             (captures A' and B')
```

Disk 1's snapshot has WAL entry A but not B. Disk 2's snapshot has data from both A' and B'. On restore, the database sees data (B') that the WAL does not account for — this is **corruption**.

**Mitigation with disk snapshots:** Freeze the application and filesystem before snapshotting. `multidisk_ia_snapshot.sh` does this using parallel execution to minimize the freeze window, but the freeze is still required.

### Recovery points: consistency is the platform's responsibility

```
Timeline ──────────────────────────────────────────────►

Disk 1 (WAL):    ──── write A ────── write B ──────────
Disk 2 (data):   ──── write A' ───────────── write B' ─
                              ▲
                         Recovery Point
                    (captures both disks at this exact instant)
```

The platform captures all disks at the **same storage-layer instant**. Either both A and A' are captured, or both A+B and A'+B' are captured — never a mix. The database WAL and data files are always consistent with each other.

---

## Performance and Cost Implications

| Factor | Disk Snapshots (8 disks) | Recovery Point |
|--------|------------------------|----------------|
| **API calls** | 8 (parallelizable) | 1 |
| **Time to initiate** | 5–15 seconds (parallel) | 1–3 seconds |
| **Application freeze window** | 5–15 seconds | 0 seconds (crash-consistent) |
| **Throttling risk** | 8× higher (8 separate calls) | Minimal (1 call) |
| **Failure handling** | Must handle partial failures (some disks succeeded, some failed) | Atomic — all or nothing |
| **Storage cost** | Incremental per disk | Incremental per collection (similar cost) |
| **Instant Access** | Per snapshot, set individually | Per recovery point, uniform |
| **Restore complexity** | Parse metadata file, create 8 disks individually | Extract disk snapshots from recovery point, create disks |
| **Management overhead** | Track 8 snapshots (naming, tags, metadata) | Track 1 recovery point |

---

## When to Use Each Approach

### Use Recovery Point Collections when:

- The VM has **multiple data disks** that must be consistent (databases, clustered storage)
- You are using **PremiumV2_LRS** or **UltraSSD_LRS** disks
- You want **zero application downtime** during snapshot (crash-consistent)
- You want **simplified management** — one resource represents the entire VM state
- You are building automated backup/clone pipelines and want **atomic success/failure**
- You want **platform-managed incremental chains** across all disks

### Use individual Disk Snapshots when:

- You need to snapshot a **subset of disks** (e.g., only 2 of 8 data disks)
- You need **different settings per disk** (e.g., different IA durations, different target resource groups)
- You need to **copy snapshots across regions individually** (recovery point replication is collection-level)
- You are snapshotting a **single-disk VM** (no consistency concern)
- You need **independent lifecycle management** per disk snapshot (different retention per disk)
- You are working with tooling that requires `Microsoft.Compute/snapshots` resources (some third-party backup solutions)

### Use `multidisk_ia_snapshot.sh` with application freeze when:

- Recovery points are not available for your scenario (e.g., API constraints, specific compliance requirements)
- You need **fine-grained control** over each snapshot's configuration
- You need **metadata file output** for downstream automation
- You want **application-consistent** snapshots without relying on the VM guest agent

---


## Recovery Points with PremiumV2 and Ultra Disk: What Changed

Before instant-access snapshot support for PremiumV2 and Ultra disks, recovery points for these SKUs had significant limitations:

| Capability | Before (standard snapshots) | Now (instant-access snapshots) |
|-----------|---------------------------|-------------------------------|
| **Snapshot type** | Full copy (slow) | Incremental with instant access |
| **Recovery point creation time** | Minutes (full copy per disk) | Seconds (copy-on-write) |
| **Disk creation from recovery point** | Minutes to hours (hydration required) | Seconds (instant access tier) |
| **Incremental chain** | Not supported for PV2/Ultra | Fully supported |
| **Practical disk count** | Limited by sequential copy time | 16+ disks in a single recovery point |

With instant-access snapshots, recovery points for PremiumV2 and Ultra disks now offer:

1. **Near-instant creation** — the recovery point is captured using copy-on-write at the storage layer. Even for multi-terabyte disks, the point-in-time is captured in seconds.

2. **Near-instant restore** — creating managed disks from the recovery point's disk restore points uses the instant-access tier. Disks are available in seconds, not minutes.

3. **Efficient incremental chains** — successive recovery points in the same collection store only changed blocks. For a database that changes 5% of its data between snapshots, the incremental cost is 5% of the total disk size, regardless of how many disks the VM has.

4. **True multi-disk atomicity** — combined with the platform's atomic capture, this means you get the **speed of instant-access snapshots** with the **consistency of a platform-coordinated multi-disk operation**. No application freeze, no filesystem freeze, no scripting complexity — just a single API call.

This is why, for production PremiumV2 and Ultra Disk workloads with multiple data disks, **Recovery Point Collections are the recommended approach**. They deliver the same instant-access performance as individual snapshots while solving the multi-disk consistency problem at the platform level.

---

## Summary

| | Disk Snapshots | Recovery Point Collections |
|---|---|---|
| **Best for** | Single-disk VMs, selective snapshots, granular control | Multi-disk VMs, databases, atomic consistency |
| **PremiumV2 / Ultra** | Works (with scripting and freeze) | **Recommended** (native, atomic, instant access) |
| **Consistency** | Caller-managed | Platform-managed |
| **Operational complexity** | Higher (freeze/thaw, parallel scripts, metadata tracking) | Lower (single API call, built-in grouping) |
| **Downtime** | 5–15 seconds (with parallel + freeze) | **Zero** (crash-consistent) |

For multi-disk PremiumV2 and Ultra Disk VMs — particularly database workloads like InterSystems IRIS, SQL Server, or SAP HANA — **Recovery Point Collections with crash-consistent recovery points** are the most efficient, consistent, and operationally simple approach to snapshotting.
